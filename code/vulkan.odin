package main

import "core:os"

import gpu "./no_graphics_api"

// :VulkanRenderer: The platform should own shader loading and expose the paths
// through the game/platform API rather than this renderer-owned config.
VulkanVertexSpirvPath            :: #config(VulkanVertexSpirvPath,            "vulkan.vertex.spirv")
VulkanFragmentSpirvPath          :: #config(VulkanFragmentSpirvPath,          "vulkan.fragment.spirv")
VulkanCompositeVertexSpirvPath   :: #config(VulkanCompositeVertexSpirvPath,   "vulkan.composite_vertex.spirv")
VulkanCompositeFragmentSpirvPath :: #config(VulkanCompositeFragmentSpirvPath, "vulkan.composite_fragment.spirv")
VulkanFinalVertexSpirvPath       :: #config(VulkanFinalVertexSpirvPath,       "vulkan.final_vertex.spirv")
VulkanFinalFragmentSpirvPath     :: #config(VulkanFinalFragmentSpirvPath,     "vulkan.final_fragment.spirv")

////////////////////////////////////////////////

frame_data_heap_size     ::  32 * Megabyte
texture_upload_heap_size ::  64 * Megabyte
texture_heap_size        :: 256 * Megabyte
VulkanFrameCount         :: 2

max_vulkan_textures :: 256

Debug_vulkan_depth_peel_index: i32 = -1 // -1 composites all layers

vulkan: struct {
    settings: RenderSettings,
    
    device: gpu.Device,
    
    frames: [VulkanFrameCount] VulkanFrame,
    next_frame_index: u32,

    texture_upload_heap:      gpu.GpuHeap,
    texture_upload_allocator: gpu.BumpAllocator,
    
    texture_heap:      gpu.TextureHeap,
    texture_allocator: gpu.TextureAllocator,
    
    texture_descriptor_heap: gpu.GpuHeap,
    sampler_descriptor_heap: gpu.GpuHeap,
    
    latest_completion: gpu.TimelinePoint,
    
    quad_pso:      gpu.PSO,
    composite_pso: gpu.PSO,
    final_pso:     gpu.PSO,
    
    textures: [1 + cast(u32) VulkanTextureDescriptor.count] gpu.PlacedTexture,
    next_texture_descriptor:  u32,
    free_texture_descriptors: [dynamic; VulkanTextureDescriptor.count] u32,
    
    depth_peel_buffers: [dynamic; 4] VulkanDepthPeelBuffer,
    composite_buffer:   RenderTarget,
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
    composite,
    first_dynamic_texture,
    count = first_dynamic_texture + max_vulkan_textures,
}

VulkanFrame :: struct {
    data_heap:      gpu.GpuHeap,
    data_allocator: gpu.BumpAllocator,
    completion:     gpu.TimelinePoint,
}


VulkanDepthPeelBuffer :: struct {
    color: RenderTarget,
    depth: RenderTarget,
}

RenderTarget :: struct {
    placed:           gpu.PlacedTexture,
    render_view:      gpu.RenderView,
    descriptor_index: u32,
}

VulkanFrameUploads :: struct {
    vertices:            gpu.GpuCpuRange(Textured_Vertex),
    texture_descriptors: gpu.GpuCpuRange(u32),
}

////////////////////////////////////////////////

VulkanQuadRoot :: struct {
    projection:                m4,
    vertices:                  [^] Textured_Vertex,
    texture_descriptors:       [^] u32,
    camera_p:                  v3,
    fog_direction:             v3,
    fog_color:                 v3,
    fog_begin:                 f32,
    fog_end:                   f32,
    clip_alpha_begin:          f32,
    clip_alpha_end:            f32,
    vertex_base:               u32,
    previous_depth_descriptor: u32,
    alpha_threshold:           f32,
}

VulkanCompositeRoot :: struct {
    texture_descriptors: [cap(vulkan.depth_peel_buffers)] u32,
    peel_count:          u32,
}

VulkanFinalRoot :: struct {
    texture_descriptor: u32,
    sampler_descriptor: u32,
}

