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

FakeSeedLighting := Shader_Path {
    #config(Path_fake_seed_lighting_vertex,   "unset"),
    #config(Path_fake_seed_lighting_fragment, "unset"),
}

MultigridLightUp := Shader_Path {
    #config(Path_multigrid_light_up_vertex,   "unset"),
    #config(Path_multigrid_light_up_fragment, "unset"),
}

MultigridLightDown := Shader_Path {
    #config(Path_multigrid_light_down_vertex,   "unset"),
    #config(Path_multigrid_light_down_fragment, "unset"),
}

////////////////////////////////////////////////

frame_data_heap_size     :: 32 * Megabyte
texture_upload_heap_size :: 64 * Megabyte
texture_heap_size        ::  1 * Gigabyte
VulkanFrameCount         :: 2
VulkanDepthPeelCount     :: 4

max_vulkan_textures :: 256

Debug_vulkan_depth_peel_index: i32 = -1 // -1 composites all layers

Vulkan :: struct {
    settings: RenderSettings,
    
    device: gpu.Device,
    
    frames: [VulkanFrameCount] Frame,
    next_frame_index: u32,

    texture_upload_heap:      gpu.GpuHeap,
    texture_upload_allocator: gpu.BumpAllocator,
    
    texture_heap:      gpu.TextureHeap,
    texture_allocator: gpu.TextureAllocator,
    sample_count: u32,
    
    texture_descriptor_heap: gpu.TextureDescriptorHeap,
    sampler_descriptor_heap: gpu.SamplerDescriptorHeap,
    
    latest_completion: gpu.TimelinePoint,
    
    quad_pso:                 gpu.PSO,
    multisample_quad_pso:     gpu.PSO,
    resolve_pso:              gpu.PSO,
    composite_pso:            gpu.PSO,
    final_pso:                gpu.PSO,
    fake_seed_pso:            gpu.PSO,
    multigrid_light_up_pso:   gpu.PSO,
    multigrid_light_down_pso: gpu.PSO,
    
    textures: [1 + cast(u32) VulkanTextureDescriptor.count] gpu.PlacedTexture,
    next_texture_descriptor:  u32,
    free_texture_descriptors: [dynamic; VulkanTextureDescriptor.count] u32,
    
    depth_peel_buffers:         [dynamic; VulkanDepthPeelCount] Depth_Peel_Buffer,
    depth_peel_resolve_buffers: [dynamic; VulkanDepthPeelCount] Depth_Peel_Buffer,
    composite_buffer:           Render_Target,
    
    light_buffers: [dynamic; 12] VulkanLightBuffer,
    debug_light_buffer_index:   i32,
    debug_light_buffer_texture: i32,
}

VulkanTextureDescriptor :: enum u32 {
    nil_texture,
    depth_peel_0_color,
    depth_peel_0_depth,
    depth_peel_1_color,
    depth_peel_1_depth,
    depth_peel_2_color,
    depth_peel_2_depth,
    depth_peel_3_color,
    depth_peel_3_depth,
    resolve_depth_peel_0_color,
    resolve_depth_peel_0_depth,
    resolve_depth_peel_1_color,
    resolve_depth_peel_1_depth,
    resolve_depth_peel_2_color,
    resolve_depth_peel_2_depth,
    resolve_depth_peel_3_color,
    resolve_depth_peel_3_depth,
    composite,
    light_buffer_begin,
    light_buffer_end = light_buffer_begin+10*4, // @cleanup
    first_dynamic_texture,
    count = first_dynamic_texture + max_vulkan_textures,
}

// :VulkanSamplers: Keep these slots matched with shared.slang.
Sampler :: enum u32 {
    Linear  = 0,
    Nearest = 1,
}

Frame :: struct {
    heap:       gpu.GpuHeap,
    allocator:  gpu.BumpAllocator,
    completion: gpu.TimelinePoint,
}


Depth_Peel_Buffer :: struct {
    color: Render_Target,
    depth: Render_Target,
}

VulkanLightBuffer :: struct {
    front_emission:      Render_Target,
    back_emission:       Render_Target,
    surface_color:       Render_Target,
    normal_xz_and_depth: Render_Target,
}

Render_Target :: struct {
    placed:           gpu.PlacedTexture,
    render_view:      gpu.RenderView,
    descriptor_index: u32,
}

