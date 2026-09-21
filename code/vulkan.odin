package main

import "core:os"

import gpu "./no_graphics_api"

// @todo this is ok for now, but the platform should control the paths like for all other things like the platform_api that the game layer uses
VulkanVertexSpirvPath   :: #config(VulkanVertexSpirvPath,   "vulkan.vertex.spirv")
VulkanFragmentSpirvPath :: #config(VulkanFragmentSpirvPath, "vulkan.fragment.spirv")

VulkanTexture :: struct {
    placed:           gpu.PlacedTexture,
    descriptor_index: u32,
}

VulkanQuadRoot :: struct {
    projection:         m4,
    vertices:           [^] Textured_Vertex,
    // @todo these dont all need to be packed into v4s
    camera_p:           v4,
    fog_direction:      v4,
    fog_color:          v4,
    fog_and_clip:       v4,
    texture_descriptor: u32,
    vertex_base:        u32,
}

// @todo generate the slang definitions from the odin code in the future
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
#assert(offset_of(VulkanQuadRoot, texture_descriptor) == 136)
#assert(offset_of(VulkanQuadRoot, vertex_base)        == 140)

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
    
    textures: map[u32] VulkanTexture,
     // @todo move to last_used_xxx so that zero is the correct initial value
    next_texture_handle:    u32,
    next_texture_descriptor: u32,
    
    depth_extent: uv2,
    depth: gpu.PlacedTexture,
    depth_render_view: gpu.RenderView,
}

// @todo make these parameters of init and or part of the vulkan state if needed
frame_data_heap_size     ::  32 * Megabyte
texture_upload_heap_size ::  64 * Megabyte
texture_heap_size        :: 256 * Megabyte
max_vulkan_textures      :: 256

// @todo mark all regions that need further iteration to complete the renderer with a tag like the codebase has, i.e. :VulkanRenderer: or something. these are hightlighted in my text editor and make grepping easy. each spot can then be marked and add a explanation if needed or refer to another marking tag.
// @todo this is not c. functions should be ordered like other files. effectively but not strictly by calling order and sections with /// separators

read_vulkan_spirv :: proc (path: string) -> (result: [] u32) {
    // @todo long term i dont want the renderer to call to the os. the platform.odin should handle this, but its fine for now.
    bytes, error := os.read_entire_file(path, context.allocator)
    assert(error == nil)
    assert(len(bytes) % size_of(u32) == 0)
    result = slice_from_parts_type(u32, raw_data(bytes), len(bytes) / size_of(u32))
    return result
}

init_vulkan :: proc (window: rawptr) {
    device, error := gpu.create_device(window = window, swapchain_format = .bgra8_srgb)
    assert(error == .none && device != nil)
    
    vulkan.device = device
    
    caps := gpu.get_device_caps(device)
    
    vulkan.frame_data_heap      = gpu.create_gpu_heap(device, frame_data_heap_size)
    vulkan.frame_data_allocator = gpu.bump_allocator(vulkan.frame_data_heap.range)

    vulkan.texture_upload_heap      = gpu.create_gpu_heap(device, texture_upload_heap_size)
    vulkan.texture_upload_allocator = gpu.bump_allocator(vulkan.texture_upload_heap.range)
    
    vulkan.texture_descriptor_heap = gpu.create_gpu_heap(device, caps.texture_descriptor_size_in_bytes * max_vulkan_textures, .texture_descriptor_heap)
    vulkan.sampler_descriptor_heap = gpu.create_gpu_heap(device, caps.sampler_descriptor_size_in_bytes, .sampler_descriptor_heap)
    
    vulkan.texture_heap      = gpu.create_texture_heap(device, texture_heap_size)
    vulkan.texture_allocator = gpu.texture_allocator(device, vulkan.texture_heap, max_vulkan_textures)
    
    vulkan.latest_completion = gpu.TimelinePoint { semaphore = gpu.create_timeline_semaphore(device) }
    vulkan.next_texture_handle = 1
    
    gpu.write_sampler_descriptor(device, raw_data(vulkan.sampler_descriptor_heap.range.cpu), min_filter = .linear, mag_filter = .linear, address_u = .clamp_to_edge, address_v = .clamp_to_edge)
    
    vertex_spirv   := read_vulkan_spirv(VulkanVertexSpirvPath)
    fragment_spirv := read_vulkan_spirv(VulkanFragmentSpirvPath)
    defer {
        delete(vertex_spirv)
        delete(fragment_spirv)
    }
    
    vulkan.quad_pso = gpu.create_graphics_pso(device,
        vertex_spirv   = vertex_spirv,
        fragment_spirv = fragment_spirv,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
        depth_format   = .d32_float,
        rasterization  = { cull = .none },
    )
}

vk_manage_textures :: proc (last: ^TextureOp) {
    allocs, deallocs: u32

    // Texture destruction is immediate in NoGraphicsAPI. The simple renderer has
    // one frame in flight, so draining it here is enough until a delete queue is
    // introduced with the asynchronous frame allocator.
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
    
    // @todo(viktor): Display in debug system
    print("texture ops %, allocs % deallocs %\n", allocs + deallocs, allocs, deallocs)
}

vk_allocate_texture :: proc (bitmap: Bitmap) -> u32 {
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
    
    texture_bytes := slice_to_bytes(bitmap.memory)
    upload := gpu.bump_allocate(&vulkan.texture_upload_allocator, len(texture_bytes))
    assert(upload.cpu != nil)
    copy(upload.cpu, texture_bytes)
    
    commands := gpu.begin_commands(vulkan.device)
    gpu.copy_memory_to_texture(commands, gpu.gpu_range(upload), placed.texture)
    gpu.barrier(commands, { .transfer }, { .transfer_write }, { .fragment }, { .shader_read })
    
    vulkan.latest_completion.value += 1
    gpu.submit({ commands }, vulkan.latest_completion)
    
    result := vulkan.next_texture_handle
    vulkan.next_texture_handle += 1
    vulkan.textures[result] = { placed, descriptor_index }
    return result
}