////////////////////////////////////////////////

init_vulkan :: proc (window: pmm) {
    device, error := gpu.create_device(window = window, swapchain_format = .bgra8_srgb, desired_swapchain_image_count = VulkanFrameCount)
    assert(error == .none && device != nil)
    
    vulkan.device = device
    
    caps := gpu.get_device_caps(device)
    
    vulkan.latest_completion = gpu.TimelinePoint { semaphore = gpu.create_timeline_semaphore(device) }
    for &frame in vulkan.frames {
        frame.data_heap      = gpu.create_gpu_heap(device, frame_data_heap_size)
        frame.data_allocator = gpu.bump_allocator(frame.data_heap.range)
        frame.completion.semaphore = vulkan.latest_completion.semaphore
    }

    vulkan.texture_upload_heap      = gpu.create_gpu_heap(device, texture_upload_heap_size)
    vulkan.texture_upload_allocator = gpu.bump_allocator(vulkan.texture_upload_heap.range)
    
    vulkan.texture_descriptor_heap = gpu.create_gpu_heap(device, caps.texture_descriptor_size_in_bytes * cast(u64) VulkanTextureDescriptor.count, .texture_descriptor_heap)
    vulkan.sampler_descriptor_heap = gpu.create_gpu_heap(device, caps.sampler_descriptor_size_in_bytes * 2, .sampler_descriptor_heap)
    
    vulkan.texture_heap      = gpu.create_texture_heap(device, texture_heap_size)
    vulkan.texture_allocator = gpu.texture_allocator(device, vulkan.texture_heap, cast(u32) VulkanTextureDescriptor.count)
    
    vulkan.next_texture_descriptor = cast(u32) VulkanTextureDescriptor.first_dynamic_texture
    gpu.write_sampler_descriptor(device, sampler_descriptor(0), min_filter = .linear, mag_filter = .linear, address_u = .clamp_to_edge, address_v = .clamp_to_edge)
    gpu.write_sampler_descriptor(device, sampler_descriptor(1), min_filter = .nearest, mag_filter = .nearest, address_u = .clamp_to_edge, address_v = .clamp_to_edge)
    
    vertex_spirv             := read_vulkan_spirv(VulkanVertexSpirvPath)
    fragment_spirv           := read_vulkan_spirv(VulkanFragmentSpirvPath)
    composite_vertex_spirv   := read_vulkan_spirv(VulkanCompositeVertexSpirvPath)
    composite_fragment_spirv := read_vulkan_spirv(VulkanCompositeFragmentSpirvPath)
    final_vertex_spirv       := read_vulkan_spirv(VulkanFinalVertexSpirvPath)
    final_fragment_spirv     := read_vulkan_spirv(VulkanFinalFragmentSpirvPath)
    defer {
        delete(vertex_spirv)
        delete(fragment_spirv)
        delete(composite_vertex_spirv)
        delete(composite_fragment_spirv)
        delete(final_vertex_spirv)
        delete(final_fragment_spirv)
    }
    
    vulkan.quad_pso = gpu.create_graphics_pso(device,
        vertex_spirv   = vertex_spirv,
        fragment_spirv = fragment_spirv,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
        depth_format   = .d32_float,
        rasterization  = { cull = .counter_clockwise },
    )
    vulkan.composite_pso = gpu.create_graphics_pso(device,
        vertex_spirv   = composite_vertex_spirv,
        fragment_spirv = composite_fragment_spirv,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
        rasterization  = { cull = .none },
    )
    vulkan.final_pso = gpu.create_graphics_pso(device,
        vertex_spirv   = final_vertex_spirv,
        fragment_spirv = final_fragment_spirv,
        color_targets  = { gpu.color_target_desc(format = .bgra8_srgb) },
        rasterization  = { cull = .none },
    )
}

////////////////////////////////////////////////