Frame_Uploads :: struct {
    vertices:            gpu.GpuCpuRange(Textured_Vertex),
    texture_descriptors: gpu.GpuCpuRange(u32),
}

////////////////////////////////////////////////

// :VulkanRenderer: Generate the Slang declarations from the Odin definitions.
// Keep these in lockstep with the C-layout SPIR-V declarations in vulkan.slang.
//
// These Roots as well as Textured_Vertex:
//

RootQuads :: struct {
    projection:                m4,
    vertices:                  [^] Textured_Vertex,
    texture_descriptors:       [^] u32,
    camera_p:                  v3,
    light_p: v3,
    fog_direction:             v3,
    fog_color:                 v3,
    fog_begin:                 f32,
    fog_end:                   f32,
    clip_alpha_begin:          f32,
    clip_alpha_end:            f32,
    vertex_base:               u32,
    previous_depth_descriptor: u32,
    alpha_threshold:           f32,
    _padding: u32,
}

RootPeelComposite :: struct {
    texture_descriptors: [VulkanDepthPeelCount] u32,
    peel_count:          u32,
}

RootResolve :: struct {
    color_descriptor: u32,
    depth_descriptor: u32,
    sample_count:     u32,
}

RootFinalStretch :: struct {
    texture_descriptor: u32,
    sampler_descriptor: Sampler,
}

RootFakeSeedLighting :: struct {
    light_p: v3,
}

RootMultigridLightUp :: struct {
    front_emission:      u32,
    back_emission:       u32,
    surface_color:       u32,
    normal_xz_and_depth: u32,
}

RootMultigridLightDown :: struct {
    
}

////////////////////////////////////////////////

