package main

import "core:os"

import gpu "./no_graphics_api"

// :VulkanRenderer: The platform should own shader loading and expose the paths
// through the game/platform API rather than this renderer-owned config.
VulkanVertexSpirvPath   :: #config(VulkanVertexSpirvPath,   "vulkan.vertex.spirv")
VulkanFragmentSpirvPath :: #config(VulkanFragmentSpirvPath, "vulkan.fragment.spirv")
VulkanCompositeVertexSpirvPath   :: #config(VulkanCompositeVertexSpirvPath,   "vulkan.composite_vertex.spirv")
VulkanCompositeFragmentSpirvPath :: #config(VulkanCompositeFragmentSpirvPath, "vulkan.composite_fragment.spirv")

VulkanTexture :: struct {
    placed:           gpu.PlacedTexture,
    descriptor_index: u32,
}

VulkanQuadRoot :: struct {
    projection:         m4,
    vertices:           [^] Textured_Vertex,
    // :VulkanRenderer: These values can use their natural scalar/vector types
    // once the rest of the OpenGL shader is ported.
    camera_p:           v4,
    fog_direction:      v4,
    fog_color:          v4,
    fog_and_clip:       v4,
    texture_descriptors: [^] u32,
    vertex_base:        u32,
    previous_depth_descriptor: u32,
    peeling:            u32,
    alpha_threshold:    f32,
}

VulkanCompositeRoot :: struct {
    texture_descriptors: [cap(vulkan.depth_peel_buffers)] u32,
    peel_count:          u32,
}

VulkanDepthPeelBuffer :: struct {
    color:            gpu.PlacedTexture,
    color_render_view: gpu.RenderView,
    color_descriptor: u32,
    depth:             gpu.PlacedTexture,
    depth_render_view: gpu.RenderView,
    depth_descriptor:  u32,
}

VulkanFrameUploads :: struct {
    vertices:            gpu.GpuCpuRange(Textured_Vertex),
    texture_descriptors: gpu.GpuCpuRange(u32),
}

// :VulkanRenderer: Generate the Slang declarations from the Odin definitions.
// Keep these in lockstep with the C-layout SPIR-V declarations in vulkan.slang.
#assert(offset_of(Textured_Vertex, p)     ==  0)
#assert(offset_of(Textured_Vertex, n)     == 16)
#assert(offset_of(Textured_Vertex, uv)    == 28)
#assert(offset_of(Textured_Vertex, color) == 36)
#assert(size_of(Textured_Vertex)         == 40)

#assert(offset_of(VulkanQuadRoot, projection)         ==   0)
#assert(offset_of(VulkanQuadRoot, vertices)           ==  64)
#assert(offset_of(VulkanQuadRoot, camera_p)           ==  72)
#assert(offset_of(VulkanQuadRoot, fog_direction)      ==  88)
#assert(offset_of(VulkanQuadRoot, fog_color)          == 104)
#assert(offset_of(VulkanQuadRoot, fog_and_clip)       == 120)
#assert(offset_of(VulkanQuadRoot, texture_descriptors)       == 136)
#assert(offset_of(VulkanQuadRoot, vertex_base)                == 144)
#assert(offset_of(VulkanQuadRoot, previous_depth_descriptor) == 148)
#assert(offset_of(VulkanQuadRoot, peeling)                   == 152)
#assert(offset_of(VulkanQuadRoot, alpha_threshold)           == 156)
#assert(size_of(VulkanQuadRoot)                              == 160)

#assert(offset_of(VulkanCompositeRoot, texture_descriptors) == 0)
#assert(offset_of(VulkanCompositeRoot, peel_count)          == 16)
#assert(size_of(VulkanCompositeRoot)                        == 20)

vulkan: struct {
    settings: RenderSettings,
    
    device: gpu.Device,
    
    frame_data_heap:      gpu.GpuHeap,
    frame_data_allocator: gpu.BumpAllocator,

    texture_upload_heap:      gpu.GpuHeap,
    texture_upload_allocator: gpu.BumpAllocator,
    
    texture_heap:      gpu.TextureHeap,
    texture_allocator: gpu.TextureAllocator,
    
    texture_descriptor_heap: gpu.GpuHeap,
    sampler_descriptor_heap: gpu.GpuHeap,
    
    latest_completion: gpu.TimelinePoint,
    
    quad_pso: gpu.PSO,
    composite_pso: gpu.PSO,
    
    textures: map[u32] VulkanTexture,
    last_used_texture_handle: u32,
    next_texture_descriptor: u32,
    
    depth_peel_extent: uv2,
    depth_peel_buffers: [dynamic; 4] VulkanDepthPeelBuffer,
}