vk_allocate_texture :: proc (bitmap: Bitmap, set_as_nil_texture := false) -> u32 {
    timed_function()
    
    placed := gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
        extent = { **cast(uv2) bitmap.dimension, 1 },
        format = .rgba8_srgb,
        usage  = { .sampled, .transfer_destination },
    ))
    assert(placed.texture != nil)
    
    descriptor: pmm
    descriptor_index: u32
    if set_as_nil_texture {
        descriptor_index = cast(u32) VulkanTextureDescriptor.nil_texture
        descriptor = texture_descriptor(descriptor_index)
    } else {
        descriptor, descriptor_index = allocate_texture_descriptor()
    }
    gpu.write_texture_descriptor(vulkan.device, descriptor, placed.texture, .sampled)
    
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

vk_manage_textures :: proc (last: ^TextureOp) {
    timed_function()
    debug_data_block("Renderer")
    debug_data_block("texture operations")
    
    allocs, deallocs: u32

    // :VulkanRenderer: Texture destruction is immediate in NoGraphicsAPI.
    // Wait for every submitted frame before changing shared texture allocations.
    if vulkan.latest_completion.value != 0 do gpu.wait_timeline(vulkan.latest_completion)
    
    for operation := last; operation != nil; operation = operation.next {
        switch &op in operation.value {
        case: unreachable()
        
        case TextureOpAllocate:
            allocs += 1
            op.result ^= vk_allocate_texture(op.bitmap)
            
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
    game.debug_record_i32(&count, "count")
    allocations := cast(i32) allocs
    game.debug_record_i32(&allocations, "allocations")
    deallocations := cast(i32) deallocs
    game.debug_record_i32(&deallocations, "deallocations")
}

////////////////////////////////////////////////

vk_render_commands :: proc (render_commands: ^RenderCommands, draw_region: Rectangle2i, window_dim: v2i) {
    timed_function()
    
    if render_commands.settings != vulkan.settings {
        change_to_settings(render_commands.settings)
    }
    
    zone_1 := game.begin_timed_block("acquire frame")
    frame := gpu.acquire(vulkan.device)
    game.end_timed_block(zone_1)
    if frame.render_view == nil { return }

    frame_index := vulkan.next_frame_index
    vulkan.next_frame_index = (frame_index + 1) % cast(u32) VulkanFrameCount
    frame_data := &vulkan.frames[frame_index]
    if frame_data.completion.value != 0 do gpu.wait_timeline(frame_data.completion)
    
    render_extent := cast(uv2) render_commands.dimension
    depth_peel_count := cast(u32) len(vulkan.depth_peel_buffers)
    
    uploads := upload_frame_data(render_commands, frame_data)
    
    zone0 := game.begin_timed_block("begin commands")
    commands := gpu.begin_commands(vulkan.device)
    gpu.set_texture_descriptor_heap(commands, gpu.gpu_range(vulkan.texture_descriptor_heap))
    gpu.set_sampler_descriptor_heap(commands, gpu.gpu_range(vulkan.sampler_descriptor_heap))
    game.end_timed_block(zone0)
    
    ////////////////////////////////////////////////
    
    peel_index: u32
    peel_header_restore: int
    begin_depth_peel_pass(commands, peel_index, .clear, render_commands.clear_color)
    
    for begin_reading(&render_commands.push_buffer); can_read(&render_commands.push_buffer); {
        header := read(&render_commands.push_buffer, RenderEntryHeader)
        
        switch header.type {
        case .None: unreachable()
        case .DepthClear:
            timed_block("depth clear")
            gpu.end_render_pass(commands)
            begin_depth_peel_pass(commands, peel_index, .load)
            
        case .BeginPeels:
            timed_block("begin peels")
            peel_header_restore = render_commands.push_buffer.read_cursor
            
        case .EndPeels:
            timed_block("end peels")
            end_depth_peel_pass(commands)
            
            if peel_index < depth_peel_count - 1 {
                render_commands.push_buffer.read_cursor = peel_header_restore
                peel_index += 1
                
                begin_depth_peel_pass(commands, peel_index, .clear, render_commands.clear_color)
            } else {
                peel_index = 0
                begin_depth_peel_pass(commands, peel_index, .load)
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
                vertices                  = uploads.vertices.gpu,
                projection                = (setup.projection),
                texture_descriptors       = &uploads.texture_descriptors.gpu[entry.bitmap_offset],
                camera_p                  = setup.camera_p,
                fog_direction             = setup.fog_direction,
                fog_color                 = setup.fog_color,
                fog_begin                 = setup.fog_begin,
                fog_end                   = setup.fog_end,
                clip_alpha_begin          = setup.clip_alpha_begin,
                clip_alpha_end            = setup.clip_alpha_end,
                vertex_base               = entry.bitmap_offset * 4,
                previous_depth_descriptor = peel_index != 0 ? vulkan.depth_peel_buffers[peel_index-1].depth.descriptor_index : 0,
                alpha_threshold           = peel_index != 0 && peel_index == depth_peel_count - 1 ? 0.9 : 0.02,
            }), entry.quad_count * 6)
        }
    }
    
    end_depth_peel_pass(commands)
    
    ////////////////////////////////////////////////
    
    {
        timed_block("peel composite")
        
        gpu.begin_render_pass(commands,
            colors = { gpu.color_attachment(render_view = vulkan.composite_buffer.render_view, load = .clear, clear = render_commands.clear_color) },
        )
        
        gpu.bind_pso(commands, vulkan.composite_pso)
        composite_root: VulkanCompositeRoot
        if Debug_vulkan_depth_peel_index >= 0 {
            debug_peel_index := min(cast(u32) Debug_vulkan_depth_peel_index, depth_peel_count-1)
            composite_root.texture_descriptors[0] = vulkan.depth_peel_buffers[debug_peel_index].color.descriptor_index
            composite_root.peel_count = 1
        } else {
            for buffer, index in vulkan.depth_peel_buffers {
                composite_root.texture_descriptors[index] = buffer.color.descriptor_index
            }
            composite_root.peel_count = depth_peel_count
        }
        gpu.draw(commands, gpu.byte_slice(&composite_root), 3)
        
        gpu.end_render_pass(commands)
    }
    
    gpu.barrier(commands, { .color_output }, { .color_write }, { .fragment }, { .shader_read })
    
    {
        timed_block("final stretch")
        
        gpu.begin_render_pass(commands,
            colors = { gpu.color_attachment(render_view = frame.render_view, load = .clear) },
        )
        
        gpu.bind_pso(commands, vulkan.final_pso)
        
        draw_dim := get_dimension(draw_region)
        draw_y := window_dim.y - draw_region.max.y
        gpu.set_viewport(commands, cast(f32) draw_region.min.x, cast(f32) draw_y, cast(f32) draw_dim.x, cast(f32) draw_dim.y)
        gpu.set_scissor(commands, draw_region.min.x, draw_y, cast(u32) draw_dim.x, cast(u32) draw_dim.y)
        
        gpu.draw(commands, gpu.byte_slice(&VulkanFinalRoot {
            texture_descriptor = vulkan.composite_buffer.descriptor_index,
            sampler_descriptor = render_commands.pixelation_hint ? 1 : 0,
        }), 3)
        
        gpu.end_render_pass(commands)
    }
    
    zone1 := game.begin_timed_block("submit and present")
    vulkan.latest_completion.value += 1
    frame_data.completion = vulkan.latest_completion
    gpu.submit_and_present(vulkan.device, { commands }, vulkan.latest_completion)
    game.end_timed_block(zone1)
}