init_vulkan :: proc (vulkan: ^Vulkan, window: pmm) {
    device, error := gpu.create_device(window = window, swapchain_format = .bgra8_srgb, desired_swapchain_image_count = VulkanFrameCount)
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
    
    vulkan.texture_descriptor_heap = gpu.create_texture_descriptor_heap(device, cast(u32) VulkanTextureDescriptor.count)
    vulkan.sampler_descriptor_heap = gpu.create_sampler_descriptor_heap(device, len(Sampler))
    
    vulkan.texture_heap      = gpu.create_texture_heap(device, texture_heap_size)
    vulkan.texture_allocator = gpu.texture_allocator(device, vulkan.texture_heap, cast(u32) VulkanTextureDescriptor.count)
    
    vulkan.next_texture_descriptor = cast(u32) VulkanTextureDescriptor.first_dynamic_texture
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
    
    zbias_vertex,                zbias_fragment                := read_path(ZBias,              &cleanup)
    peel_composite_vertex,       peel_composite_fragment       := read_path(PeelComposite,      &cleanup)
    multisample_resolve_vertex,  multisample_resolve_fragment  := read_path(MultisampleResolve, &cleanup)
    final_stretch_vertex,        final_stretch_fragment        := read_path(FinalStretch,       &cleanup)
    fake_seed_lighting_vertex,   fake_seed_lighting_fragment   := read_path(FakeSeedLighting,   &cleanup)
    multigrid_light_up_vertex,   multigrid_light_up_fragment   := read_path(MultigridLightUp,   &cleanup)
    // multigrid_light_down_vertex, multigrid_light_down_fragment := read_path(MultigridLightDown, &cleanup)
    
    defer for slice in cleanup {
        delete(slice)
    }
    
    gpu.destroy_pso(vulkan.quad_pso)
    gpu.destroy_pso(vulkan.composite_pso)
    gpu.destroy_pso(vulkan.resolve_pso)
    gpu.destroy_pso(vulkan.final_pso)
    gpu.destroy_pso(vulkan.fake_seed_pso)
    gpu.destroy_pso(vulkan.multigrid_light_up_pso)
    gpu.destroy_pso(vulkan.multigrid_light_down_pso)
    
    vulkan.quad_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = zbias_vertex,
        fragment_spirv = zbias_fragment,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
        depth_format   = .d32_float,
        rasterization  = { cull = .counter_clockwise },
    )
    
    vulkan.composite_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = peel_composite_vertex,
        fragment_spirv = peel_composite_fragment,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
    )
    
    vulkan.resolve_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = multisample_resolve_vertex,
        fragment_spirv = multisample_resolve_fragment,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
        depth_format   = .d32_float,
    )
    
    vulkan.final_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = final_stretch_vertex,
        fragment_spirv = final_stretch_fragment,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
    )
    
    vulkan.fake_seed_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = fake_seed_lighting_vertex,
        fragment_spirv = fake_seed_lighting_fragment,
        color_targets  = { 
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
        },
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
    
    /*
    vulkan.multigrid_light_down_pso = gpu.create_graphics_pso(vulkan.device,
        vertex_spirv   = multigrid_light_down_vertex,
        fragment_spirv = multigrid_light_down_fragment,
        color_targets  = {
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
        },
    )
    */
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
        descriptor_index = cast(u32) VulkanTextureDescriptor.nil_texture
    } else {
        descriptor_index = allocate_texture_descriptor(vulkan)
    }
    gpu.write_texture_descriptor(vulkan.texture_descriptor_heap, descriptor_index, placed.texture, .sampled)
    
    texture_bytes := slice_to_bytes(bitmap.memory)
    upload := gpu.bump_allocate(&vulkan.texture_upload_allocator, len(texture_bytes))
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
    
    allocs, deallocs: u32

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
            
            assert(op.handle > cast(u32) VulkanTextureDescriptor.first_dynamic_texture)
            texture := &vulkan.textures[op.handle]
            assert(texture.texture != nil)
            gpu.texture_free(&vulkan.texture_allocator, texture)
            texture^ = {}
            append(&vulkan.free_texture_descriptors, op.handle - 1)
        }
    }
    
    count := cast(i32) (allocs + deallocs)
    render_state.game.debug_record_i32(&count, "count")
    allocations := cast(i32) allocs
    render_state.game.debug_record_i32(&allocations, "allocations")
    deallocations := cast(i32) deallocs
    render_state.game.debug_record_i32(&deallocations, "deallocations")
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
    vulkan.next_frame_index = (frame_index + 1) % cast(u32) VulkanFrameCount
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
            
            root := gpu.bump_allocate(&frame.allocator, RootQuads)
            root.cpu^ = {
                projection                = setup.projection,
                vertices                  = uploads.vertices.gpu,
                texture_descriptors       = &uploads.texture_descriptors.gpu[entry.bitmap_offset],
                camera_p                  = setup.camera_p,
                light_p                   = setup.debug_light_p,
                fog_direction             = setup.fog_direction,
                fog_color                 = setup.fog_color,
                fog_begin                 = setup.fog_begin,
                fog_end                   = setup.fog_end,
                clip_alpha_begin          = setup.clip_alpha_begin,
                clip_alpha_end            = setup.clip_alpha_end,
                vertex_base               = entry.bitmap_offset * 4,
                previous_depth_descriptor = peel_index != 0 ? vk_get_depth_peel_read_buffer(vulkan, peel_index-1).depth.descriptor_index : 0,
                alpha_threshold           = peel_index != 0 && peel_index == depth_peel_count - 1 ? 0.9 : 0.02,
            }
            gpu.draw(commands, root.gpu, entry.quad_count * 6)
        }
    }
    
    end_depth_peel_pass(vulkan, commands, peel_index, &frame.allocator)
    
    ////////////////////////////////////////////////
    
    {
        timed_block("peel composite")
        
        gpu.begin_render_pass(commands, colors = { gpu.color_attachment(render_view = vulkan.composite_buffer.render_view, load = .clear, clear = render_commands.clear_color) })
        
        gpu.bind_pso(commands, vulkan.composite_pso)
        root := gpu.bump_allocate(&frame.allocator, RootPeelComposite)
        root.cpu^ = {}
        
        if Debug_vulkan_depth_peel_index >= 0 {
            debug_peel_index := min(cast(u32) Debug_vulkan_depth_peel_index, depth_peel_count-1)
            root.cpu.texture_descriptors[0] = vk_get_depth_peel_read_buffer(vulkan, debug_peel_index).color.descriptor_index
            root.cpu.peel_count = 1
        } else {
            for index in 0 ..< cast(u32) len(vulkan.depth_peel_buffers) {
                root.cpu.texture_descriptors[index] = vk_get_depth_peel_read_buffer(vulkan, index).color.descriptor_index
            }
            root.cpu.peel_count = depth_peel_count
        }
        
        gpu.draw(commands, root.gpu, 3)
        
        gpu.end_render_pass(commands)
    }
    
    gpu.barrier(commands, { .color_output }, { .color_write }, { .fragment }, { .shader_read })
    
    {
        timed_block("final stretch")
        
        if true {
            if debug_setup != nil {
                fake_seed_lighting(vulkan, commands, frame, debug_setup^)
            }
            
            compute_light_transport(vulkan, commands, frame)
            
            gpu.begin_render_pass(commands, colors = { gpu.color_attachment(render_view = render_frame.render_view, load = .clear) })
            gpu.bind_pso(commands, vulkan.final_pso)
            
            vulkan.debug_light_buffer_index   = clamp(vulkan.debug_light_buffer_index, 0, cast(i32) len(vulkan.light_buffers)-1)
            vulkan.debug_light_buffer_texture = clamp(vulkan.debug_light_buffer_texture, 0, 3)
            
            index := cast(u32) vulkan.debug_light_buffer_index
            texture: u32
            switch vulkan.debug_light_buffer_texture {
            case 0: texture = vulkan.light_buffers[index].front_emission.descriptor_index
            case 1: texture = vulkan.light_buffers[index].back_emission.descriptor_index
            case 2: texture = vulkan.light_buffers[index].surface_color.descriptor_index
            case 3: texture = vulkan.light_buffers[index].normal_xz_and_depth.descriptor_index
            }
            
            root := gpu.bump_allocate(&frame.allocator, RootFinalStretch)
            root.cpu^ = { texture_descriptor = texture, sampler_descriptor = .Nearest }
            gpu.draw(commands, root.gpu, 3)
            
            gpu.end_render_pass(commands)
        } else {
            gpu.begin_render_pass(commands, colors = { gpu.color_attachment(render_view = render_frame.render_view, load = .clear) })
            gpu.bind_pso(commands, vulkan.final_pso)
            
            draw_dim := get_dimension(draw_region)
            draw_y := window_dim.y - draw_region.max.y
            gpu.set_viewport(commands, cast(f32) draw_region.min.x, cast(f32) draw_y, cast(f32) draw_dim.x, cast(f32) draw_dim.y)
            gpu.set_scissor(commands, draw_region.min.x, draw_y, cast(u32) draw_dim.x, cast(u32) draw_dim.y)
            
            root := gpu.bump_allocate(&frame.allocator, RootFinalStretch)
            root.cpu^ = {
                texture_descriptor = vulkan.composite_buffer.descriptor_index,
                sampler_descriptor = render_commands.pixelation_hint ? .Nearest : .Linear,
            }
            gpu.draw(commands, root.gpu, 3)
     
            gpu.end_render_pass(commands)
        }
    }
    
    render_state.game.begin_timed_block("submit and present")
    vulkan.latest_completion.value += 1
    frame.completion = vulkan.latest_completion
    gpu.submit_and_present(vulkan.device, { commands }, vulkan.latest_completion)
    render_state.game.end_timed_block()
}

