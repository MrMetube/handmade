package render

import "core:os"
import "core:io"
import "core:dynlib"

import vk "vendor:vulkan"
import gpu "./no_graphics_api"

import "./shared"

// :VulkanRenderer: The platform should own shader loading and expose the paths
// through the game/platform API rather than this renderer-owned config.
shader_pack_path := #config(shader_pack_path, "unset")

////////////////////////////////////////////////

frame_heap_size          :: 32 * Megabyte
ligting_heap_size        :: 16 * Megabyte
texture_upload_heap_size :: 64 * Megabyte
texture_heap_size        ::  2 * Gigabyte
frames_in_flight         :: 2
max_depth_peels          :: 4

max_vulkan_textures :: 256

Debug_vulkan_depth_peel_index: i32 = -1 // -1 composites all layers

Vulkan :: struct {
    settings: RenderSettings,
    
    device: gpu.Device,
    
    frames:           [frames_in_flight] Frame,
    next_frame_index: u32,
    
    texture_upload_heap:      gpu.GpuHeap,
    texture_upload_allocator: gpu.BumpAllocator,
    
    texture_heap:      gpu.TextureHeap,
    texture_allocator: gpu.TextureAllocator,
    
    supported_sample_count: u32,
    active_sample_count:    u32,
    
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
    
    // :TextureHandleOffset:
    textures:     [TextureDescriptor.count + .one] gpu.PlacedTexture,
    next_texture:  TextureDescriptor,
    free_texture: [dynamic; TextureDescriptor.count] TextureDescriptor,
    
    depth_peel_buffers:         [dynamic; max_depth_peels] DepthPeelBuffer,
    depth_peel_resolve_buffers: [dynamic; max_depth_peels] DepthPeelBuffer,
    peel_composite_buffer:      RenderTarget,
    light_buffers:              [dynamic; 10] [LightBufferKind] RenderTarget,
    
    debug_light_buffer_index:   i32,
    debug_light_buffer_texture: i32,
    
    
    voxel_min_corner:             v3,
    voxel_inverse_cell_dimension: v3,
    
    lighting_heap: gpu.GpuHeap,
    lighting_bump: gpu.BumpAllocator,
    
    pnext_buffer:  gpu.GpuCpuRange(v4),
    c_buffer:      gpu.GpuCpuRange(Color),
    lookup_buffer: gpu.GpuCpuRange(u16),
}

Frame :: struct {
    heap:       gpu.GpuHeap,
    allocator:  gpu.BumpAllocator,
    completion: gpu.TimelinePoint,
}

RenderTarget :: struct {
    render_view: gpu.RenderView,
    descriptor:  TextureDescriptor,
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
    
    depth_peel_begin = 1,
    depth_peel_end = depth_peel_begin + depth_peel_and_resolve_target_count,
    
    resolve_begin,
    resolve_end = resolve_begin + depth_peel_and_resolve_target_count,
    
    peel_composite,
    
    light_buffer_begin,
    light_buffer_end = light_buffer_begin + light_buffer_count,
    
    lighting_pnext,
    lighting_c,
    lighting_lookup,
    
    first_dynamic_texture,
    count = first_dynamic_texture + max_vulkan_textures,
    
    one = 1, // @note remove with :TextureHandleOffset:
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

////////////////////////////////////////////////

// :VulkanRenderer: Generate the Slang declarations from the Odin definitions.
// Keep these in lockstep with the C-layout SPIR-V declarations in vulkan.slang.
//
// These Roots as well as Textured_Vertex:
//

RootZBias :: struct #all_or_none {
    projection:       m4,
    vertices:         [^] Textured_Vertex,
    textures:         [^] u32,
    camera_p:         v3,
    fog_direction:    v3,
    fog_color:        v3,
    fog_begin:        f32,
    fog_end:          f32,
    clip_alpha_begin: f32,
    clip_alpha_end:   f32,
    vertex_base:      u32,
    previous_depth:   TextureDescriptor,
    alpha_threshold:  f32,
    
    voxel_min_corner:             v3,
    voxel_inverse_cell_dimension: v3,
    
    lighting_pnext:  [^] v4,
    lighting_c:      [^] Color,
    lighting_lookup: [^] u16,
}
#assert(size_of(RootZBias) % 32 == 0)

// @todo compress descriptors
RootPeelComposite :: struct #all_or_none {
    peels:                 [max_depth_peels] TextureDescriptor,
    npls:                  [max_depth_peels] TextureDescriptor,
    light_normal_xy_depth: TextureDescriptor,
    light_emission:        TextureDescriptor,
    peel_count:            u32,
}

