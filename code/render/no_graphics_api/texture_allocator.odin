package gpu

TextureAllocator :: struct {
    device: Device,
    heap:   TextureHeap,
    ranges: RangeAllocator,
}

PlacedTexture :: struct {
    texture: Texture,
    token:   NodeIndex,
}

texture_allocator :: proc (device: Device, heap: TextureHeap, max_textures: u32) -> TextureAllocator {
    assert(heap.owner != nil)
    
    result := TextureAllocator {
        device = device,
        heap   = heap,
        ranges = range_allocator(heap.size_in_bytes, max_textures, get_device_caps(device).texture_heap_alignment),
    }
    return result
}

// An empty result reports exhausted heap space. Free once with the same allocator after all views and GPU use have finished.
texture_allocate :: proc (ta: ^TextureAllocator, desc: TextureDesc) -> PlacedTexture {
    size, alignment := get_texture_size_align(ta.device, desc)
    padding := alignment > ta.ranges.element_size ? alignment - ta.ranges.element_size : 0
    offset, token := range_allocate(&ta.ranges, size + padding)
    
    result: PlacedTexture
    if offset == cast(u32) unused_node { return result }
    
    result = {
        texture = create_texture(ta.device, desc, ta.heap, align_up(cast(u64) offset * ta.ranges.element_size, alignment)),
        token   = token,
    }
    return result
}

texture_free :: proc (ta: ^TextureAllocator, texture: ^PlacedTexture) {
    if texture.texture == nil { return }
    
    range_free(&ta.ranges, texture.token)
    destroy_texture(texture.texture)
    texture^ = {}
}