////////////////////////////////////////////////

read_vulkan_spirv :: proc (path: string) -> [] u32 {
    // :VulkanRenderer: Move this through the platform API with the other file IO.
    bytes, error := os.read_entire_file(path, context.allocator)
    assert(error == nil)
    assert(len(bytes) % size_of(u32) == 0)
    result := slice_from_parts_type(u32, raw_data(bytes), len(bytes) / size_of(u32))
    return result
}

upload_frame_data :: proc (render_commands: ^RenderCommands, frame: ^VulkanFrame) -> VulkanFrameUploads {
    timed_function()
    
    debug_data_block("Renderer")
    debug_data_block("frame uploads")
    
    gpu.bump_reset(&frame.data_allocator)
    
    result: VulkanFrameUploads
    {
        timed_block("copy textured vertices")
        
        count := cast(i32) len(render_commands.vertex_buffer)
        game.debug_record_i32(&count, "vertex count")
        
        result.vertices = gpu.bump_allocate(&frame.data_allocator, [] Textured_Vertex, len(render_commands.vertex_buffer))
        copy(result.vertices.cpu, render_commands.vertex_buffer[:])
    }
    
    {
        timed_block("copy texture descriptors")
        
        count := cast(i32) len(render_commands.quad_bitmap_buffer)
        game.debug_record_i32(&count, "bitmap count")
        
        result.texture_descriptors = gpu.bump_allocate(&frame.data_allocator, [] u32, len(render_commands.quad_bitmap_buffer))
        
        for bitmap, index in render_commands.quad_bitmap_buffer {
            texture_handle := max(0, bitmap.texture_handle-1)
            result.texture_descriptors.cpu[index] = texture_handle
        }
    }
    return result
}