RootMultisampleResolve :: struct #all_or_none {
    peel_index:   u32,
    sample_count: u32,
}

RootFinalStretch :: struct #all_or_none {
    texture: TextureDescriptor,
    sampler: Sampler,
}

RootMultigridLightUp :: struct #all_or_none {
    source_index: u32,
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
        frame.heap      = gpu.create_gpu_heap(device, frame_heap_size)
        frame.allocator = gpu.bump_allocator(frame.heap.range)
        frame.completion.semaphore = vulkan.latest_completion.semaphore
    }

    vulkan.texture_upload_heap      = gpu.create_gpu_heap(device, texture_upload_heap_size)
    vulkan.texture_upload_allocator = gpu.bump_allocator(vulkan.texture_upload_heap.range)
    
    vulkan.lighting_heap = gpu.create_gpu_heap(device, ligting_heap_size)
    vulkan.lighting_bump = gpu.bump_allocator(vulkan.lighting_heap.range)
    
    vulkan.texture_descriptor_heap = gpu.create_texture_descriptor_heap(device, cast(u32) TextureDescriptor.count)
    vulkan.sampler_descriptor_heap = gpu.create_sampler_descriptor_heap(device, len(Sampler))
    
    vulkan.texture_heap      = gpu.create_texture_heap(device, texture_heap_size)
    vulkan.texture_allocator = gpu.texture_allocator(device, vulkan.texture_heap, cast(u32) TextureDescriptor.count)
    
    vulkan.next_texture = .first_dynamic_texture
    
    gpu.write_sampler_descriptor(vulkan.sampler_descriptor_heap, cast(u32) Sampler.Linear, min_filter = .linear, mag_filter = .linear, address_u = .clamp_to_edge, address_v = .clamp_to_edge)
    gpu.write_sampler_descriptor(vulkan.sampler_descriptor_heap, cast(u32) Sampler.Nearest, min_filter = .nearest, mag_filter = .nearest, address_u = .clamp_to_edge, address_v = .clamp_to_edge)
    
    { // @note Find the maximum supported multisample count.
        test_dimension := uv3 { 1920, 1080, 1 }
        
        peel_color_desc := gpu.texture_desc(
            extent = test_dimension,
            format = .bgra8_srgb,
            usage  = { .sampled, .color_attachment },
        )
        
        peel_depth_desc := gpu.texture_desc(
            extent = test_dimension,
            format = .d32_float,
            usage  = { .sampled, .depth_stencil_attachment },
        )
        
        sample_counts := [?] u32 { 8, 4, 2 }
        for candidate in sample_counts {
            peel_color_desc.sample_count = candidate
            peel_depth_desc.sample_count = candidate
        
            if gpu.supports_texture_sample_count(vulkan.device, peel_color_desc) && gpu.supports_texture_sample_count(vulkan.device, peel_depth_desc) {
                vulkan.supported_sample_count = candidate
                break
            }
        }
        
        if vulkan.supported_sample_count == 0 {
            vulkan.supported_sample_count = 1
        }
    }
    
    create_psos(vulkan)
}

unload_vulkan :: proc (vulkan: ^Vulkan) {
    device := vulkan.device
    if device != nil && device.debug_messenger != 0 && device.destroy_debug_messenger != nil {
        device.destroy_debug_messenger(device.instance, device.debug_messenger, nil)
        device.debug_messenger = 0
    }
}

hotreload_vulkan :: proc (vulkan: ^Vulkan) {
    device := vulkan.device
    assert(device != nil)
    
    address, found := dynlib.symbol_address(cast(dynlib.Library) device.vulkan_library, "vkGetInstanceProcAddr", allocator = context.temp_allocator)
    assert(found)
    
    vk.load_proc_addresses_global(address)
    vk.load_proc_addresses_instance(device.instance)
    vk.load_proc_addresses_device(device.device)
    
    gpu.wait_idle(vulkan.device)
    
    create_psos(vulkan)
    
    device.destroy_debug_messenger = auto_cast vk.GetInstanceProcAddr(device.instance, "vkDestroyDebugUtilsMessengerEXT")
    assert(vk.CmdBindResourceHeapEXT != nil && vk.CmdBindSamplerHeapEXT != nil && vk.CmdPushDataEXT != nil)
}

