package render

import "core:os"
import "core:dynlib"

import vk "vendor:vulkan"
import gpu "./no_graphics_api"

// :VulkanRenderer: The platform should own shader loading and expose the paths
// through the game/platform API rather than this renderer-owned config.
Shader_Path :: struct { vertex: string, fragment: string }

ZBias := Shader_Path {
    #config(Path_z_bias_vertex,            "unset"),
    #config(Path_z_bias_fragment,          "unset"),
}
PeelComposite := Shader_Path {
    #config(Path_peel_composite_vertex,   "unset"),
    #config(Path_peel_composite_fragment, "unset"),
}
MultisampleResolve := Shader_Path {
    #config(Path_multisample_resolve_vertex,     "unset"),
    #config(Path_multisample_resolve_fragment,   "unset"),
}

FinalStretch := Shader_Path {
    #config(Path_final_stretch_vertex,   "unset"),
    #config(Path_final_stretch_fragment, "unset"),
}

MultigridLightUp := Shader_Path {
    #config(Path_multigrid_light_up_vertex,   "unset"),
    #config(Path_multigrid_light_up_fragment, "unset"),
}

MultigridLightDown := Shader_Path {
    #config(Path_multigrid_light_down_vertex,   "unset"),
    #config(Path_multigrid_light_down_fragment, "unset"),
}

DepthPeelToLighting := Shader_Path {
    #config(Path_depth_peel_to_lighting_vertex,   "unset"),
    #config(Path_depth_peel_to_lighting_fragment, "unset"),
}

////////////////////////////////////////////////

frame_data_heap_size     :: 32 * Megabyte
texture_upload_heap_size :: 64 * Megabyte
texture_heap_size        ::  2 * Gigabyte
frames_in_flight         :: 2
max_depth_peels          :: 4

max_vulkan_textures :: 256

Debug_vulkan_depth_peel_index: i32 = -1 // -1 composites all layers

Vulkan :: struct {
    settings: RenderSettings,
    
    device: gpu.Device,
    
    frames: [frames_in_flight] Frame,
    next_frame_index: u32,

    texture_upload_heap:      gpu.GpuHeap,
    texture_upload_allocator: gpu.BumpAllocator,
    
    texture_heap:      gpu.TextureHeap,
    texture_allocator: gpu.TextureAllocator,
    sample_count: u32,
    
    texture_descriptor_heap: gpu.TextureDescriptorHeap,
    sampler_descriptor_heap: gpu.SamplerDescriptorHeap,
    
    latest_completion: gpu.TimelinePoint,
    
    zbias_pso:                  gpu.PSO,
    multisampled_zbias_pso:     gpu.PSO,
    multisample_resolve_pso:    gpu.PSO,
    peel_composite_pso:         gpu.PSO,
    final_stretch_pso:          gpu.PSO,
    multigrid_light_up_pso:     gpu.PSO,
    multigrid_light_down_pso:   gpu.PSO,
    depth_peel_to_lighting_pso: gpu.PSO,
    
    textures: [1 + cast(u32) TextureDescriptor.count] gpu.PlacedTexture,
    next_texture:  u32,
    free_texture: [dynamic; TextureDescriptor.count] u32,
    
    depth_peel_buffers:         [dynamic; max_depth_peels] DepthPeelBuffer,
    depth_peel_resolve_buffers: [dynamic; max_depth_peels] DepthPeelBuffer,
    composite_buffer:           RenderTarget,
    
    light_buffers: [dynamic; 10] VulkanLightBuffer,
    debug_light_buffer_index:   i32,
    debug_light_buffer_texture: i32,
}

Frame :: struct {
    heap:       gpu.GpuHeap,
    allocator:  gpu.BumpAllocator,
    completion: gpu.TimelinePoint,
}

RenderTarget :: struct {
    placed:      gpu.PlacedTexture,
    render_view: gpu.RenderView,
    descriptor:  u32,
}

// @todo if we really only want to specify textured oriented quads there should be a compacter way then sending the vertices like this right?
// @todo is Textured_Vertex.color ever varied across a single quad?

FrameUploads :: struct {
    vertices: gpu.GpuCpuRange(Textured_Vertex),
    textures: gpu.GpuCpuRange(u32),
}

////////////////////////////////////////////////

// @volatile see shared.slang
depth_peel_and_resolve_target_stride :: 1 + len(PeelColorKind)
depth_peel_and_resolve_target_count  :: max_depth_peels * depth_peel_and_resolve_target_stride

light_buffer_stride :: len(LightBufferKind)
light_buffer_count  :: 10 * light_buffer_stride

// @volatile see shared.slang
TextureDescriptor :: enum u32 {
    nil_texture = 0,
    
    depth_peel_begin,
    depth_peel_end = depth_peel_begin + depth_peel_and_resolve_target_count,
    
    resolve_begin,
    resolve_end = resolve_begin + depth_peel_and_resolve_target_count,
    
    composite,
    
    light_buffer_begin,
    light_buffer_end = light_buffer_begin + light_buffer_count,
    
    first_dynamic_texture,
    count = first_dynamic_texture + max_vulkan_textures,
}

// @volatile see shared.slang
LightBufferKind :: enum u32 {
    front_emission  = 0,
    back_emission   = 1,
    surface_color   = 2,
    normal_xy_depth = 3,
}

// :VulkanSamplers: Keep these slots matched with shared.slang.
Sampler :: enum u32 {
    Linear  = 0,
    Nearest = 1,
}

DepthPeelBuffer :: struct {
    // @note allocation order must match this ordering
    depth: RenderTarget,
    color: [PeelColorKind] RenderTarget,
}