////////////////////////////////////////////////

fake_seed_lighting :: proc (vulkan: ^Vulkan, commands: gpu.CommandBuffer, frame: ^Frame, setup: RenderSetup) {
    gpu.barrier(commands, { .color_output }, { .color_write }, { .fragment }, { .shader_read }) // @todo real masks
    
    light_buffer := vulkan.light_buffers[0]
    
    gpu.begin_render_pass(commands, colors = { 
        gpu.color_attachment( render_view = light_buffer.front_emission.render_view,      load = .clear ),
        gpu.color_attachment( render_view = light_buffer.back_emission.render_view,       load = .clear ),
        gpu.color_attachment( render_view = light_buffer.surface_color.render_view,       load = .clear ),
        gpu.color_attachment( render_view = light_buffer.normal_xz_and_depth.render_view, load = .clear ),
    })
    
    gpu.bind_pso(commands, vulkan.fake_seed_pso)
    
    root := gpu.bump_allocate(&frame.allocator, RootFakeSeedLighting)
    root.cpu^ = { light_p = setup.debug_light_p }
    
    gpu.draw(commands, root.gpu, 6)
    
    gpu.end_render_pass(commands)
}

compute_light_transport :: proc (vulkan: ^Vulkan, commands: gpu.CommandBuffer, frame: ^Frame) {
    //
    // @note The hare-brained scheme below! Not for the faint of heart.
    //
    
    // @note Upward phase - build  successfully less detailed light buffers
    for destination_buffer_index in 1..<len(vulkan.light_buffers) {
        source_buffer_index := destination_buffer_index - 1
        
        destination_buffer := &vulkan.light_buffers[destination_buffer_index]
        source_buffer      := &vulkan.light_buffers[source_buffer_index]
        
        if destination_buffer_index == 1 {
            gpu.barrier(commands, gpu.Stages{ .fragment, .color_output }, gpu.Access{ .shader_read, .shader_write, .color_write }, { .fragment }, { .shader_read, .shader_write }) // @todo real masks
        } else {
            gpu.barrier(commands, gpu.Stages{ .fragment }, { .shader_read, .shader_write }) // @todo real masks
        }
        
        gpu.begin_render_pass(commands, colors = { 
            gpu.color_attachment( render_view = destination_buffer.front_emission.render_view,      load = .load ),
            gpu.color_attachment( render_view = destination_buffer.back_emission.render_view,       load = .load ),
            gpu.color_attachment( render_view = destination_buffer.surface_color.render_view,       load = .load ),
            gpu.color_attachment( render_view = destination_buffer.normal_xz_and_depth.render_view, load = .load ),
        })
        
        gpu.bind_pso(commands, vulkan.multigrid_light_up_pso)
        
        root := gpu.bump_allocate(&frame.allocator, RootMultigridLightUp)
        root.cpu^ = {
            front_emission      = source_buffer.front_emission.descriptor_index,
            back_emission       = source_buffer.back_emission.descriptor_index,
            surface_color       = source_buffer.surface_color.descriptor_index,
            normal_xz_and_depth = source_buffer.normal_xz_and_depth.descriptor_index,
        }
        gpu.draw(commands, root.gpu, 6)
        
        gpu.end_render_pass(commands)
    }
    
    // @note Downward phase - distribute lighting calculations
    
}

