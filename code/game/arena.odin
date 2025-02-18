package game

DefaultAlignment :: 4

Arena :: struct {
    storage:    []u8,
    used:       u64,
    temp_count: i32,
}

TemporaryMemory :: struct {
    arena: ^Arena,
    used:  u64,
}

init_arena :: #force_inline proc(arena: ^Arena, storage: []u8) {
    arena.storage = storage
}

push :: proc { push_slice, push_struct, push_size, push_string }
@require_results
push_slice :: #force_inline proc(arena: ^Arena, $Element: typeid, #any_int count: u64, #any_int alignment: u64 = DefaultAlignment, clear_to_zero: b32 = true) -> (result: []Element) {
    size := size_of(Element) * count
    data := cast([^]Element) push_size(arena, size, alignment)
    result = data[:count]
    
    if clear_to_zero {
        zero_slice(result)
    }
    
    return result
}

@require_results
push_struct :: #force_inline proc(arena: ^Arena, $T: typeid, #any_int alignment: u64 = DefaultAlignment, clear_to_zero: b32 = true) -> (result: ^T) {
    result = cast(^T) push_size(arena, size_of(T), alignment)
    
    if clear_to_zero {
        result^ = {}
    }
    
    return result
}

@require_results
push_size :: #force_inline proc(arena: ^Arena, #any_int size_init: u64, #any_int alignment: u64 = DefaultAlignment) -> (result: rawpointer) {
    alignment_offset := arena_alignment_offset(arena, alignment)

    size := size_init + alignment_offset
    assert(arena.used + size < cast(u64)len(arena.storage))
    
    result = &arena.storage[arena.used + alignment_offset]
    arena.used += size
    
    assert(size >= size_init)
    
    return result
}

// NOTE(viktor): This is generally not for production use, this is probably
// only really something we need during testing, but who knows
@require_results
push_string :: #force_inline proc(arena: ^Arena, s: string) -> (result: string) {
    buffer := push_slice(arena, u8, len(s))
    bytes  := transmute([]u8) s
    for r, i in bytes {
        buffer[i] = r
    }
    result = transmute(string) buffer
    
    return result
}


arena_has_room :: proc { arena_has_room_slice, arena_has_room_struct, arena_has_room_size }
@require_results
arena_has_room_slice :: #force_inline proc(arena: ^Arena, $Element: typeid, #any_int len: u64, #any_int alignment: u64 = DefaultAlignment) -> (result: b32) {
    return arena_has_room_size(arena, size_of(Element) * len, alignment)
}

@require_results
arena_has_room_struct :: #force_inline proc(arena: ^Arena, $T: typeid, #any_int alignment: u64 = DefaultAlignment) -> (result: b32) {
    return arena_has_room_size(arena, size_of(T), alignment)
}

arena_has_room_size :: #force_inline proc(arena: ^Arena, #any_int size_init: u64, #any_int alignment: u64 = DefaultAlignment) -> (result: b32) {
    size := arena_get_effective_size(arena, size_init, alignment)
    result = arena.used + size < cast(u64)len(arena.storage)
    return result
}


zero :: proc { zero_size, zero_slice }
zero_size :: #force_inline proc(memory: rawpointer, size: u64) {
    // :PointerArithmetic
    bytes := (cast([^]u8)memory)[:size]
    for &b in bytes {
        b = {}
    }
}
zero_slice :: #force_inline proc(data: []$T){
    for &entry in data do entry = {}
}

sub_arena :: #force_inline proc(sub_arena: ^Arena, arena: ^Arena, #any_int storage_size: u64, #any_int alignment: u64 = DefaultAlignment) {
    assert(sub_arena != arena)
    
    storage := push(arena, u8, storage_size, alignment)
    init_arena(sub_arena, storage)
}

arena_get_effective_size :: #force_inline proc(arena: ^Arena, size_init: u64, alignment: u64) -> (result: u64) {
    alignment_offset := arena_alignment_offset(arena, alignment)
    result =  size_init + alignment_offset
    return result
}

arena_alignment_offset :: #force_inline proc(arena: ^Arena, #any_int alignment: u64 = DefaultAlignment) -> (result: u64) {
    pointer := transmute(u64) &arena.storage[arena.used]

    alignment_mask := alignment - 1
    if pointer & alignment_mask != 0 {
        result = alignment - (pointer & alignment_mask) 
    }
    
    return result
}

arena_remaining_size :: #force_inline proc(arena: ^Arena, #any_int alignment: u64 = DefaultAlignment) -> (result: u64) {
    alignment_offset:= arena_alignment_offset(arena, alignment)
    result = (auto_cast len(arena.storage) - 1) - (arena.used + alignment_offset)
    
    return result
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

check_arena :: #force_inline proc(arena: ^Arena) {
    assert(arena.temp_count == 0)
}