// @volatile see shared.slang
PeelColorKind :: enum u8 {
    // @todo It's worth thinking about making it so there's only one rgb stored here, and then an emission power value instead of storing the emission separately?
    surface_reflect = 0, // @note reflect rgb, coverage a
    emission        = 1, // @note emission rgb, spread a
    normal_lp       = 2, // @note nx, ny @todo lp0, lp1 are unused
}

VulkanLightBuffer :: [LightBufferKind] RenderTarget

////////////////////////////////////////////////

// :VulkanRenderer: Generate the Slang declarations from the Odin definitions.
// Keep these in lockstep with the C-layout SPIR-V declarations in vulkan.slang.
//
// These Roots as well as Textured_Vertex:
//

RootZBias :: struct /* #all_or_none */ {
    projection:       m4,
    vertices:         [^] Textured_Vertex,
    textures:         [^] u32,
    camera_p:         v3,
    light_p:          v3,
    fog_direction:    v3,
    fog_color:        v3,
    fog_begin:        f32,
    fog_end:          f32,
    clip_alpha_begin: f32,
    clip_alpha_end:   f32,
    vertex_base:      u32,
    previous_depth:   u32,
    alpha_threshold:  f32,
    _padding: u32,
}

// @todo compress descriptors
RootPeelComposite :: struct #all_or_none {
    peels:                 [max_depth_peels] u32,
    npls:                  [max_depth_peels] u32,
    light_normal_xy_depth: u32,
    light_emission:        u32,
    peel_count:            u32,
}

RootMultisampleResolve :: struct #all_or_none {
    peel_index:   u32,
    sample_count: u32,
}

RootFinalStretch :: struct #all_or_none {
    texture: u32,
    sampler: Sampler,
}

RootMultigridLightUp :: struct #all_or_none {
    source_index:    u32,
}

RootMultigridLightDown :: struct #all_or_none {
    parent_index: u32,
    our_index:    u32,
}

RootDepthPeelToLighting :: struct #all_or_none {
    source_resolve_buffer: u32,
}

////////////////////////////////////////////////

init_vulkan :: proc (vulkan: ^Vulkan, window: pmm) {
    device, error := gpu.create_device(window = window, swapchain_format = .bgra8_srgb, desired_swapchain_image_count = frames_in_flight)
    assert(error == .none && device != nil)
    
    vulkan.device = device
    
    vulkan.latest_completion = gpu.TimelinePoint { semaphore = gpu.create_timeline_semaphore(device) }
    for &frame in vulkan.frames {
        frame.heap      = gpu.create_gpu_heap(device, frame_data_heap_size)
        frame.allocator = gpu.bump_allocator(frame.heap.range)
        frame.completion.semaphore = vulkan.latest_completion.semaphore
    }

    vulkan.texture_upload_heap      = gpu.create_gpu_heap(device, texture_upload_heap_size)
    vulkan.texture_upload_allocator = gpu.bump_allocator(vulkan.texture_upload_heap.range)
    
    vulkan.texture_descriptor_heap = gpu.create_texture_descriptor_heap(device, cast(u32) TextureDescriptor.count)
    vulkan.sampler_descriptor_heap = gpu.create_sampler_descriptor_heap(device, len(Sampler))
    
    vulkan.texture_heap      = gpu.create_texture_heap(device, texture_heap_size)
    vulkan.texture_allocator = gpu.texture_allocator(device, vulkan.texture_heap, cast(u32) TextureDescriptor.count)
    
    vulkan.next_texture = cast(u32) TextureDescriptor.first_dynamic_texture
    gpu.write_sampler_descriptor(vulkan.sampler_descriptor_heap, cast(u32) Sampler.Linear, min_filter = .linear, mag_filter = .linear, address_u = .clamp_to_edge, address_v = .clamp_to_edge)
    gpu.write_sampler_descriptor(vulkan.sampler_descriptor_heap, cast(u32) Sampler.Nearest, min_filter = .nearest, mag_filter = .nearest, address_u = .clamp_to_edge, address_v = .clamp_to_edge)
    
    create_psos(vulkan)
}