deinit_vulkan :: proc (vulkan: ^Vulkan) {
    device := vulkan.device
    if device == nil { return }
    
    gpu.wait_idle(device)
    
    destroy_all_render_targets(vulkan)
    
    for &texture in vulkan.textures {
        gpu.texture_free(&vulkan.texture_allocator, &texture)
    }
    clear(&vulkan.free_texture)
    
    destroy_all_psos(vulkan)
    
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

////////////////////////////////////////////////

vk_allocate_texture :: proc (vulkan: ^Vulkan, bitmap: Bitmap, set_as_nil_texture := false) -> u32 {
    timed_function()
    
    placed := gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
        extent = { **cast(uv2) bitmap.dimension, 1 },
        format = .rgba8_srgb,
        usage  = { .sampled, .transfer_destination },
    ))
    assert(placed.texture != nil)
    
    descriptor: TextureDescriptor
    if set_as_nil_texture {
        descriptor = .nil_texture
    } else {
        if len(vulkan.free_texture) > 0 {
            descriptor = pop(&vulkan.free_texture)
        } else {
            assert(vulkan.next_texture < .count)
            descriptor = vulkan.next_texture
            vulkan.next_texture += .one
        }
    }
    gpu.write_texture_descriptor(vulkan.texture_descriptor_heap, cast(u32) descriptor, placed.texture, .sampled)
    
    texture_bytes := slice_to_bytes(bitmap.memory)
    upload        := gpu.bump_allocate(&vulkan.texture_upload_allocator, len(texture_bytes))
    copy(upload.cpu, texture_bytes)
    
    commands := gpu.begin_commands(vulkan.device)
    
    gpu.copy_memory_to_texture(commands, gpu.gpu_range(upload), placed.texture)
    
    gpu.barrier(commands, { .transfer }, { .transfer_write }, { .fragment }, { .shader_read })
    
    vulkan.latest_completion.value += 1
    gpu.submit({ commands }, vulkan.latest_completion)
    
    // :TextureHandleOffset:
    //
    // Handles passed to the game and platform are offset by 1, so that a 0 always means
    // an invalid handle. 
    // @todo Get rid of "set_as_nil_texture" which is used to set the "white pixel" texture.
    // This requires that the game always provides a valid bitmap+handle for any renderer
    // geometry instead of assuming anything about the handle of the white pixel, but I presume
    // that that is already the case. But check anyways!
    // That should remove all the offsetting and also simplify the TextureDescriptor meanings.
    // TextureDescriptor could also keep a slot just for the white pixels, if that is not too
    // game specific, but I feel like its fine. Then the platform has to pass the now 
    // @(common) TextureDescriptor.white_pixel on the allocation, which must also ensure its
    // slot is free. This code is then the same as the one that the fixed render_target from
    // all the buffers want to use. They can then reuse it and explicitely pass an enum value
    // instead of a raw u32.
    //
    texture_index := cast(u32) (descriptor + .one)
    vulkan.textures[texture_index] = placed
    
    return texture_index
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
            
            // :TextureHandleOffset:
            descriptor := cast(TextureDescriptor) op.handle - .one
            assert(descriptor > .first_dynamic_texture)
            
            texture := &vulkan.textures[op.handle]
            assert(texture.texture != nil)
            
            gpu.texture_free(&vulkan.texture_allocator, texture)
            texture^ = {}
            
            append(&vulkan.free_texture, descriptor)
        }
    }
    
    count := allocs + deallocs
    debug_record_i32(&count, "count")
    debug_record_i32(&allocs, "allocations")
    debug_record_i32(&deallocs, "deallocations")
}

////////////////////////////////////////////////

