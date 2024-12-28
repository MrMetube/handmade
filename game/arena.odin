package game

Arena :: struct {
    storage: []u8,
    used: u64,
    temp_count: i32,
}

TemporaryMemory :: struct {
    arena: ^Arena,
    used: u64,
}

init_arena :: #force_inline proc(arena: ^Arena, storage: []u8) {
    arena.storage = storage
}

push :: proc { push_slice, push_struct, push_size }

push_slice :: #force_inline proc(arena: ^Arena, $Element: typeid, #any_int len: u64, clear_to_zero: b32 = true) -> (result: []Element) {
    data := cast([^]Element) push_size(arena, size_of(Element) * len)
    result = data[:len]
    
    if clear_to_zero {   
        zero_slice(result)
    }
    
    return result
}

push_struct :: #force_inline proc(arena: ^Arena, $T: typeid, clear_to_zero: b32= true) -> (result: ^T) {
    result = cast(^T) push_size(arena, size_of(T))
    
    if clear_to_zero {
        zero_struct(result)
    }
    
    return result
}

push_size :: #force_inline proc(arena: ^Arena, #any_int size: u64) -> (result: [^]u8) {
    assert(arena.used + size < cast(u64)len(arena.storage))
    result = &arena.storage[arena.used]
    arena.used += size
    return result
}

zero :: proc { zero_struct, zero_slice }

zero_struct :: #force_inline proc(s: ^$T) {
    s^ = {}
}

zero_slice :: #force_inline proc(data: []$T){
    // TODO(viktor): check this guy for performance
    if data != nil {
        for &entry in data {
            entry = {}
        }
    }
}

begin_temporary_memory :: #force_inline proc(arena: ^Arena) -> (result: TemporaryMemory) {
    result.arena = arena
    result.used = arena.used
    
    arena.temp_count += 1
    
    return result 
}

end_temporary_memory :: #force_inline proc(temp_mem: TemporaryMemory) {
    arena := temp_mem.arena
    assert(arena.used >= temp_mem.used)
    assert(arena.temp_count > 0)
    
    arena.used = temp_mem.used
    arena.temp_count -= 1
}

check_arena :: #force_inline proc(arena: Arena) {
    assert(arena.temp_count == 0)
}