create_psos :: proc (vulkan: ^Vulkan) {
    cleanup: [dynamic; 128] [] u8
    read_path :: proc (path: Shader_Path, cleanup: ^[dynamic; 128] [] u8) -> ([] u8, [] u8) {
        vertex   := read_vulkan_spirv(path.vertex)
        fragment := read_vulkan_spirv(path.fragment)
        
        append(cleanup, vertex, fragment)
        
        return vertex, fragment
    }
    
    zbias_vertex,                  zbias_fragment                  := read_path(ZBias,              &cleanup)
    peel_composite_vertex,         peel_composite_fragment         := read_path(PeelComposite,      &cleanup)
    multisample_resolve_vertex,    multisample_resolve_fragment    := read_path(MultisampleResolve, &cleanup)
    final_stretch_vertex,          final_stretch_fragment          := read_path(FinalStretch,       &cleanup)
    multigrid_light_up_vertex,     multigrid_light_up_fragment     := read_path(MultigridLightUp,   &cleanup)
    multigrid_light_down_vertex,   multigrid_light_down_fragment   := read_path(MultigridLightDown, &cleanup)
    depth_peel_to_lighting_vertex, depth_peel_to_lighting_fragment := read_path(DepthPeelToLighting, &cleanup)
    
    defer for slice in cleanup {
        delete(slice)
    }
    
    gpu.destroy_pso(vulkan.zbias_pso)
    gpu.destroy_pso(vulkan.peel_composite_pso)
    gpu.destroy_pso(vulkan.multisample_resolve_pso)
    gpu.destroy_pso(vulkan.final_stretch_pso)
    gpu.destroy_pso(vulkan.multigrid_light_up_pso)
    gpu.destroy_pso(vulkan.multigrid_light_down_pso)
    gpu.destroy_pso(vulkan.depth_peel_to_lighting_pso)
    
    vulkan.zbias_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = zbias_vertex,
        fragment_spirv = zbias_fragment,
        color_targets  = { 
            gpu.color_target_desc(format = .bgra8_srgb),
            gpu.color_target_desc(format = .rgba8_unorm),
            gpu.color_target_desc(format = .rgba8_unorm),
        },
        depth_format   = .d32_float,
        rasterization  = { cull = .counter_clockwise },
    )
    
    vulkan.peel_composite_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = peel_composite_vertex,
        fragment_spirv = peel_composite_fragment,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
    )
    
    vulkan.multisample_resolve_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = multisample_resolve_vertex,
        fragment_spirv = multisample_resolve_fragment,
        color_targets  = { 
            gpu.color_target_desc(format = .bgra8_srgb),
            gpu.color_target_desc(format = .rgba8_unorm),
            gpu.color_target_desc(format = .rgba8_unorm),
        },
        depth_format   = .d32_float,
    )
    
    vulkan.final_stretch_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = final_stretch_vertex,
        fragment_spirv = final_stretch_fragment,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
    )
    
    vulkan.multigrid_light_up_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = multigrid_light_up_vertex,
        fragment_spirv = multigrid_light_up_fragment,
        color_targets  = { 
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
        },
    )
        
    vulkan.multigrid_light_down_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = multigrid_light_down_vertex,
        fragment_spirv = multigrid_light_down_fragment,
        color_targets  = {
            gpu.color_target_desc(format = .rgba32_float, blend = gpu.blend_state(enabled = true, color = {.one, .one, .add})),
            gpu.color_target_desc(format = .rgba32_float, blend = gpu.blend_state(enabled = true, color = {.one, .one, .add})),
        },
    )
    
    // @todo I already had bugs, where the declaration and usage in begin_rendering did not match, i.e. formats and target count. how can this kind of bug be prevented.
    vulkan.depth_peel_to_lighting_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = depth_peel_to_lighting_vertex,
        fragment_spirv = depth_peel_to_lighting_fragment,
        color_targets  = { 
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
        },
    )
}

////////////////////////////////////////////////

vk_allocate_texture :: proc (vulkan: ^Vulkan, bitmap: Bitmap, set_as_nil_texture := false) -> u32 {
    timed_function()
    
    placed := gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
        extent = { **cast(uv2) bitmap.dimension, 1 },
        format = .rgba8_srgb,
        usage  = { .sampled, .transfer_destination },
    ))
    assert(placed.texture != nil)
    
    descriptor_index: u32
    if set_as_nil_texture {
        descriptor_index = cast(u32) TextureDescriptor.nil_texture
    } else {
        descriptor_index = allocate_texture_descriptor(vulkan)
    }
    gpu.write_texture_descriptor(vulkan.texture_descriptor_heap, descriptor_index, placed.texture, .sampled)
    
    texture_bytes := slice_to_bytes(bitmap.memory)
    upload        := gpu.bump_allocate(&vulkan.texture_upload_allocator, len(texture_bytes))
    copy(upload.cpu, texture_bytes)
    
    commands := gpu.begin_commands(vulkan.device)
    
    gpu.copy_memory_to_texture(commands, gpu.gpu_range(upload), placed.texture)
    
    gpu.barrier(commands, { .transfer }, { .transfer_write }, { .fragment }, { .shader_read })
    
    vulkan.latest_completion.value += 1
    gpu.submit({ commands }, vulkan.latest_completion)
    
    result := 1 + descriptor_index
    vulkan.textures[result] = placed
    
    return result
}

vk_manage_textures :: proc (vulkan: ^Vulkan, last: ^TextureOp) {
    timed_function()
    debug_data_block("Renderer")
    debug_data_block("texture operations")
    
    allocs, deallocs: i32

    // :VulkanRenderer: Texture destruction is immediate in NoGraphicsAPI.
    // Wait for every submitted frame before changing shared texture allocations.
    if vulkan.latest_completion.value != 0 {
        timed_block("wait before texture allocation")
        gpu.wait_timeline(vulkan.latest_completion)
    }
    gpu.bump_reset(&vulkan.texture_upload_allocator)
    
    for operation := last; operation != nil; operation = operation.next {
        switch &op in operation.value {
        case: unreachable()
        
        case TextureOpAllocate:
            allocs += 1
            op.result ^= vk_allocate_texture(vulkan, op.bitmap)
            
        case TextureOpDeallocate:
            deallocs += 1
            
            assert(op.handle > cast(u32) TextureDescriptor.first_dynamic_texture)
            texture := &vulkan.textures[op.handle]
            assert(texture.texture != nil)
            gpu.texture_free(&vulkan.texture_allocator, texture)
            texture^ = {}
            append(&vulkan.free_texture, op.handle - 1)
        }
    }
    
    count := allocs + deallocs
    render_state.game.debug_record_i32(&count, "count")
    render_state.game.debug_record_i32(&allocs, "allocations")
    render_state.game.debug_record_i32(&deallocs, "deallocations")
}

////////////////////////////////////////////////

