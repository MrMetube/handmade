package main

import gpu "./no_graphics_api"

vulkan: struct {
    settings: RenderSettings,
    
    device: gpu.Device,
    
    data_heap:      gpu.GpuHeap,
    data_allocator: gpu.BumpAllocator,
    
    texture_heap:      gpu.TextureHeap,
    texture_allocator: gpu.TextureAllocator,
    
    texture_descriptor_heap: gpu.GpuHeap,
    sampler_descriptor_heap: gpu.GpuHeap,
    
    latest_completion: gpu.TimelinePoint,
    
    textures: map[u32] gpu.PlacedTexture, // @todo can this be not a map?
    
    depth_extent: uv2,
    depth: gpu.PlacedTexture,
    depth_render_view: gpu.RenderView,
    depth_peel_views: [] gpu.RenderView, // @todo size and make on init
}

data_heap_size    ::   2 * Megabyte // @todo
texture_heap_size :: 256 * Megabyte // @todo

init_vulkan :: proc (window: rawptr) {
    device, error := gpu.create_device(window = window, swapchain_format = .bgra8_srgb)
    assert(error == .none && device != nil)
    
    vulkan.device = device
    
    // Create Texture Allocator
    caps := gpu.get_device_caps(device)
    
    vulkan.data_heap      = gpu.create_gpu_heap(device, data_heap_size)
    vulkan.data_allocator = gpu.bump_allocator(vulkan.data_heap.range)
    // defer gpu.destroy_gpu_heap(data_heap) @todo
    
    max_textures :: 256
    
    vulkan.texture_descriptor_heap = gpu.create_gpu_heap(device, caps.texture_descriptor_size_in_bytes * max_textures, .texture_descriptor_heap)
    vulkan.sampler_descriptor_heap = gpu.create_gpu_heap(device, caps.sampler_descriptor_size_in_bytes, .sampler_descriptor_heap)
    
    vulkan.texture_heap      = gpu.create_texture_heap(device, texture_heap_size)
    vulkan.texture_allocator = gpu.texture_allocator(device, vulkan.texture_heap, max_textures)
    // defer gpu.destroy_texture_heap(texture_heap) @todo
    
    vulkan.latest_completion = gpu.TimelinePoint { semaphore = gpu.create_timeline_semaphore(device) }
    
    gpu.write_sampler_descriptor(device, raw_data(vulkan.sampler_descriptor_heap.range.cpu), min_filter = .nearest, mag_filter = .nearest, address_u = .clamp_to_edge, address_v = .clamp_to_edge)
}

vk_manage_textures :: proc (last: ^TextureOp) {
    allocs, deallocs: u32
    
    for operation := last; operation != nil; operation = operation.next {
        switch &op in operation.value {
        case: unreachable()
        
        case TextureOpAllocate:
            allocs += 1
            op.result ^= vk_allocate_texture(op.bitmap)
            
        case TextureOpDeallocate:
            deallocs += 1
            
            // @todo defer texture free's like in the deferred-example
            was, texture := delete_key(&vulkan.textures, op.handle)
            assert(was == op.handle && texture.texture != nil)
            
            gpu.texture_free(&vulkan.texture_allocator, &texture)
        }
    }
    
    // @todo(viktor): Display in debug system
    print("texture ops %, allocs % deallocs %\n", allocs + deallocs, allocs, deallocs)
}

vk_allocate_texture :: proc (bitmap: Bitmap) -> u32 {
    texture := gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
        extent = { ** cast(uv2) bitmap.dimension, 1 },
        format = .rgba8_srgb,
    ))
    
    // @correctness is the token really an unique id?
    result := cast(u32) texture.token
    vulkan.textures[result] = texture
    
    
    texture_bytes := slice_to_bytes(bitmap.memory)
    upload_allocation := gpu.bump_allocate(&vulkan.data_allocator, len(texture_bytes))
    copy(upload_allocation.cpu, texture_bytes)
    
    
    gpu.write_texture_descriptor(vulkan.device, raw_data(vulkan.texture_descriptor_heap.range.cpu), texture.texture, .sampled)
    
    // @leak the upload allocation can be reused after the copy is done
    upload_commands := gpu.begin_commands(vulkan.device)
    gpu.copy_memory_to_texture(upload_commands, gpu.gpu_range(upload_allocation), texture.texture)
    
    gpu.barrier(upload_commands, { .transfer }, { .transfer_write }, { .fragment }, { .shader_read })
    
    vulkan.latest_completion.value += 1
    gpu.submit( { upload_commands }, vulkan.latest_completion)
    
    return result
}