destroy_render_target :: proc (target: ^RenderTarget) {
    gpu.destroy_render_view(target.render_view)
    gpu.texture_free(&vulkan.texture_allocator, &target.placed)
}

change_to_settings :: proc (settings: RenderSettings) {
    timed_function()
    
    // :VulkanRenderer: Multisampled depth peels remain deferred.
    if vulkan.latest_completion.value != 0 do gpu.wait_timeline(vulkan.latest_completion)
    
    depth_peel_count := clamp(settings.depth_peel_count_hint, 1, cap(vulkan.depth_peel_buffers))
    extent := cast(uv2) settings.dimension
    
    {
        timed_block("recreate_depth_peel_targets")
        
        for &buffer in vulkan.depth_peel_buffers {
            destroy_render_target(&buffer.color)
            destroy_render_target(&buffer.depth)
        }
        destroy_render_target(&vulkan.composite_buffer)
        
        assert(depth_peel_count <= cap(vulkan.depth_peel_buffers))
        resize(&vulkan.depth_peel_buffers, depth_peel_count)
        
        for &buffer, index in vulkan.depth_peel_buffers {
            buffer.color.placed = gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
                extent = { extent.x, extent.y, 1 },
                format = .bgra8_srgb,
                usage  = { .sampled, .color_attachment },
            ))
            assert(buffer.color.placed.texture != nil)
            
            buffer.color.render_view = gpu.create_render_view(buffer.color.placed.texture)
            buffer.color.descriptor_index = cast(u32) VulkanTextureDescriptor.depth_peel_0_color + cast(u32) index * 2
            gpu.write_texture_descriptor(vulkan.device, texture_descriptor(buffer.color.descriptor_index), buffer.color.placed.texture, .sampled)
            
            buffer.depth.placed = gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
                extent = { extent.x, extent.y, 1 },
                format = .d32_float,
                usage  = { .sampled, .depth_stencil_attachment },
            ))
            assert(buffer.depth.placed.texture != nil)
            
            buffer.depth.render_view = gpu.create_render_view(buffer.depth.placed.texture)
            buffer.depth.descriptor_index = buffer.color.descriptor_index + 1
            gpu.write_texture_descriptor(vulkan.device, texture_descriptor(buffer.depth.descriptor_index), buffer.depth.placed.texture, .sampled)
        }
        
        vulkan.composite_buffer.placed = gpu.texture_allocate(&vulkan.texture_allocator, gpu.texture_desc(
            extent = { extent.x, extent.y, 1 },
            format = .bgra8_srgb,
            usage  = { .sampled, .color_attachment },
        ))
        assert(vulkan.composite_buffer.placed.texture != nil)
        
        vulkan.composite_buffer.render_view = gpu.create_render_view(vulkan.composite_buffer.placed.texture)
        vulkan.composite_buffer.descriptor_index = cast(u32) VulkanTextureDescriptor.composite
        gpu.write_texture_descriptor(vulkan.device, texture_descriptor(vulkan.composite_buffer.descriptor_index), vulkan.composite_buffer.placed.texture, .sampled)
    }
    vulkan.settings = settings
}