vk_render_commands :: proc (vulkan: ^Vulkan, render_commands: ^RenderCommands, draw_region: Rectangle2i, window_dim: v2i) {
    timed_function()
    
    if render_commands.settings != vulkan.settings {
        change_to_settings(vulkan, render_commands.settings)
    }
    
    render_state.game.begin_timed_block("acquire frame")
    render_frame := gpu.acquire(vulkan.device)
    render_state.game.end_timed_block()
    if render_frame.render_view == nil { return }

    frame_index := vulkan.next_frame_index
    vulkan.next_frame_index = (frame_index + 1) % cast(u32) frames_in_flight
    frame := &vulkan.frames[frame_index]
    if frame.completion.value != 0 { 
        timed_block("wait before render commands")
        gpu.wait_timeline(frame.completion)
    }
    
    render_extent := cast(uv2) render_commands.dimension
    depth_peel_count := cast(u32) len(vulkan.depth_peel_buffers)
    
    uploads := upload_frame_data(render_commands, frame)
    
    render_state.game.begin_timed_block("begin commands")
    commands := gpu.begin_commands(vulkan.device)
    gpu.set_texture_descriptor_heap(commands, vulkan.texture_descriptor_heap)
    gpu.set_sampler_descriptor_heap(commands, vulkan.sampler_descriptor_heap)
    render_state.game.end_timed_block()
    
    ////////////////////////////////////////////////
    
    // @cleanup
    debug_setup: ^RenderSetup
    
    peel_index: u32
    peel_header_restore: int
    begin_depth_peel_pass(vulkan, commands, peel_index, .clear, render_commands.clear_color)
    
    for begin_reading(&render_commands.push_buffer); can_read(&render_commands.push_buffer); {
        type := read(&render_commands.push_buffer, RenderEntryType)
        
        switch type^ {
        case .None: unreachable()
        case .DepthClear:
            timed_block("depth clear")
            gpu.end_render_pass(commands)
            begin_depth_peel_pass(vulkan, commands, peel_index, .load)
            
        case .BeginPeels:
            timed_block("begin peels")
            peel_header_restore = render_commands.push_buffer.read_cursor
            
        case .EndPeels:
            timed_block("end peels")
            end_depth_peel_pass(vulkan, commands, peel_index, &frame.allocator)
            
            if peel_index < depth_peel_count - 1 {
                render_commands.push_buffer.read_cursor = peel_header_restore
                peel_index += 1
                
                begin_depth_peel_pass(vulkan, commands, peel_index, .clear, render_commands.clear_color)
            } else {
                peel_index = 0
                begin_depth_peel_pass(vulkan, commands, peel_index, .load)
            }
            
        case .Textured_Quads:
            timed_block("textured quads")
            entry := read(&render_commands.push_buffer, Textured_Quads)
            if entry.quad_count == 0 { continue }
            
            setup := &entry.setup
            render_rect := rectangle_zero_min_dimension(render_commands.dimension)
            clip := get_intersection(setup.clip_rect, render_rect)
            if !has_area(clip) { continue }
            
            gpu.set_viewport(commands, 0, 0, cast(f32) render_extent.x, cast(f32) render_extent.y)
            dim := get_dimension(clip)
            scissor_y := cast(i32) render_extent.y - clip.max.y
            gpu.set_scissor(commands, clip.min.x, scissor_y, cast(u32) dim.x, cast(u32) dim.y)
            
            if debug_setup == nil {
                debug_setup = setup
            }
            
            root := gpu.bump_allocate(&frame.allocator, RootZBias)
            root.cpu^ = {
                projection       = setup.projection,
                vertices         = uploads.vertices.gpu,
                textures         = &uploads.textures.gpu[entry.bitmap_offset],
                camera_p         = setup.camera_p,
                light_p          = setup.debug_light_p,
                fog_direction    = setup.fog_direction,
                fog_color        = setup.fog_color,
                fog_begin        = setup.fog_begin,
                fog_end          = setup.fog_end,
                clip_alpha_begin = setup.clip_alpha_begin,
                clip_alpha_end   = setup.clip_alpha_end,
                vertex_base      = entry.bitmap_offset * 4,
                previous_depth   = peel_index != 0 ? get_depth_peel_read_buffer(vulkan, peel_index-1).depth.descriptor : 0,
                alpha_threshold  = peel_index != 0 && peel_index == depth_peel_count - 1 ? 0.9 : 0.02,
            }
            gpu.draw(commands, root.gpu, entry.quad_count * 6)
        }
    }
    
    end_depth_peel_pass(vulkan, commands, peel_index, &frame.allocator)
    
    ////////////////////////////////////////////////
    
    // compute_light_transport(vulkan, commands, frame)
    
    // gpu.barrier(commands, { .color_output }, { .color_write }, { .fragment }, { .shader_read }) // @todo real barrier
    
    ////////////////////////////////////////////////
    
    {
        timed_block("peel composite")
        
        gpu.begin_render_pass(commands, colors = { gpu.color_attachment(render_view = vulkan.composite_buffer.render_view, load = .clear, clear = render_commands.clear_color) })
        
        gpu.bind_pso(commands, vulkan.peel_composite_pso)
        root := gpu.bump_allocate(&frame.allocator, RootPeelComposite)
        root.cpu^ = {}
        
        root.cpu.light_emission        = vulkan.light_buffers[0][.front_emission].descriptor
        root.cpu.light_normal_xy_depth = vulkan.light_buffers[0][.normal_xy_depth].descriptor
        
        if Debug_vulkan_depth_peel_index >= 0 {
            Debug_vulkan_depth_peel_index = clamp(Debug_vulkan_depth_peel_index, 0, cast(i32) depth_peel_count-1)
            
            root.cpu.peel_count = 1
            
            peel_buffer := get_depth_peel_read_buffer(vulkan, cast(u32) Debug_vulkan_depth_peel_index)
            root.cpu.peels[0] = peel_buffer.color[.surface_reflect].descriptor
            root.cpu.npls[0]  = peel_buffer.color[.normal_lp].descriptor
        } else {
            root.cpu.peel_count = depth_peel_count
            
            for index in 0 ..< cast(u32) len(vulkan.depth_peel_buffers) {
                buffer := get_depth_peel_read_buffer(vulkan, index)
                root.cpu.peels[index] = buffer.color[.surface_reflect].descriptor
                root.cpu.npls[index]  = buffer.color[.normal_lp].descriptor
            }
        }
        
        gpu.draw(commands, root.gpu, 3)
        
        gpu.end_render_pass(commands)
    }
    
    gpu.barrier(commands, { .color_output }, { .color_write }, { .fragment }, { .shader_read })
    
    {
        timed_block("final stretch")
        
        gpu.begin_render_pass(commands, colors = { gpu.color_attachment(render_view = render_frame.render_view, load = .clear) })
        gpu.bind_pso(commands, vulkan.final_stretch_pso)
        
        draw_dim := get_dimension(draw_region)
        draw_y := window_dim.y - draw_region.max.y
        gpu.set_viewport(commands, cast(f32) draw_region.min.x, cast(f32) draw_y, cast(f32) draw_dim.x, cast(f32) draw_dim.y)
        gpu.set_scissor(commands, draw_region.min.x, draw_y, cast(u32) draw_dim.x, cast(u32) draw_dim.y)
        
        root := gpu.bump_allocate(&frame.allocator, RootFinalStretch)
        root.cpu^ = {
            texture = vulkan.composite_buffer.descriptor,
            sampler = render_commands.pixelation_hint ? .Nearest : .Linear,
        }
        gpu.draw(commands, root.gpu, 3)
        
        gpu.end_render_pass(commands)
    }
    
    vulkan.debug_light_buffer_index   = clamp(vulkan.debug_light_buffer_index, 0, cast(i32) len(vulkan.light_buffers)-1)
    vulkan.debug_light_buffer_texture = clamp(vulkan.debug_light_buffer_texture, 0, 4)
    
    if vulkan.debug_light_buffer_texture > 0  {
        gpu.barrier(commands, { .color_output }, { .color_write }, { .fragment }, { .shader_read }) // @todo real barrier
        
        gpu.begin_render_pass(commands, colors = { gpu.color_attachment(render_view = render_frame.render_view, load = .clear) })
        gpu.bind_pso(commands, vulkan.final_stretch_pso)
        
        index := cast(u32) vulkan.debug_light_buffer_index
        texture: u32
        switch vulkan.debug_light_buffer_texture - 1 {
        case 0: texture = vulkan.light_buffers[index][.front_emission].descriptor
        case 1: texture = vulkan.light_buffers[index][.back_emission].descriptor
        case 2: texture = vulkan.light_buffers[index][.surface_color].descriptor
        case 3: texture = vulkan.light_buffers[index][.normal_xy_depth].descriptor
        }
        
        root := gpu.bump_allocate(&frame.allocator, RootFinalStretch)
        root.cpu^ = { texture = texture, sampler = .Nearest }
        gpu.draw(commands, root.gpu, 3)
        
        gpu.end_render_pass(commands)
    }
    
    render_state.game.begin_timed_block("submit and present")
    vulkan.latest_completion.value += 1
    frame.completion = vulkan.latest_completion
    gpu.submit_and_present(vulkan.device, { commands }, vulkan.latest_completion)
    render_state.game.end_timed_block()
}