create_psos :: proc (vulkan: ^Vulkan) {
    spirvs: [shared.Shaders] struct { vertex, fragment: [] u8 }
    
    {
        pack, err := os.open(shader_pack_path)
        assert(err == nil)
        defer os.close(pack)
        
        read_value :: proc (r: io.Reader, $T: typeid) -> T {
            result: T
            n, err := io.read_ptr(r, &result, size_of(T))
            assert(err == nil && n == size_of(T))
            return result
        }
        
        read_slice_at :: proc (r: io.Reader, destination: [] u8, offset: u64) {
            n, err := io.read_at(r, destination, cast(i64) offset)
            assert(err == nil && n == len(destination))
        }
        
        r := os.to_reader(pack)
        
        header := read_value(r, shared.ShaderPackHeader)
        assert(header.magic == "SPAK")
        assert(header.version == 1)
        
        for it, shader in header.infos {
            spirv := &spirvs[shader]
            
            spirv.vertex   = make(context.allocator, u8, it.vertex_count)
            spirv.fragment = make(context.allocator, u8, it.fragment_count)
            
            read_slice_at(r, spirv.vertex,   it.vertex_offset)
            read_slice_at(r, spirv.fragment, it.fragment_offset)
        }
    }
    
    defer for it in spirvs {
        delete(it.vertex,   context.allocator)
        delete(it.fragment, context.allocator)
    }
    
    ////////////////////////////////////////////////
    
    destroy_all_psos(vulkan)
    
    vulkan.zbias_pso = create_graphics_pso(vulkan.device, 
        spirvs[.zbias].vertex, 
        spirvs[.zbias].fragment, 
        color_targets = { gpu.color_target_desc(format = .bgra8_srgb) },
        depth_format   = .d32_float,
        rasterization  = { cull = .counter_clockwise },
    )
    
    vulkan.peel_composite_pso = create_graphics_pso(vulkan.device,
        spirvs[.peel_composite].vertex, 
        spirvs[.peel_composite].fragment, 
        color_targets = { gpu.color_target_desc(format = .bgra8_srgb) },
    )
    
    vulkan.multisample_resolve_pso = create_graphics_pso(vulkan.device,
        spirvs[.multisample_resolve].vertex, 
        spirvs[.multisample_resolve].fragment, 
        color_targets = {
            gpu.color_target_desc(format = .bgra8_srgb),
            gpu.color_target_desc(format = .rgba8_unorm),
            gpu.color_target_desc(format = .rgba8_unorm),
        },
        depth_format   = .d32_float,
    )
    
    vulkan.final_stretch_pso = create_graphics_pso(vulkan.device,
        spirvs[.final_stretch].vertex, 
        spirvs[.final_stretch].fragment, 
        color_targets = { gpu.color_target_desc(format = .bgra8_srgb) },
    )
    
    vulkan.multigrid_light_up_pso = create_graphics_pso(vulkan.device,
        spirvs[.multigrid_light_up].vertex, 
        spirvs[.multigrid_light_up].fragment, 
        color_targets = {
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
        },
    )
    
    vulkan.multigrid_light_down_pso = create_graphics_pso(vulkan.device,
        spirvs[.multigrid_light_down].vertex, 
        spirvs[.multigrid_light_down].fragment, 
        color_targets = {
            gpu.color_target_desc(format = .rgba32_float, blend = gpu.blend_state(enabled = true, color = {.one, .one, .add})),
            gpu.color_target_desc(format = .rgba32_float, blend = gpu.blend_state(enabled = true, color = {.one, .one, .add})),
        },
    )
    
    vulkan.depth_peel_to_lighting_pso = create_graphics_pso(vulkan.device,
        spirvs[.depth_peel_to_lighting].vertex, 
        spirvs[.depth_peel_to_lighting].fragment, 
        color_targets = {
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
            gpu.color_target_desc(format = .rgba32_float),
        },
    )
    
    if vulkan.supported_sample_count > 1 {
        vulkan.multisampled_zbias_pso = create_graphics_pso(vulkan.device,
            spirvs[.zbias].vertex, 
            spirvs[.zbias].fragment,
            color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
            depth_format   = .d32_float,
            rasterization  = { cull = .counter_clockwise },
            sample_count   = vulkan.supported_sample_count,
        )
    }
}
    
// @note Bake my default arguments.
create_graphics_pso :: proc (
    device: gpu.Device,
    vertex:   [] u8,
    fragment: [] u8,
    color_targets:  [] gpu.ColorTargetDesc,
    depth_format:   gpu.Format             = .undefined,
    stencil_format: gpu.Format             = .undefined,
    rasterization:  gpu.RasterizationState = {},
    sample_count:   u32                    = 1,
    ) -> gpu.PSO {
    
    result := gpu.create_graphics_pso(device, vertex, fragment, "main", "main", color_targets, depth_format, stencil_format, rasterization, sample_count)
    return result
}

////////////////////////////////////////////////