vk_begin_frame_uploads :: proc (vertices: [] Textured_Vertex) -> (result: gpu.GpuCpuRange(Textured_Vertex)) {
    // This is the one-frame version of the eventual frame allocator. A later
    // version gives each frame in flight its own bump allocator.
    gpu.bump_reset(&vulkan.frame_data_allocator)

    if len(vertices) != 0 {
        result = gpu.bump_allocate(&vulkan.frame_data_allocator, [] Textured_Vertex, len(vertices))
        assert(result.cpu != nil)
        copy(result.cpu, vertices)
    }
    return result
}

vk_recreate_depth :: proc (extent: uv2) {
    if vulkan.depth.texture != nil {
        gpu.destroy_render_view(vulkan.depth_render_view)
        gpu.texture_free(&vulkan.texture_allocator, &vulkan.depth)
    }
    
    vulkan.depth = gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
        extent = { extent.x, extent.y, 1 },
        format = .d32_float,
        usage  = { .depth_stencil_attachment },
    ))
    assert(vulkan.depth.texture != nil)
    
    vulkan.depth_render_view = gpu.create_render_view(vulkan.depth.texture)
    vulkan.depth_extent = extent
}

vk_render_commands :: proc (render_commands: ^RenderCommands, draw_region: Rectangle2i, window_dim: v2i) {
    timed_function()
    unused(draw_region)
    unused(window_dim)

    if render_commands.settings != vulkan.settings {
        vk_change_to_settings(render_commands.settings)
    }

    frame := gpu.acquire(vulkan.device)
    if frame.render_view == nil { return }

    if frame.extent != vulkan.depth_extent {
        if vulkan.latest_completion.value != 0 do gpu.wait_timeline(vulkan.latest_completion)
        vk_recreate_depth(frame.extent)
    }

    vertices := vk_begin_frame_uploads(render_commands.vertex_buffer[:])
    commands := gpu.begin_commands(vulkan.device)
    gpu.set_texture_descriptor_heap(commands, gpu.gpu_range(vulkan.texture_descriptor_heap))
    gpu.set_sampler_descriptor_heap(commands, gpu.gpu_range(vulkan.sampler_descriptor_heap))

    gpu.begin_render_pass(commands,
        colors = { gpu.color_attachment(render_view = frame.render_view, load = .clear, clear = render_commands.clear_color) },
        depth  = gpu.depth_attachment(render_view = vulkan.depth_render_view, load = .clear, store = .discard),
    )
    gpu.set_depth_stencil(commands, depth_test = true, depth_write = true)
    gpu.bind_pso(commands, vulkan.quad_pso)

    for begin_reading(&render_commands.push_buffer); can_read(&render_commands.push_buffer); {
        header := read(&render_commands.push_buffer, RenderEntryHeader)

        switch header.type {
        case .None: unreachable()
        case .DepthClear:
            gpu.end_render_pass(commands)
            gpu.begin_render_pass(commands,
                colors = { gpu.color_attachment(render_view = frame.render_view, load = .load) },
                depth  = gpu.depth_attachment(render_view = vulkan.depth_render_view, load = .clear, store = .discard),
            )
            gpu.set_depth_stencil(commands, depth_test = true, depth_write = true)
            gpu.bind_pso(commands, vulkan.quad_pso)

        case .BeginPeels, .EndPeels:
            // :VulkanRenderer: Depth peeling needs its own color/depth targets
            // and compositing pass. The basic opaque depth path still honors
            // DepthClear above while this work remains deferred.

        case .Textured_Quads:
            entry := read(&render_commands.push_buffer, Textured_Quads)
            setup := entry.setup
            render_rect := Rectangle2i { min = {}, max = cast(v2i) frame.extent }
            clip := get_intersection(setup.clip_rect, render_rect)
            if !has_area(clip) do continue

            gpu.set_viewport(commands, 0, 0, cast(f32) frame.extent.x, cast(f32) frame.extent.y)
            dim := get_dimension(clip)
            gpu.set_scissor(commands, clip.min.x, clip.min.y, cast(u32) dim.x, cast(u32) dim.y)

            for bitmap_index in entry.bitmap_offset ..< entry.bitmap_offset + entry.quad_count {
                bitmap := render_commands.quad_bitmap_buffer[bitmap_index]
                texture, ok := vulkan.textures[bitmap.texture_handle]
                if !ok do continue

                root := VulkanQuadRoot {
                    vertices           = vertices.gpu,
                    projection         = (setup.projection),
                    camera_p           = { **setup.camera_p, 1 },
                    fog_direction      = { **setup.fog_direction, 0 },
                    fog_color          = { **setup.fog_color, 0 },
                    fog_and_clip       = { setup.fog_begin, setup.fog_end, setup.clip_alpha_begin, setup.clip_alpha_end },
                    texture_descriptor = texture.descriptor_index,
                    vertex_base        = bitmap_index * 4,
                }
                gpu.draw(commands, gpu.byte_slice(&root), 6)
            }
        }
    }

    gpu.end_render_pass(commands)

    vulkan.latest_completion.value += 1
    gpu.submit_and_present(vulkan.device, { commands }, vulkan.latest_completion)
}

vk_change_to_settings :: proc (settings: RenderSettings) {
    // :VulkanRenderer: The first Vulkan path renders directly to the swapchain.
    // Settings-dependent offscreen peel and resolve targets are deliberately
    // deferred until the basic textured-quad pass has parity with OpenGL.
    vulkan.settings = settings
}