////////////////////////////////////////////////

compute_light_transport :: proc (vulkan: ^Vulkan, commands: gpu.CommandBuffer, frame: ^Frame) {
    //
    // @note The hare-brained scheme below! Not for the faint of heart.
    //
    
    // @note Import depth peel results.
    {
        gpu.barrier(commands, { .fragment }, { .shader_read, .shader_write }) // @todo real masks
        
        // @todo This probably needs to use all 4 depth peels, eventually.
        source      := &vulkan.depth_peel_resolve_buffers[0]
        destination := &vulkan.light_buffers[0]
        
        gpu.begin_render_pass(commands, colors = {
            gpu.color_attachment(render_view = destination[.front_emission].render_view,  load = .discard),
            gpu.color_attachment(render_view = destination[.back_emission].render_view,   load = .discard),
            gpu.color_attachment(render_view = destination[.surface_color].render_view,   load = .discard),
            gpu.color_attachment(render_view = destination[.normal_xy_depth].render_view, load = .discard),
        })
        
        gpu.bind_pso(commands, vulkan.depth_peel_to_lighting_pso)
        
        root := gpu.bump_allocate(&frame.allocator, RootDepthPeelToLighting)
        root.cpu^ = { source_resolve_buffer = 0 }
        
        gpu.draw(commands, root.gpu, 3)
        
        gpu.end_render_pass(commands)
    }
    
    // @note Upward phase - build  successfully less detailed light buffers.
    for destination_index in 1..<len(vulkan.light_buffers) {
        source_index := destination_index - 1
        
        destination := &vulkan.light_buffers[destination_index]
        
        if destination_index == 1 {
            gpu.barrier(commands, { .fragment, .color_output }, { .shader_read, .shader_write, .color_write }, { .fragment }, { .shader_read, .shader_write }) // @todo real masks
        } else {
            gpu.barrier(commands, { .fragment }, { .shader_read, .shader_write }) // @todo real masks
        }
        // @todo when are these cleared? in fake seed lighting its fully cleared and filled
        gpu.begin_render_pass(commands, colors = { 
            gpu.color_attachment(render_view = destination[.front_emission].render_view,  load = .load),
            gpu.color_attachment(render_view = destination[.back_emission].render_view,   load = .load),
            gpu.color_attachment(render_view = destination[.surface_color].render_view,   load = .load),
            gpu.color_attachment(render_view = destination[.normal_xy_depth].render_view, load = .load),
        })
        
        gpu.bind_pso(commands, vulkan.multigrid_light_up_pso)
        
        root := gpu.bump_allocate(&frame.allocator, RootMultigridLightUp)
        root.cpu^ = { source_index = cast(u32) source_index }
        
        gpu.draw(commands, root.gpu, 3)
        
        gpu.end_render_pass(commands)
    }
    
    // @note Downward phase - transfer light from less-detailed light buffers to higher-detailed ones.
    for source_index := len(vulkan.light_buffers)-1; source_index >= 1; source_index -= 1 {
        destination_index := source_index - 1
        
        destination := &vulkan.light_buffers[destination_index]
        
        gpu.barrier(commands, { .fragment }, { .shader_read, .shader_write }) // @todo real masks
        gpu.begin_render_pass(commands, colors = {
            gpu.color_attachment(render_view = destination[.front_emission].render_view, load = .load),
            gpu.color_attachment(render_view = destination[.back_emission].render_view,  load = .load),
        })
        
        gpu.bind_pso(commands, vulkan.multigrid_light_down_pso)
        
        root := gpu.bump_allocate(&frame.allocator, RootMultigridLightDown)
        root.cpu^ = {
            parent_index = cast(u32) source_index,
            our_index    = cast(u32) destination_index,
        }
        gpu.draw(commands, root.gpu, 3)
        
        gpu.end_render_pass(commands)
    }
}