// :VulkanRenderer: Make these init parameters or Vulkan-state configuration.
frame_data_heap_size     ::  32 * Megabyte
texture_upload_heap_size ::  64 * Megabyte
texture_heap_size        :: 256 * Megabyte
max_vulkan_textures      :: 256
// Match the current four-sampler OpenGL composite shader.
max_vulkan_texture_descriptors :: max_vulkan_textures + 2 * cap(vulkan.depth_peel_buffers)
max_vulkan_texture_allocations :: max_vulkan_textures + 2 * cap(vulkan.depth_peel_buffers)
vulkan_debug_depth_peel_index: i32 = -1 // -1 composites all layers

////////////////////////////////////////////////

init_vulkan :: proc (window: rawptr) {
    device, error := gpu.create_device(window = window, swapchain_format = .bgra8_srgb)
    assert(error == .none && device != nil)
    
    vulkan.device = device
    
    caps := gpu.get_device_caps(device)
    
    vulkan.frame_data_heap      = gpu.create_gpu_heap(device, frame_data_heap_size)
    vulkan.frame_data_allocator = gpu.bump_allocator(vulkan.frame_data_heap.range)

    vulkan.texture_upload_heap      = gpu.create_gpu_heap(device, texture_upload_heap_size)
    vulkan.texture_upload_allocator = gpu.bump_allocator(vulkan.texture_upload_heap.range)
    
    vulkan.texture_descriptor_heap = gpu.create_gpu_heap(device, caps.texture_descriptor_size_in_bytes * max_vulkan_texture_descriptors, .texture_descriptor_heap)
    vulkan.sampler_descriptor_heap = gpu.create_gpu_heap(device, caps.sampler_descriptor_size_in_bytes, .sampler_descriptor_heap)
    
    vulkan.texture_heap      = gpu.create_texture_heap(device, texture_heap_size)
    vulkan.texture_allocator = gpu.texture_allocator(device, vulkan.texture_heap, max_vulkan_texture_allocations)
    
    vulkan.latest_completion = gpu.TimelinePoint { semaphore = gpu.create_timeline_semaphore(device) }
    gpu.write_sampler_descriptor(device, raw_data(vulkan.sampler_descriptor_heap.range.cpu), min_filter = .linear, mag_filter = .linear, address_u = .clamp_to_edge, address_v = .clamp_to_edge)
    
    vertex_spirv   := read_vulkan_spirv(VulkanVertexSpirvPath)
    fragment_spirv := read_vulkan_spirv(VulkanFragmentSpirvPath)
    composite_vertex_spirv   := read_vulkan_spirv(VulkanCompositeVertexSpirvPath)
    composite_fragment_spirv := read_vulkan_spirv(VulkanCompositeFragmentSpirvPath)
    defer {
        delete(vertex_spirv)
        delete(fragment_spirv)
        delete(composite_vertex_spirv)
        delete(composite_fragment_spirv)
    }
    
    vulkan.quad_pso = gpu.create_graphics_pso(device,
        vertex_spirv   = vertex_spirv,
        fragment_spirv = fragment_spirv,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
        depth_format   = .d32_float,
        rasterization  = { cull = .none },
    )
    vulkan.composite_pso = gpu.create_graphics_pso(device,
        vertex_spirv   = composite_vertex_spirv,
        fragment_spirv = composite_fragment_spirv,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
        rasterization  = { cull = .none },
    )
}

////////////////////////////////////////////////