render_commands :: proc (vulkan: ^Vulkan, render_commands: ^RenderCommands, draw_region: Rectangle2i, window_dim: iv2) {
    timed_function()
    
    if render_commands.settings != vulkan.settings {
        change_to_settings(vulkan, render_commands.settings)
    }
    
    begin_timed_block("acquire frame")
    render_frame := gpu.acquire(vulkan.device)
    end_timed_block()
    if render_frame.render_view == nil { return }
    
    frame_index := vulkan.next_frame_index
    vulkan.next_frame_index = (frame_index + 1) % cast(u32) frames_in_flight
    frame := &vulkan.frames[frame_index]
    if frame.completion.value != 0 { 
        timed_block("wait before render commands")
        gpu.wait_timeline(frame.completion)
    }
    
    render_extent    := cast(uv2) render_commands.dimension
    depth_peel_count := cast(u32) len(vulkan.depth_peel_buffers)
    
    uploads: FrameUploads
    {
        timed_block("upload per-frame data")
        
        debug_data_block("Renderer")
        debug_data_block("frame uploads")
        
        gpu.bump_reset(&frame.allocator)
        
        {
            timed_block("copy textured vertices")
            
            count := cast(i32) len(render_commands.vertex_buffer)
            debug_record_i32(&count, "vertex count")
            
            uploads.vertices = gpu.bump_allocate(&frame.allocator, [] Textured_Vertex, len(render_commands.vertex_buffer))
            copy(uploads.vertices.cpu, render_commands.vertex_buffer[:])
        }
        
        {
            timed_block("copy texture descriptors")
            
            count := cast(i32) len(render_commands.quad_bitmap_buffer)
            debug_record_i32(&count, "bitmap count")
            
            uploads.textures = gpu.bump_allocate(&frame.allocator, [] u32, len(render_commands.quad_bitmap_buffer))
            for bitmap, index in render_commands.quad_bitmap_buffer {
                texture_handle := max(0, bitmap.texture_handle-1)
                uploads.textures.cpu[index] = texture_handle
            }
        }
    }
    
    begin_timed_block("begin commands")
    commands := gpu.begin_commands(vulkan.device)
    gpu.set_texture_descriptor_heap(commands, vulkan.texture_descriptor_heap)
    gpu.set_sampler_descriptor_heap(commands, vulkan.sampler_descriptor_heap)
    end_timed_block()
    
    ////////////////////////////////////////////////
    
    peel_index: u32
    peel_header_restore: int
    begin_depth_peel_pass(vulkan, commands, peel_index, .clear, render_commands.clear_color)
    
    for cursor: int; cursor < len(render_commands.entries); {
        entry := render_commands.entries[cursor]
        
        advance := true
        
        switch entry.kind {
        case .None: unreachable()
        case .DepthClear:
            timed_block("depth clear")
            gpu.end_render_pass(commands)
            begin_depth_peel_pass(vulkan, commands, peel_index, .load)
            
        case .BeginPeels:
            timed_block("begin peels")
            peel_header_restore = cursor
            
        case .EndPeels:
            timed_block("end peels")
            end_depth_peel_pass(vulkan, commands, peel_index, &frame.allocator)
            
            if peel_index < depth_peel_count - 1 {
                cursor  = peel_header_restore
                advance = false
                
                peel_index += 1
                
                begin_depth_peel_pass(vulkan, commands, peel_index, .clear, render_commands.clear_color)
            } else {
                peel_index = 0
                begin_depth_peel_pass(vulkan, commands, peel_index, .load)
            }
            
        case .Textured_Quads:
            timed_block("textured quads")
            entry := entry.textured_quads
            if entry.quad_count == 0 { continue }
            
            setup := &entry.setup
            render_rect := rectangle_zero_min_dimension(render_commands.dimension)
            clip := get_intersection(setup.clip_rect, render_rect)
            if !has_area(clip) { continue }
            
            gpu.set_viewport(commands, 0, 0, cast(f32) render_extent.x, cast(f32) render_extent.y)
            dim := get_dimension(clip)
            scissor_y := cast(i32) render_extent.y - clip.max.y
            gpu.set_scissor(commands, clip.min.x, scissor_y, cast(u32) dim.x, cast(u32) dim.y)
            
            root := gpu.bump_allocate(&frame.allocator, RootZBias)
            root.cpu^ = {
                projection       = setup.projection,
                vertices         = uploads.vertices.gpu,
                textures         = &uploads.textures.gpu[entry.bitmap_offset],
                camera_p         = setup.camera_p,
                fog_direction    = setup.fog_direction,
                fog_color        = setup.fog_color,
                fog_begin        = setup.fog_begin,
                fog_end          = setup.fog_end,
                clip_alpha_begin = setup.clip_alpha_begin,
                clip_alpha_end   = setup.clip_alpha_end,
                vertex_base      = entry.bitmap_offset * 4,
                previous_depth   = peel_index != 0 ? get_depth_peel_read_buffer(vulkan, peel_index-1).depth.descriptor : .nil_texture,
                alpha_threshold  = peel_index != 0 && peel_index == depth_peel_count - 1 ? 0.9 : 0.02,
                
                voxel_min_corner             = vulkan.voxel_min_corner,
                voxel_inverse_cell_dimension = vulkan.voxel_inverse_cell_dimension,
                
                lighting_pnext  = vulkan.pnext_buffer.gpu,
                lighting_c      = vulkan.c_buffer.gpu,
                lighting_lookup = vulkan.lookup_buffer.gpu,
            }
            gpu.draw(commands, root.gpu, entry.quad_count * 6)
        
        case .Lighting:
            timed_block("lighting transfer")
            entry := entry.lighting
            
            vulkan.voxel_min_corner             = entry.voxel_min_corner
            vulkan.voxel_inverse_cell_dimension = entry.voxel_inverse_cell_dimension
            
            // @note This is only called once per creation, not per frame.
            gpu.bump_reset(&vulkan.lighting_bump)
            
            
            lookup_count := lookup_dimensions.x * lookup_dimensions.y * lookup_dimensions.z
            
            vulkan.pnext_buffer  = gpu.bump_allocate(&vulkan.lighting_bump, [] v4, len(entry.pnext^))
            vulkan.c_buffer      = gpu.bump_allocate(&vulkan.lighting_bump, [] Color, len(entry.c^))
            vulkan.lookup_buffer = gpu.bump_allocate(&vulkan.lighting_bump, [] u16, lookup_count)
            
            copy(vulkan.pnext_buffer.cpu,  entry.pnext^[:])
            copy(vulkan.c_buffer.cpu,      entry.c^[:])
            copy(vulkan.lookup_buffer.cpu, slice_from_parts(u16, entry.lookup, lookup_count))
            
            if false { // @todo Can we just use the buffers? or do we actually "sample" from the textures?
                gpu.end_render_pass(commands) // @todo do we need to restart the depth peel pass?
                
                pnext_texture  := get_texture(vulkan, .lighting_pnext)
                c_texture      := get_texture(vulkan, .lighting_c)
                lookup_texture := get_texture(vulkan, .lighting_lookup)
                
                // @todo dont call this inside a render pass and fix dependency_flags=by_region
                gpu.barrier(commands, { .fragment }, { .shader_read }, { .transfer }, { .transfer_write })
                
                gpu.copy_memory_to_texture(commands, gpu.gpu_range(vulkan.pnext_buffer),  pnext_texture.texture)
                gpu.copy_memory_to_texture(commands, gpu.gpu_range(vulkan.c_buffer),      c_texture.texture)
                gpu.copy_memory_to_texture(commands, gpu.gpu_range(vulkan.lookup_buffer), lookup_texture.texture)
                
                gpu.barrier(commands, { .transfer }, { .transfer_write }, { .fragment }, { .shader_read })
                
                begin_depth_peel_pass(vulkan, commands, peel_index, .load)
            }
        }
        
        if advance {
            cursor += 1
        }
    }
    
    end_depth_peel_pass(vulkan, commands, peel_index, &frame.allocator)
    
    ////////////////////////////////////////////////
    
    // compute_light_transport(vulkan, commands, frame)
    unused(compute_light_transport)
    
    // gpu.barrier(commands, { .color_output }, { .color_write }, { .fragment }, { .shader_read }) // @todo real barrier
    
    ////////////////////////////////////////////////
    
    {
        timed_block("peel composite")
        
        gpu.begin_render_pass(commands, colors = { gpu.color_attachment(render_view = vulkan.peel_composite_buffer.render_view, load = .clear, clear = render_commands.clear_color) })
        
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
            texture = vulkan.peel_composite_buffer.descriptor,
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
        texture: TextureDescriptor
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
    
    begin_timed_block("submit and present")
    vulkan.latest_completion.value += 1
    frame.completion = vulkan.latest_completion
    gpu.submit_and_present(vulkan.device, { commands }, vulkan.latest_completion)
    end_timed_block()
}

////////////////////////////////////////////////

compute_light_transport :: proc (vulkan: ^Vulkan, commands: gpu.CommandBuffer, frame: ^Frame) {
    //
    // @note The hare-brained scheme below! Not for the faint of heart.
    //
    
    // @note Import depth peel results.
    {
        gpu.barrier(commands, { .fragment }, { .shader_read, .shader_write }) // @todo real masks
        
        destination := &vulkan.light_buffers[0]
        
        gpu.begin_render_pass(commands, colors = {
            gpu.color_attachment(render_view = destination[.front_emission].render_view,  load = .discard),
            gpu.color_attachment(render_view = destination[.back_emission].render_view,   load = .discard),
            gpu.color_attachment(render_view = destination[.surface_color].render_view,   load = .discard),
            gpu.color_attachment(render_view = destination[.normal_xy_depth].render_view, load = .discard),
        })
        
        gpu.bind_pso(commands, vulkan.depth_peel_to_lighting_pso)
        
        root := gpu.bump_allocate(&frame.allocator, RootDepthPeelToLighting)
        // @todo This probably needs to use all 4 depth peels, eventually.
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

change_to_settings :: proc (vulkan: ^Vulkan, settings: RenderSettings) {
    timed_function()
    
    if vulkan.latest_completion.value != 0 { 
        timed_block("wait before graphics settings change")
        gpu.wait_timeline(vulkan.latest_completion)
    }
    
    {
        timed_block("recreate render targets")
        
        destroy_all_render_targets(vulkan)
        
        depth_peel_count := clamp(settings.depth_peel_count_hint, 1, cap(vulkan.depth_peel_buffers))
        render_dim := uv3 { cast(u32) settings.dimension.x, cast(u32) settings.dimension.y, 1 } 
        
        vulkan.active_sample_count = 1
        if settings.multisampling_hint {
            vulkan.active_sample_count = vulkan.supported_sample_count
        }
        
        resize(&vulkan.depth_peel_buffers,         depth_peel_count)
        resize(&vulkan.depth_peel_resolve_buffers, vulkan.active_sample_count != 1 ? depth_peel_count : 0)
        
        {
            descriptor := TextureDescriptor.depth_peel_begin
            for &buffer in vulkan.depth_peel_buffers {
                buffer.depth = create_render_target(vulkan, descriptor, gpu.texture_desc(
                    extent = render_dim,
                    format = .d32_float,
                    usage  = { .sampled, .depth_stencil_attachment },
                    sample_count = vulkan.active_sample_count,
                ))
                descriptor += .one
                
                for &target, target_index in buffer.color {
                    target = create_render_target(vulkan, descriptor, gpu.texture_desc(
                        extent = render_dim,
                        format = (target_index == .surface_reflect) ? .bgra8_srgb : .rgba8_unorm,
                        usage  = { .sampled, .color_attachment },
                        sample_count = vulkan.active_sample_count,
                    ))
                    descriptor += .one
                }
            }
        }
        
        if vulkan.active_sample_count != 1 {
            descriptor := TextureDescriptor.resolve_begin
            for &buffer in vulkan.depth_peel_resolve_buffers {
                buffer.depth = create_render_target(vulkan, descriptor, gpu.texture_desc(
                    extent = render_dim,
                    format = .d32_float,
                    usage  = { .sampled, .depth_stencil_attachment },
                ))
                descriptor += .one
                
                for &target, target_index in buffer.color {
                    target = create_render_target(vulkan, descriptor, gpu.texture_desc(
                        extent = render_dim,
                        format = (target_index == .surface_reflect) ? .bgra8_srgb : .rgba8_unorm,
                        usage  = { .sampled, .color_attachment },
                    ))
                    descriptor += .one
                }
            }
        }
        
        vulkan.peel_composite_buffer = create_render_target(vulkan, .peel_composite, gpu.texture_desc(
            extent = render_dim,
            format = .bgra8_srgb,
            usage  = { .sampled, .color_attachment },
        ))
        
        {
            clear(&vulkan.light_buffers)
            
            light_buffer_dim: uv2
            light_buffer_dim.x = 1 << find_most_significant_bit(render_dim.x)
            light_buffer_dim.y = 1 << find_most_significant_bit(render_dim.y)
            
            descriptor := TextureDescriptor.light_buffer_begin
            for light_buffer_dim.x > 1 && light_buffer_dim.y > 1 && len(vulkan.light_buffers) < cap(vulkan.light_buffers) {
                buffer := append_into(&vulkan.light_buffers)
                
                // @note Drop these down to f16 once we know what's what and probably use rgb8 for surface_color? And normal_xy_and_depth could probably be encoded in rgb8?
                desc := gpu.texture_desc(
                    extent = { light_buffer_dim.x, light_buffer_dim.y, 1 },
                    format = .rgba32_float,
                    usage  = { .sampled, .color_attachment },
                )
                
                for &target in buffer {
                    target = create_render_target(vulkan, descriptor, desc)
                    descriptor += .one
                }
                
                light_buffer_dim.xy = (light_buffer_dim.xy + 1) / 2
                if light_buffer_dim.x < 1 { light_buffer_dim.x = 1 }
                if light_buffer_dim.y < 1 { light_buffer_dim.y = 1 }
            }
        }
    }
    
    {
        timed_block("recreate lighting buffers")
        
        pnext_texture  := get_texture(vulkan, .lighting_pnext)
        c_texture      := get_texture(vulkan, .lighting_c)
        lookup_texture := get_texture(vulkan, .lighting_lookup)
        
        gpu.texture_free(&vulkan.texture_allocator, pnext_texture)
        gpu.texture_free(&vulkan.texture_allocator, c_texture)
        gpu.texture_free(&vulkan.texture_allocator, lookup_texture)
            
        pnext_texture^  = gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(type = .one_d,   extent = { len(Lighting{}.pnext^), 1, 1 }, format = .rgba32_float, usage = { .transfer_destination, .sampled }))
        c_texture^      = gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(type = .one_d,   extent = { len(Lighting{}.c^),     1, 1 }, format = .rgba8_uint,   usage = { .transfer_destination, .sampled }))
        lookup_texture^ = gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(type = .three_d, extent = lookup_dimensions,                format = .r16_uint,     usage = { .transfer_destination, .sampled }))
    }
    
    vulkan.settings = settings
}