////////////////////////////////////////////////

upload_frame_data :: proc (render_commands: ^RenderCommands, frame: ^Frame) -> FrameUploads {
    timed_function()
    
    debug_data_block("Renderer")
    debug_data_block("frame uploads")
    
    gpu.bump_reset(&frame.allocator)
    
    result: FrameUploads
    {
        timed_block("copy textured vertices")
        
        count := cast(i32) len(render_commands.vertex_buffer)
        render_state.game.debug_record_i32(&count, "vertex count")
        
        result.vertices = gpu.bump_allocate(&frame.allocator, [] Textured_Vertex, len(render_commands.vertex_buffer))
        copy(result.vertices.cpu, render_commands.vertex_buffer[:])
    }
    
    {
        timed_block("copy texture descriptors")
        
        count := cast(i32) len(render_commands.quad_bitmap_buffer)
        render_state.game.debug_record_i32(&count, "bitmap count")
        
        result.textures = gpu.bump_allocate(&frame.allocator, [] u32, len(render_commands.quad_bitmap_buffer))
        for bitmap, index in render_commands.quad_bitmap_buffer {
            texture_handle := max(0, bitmap.texture_handle-1)
            result.textures.cpu[index] = texture_handle
        }
    }
    return result
}

change_to_settings :: proc (vulkan: ^Vulkan, settings: RenderSettings) {
    timed_function()
    if vulkan.latest_completion.value != 0 { 
        timed_block("wait before graphics settings change")
        gpu.wait_timeline(vulkan.latest_completion)
    }
    depth_peel_count := clamp(settings.depth_peel_count_hint, 1, cap(vulkan.depth_peel_buffers))
    
    render_dim := uv3 { cast(u32) settings.dimension.x, cast(u32) settings.dimension.y, 1 } 
    {
        timed_block("recreate_depth_peel_targets")
        
        destroy_all_render_targets(vulkan)
        
        gpu.destroy_pso(vulkan.multisampled_zbias_pso)
        vulkan.multisampled_zbias_pso = nil
        vulkan.sample_count = 1
        
        if settings.multisampling_hint {
            peel_color_desc := gpu.texture_desc(
                extent = render_dim,
                format = .bgra8_srgb,
                usage  = { .sampled, .color_attachment },
            )
            
            peel_depth_desc := gpu.texture_desc(
                extent = render_dim,
                format = .d32_float,
                usage  = { .sampled, .depth_stencil_attachment },
            )
            
            sample_counts := [?] u32 { 8, 4, 2 }
            for candidate in sample_counts {
                if candidate > MaxMultisampleCount { continue }
                peel_color_desc.sample_count = candidate
                peel_depth_desc.sample_count = candidate
                if gpu.supports_texture_sample_count(vulkan.device, peel_color_desc) && gpu.supports_texture_sample_count(vulkan.device, peel_depth_desc) {
                    vulkan.sample_count = candidate
                    break
                }
            }
        }
        
        resize(&vulkan.depth_peel_buffers,         depth_peel_count)
        resize(&vulkan.depth_peel_resolve_buffers, vulkan.sample_count > 1 ? depth_peel_count : 0)
        for &buffer, index in vulkan.depth_peel_buffers {
            descriptor := cast(u32) TextureDescriptor.depth_peel_begin + cast(u32) index * depth_peel_and_resolve_target_stride
            
            buffer.depth = create_render_target(vulkan, gpu.texture_desc(
                extent = render_dim,
                format = .d32_float,
                usage  = { .sampled, .depth_stencil_attachment },
                sample_count = vulkan.sample_count,
            ), descriptor + 0)
            
            for &target, target_index in buffer.color {
                target = create_render_target(vulkan, gpu.texture_desc(
                        extent = render_dim,
                        format = (target_index == .surface_reflect) ? .bgra8_srgb : .rgba8_unorm,
                        usage  = { .sampled, .color_attachment },
                        sample_count = vulkan.sample_count,
                    ), descriptor + 1 + cast(u32) target_index)
            }
        }
        
        if vulkan.sample_count > 1 {
            for &buffer, index in vulkan.depth_peel_resolve_buffers {
                descriptor := cast(u32) TextureDescriptor.resolve_begin + cast(u32) index * depth_peel_and_resolve_target_stride
                
                buffer.depth = create_render_target(vulkan, gpu.texture_desc(
                    extent = render_dim,
                    format = .d32_float,
                    usage  = { .sampled, .depth_stencil_attachment },
                    sample_count = 1,
                ), descriptor + 0)
                
                for &target, target_index in buffer.color {
                    target = create_render_target(vulkan, gpu.texture_desc(
                        extent = render_dim,
                        format = (target_index == .surface_reflect) ? .bgra8_srgb : .rgba8_unorm,
                        usage  = { .sampled, .color_attachment },
                        sample_count = 1,
                    ), descriptor + 1 + cast(u32) target_index)
                }
            }
        }
        
        vulkan.composite_buffer = create_render_target(vulkan, gpu.texture_desc(
                extent = render_dim,
                format = .bgra8_srgb,
                usage  = { .sampled, .color_attachment },
                sample_count = 1,
            ), cast(u32) TextureDescriptor.composite)
            
        if vulkan.sample_count > 1 {
            // @cleanup
            vertex   := read_vulkan_spirv(ZBias.vertex)
            fragment := read_vulkan_spirv(ZBias.fragment)
            vulkan.multisampled_zbias_pso = gpu.create_graphics_pso(vulkan.device,
                vertex_spirv   = vertex,
                fragment_spirv = fragment,
                color_targets  = { 
                    gpu.color_target_desc(format = .bgra8_srgb),
                    gpu.color_target_desc(format = .rgba8_unorm),
                    gpu.color_target_desc(format = .rgba8_unorm),
                },
                depth_format   = .d32_float,
                rasterization  = { cull = .counter_clockwise },
                sample_count   = vulkan.sample_count,
            )
            delete(vertex)
            delete(fragment)
        }
        
        light_buffer_dim : uv2
        light_buffer_dim.x = 1 << find_most_significant_bit(render_dim.x)
        light_buffer_dim.y = 1 << find_most_significant_bit(render_dim.y)
        
        light_buffer_descriptor := cast(u32) TextureDescriptor.light_buffer_begin
        for light_buffer_dim.x > 1 && light_buffer_dim.y > 1 && len(vulkan.light_buffers) < cap(vulkan.light_buffers) {
            buffer := append_into(&vulkan.light_buffers)
            
            // @note Drop these down to f16 once we know what's what and probably use rgb8 for surface_color? And normal_xy_and_depth could probably be encoded in rgb8?
            desc := gpu.texture_desc(
                extent = { light_buffer_dim.x, light_buffer_dim.y, 1 },
                format = .rgba32_float,
                usage  = { .sampled, .color_attachment },
            )
            
            before := light_buffer_descriptor
            for &target in buffer {
                target = create_render_target(vulkan, desc, light_buffer_descriptor)
                light_buffer_descriptor += 1
            }
            assert(light_buffer_descriptor == before + 4)
            
            light_buffer_dim.xy = (light_buffer_dim.xy + 1) / 2
            if light_buffer_dim.x < 1 { light_buffer_dim.x = 1 }
            if light_buffer_dim.y < 1 { light_buffer_dim.y = 1 }
        }
        assert(len(vulkan.light_buffers) <= 10)
    }
    vulkan.settings = settings
}