vk_allocate_texture :: proc (bitmap: Bitmap, set_as_nil_texture := false) -> u32 {
    timed_function()
    assert(vulkan.next_texture_descriptor < max_vulkan_textures)
    
    placed := gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
        extent = { **cast(uv2) bitmap.dimension, 1 },
        format = .rgba8_srgb,
        usage  = { .sampled, .transfer_destination },
    ))
    assert(placed.texture != nil)
    
    descriptor_index := vulkan.next_texture_descriptor
    vulkan.next_texture_descriptor += 1
    
    descriptor_size := gpu.get_device_caps(vulkan.device).texture_descriptor_size_in_bytes
    descriptor := &vulkan.texture_descriptor_heap.range.cpu[cast(u64) descriptor_index * descriptor_size]
    gpu.write_texture_descriptor(vulkan.device, descriptor, placed.texture, .sampled)
    if set_as_nil_texture {
        // @correctness later on, store that the nil texture was set? or test that it wasnt set
        // Descriptor zero is the meaningful fallback for a nil texture handle.
        gpu.write_texture_descriptor(vulkan.device, raw_data(vulkan.texture_descriptor_heap.range.cpu), placed.texture, .sampled)
    }
    
    texture_bytes := slice_to_bytes(bitmap.memory)
    upload := gpu.bump_allocate(&vulkan.texture_upload_allocator, len(texture_bytes))
    assert(upload.cpu != nil)
    copy(upload.cpu, texture_bytes)
    
    commands := gpu.begin_commands(vulkan.device)
    gpu.copy_memory_to_texture(commands, gpu.gpu_range(upload), placed.texture)
    gpu.barrier(commands, { .transfer }, { .transfer_write }, { .fragment }, { .shader_read })
    
    vulkan.latest_completion.value += 1
    gpu.submit({ commands }, vulkan.latest_completion)
    
    vulkan.last_used_texture_handle += 1
    result := vulkan.last_used_texture_handle
    vulkan.textures[result] = { placed, descriptor_index }
    return result
}

vk_manage_textures :: proc (last: ^TextureOp) {
    timed_function()
    allocs, deallocs: u32

    // :VulkanRenderer: Texture destruction is immediate in NoGraphicsAPI. The
    // simple renderer has one frame in flight, so draining it here is enough
    // until a delete queue is introduced with the asynchronous frame allocator.
    if vulkan.latest_completion.value != 0 do gpu.wait_timeline(vulkan.latest_completion)
    
    for operation := last; operation != nil; operation = operation.next {
        switch &op in operation.value {
        case: unreachable()
        
        case TextureOpAllocate:
            allocs += 1
            op.result ^= vk_allocate_texture(op.bitmap)
            
        case TextureOpDeallocate:
            deallocs += 1
            
            was, texture := delete_key(&vulkan.textures, op.handle)
            assert(was == op.handle && texture.placed.texture != nil)
            gpu.texture_free(&vulkan.texture_allocator, &texture.placed)
        }
    }
    
    // @todo Display this in the debug system.
    print("texture ops %, allocs % deallocs %\n", allocs + deallocs, allocs, deallocs)
}

////////////////////////////////////////////////