begin_depth_peel_pass :: proc (commands: gpu.CommandBuffer, peel_index: u32, color_load: gpu.LoadOp, render_commands_clear_color: v4 = {}) {
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
    gpu.bind_pso(commands, vulkan.quad_pso)
}

end_depth_peel_pass :: proc (commands: gpu.CommandBuffer) {
    gpu.end_render_pass(commands)
    gpu.barrier(commands, { .color_output, .depth_stencil_tests }, { .color_write, .depth_stencil_write }, { .fragment }, { .shader_read })
}

texture_descriptor :: proc (index: u32) -> pmm {
    descriptor_size := gpu.get_device_caps(vulkan.device).texture_descriptor_size_in_bytes
    result := &vulkan.texture_descriptor_heap.range.cpu[cast(u64) index * descriptor_size]
    return result
}

sampler_descriptor :: proc (index: u32) -> pmm {
    sampler_size := gpu.get_device_caps(vulkan.device).sampler_descriptor_size_in_bytes
    result := &vulkan.sampler_descriptor_heap.range.cpu[cast(u64) index * sampler_size]
    return result
}

allocate_texture_descriptor :: proc () -> (descriptor: pmm, index: u32) {
    last_free := len(vulkan.free_texture_descriptors)-1
    if last_free >= 0 {
        index = vulkan.free_texture_descriptors[last_free]
        resize(&vulkan.free_texture_descriptors, last_free)
    } else {
        assert(vulkan.next_texture_descriptor < cast(u32) VulkanTextureDescriptor.count)
        
        index = vulkan.next_texture_descriptor
        vulkan.next_texture_descriptor += 1
    }
    
    descriptor = texture_descriptor(index)
    
    return descriptor, index
}

////////////////////////////////////////////////

// :VulkanRenderer: Generate the Slang declarations from the Odin definitions.
// Keep these in lockstep with the C-layout SPIR-V declarations in vulkan.slang.
#assert(offset_of(Textured_Vertex, p)     == 0)
#assert(offset_of(Textured_Vertex, n)     == 16)
#assert(offset_of(Textured_Vertex, uv)    == 28)
#assert(offset_of(Textured_Vertex, color) == 36)
#assert(size_of(Textured_Vertex)          == 40)

#assert(offset_of(VulkanQuadRoot, projection)                == 0)
#assert(offset_of(VulkanQuadRoot, vertices)                  == 64)
#assert(offset_of(VulkanQuadRoot, texture_descriptors)       == 72)
#assert(offset_of(VulkanQuadRoot, camera_p)                  == 80)
#assert(offset_of(VulkanQuadRoot, fog_direction)             == 92)
#assert(offset_of(VulkanQuadRoot, fog_color)                 == 104)
#assert(offset_of(VulkanQuadRoot, fog_begin)                 == 116)
#assert(offset_of(VulkanQuadRoot, fog_end)                   == 120)
#assert(offset_of(VulkanQuadRoot, clip_alpha_begin)          == 124)
#assert(offset_of(VulkanQuadRoot, clip_alpha_end)            == 128)
#assert(offset_of(VulkanQuadRoot, vertex_base)               == 132)
#assert(offset_of(VulkanQuadRoot, previous_depth_descriptor) == 136)
#assert(offset_of(VulkanQuadRoot, alpha_threshold)           == 140)
#assert(size_of(VulkanQuadRoot)                              == 144)

#assert(offset_of(VulkanCompositeRoot, texture_descriptors) == 0)
#assert(offset_of(VulkanCompositeRoot, peel_count)          == 16)
#assert(size_of(VulkanCompositeRoot)                        == 20)

#assert(offset_of(VulkanFinalRoot, texture_descriptor) == 0)
#assert(offset_of(VulkanFinalRoot, sampler_descriptor) == 4)
#assert(size_of(VulkanFinalRoot)                       == 8)
