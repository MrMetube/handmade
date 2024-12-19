package game

Arena :: struct {
    storage: []u8,
    used: u64
}

init_arena :: #force_inline proc(arena: ^Arena, storage: []u8) {
    arena.storage = storage
}

// TODO(viktor): zero all pushed data by default and add nonzeroing version for all procs
push :: proc { push_slice, push_struct, push_size }

push_slice :: #force_inline proc(arena: ^Arena, $Element: typeid, len: u64) -> (result: []Element) {
    data := cast([^]Element) push_size(arena, cast(u64) size_of(Element) * len)
    result = data[:len]
    return result
}

push_struct :: #force_inline proc(arena: ^Arena, $T: typeid) -> (result: ^T) {
    result = cast(^T) push_size(arena, cast(u64)size_of(T))
    return result
}

push_size :: #force_inline proc(arena: ^Arena, size: u64) -> (result: [^]u8) {
    assert(arena.used + size < cast(u64)len(arena.storage))
    result = &arena.storage[arena.used]
    arena.used += size
    return result
}

zero :: proc { zero_struct, zero_slice }

zero_struct :: #force_inline proc(s: ^$T) {
    data := cast([^]u8) s
    len  := size_of(T)
    zero_slice(data[:len])
}

zero_slice :: #force_inline proc(memory: []$u8){
    // TODO(viktor): check this guy for performance
    for &Byte in memory {
        Byte = 0
    }
}