////////////////////////////////////////////////

read_vulkan_spirv :: proc (path: string) -> [] u8 {
    // :VulkanRenderer: Move this through the platform API with the other file IO.
    bytes, error := os.read_entire_file(path, context.allocator)
    assert(error == nil)
    assert(len(bytes) % size_of(u32) == 0)
    return bytes
}

create_render_target :: proc (vulkan: ^Vulkan, desc: gpu.TextureDesc, index: u32) -> RenderTarget {
    result := RenderTarget {
        placed     = gpu.texture_allocate(&vulkan.texture_allocator, desc),
        descriptor = index,
    }
    assert(result.placed.texture != nil)
    
    result.render_view = gpu.create_render_view(result.placed.texture)
    gpu.write_texture_descriptor(vulkan.texture_descriptor_heap, index, result.placed.texture, .sampled)
    
    return result
}

destroy_render_target :: proc (vulkan: ^Vulkan, target: ^RenderTarget) {
    gpu.destroy_render_view(target.render_view)
    gpu.texture_free(&vulkan.texture_allocator, &target.placed)
    target^ = {}
}

get_depth_peel_read_buffer :: proc (vulkan: ^Vulkan, index: u32) -> ^DepthPeelBuffer {
    result := &vulkan.depth_peel_buffers[index]
    if vulkan.sample_count > 1 {
        result = &vulkan.depth_peel_resolve_buffers[index]
    }
    return result
}

begin_depth_peel_pass :: proc (vulkan: ^Vulkan, commands: gpu.CommandBuffer, peel_index: u32, color_load: gpu.LoadOp, render_commands_clear_color: v4 = {}) {
    timed_function()
    
    depth_peel_count := cast(u32) len(vulkan.depth_peel_buffers)
    
    clear_color: v4
    if color_load == .clear && peel_index == depth_peel_count - 1 {
        clear_color = render_commands_clear_color
        clear_color.a = 1
    }
    
    buffer := vulkan.depth_peel_buffers[peel_index]
    gpu.begin_render_pass(commands,
        colors = {
            gpu.color_attachment(render_view = buffer.color[.surface_reflect].render_view, load = color_load, clear = clear_color),
            gpu.color_attachment(render_view = buffer.color[.emission].render_view,        load = color_load, clear = 0),
            gpu.color_attachment(render_view = buffer.color[.normal_lp].render_view,       load = color_load, clear = 0),
        },
        depth = gpu.depth_attachment(render_view = buffer.depth.render_view, load = .clear),
    )
    gpu.set_depth_stencil(commands, depth_test = true, depth_write = true)
    gpu.bind_pso(commands, vulkan.sample_count == 1 ? vulkan.zbias_pso : vulkan.multisampled_zbias_pso)
}