////////////////////////////////////////////////

get_texture :: proc (vulkan: ^Vulkan, descriptor: TextureDescriptor) -> ^gpu.PlacedTexture {
    // :TextureHandleOffset:
    result := &vulkan.textures[descriptor + .one]
    return result
}

create_render_target :: proc (vulkan: ^Vulkan, index: TextureDescriptor, desc: gpu.TextureDesc) -> RenderTarget {
    placed := gpu.texture_allocate(&vulkan.texture_allocator, desc)
    assert(placed.texture != nil)
    
    slot := get_texture(vulkan, index)
    assert(slot.texture == nil)
    slot^ = placed
        
    result := RenderTarget {
        descriptor  = index,
        render_view = gpu.create_render_view(placed.texture)
    }
    gpu.write_texture_descriptor(vulkan.texture_descriptor_heap, transmute(u32) index, placed.texture, .sampled)
    
    return result
}

destroy_render_target :: proc (vulkan: ^Vulkan, target: ^RenderTarget) {
    if target.render_view == nil { return }
    assert(target.descriptor < .first_dynamic_texture)
    
    // :TextureHandleOffset:
    texture := &vulkan.textures[target.descriptor - .one]
    
    gpu.destroy_render_view(target.render_view)
    gpu.texture_free(&vulkan.texture_allocator, texture)
    
    target^ = {}
}