vk_render_commands :: proc (render_commands: ^RenderCommands, draw_region: Rectangle2i, window_dim: v2i) {
    timed_function()
    
    if render_commands.settings != vulkan.settings {
        vk_change_to_settings(render_commands.settings)
    }
    
    frame := gpu.acquire(vulkan.device)
    if frame.render_view == nil { return }
    
    if frame.extent != vulkan.depth_extent {
        if vulkan.depth.texture != nil {
            gpu.wait_timeline(vulkan.latest_completion)
        }
        
        gpu.destroy_render_view(vulkan.depth_render_view)
        gpu.texture_free(&vulkan.texture_allocator, &vulkan.depth)
        
        vulkan.depth = gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
            extent = { frame.extent.x, frame.extent.y, 1 },
            format = .d32_float,
            usage  = { .depth_stencil_attachment },
        ))
        vulkan.depth_render_view = gpu.create_render_view(vulkan.depth.texture)
        vulkan.depth_extent      = frame.extent
    }
    
    commands := gpu.begin_commands(vulkan.device)
    gpu.set_texture_descriptor_heap(commands, gpu.gpu_range(vulkan.texture_descriptor_heap))
    gpu.set_sampler_descriptor_heap(commands, gpu.gpu_range(vulkan.sampler_descriptor_heap))
    
    // @todo for all render_passes enforce that the viewport is set to commands.dimension
    
    depth_attachment := gpu.depth_attachment(
        render_view = vulkan.depth_render_view,
        load  = .clear,
        clear = 1,
    )
    
    // @todo barrier
    gpu.begin_render_pass(commands, colors = { gpu.color_attachment(
            render_view = vulkan.depth_peel_views[0],
            load        = .clear,
            clear       = render_commands.clear_color,
        ) }, depth = depth_attachment)
    gpu.set_depth_stencil(commands, depth_test = true, depth_write = true)
    
    peeling: bool
    peel_index: u32
    peel_header_restore: int
    for begin_reading(&render_commands.push_buffer); can_read(&render_commands.push_buffer); {
        header := read(&render_commands.push_buffer, RenderEntryHeader)
        
        switch header.type {
        case .None: unreachable()
        case: panic("Unhandled Entry")
            
        case .DepthClear:
            gpu.end_render_pass(commands)
            
            gpu.begin_render_pass(commands, colors = { gpu.color_attachment(
                render_view = vulkan.depth_peel_views[peel_index],
                load        = .load,
            ) }, depth = depth_attachment)
            gpu.set_depth_stencil(commands, depth_test = true, depth_write = true)
            
        case .BeginPeels:
            peel_header_restore = render_commands.push_buffer.read_cursor
            
        case .EndPeels:
            // if open_gl.multisampling {
            //     from := open_gl.depth_peel_buffers[peel_index]
            //     to   := open_gl.depth_peel_resolve_buffers[peel_index]
            //     when true {
            //         resolve_multisample(from, to, render_dim)
            //     } else {
            //         gl.BindFramebuffer(gl.READ_FRAMEBUFFER, from.handle)
            //         gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, to.handle)
            //         gl.Viewport(0, 0, render_dim.x, render_dim.y)
            //         gl.BlitFramebuffer(0, 0, render_dim.x, render_dim.y, 0, 0, render_dim.x, render_dim.y, gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT, gl.NEAREST)
            //     }
            // }
            
            if peel_index < open_gl.depth_peel_count-1 {
                render_commands.push_buffer.read_cursor = peel_header_restore
                
                peel_index += 1
                peeling = peel_index > 0
                
                gpu.end_render_pass(commands)
                gpu.begin_render_pass(commands, colors = { gpu.color_attachment(
                    render_view = vulkan.depth_peel_views[peel_index],
                    load        = .load,
                ) }, depth = gpu.depth_attachment( render_view = vulkan.depth_render_view, load = .load ))
                gpu.set_depth_stencil(commands, depth_test = true, depth_write = true)
                
            } else {
                assert(peel_index == open_gl.depth_peel_count-1)
                
                peeling = false
                peel_index = 0
                
                // buffer := get_depth_peel_read_buffer(0)
                // gl_bind_frame_buffer(buffer, render_dim)
                // @todo this has a branch on multisample enabled
                
                gpu.end_render_pass(commands)
                gpu.begin_render_pass(commands, colors = { gpu.color_attachment(
                    render_view = vulkan.depth_peel_views[0],
                    load        = .load,
                ) }, depth = gpu.depth_attachment( render_view = vulkan.depth_render_view, load = .load ))
                gpu.set_depth_stencil(commands, depth_test = true, depth_write = true)
                
            }
            
        case .Textured_Quads:
            entry := read(&render_commands.push_buffer, Textured_Quads)
            
            ////////////////////////////////////////////////
            // gl_bind_frame_buffer(open_gl.depth_peel_buffers[peel_index], render_dim)
            
            // setup := entry.setup
            // gl.Scissor(get_xywh(setup.clip_rect))
            
            // copy := game.begin_timed_block("gl copy buffer data")
            // gl.BufferData(gl.ARRAY_BUFFER, len(render_commands.vertex_buffer) * size_of(Textured_Vertex), raw_data(render_commands.vertex_buffer), gl.STREAM_DRAW)
            // game.end_timed_block(copy)
            
            // ////////////////////////////////////////////////
            
            // program := open_gl.zbias_no_depth_peel
            // alpha_threshold: f32 = 0.02
            // if peeling {
            //     program = open_gl.zbias_depth_peel
            //     buffer := get_depth_peel_read_buffer(peel_index-1)
                
            //     // @metaprogram
            //     gl.ActiveTexture(gl.TEXTURE1)
            //     gl.BindTexture(gl.TEXTURE_2D, buffer.depth_texture)
            //     gl.ActiveTexture(gl.TEXTURE0)
            //     if peel_index == open_gl.depth_peel_count-1 {
            //         alpha_threshold = 0.9
            //     }
            // }
            // begin_program(program, setup, alpha_threshold)
            
            // loop := game.begin_timed_block("gl quad loop")
            // for bitmap_index in entry.bitmap_offset ..< entry.bitmap_offset + entry.quad_count {
            //     bitmap := render_commands.quad_bitmap_buffer[bitmap_index]
            //     gl.BindTexture(gl.TEXTURE_2D, bitmap.texture_handle)
                
            //     vertex_index := cast(i32) bitmap_index * 4
            //     gl.DrawArrays(gl.TRIANGLE_STRIP, vertex_index, 4)
            // }
            // end_timed_block(loop)
            
            // end_program(program)
            
            // // @metaprogram
            // gl.BindTexture(gl.TEXTURE_2D, 0)
            // if peeling {
            //     gl.ActiveTexture(gl.TEXTURE1)
            //     gl.BindTexture(gl.TEXTURE_2D, 0)
            //     gl.ActiveTexture(gl.TEXTURE0)
            // }
        }
    }
    
    gpu.end_render_pass(commands)
    
    vulkan.latest_completion.value += 1
    gpu.submit_and_present(vulkan.device, { commands }, vulkan.latest_completion)
}

vk_change_to_settings :: proc (settings: RenderSettings) {
    
    // @todo delete old peel and resolve and light buffers
    // @todo delete old peel, zbias, composite, final_strech, and multisample programs
    // @todo recreate render textures, programms
    
    unimplemented()
}