end_depth_peel_pass :: proc (vulkan: ^Vulkan, commands: gpu.CommandBuffer, peel_index: u32, allocator: ^gpu.BumpAllocator) {
    gpu.end_render_pass(commands)
    gpu.barrier(commands, { .color_output, .depth_stencil_tests }, { .color_write, .depth_stencil_write }, { .fragment }, { .shader_read })
    if vulkan.sample_count == 1 { return }
    
    from := vulkan.depth_peel_buffers[peel_index]
    to   := vulkan.depth_peel_resolve_buffers[peel_index]
    
    gpu.begin_render_pass(commands,
        colors = {
            gpu.color_attachment(render_view = to.color[.surface_reflect].render_view, load = .discard),
            gpu.color_attachment(render_view = to.color[.emission].render_view,        load = .discard),
            gpu.color_attachment(render_view = to.color[.normal_lp].render_view,       load = .discard),
        },
        depth = gpu.depth_attachment(render_view = to.depth.render_view, load = .discard),
    )
    
    gpu.set_depth_stencil(commands, depth_test = true, depth_write = true, depth_compare = .always)
    gpu.bind_pso(commands, vulkan.multisample_resolve_pso)
    
    root := gpu.bump_allocate(allocator, RootMultisampleResolve)
    root.cpu^ = {
        peel_index   = peel_index,
        sample_count = vulkan.sample_count,
    }
    
    gpu.draw(commands, root.gpu, 3)
    
    gpu.end_render_pass(commands)
    
    gpu.barrier(commands, { .color_output, .depth_stencil_tests }, { .color_write, .depth_stencil_write }, { .fragment }, { .shader_read })
}

allocate_texture_descriptor :: proc (vulkan: ^Vulkan) -> u32 {
    last_free := len(vulkan.free_texture)-1
    index: u32
    if last_free >= 0 {
        index = vulkan.free_texture[last_free]
        resize(&vulkan.free_texture, last_free)
    } else {
        assert(vulkan.next_texture < cast(u32) TextureDescriptor.count)
        
        index = vulkan.next_texture
        vulkan.next_texture += 1
    }
    
    return index
}

////////////////////////////////////////////////

destroy_all_render_targets :: proc (vulkan: ^Vulkan) {
    for &buffer in vulkan.depth_peel_buffers {
        for &target in buffer.color {
            destroy_render_target(vulkan, &target)
        }
        destroy_render_target(vulkan, &buffer.depth)
    }
    
    for &buffer in vulkan.depth_peel_resolve_buffers {
        for &target in buffer.color {
            destroy_render_target(vulkan, &target)
        }
        destroy_render_target(vulkan, &buffer.depth)
    }
    
    for &buffer in vulkan.light_buffers {
        for &target in buffer {
            destroy_render_target(vulkan, &target)
        }
    }
    
    destroy_render_target(vulkan, &vulkan.composite_buffer)
}

////////////////////////////////////////////////

vk_reload :: proc (vulkan: ^Vulkan) {
    device := vulkan.device
    if device != nil && device.debug_messenger != 0 && device.destroy_debug_messenger != nil {
        device.destroy_debug_messenger(device.instance, device.debug_messenger, nil)
        device.debug_messenger = 0
    }
}

vk_shutdown :: proc (vulkan: ^Vulkan) {
    device := vulkan.device
    if device == nil { return }
    
    gpu.wait_idle(device)
    
    destroy_all_render_targets(vulkan)
    
    for &texture in vulkan.textures[1:] {
        gpu.texture_free(&vulkan.texture_allocator, &texture)
    }
    
    gpu.destroy_pso(vulkan.zbias_pso)
    gpu.destroy_pso(vulkan.multisampled_zbias_pso)
    gpu.destroy_pso(vulkan.multisample_resolve_pso)
    gpu.destroy_pso(vulkan.peel_composite_pso)
    gpu.destroy_pso(vulkan.final_stretch_pso)
    gpu.destroy_timeline_semaphore(vulkan.latest_completion.semaphore)
    
    for &frame in vulkan.frames {
        gpu.destroy_gpu_heap(frame.heap)
    }
    gpu.destroy_gpu_heap(vulkan.texture_upload_heap)
    gpu.destroy_texture_descriptor_heap(vulkan.texture_descriptor_heap)
    gpu.destroy_sampler_descriptor_heap(vulkan.sampler_descriptor_heap)
    gpu.destroy_texture_heap(vulkan.texture_heap)
    
    gpu.destroy_device(device)
}

vk_reattach :: proc (vulkan: ^Vulkan) -> bool {
    device := vulkan.device
    if device == nil { return false }
    
    address, found := dynlib.symbol_address(cast(dynlib.Library) device.vulkan_library, "vkGetInstanceProcAddr", allocator = context.temp_allocator)
    if !found { return false }
    
    vk.load_proc_addresses_global(address)
    vk.load_proc_addresses_instance(device.instance)
    vk.load_proc_addresses_device(device.device)
    
    gpu.wait_idle(vulkan.device)
    
    create_psos(vulkan)
    
    device.destroy_debug_messenger = auto_cast vk.GetInstanceProcAddr(device.instance, "vkDestroyDebugUtilsMessengerEXT")
    result := vk.CmdBindResourceHeapEXT != nil && vk.CmdBindSamplerHeapEXT != nil && vk.CmdPushDataEXT != nil
    return result
}