get_depth_peel_read_buffer :: proc (vulkan: ^Vulkan, index: u32) -> ^DepthPeelBuffer {
    result := &vulkan.depth_peel_buffers[index]
    if vulkan.active_sample_count > 1 {
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
        colors = { gpu.color_attachment(render_view = buffer.color[.surface_reflect].render_view, load = color_load, clear = clear_color) },
        depth = gpu.depth_attachment(render_view = buffer.depth.render_view, load = .clear),
    )
    gpu.set_depth_stencil(commands, depth_test = true, depth_write = true)
    gpu.bind_pso(commands, vulkan.active_sample_count == 1 ? vulkan.zbias_pso : vulkan.multisampled_zbias_pso)
}

end_depth_peel_pass :: proc (vulkan: ^Vulkan, commands: gpu.CommandBuffer, peel_index: u32, allocator: ^gpu.BumpAllocator) {
    gpu.end_render_pass(commands)
    gpu.barrier(commands, { .color_output, .depth_stencil_tests }, { .color_write, .depth_stencil_write }, { .fragment }, { .shader_read })
    if vulkan.active_sample_count == 1 { return }
    
    from := peel_index
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
        peel_index   = from,
        sample_count = vulkan.active_sample_count,
    }
    
    gpu.draw(commands, root.gpu, 3)
    
    gpu.end_render_pass(commands)
    
    gpu.barrier(commands, { .color_output, .depth_stencil_tests }, { .color_write, .depth_stencil_write }, { .fragment }, { .shader_read })
}

////////////////////////////////////////////////

destroy_all_render_targets :: proc (vulkan: ^Vulkan) {
    // @todo We want to just write this:
    // for &texture in vulkan.textures[cast(u32) TextureDescriptor.nil_texture + 1 : TextureDescriptor.first_dynamic_texture] {
    // 
    // }
    // But we also need to destoy the render_views in the buffers...
    
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
    
    destroy_render_target(vulkan, &vulkan.peel_composite_buffer)
}

destroy_all_psos :: proc (vulkan: ^Vulkan) {
    gpu.destroy_pso(vulkan.zbias_pso)
    gpu.destroy_pso(vulkan.multisampled_zbias_pso)
    gpu.destroy_pso(vulkan.multisample_resolve_pso)
    gpu.destroy_pso(vulkan.peel_composite_pso)
    gpu.destroy_pso(vulkan.final_stretch_pso)
    gpu.destroy_pso(vulkan.multigrid_light_up_pso)
    gpu.destroy_pso(vulkan.multigrid_light_down_pso)
    gpu.destroy_pso(vulkan.depth_peel_to_lighting_pso)
}