vk_render_commands :: proc (render_commands: ^RenderCommands, draw_region: Rectangle2i, window_dim: v2i) {
    timed_function()
    unused(draw_region)
    unused(window_dim)

    if render_commands.settings != vulkan.settings {
        vk_change_to_settings(render_commands.settings)
    }

    frame := gpu.acquire(vulkan.device)
    if frame.render_view == nil { return }

    render_extent := cast(uv2) render_commands.dimension
    depth_peel_count := cast(u32) len(vulkan.depth_peel_buffers)

    uploads := vk_begin_frame_uploads(render_commands)
    commands := gpu.begin_commands(vulkan.device)
    gpu.set_texture_descriptor_heap(commands, gpu.gpu_range(vulkan.texture_descriptor_heap))
    gpu.set_sampler_descriptor_heap(commands, gpu.gpu_range(vulkan.sampler_descriptor_heap))

    peel_index: u32
    peeling: bool
    peel_header_restore: int
    peel_clear_color: v4
    if peel_index == depth_peel_count - 1 {
        peel_clear_color = render_commands.clear_color
        peel_clear_color.a = 1
    }
    vk_begin_depth_peel_pass(commands, vulkan.depth_peel_buffers[peel_index], .clear, peel_clear_color)

    for begin_reading(&render_commands.push_buffer); can_read(&render_commands.push_buffer); {
        header := read(&render_commands.push_buffer, RenderEntryHeader)

        switch header.type {
        case .None: unreachable()
        case .DepthClear:
            timed_block("depth clear")
            gpu.end_render_pass(commands)
            vk_begin_depth_peel_pass(commands, vulkan.depth_peel_buffers[peel_index], .load, {})

        case .BeginPeels:
            timed_block("begin peels")
            peel_header_restore = render_commands.push_buffer.read_cursor

        case .EndPeels:
            timed_block("end peels")
            gpu.end_render_pass(commands)
            gpu.barrier(commands, { .color_output, .depth_stencil_tests }, { .color_write, .depth_stencil_write }, { .fragment }, { .shader_read })

            if peel_index < depth_peel_count - 1 {
                render_commands.push_buffer.read_cursor = peel_header_restore
                peel_index += 1
                peeling = true

                peel_clear_color = {}
                if peel_index == depth_peel_count - 1 {
                    peel_clear_color = render_commands.clear_color
                    peel_clear_color.a = 1
                }
                vk_begin_depth_peel_pass(commands, vulkan.depth_peel_buffers[peel_index], .clear, peel_clear_color)
            } else {
                peel_index = 0
                peeling = false
                vk_begin_depth_peel_pass(commands, vulkan.depth_peel_buffers[peel_index], .load, {})
            }

        case .Textured_Quads:
            timed_block("textured quads")
            entry := read(&render_commands.push_buffer, Textured_Quads)
            if entry.quad_count == 0 do continue
            setup := entry.setup
            render_rect := rectangle_zero_min_dimension(render_commands.dimension)
            clip := get_intersection(setup.clip_rect, render_rect)
            if !has_area(clip) do continue

            gpu.set_viewport(commands, 0, 0, cast(f32) render_extent.x, cast(f32) render_extent.y)
            dim := get_dimension(clip)
            scissor_y := cast(i32) render_extent.y - clip.max.y
            gpu.set_scissor(commands, clip.min.x, scissor_y, cast(u32) dim.x, cast(u32) dim.y)

            gpu.draw(commands, gpu.byte_slice(&VulkanQuadRoot {
                vertices            = uploads.vertices.gpu,
                projection          = (setup.projection),
                camera_p            = { **setup.camera_p, 1 },
                fog_direction       = { **setup.fog_direction, 0 },
                fog_color           = { **setup.fog_color, 0 },
                fog_and_clip        = { setup.fog_begin, setup.fog_end, setup.clip_alpha_begin, setup.clip_alpha_end },
                texture_descriptors = &uploads.texture_descriptors.gpu[entry.bitmap_offset],
                vertex_base         = entry.bitmap_offset * 4,
                previous_depth_descriptor = peeling ? vulkan.depth_peel_buffers[peel_index-1].depth_descriptor : 0,
                peeling             = cast(u32) peeling,
                alpha_threshold     = peeling && peel_index == depth_peel_count - 1 ? 0.9 : 0.02,
            }), entry.quad_count * 6)
        }
    }

    gpu.end_render_pass(commands)
    gpu.barrier(commands, { .color_output, .depth_stencil_tests }, { .color_write, .depth_stencil_write }, { .fragment }, { .shader_read })
    gpu.begin_render_pass(commands,
        colors = { gpu.color_attachment(render_view = frame.render_view, load = .clear, clear = render_commands.clear_color) },
    )
    gpu.bind_pso(commands, vulkan.composite_pso)
    composite_root: VulkanCompositeRoot
    if vulkan_debug_depth_peel_index >= 0 {
        debug_peel_index := min(cast(u32) vulkan_debug_depth_peel_index, depth_peel_count-1)
        composite_root.texture_descriptors[0] = vulkan.depth_peel_buffers[debug_peel_index].color_descriptor
        composite_root.peel_count = 1
    } else {
        for buffer, index in vulkan.depth_peel_buffers {
            composite_root.texture_descriptors[index] = buffer.color_descriptor
        }
        composite_root.peel_count = depth_peel_count
    }
    gpu.draw(commands, gpu.byte_slice(&composite_root), 3)
    gpu.end_render_pass(commands)

    vulkan.latest_completion.value += 1
    gpu.submit_and_present(vulkan.device, { commands }, vulkan.latest_completion)
}

////////////////////////////////////////////////

read_vulkan_spirv :: proc (path: string) -> (result: [] u32) {
    // :VulkanRenderer: Move this through the platform API with the other file IO.
    bytes, error := os.read_entire_file(path, context.allocator)
    assert(error == nil)
    assert(len(bytes) % size_of(u32) == 0)
    result = slice_from_parts_type(u32, raw_data(bytes), len(bytes) / size_of(u32))
    return result
}