////////////////////////////////////////////////

upload_frame_data :: proc (render_commands: ^RenderCommands, frame: ^Frame) -> Frame_Uploads {
    timed_function()
    
    debug_data_block("Renderer")
    debug_data_block("frame uploads")
    
    gpu.bump_reset(&frame.allocator)
    
    result: Frame_Uploads
    {
        timed_block("copy textured vertices")
        
        count := cast(i32) len(render_commands.vertex_buffer)
        render_state.game.debug_record_i32(&count, "vertex count")
        
        if len(render_commands.vertex_buffer) != 0 {
            result.vertices = gpu.bump_allocate(&frame.allocator, [] Textured_Vertex, len(render_commands.vertex_buffer))
            copy(result.vertices.cpu, render_commands.vertex_buffer[:])
        }
    }
    
    {
        timed_block("copy texture descriptors")
        
        count := cast(i32) len(render_commands.quad_bitmap_buffer)
        render_state.game.debug_record_i32(&count, "bitmap count")
        
        if len(render_commands.quad_bitmap_buffer) != 0 {
            result.texture_descriptors = gpu.bump_allocate(&frame.allocator, [] u32, len(render_commands.quad_bitmap_buffer))
            for bitmap, index in render_commands.quad_bitmap_buffer {
                texture_handle := max(0, bitmap.texture_handle-1)
                result.texture_descriptors.cpu[index] = texture_handle
            }
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
    
    texture_dim := uv3 { cast(u32) settings.dimension.x, cast(u32) settings.dimension.y, 1 } 
    {
        timed_block("recreate_depth_peel_targets")
        for &buffer in vulkan.depth_peel_buffers {
            destroy_render_target(vulkan, &buffer.color)
            destroy_render_target(vulkan, &buffer.depth)
        }
        for &buffer in vulkan.depth_peel_resolve_buffers {
            destroy_render_target(vulkan, &buffer.color)
            destroy_render_target(vulkan, &buffer.depth)
        }
        for &buffer in vulkan.light_buffers {
            destroy_render_target(vulkan, &buffer.front_emission)
            destroy_render_target(vulkan, &buffer.back_emission)
            destroy_render_target(vulkan, &buffer.surface_color)
            destroy_render_target(vulkan, &buffer.normal_xz_and_depth)
        }
        
        destroy_render_target(vulkan, &vulkan.composite_buffer)
        
        gpu.destroy_pso(vulkan.multisample_quad_pso)
        vulkan.multisample_quad_pso = nil
        vulkan.sample_count = 1
        
        peel_color_desc := gpu.texture_desc(
            extent = texture_dim,
            format = .bgra8_srgb,
            usage  = { .sampled, .color_attachment },
        )
        peel_depth_desc := gpu.texture_desc(
            extent = texture_dim,
            format = .d32_float,
            usage  = { .sampled, .depth_stencil_attachment },
        )
        if settings.multisampling_hint {
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
        
        // @cleanup
        peel_color_desc.sample_count = vulkan.sample_count
        peel_depth_desc.sample_count = vulkan.sample_count
        resolve_color_desc := peel_color_desc
        resolve_depth_desc := peel_depth_desc
        resolve_color_desc.sample_count = 1
        resolve_depth_desc.sample_count = 1
        
        resize(&vulkan.depth_peel_buffers, depth_peel_count)
        resize(&vulkan.depth_peel_resolve_buffers, vulkan.sample_count > 1 ? depth_peel_count : 0)
        for &buffer, index in vulkan.depth_peel_buffers {
            // @cleanup
            descriptor_index := cast(u32) VulkanTextureDescriptor.depth_peel_0_color + cast(u32) index * 2
            
            buffer.color = create_render_target(vulkan, peel_color_desc, descriptor_index)
            buffer.depth = create_render_target(vulkan, peel_depth_desc, descriptor_index + 1)
            if vulkan.sample_count > 1 {
                resolve_buffer := &vulkan.depth_peel_resolve_buffers[index]
                resolve_index := cast(u32) VulkanTextureDescriptor.resolve_depth_peel_0_color + cast(u32) index * 2
                resolve_buffer.color = create_render_target(vulkan, resolve_color_desc, resolve_index)
                resolve_buffer.depth = create_render_target(vulkan, resolve_depth_desc, resolve_index + 1)
            }
        }
        
        vulkan.composite_buffer = create_render_target(vulkan, resolve_color_desc, cast(u32) VulkanTextureDescriptor.composite)
        if vulkan.sample_count > 1 {
            vertex   := read_vulkan_spirv(ZBias.vertex)
            fragment := read_vulkan_spirv(ZBias.fragment)
            vulkan.multisample_quad_pso = gpu.create_graphics_pso(vulkan.device,
                vertex_spirv   = vertex,
                fragment_spirv = fragment,
                color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
                depth_format   = .d32_float,
                rasterization  = { cull = .counter_clockwise },
                sample_count   = vulkan.sample_count,
            )
            delete(vertex)
            delete(fragment)
        }
        
        resize(&vulkan.light_buffers, 10)
        light_texture_dim := texture_dim
        for &buffer, index in vulkan.light_buffers {
            descriptor_index := cast(u32) VulkanTextureDescriptor.light_buffer_begin + cast(u32) (index*4)
            
            // @note Drop these down to f16 once we know what's what and probably use rgb8 for surface_color? And normal_xy_and_depth could probably be encoded in rgb8?
            desc := gpu.texture_desc(
                extent = light_texture_dim,
                format = .rgba32_float,
                usage = { .sampled, .color_attachment },
            )
            
            buffer.front_emission      = create_render_target(vulkan, desc, descriptor_index + 0)
            buffer.back_emission       = create_render_target(vulkan, desc, descriptor_index + 1)
            buffer.surface_color       = create_render_target(vulkan, desc, descriptor_index + 2)
            buffer.normal_xz_and_depth = create_render_target(vulkan, desc, descriptor_index + 3)
            
            // @note "up"   uses: front, back, surface and normal
            // @note "down" uses: front and back
            
            light_texture_dim.xy /= 2
            if light_texture_dim.x < 1 { light_texture_dim.x = 1 }
            if light_texture_dim.y < 1 { light_texture_dim.y = 1 }
        }
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

create_render_target :: proc (vulkan: ^Vulkan, desc: gpu.TextureDesc, descriptor_index: u32) -> Render_Target {
    result := Render_Target {
        placed           = gpu.texture_allocate(&vulkan.texture_allocator, desc),
        descriptor_index = descriptor_index,
    }
    assert(result.placed.texture != nil)
    result.render_view = gpu.create_render_view(result.placed.texture)
    gpu.write_texture_descriptor(vulkan.texture_descriptor_heap, descriptor_index, result.placed.texture, .sampled)
    return result
}

destroy_render_target :: proc (vulkan: ^Vulkan, target: ^Render_Target) {
    gpu.destroy_render_view(target.render_view)
    gpu.texture_free(&vulkan.texture_allocator, &target.placed)
    target^ = {}
}

vk_get_depth_peel_read_buffer :: proc (vulkan: ^Vulkan, index: u32) -> ^Depth_Peel_Buffer {
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
        colors = { gpu.color_attachment(render_view = buffer.color.render_view, load = color_load, clear = clear_color) },
        depth  = gpu.depth_attachment(render_view = buffer.depth.render_view, load = .clear, store = .store),
    )
    gpu.set_depth_stencil(commands, depth_test = true, depth_write = true)
    gpu.bind_pso(commands, vulkan.sample_count == 1 ? vulkan.quad_pso : vulkan.multisample_quad_pso)
}

end_depth_peel_pass :: proc (vulkan: ^Vulkan, commands: gpu.CommandBuffer, peel_index: u32, allocator: ^gpu.BumpAllocator) {
    gpu.end_render_pass(commands)
    gpu.barrier(commands, { .color_output, .depth_stencil_tests }, { .color_write, .depth_stencil_write }, { .fragment }, { .shader_read })
    if vulkan.sample_count == 1 { return }
    
    from := vulkan.depth_peel_buffers[peel_index]
    to   := vulkan.depth_peel_resolve_buffers[peel_index]
    
    gpu.begin_render_pass(commands,
        colors = { gpu.color_attachment(render_view = to.color.render_view, load = .discard) },
        depth  = gpu.depth_attachment(render_view = to.depth.render_view, load = .discard),
    )
    
    gpu.set_depth_stencil(commands, depth_test = true, depth_write = true, depth_compare = .always)
    gpu.bind_pso(commands, vulkan.resolve_pso)
    
    root := gpu.bump_allocate(allocator, RootResolve)
    root.cpu^ = {
        color_descriptor = from.color.descriptor_index,
        depth_descriptor = from.depth.descriptor_index,
        sample_count      = vulkan.sample_count,
    }
    
    gpu.draw(commands, root.gpu, 3)
    
    gpu.end_render_pass(commands)
    
    gpu.barrier(commands, { .color_output, .depth_stencil_tests }, { .color_write, .depth_stencil_write }, { .fragment }, { .shader_read })
}

allocate_texture_descriptor :: proc (vulkan: ^Vulkan) -> u32 {
    last_free := len(vulkan.free_texture_descriptors)-1
    index: u32
    if last_free >= 0 {
        index = vulkan.free_texture_descriptors[last_free]
        resize(&vulkan.free_texture_descriptors, last_free)
    } else {
        assert(vulkan.next_texture_descriptor < cast(u32) VulkanTextureDescriptor.count)
        
        index = vulkan.next_texture_descriptor
        vulkan.next_texture_descriptor += 1
    }
    
    return index
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
    
    for &buffer in vulkan.depth_peel_buffers {
        destroy_render_target(vulkan, &buffer.color)
        destroy_render_target(vulkan, &buffer.depth)
    }
    for &buffer in vulkan.depth_peel_resolve_buffers {
        destroy_render_target(vulkan, &buffer.color)
        destroy_render_target(vulkan, &buffer.depth)
    }
    destroy_render_target(vulkan, &vulkan.composite_buffer)
    
    for &texture in vulkan.textures[1:] {
        gpu.texture_free(&vulkan.texture_allocator, &texture)
    }
    
    gpu.destroy_pso(vulkan.quad_pso)
    gpu.destroy_pso(vulkan.multisample_quad_pso)
    gpu.destroy_pso(vulkan.resolve_pso)
    gpu.destroy_pso(vulkan.composite_pso)
    gpu.destroy_pso(vulkan.final_pso)
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

rebind_device :: proc (vulkan: ^Vulkan) -> bool {
    device := vulkan.device
    if device == nil { return false }
    
    address, found := dynlib.symbol_address(cast(dynlib.Library) device.vulkan_library, "vkGetInstanceProcAddr", allocator = context.temp_allocator)
    if !found { return false }
    
    vk.load_proc_addresses_global(address)
    vk.load_proc_addresses_instance(device.instance)
    vk.load_proc_addresses_device(device.device)
    
    create_psos(vulkan)
    
    device.destroy_debug_messenger = auto_cast vk.GetInstanceProcAddr(device.instance, "vkDestroyDebugUtilsMessengerEXT")
    result := vk.CmdBindResourceHeapEXT != nil && vk.CmdBindSamplerHeapEXT != nil && vk.CmdPushDataEXT != nil
    return result
}