vk_begin_frame_uploads :: proc (render_commands: ^RenderCommands) -> (result: VulkanFrameUploads) {
    timed_function()
    
    game.debug_begin_data_block("frame uploads")
    defer game.debug_end_data_block()
    
    // :VulkanRenderer: This is the one-frame version of the eventual frame
    // allocator. A later version gives each frame in flight its own bump.
    gpu.bump_reset(&vulkan.frame_data_allocator)
    
    {
        timed_block("copy textured vertices")
        
        count := cast(i32) len(render_commands.vertex_buffer)
        game.debug_record_i32(&count, "vertex count")
        
        result.vertices = gpu.bump_allocate(&vulkan.frame_data_allocator, [] Textured_Vertex, len(render_commands.vertex_buffer))
        assert(result.vertices.cpu != nil)
        copy(result.vertices.cpu, render_commands.vertex_buffer[:])
    }
    
    {
        timed_block("map texture descriptors")
        
        count := cast(i32) len(render_commands.quad_bitmap_buffer)
        game.debug_record_i32(&count, "bitmap count")
        
        result.texture_descriptors = gpu.bump_allocate(&vulkan.frame_data_allocator, [] u32, len(render_commands.quad_bitmap_buffer))
        assert(result.texture_descriptors.cpu != nil)
        for bitmap, index in render_commands.quad_bitmap_buffer {
            if texture, ok := vulkan.textures[bitmap.texture_handle]; ok {
                result.texture_descriptors.cpu[index] = texture.descriptor_index
            }
        }
    }
    return result
}

vk_change_to_settings :: proc (settings: RenderSettings) {
    // :VulkanRenderer: The first Vulkan path supports four non-MSAA depth peels.
    // Resolve targets and pixelation remain deferred.
    if vulkan.latest_completion.value != 0 do gpu.wait_timeline(vulkan.latest_completion)
    
    depth_peel_count := min(settings.depth_peel_count_hint, cap(vulkan.depth_peel_buffers))
    if depth_peel_count == 0 do depth_peel_count = 1
    vk_recreate_depth_peel_targets(cast(uv2) settings.dimension, depth_peel_count)
    
    vulkan.settings = settings
}

vk_begin_depth_peel_pass :: proc (commands: gpu.CommandBuffer, buffer: VulkanDepthPeelBuffer, color_load: gpu.LoadOp, color_clear: v4) {
    timed_function()
    gpu.begin_render_pass(commands,
        colors = { gpu.color_attachment(render_view = buffer.color_render_view, load = color_load, clear = color_clear) },
        depth  = gpu.depth_attachment(render_view = buffer.depth_render_view, load = .clear, store = .store),
    )
    gpu.set_depth_stencil(commands, depth_test = true, depth_write = true)
    gpu.bind_pso(commands, vulkan.quad_pso)
}

vk_recreate_depth_peel_targets :: proc (extent: uv2, depth_peel_count: u32) {
    timed_function()
    for &buffer in vulkan.depth_peel_buffers {
        gpu.destroy_render_view(buffer.color_render_view)
        gpu.texture_free(&vulkan.texture_allocator, &buffer.color)
        gpu.destroy_render_view(buffer.depth_render_view)
        gpu.texture_free(&vulkan.texture_allocator, &buffer.depth)
    }
    assert(depth_peel_count <= cap(vulkan.depth_peel_buffers))
    resize(&vulkan.depth_peel_buffers, depth_peel_count)
    
    descriptor_size := gpu.get_device_caps(vulkan.device).texture_descriptor_size_in_bytes
    for &buffer, index in vulkan.depth_peel_buffers {
        buffer.color = gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
            extent = { extent.x, extent.y, 1 },
            format = .bgra8_srgb,
            usage  = { .sampled, .color_attachment },
        ))
        assert(buffer.color.texture != nil)
        buffer.color_render_view = gpu.create_render_view(buffer.color.texture)
        buffer.color_descriptor = max_vulkan_textures + cast(u32) index * 2
        color_descriptor := &vulkan.texture_descriptor_heap.range.cpu[cast(u64) buffer.color_descriptor * descriptor_size]
        gpu.write_texture_descriptor(vulkan.device, color_descriptor, buffer.color.texture, .sampled)

        buffer.depth = gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
            extent = { extent.x, extent.y, 1 },
            format = .d32_float,
            usage  = { .sampled, .depth_stencil_attachment },
        ))
        assert(buffer.depth.texture != nil)
        buffer.depth_render_view = gpu.create_render_view(buffer.depth.texture)
        buffer.depth_descriptor = buffer.color_descriptor + 1
        depth_descriptor := &vulkan.texture_descriptor_heap.range.cpu[cast(u64) buffer.depth_descriptor * descriptor_size]
        gpu.write_texture_descriptor(vulkan.device, depth_descriptor, buffer.depth.texture, .sampled, aspect = .depth)
    }
    
    vulkan.depth_peel_extent = extent
}
