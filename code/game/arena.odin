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
push_slice :: #force_inline proc(arena: ^Arena, $Element: typeid, #any_int len: u64, #any_int alignment: u64 = 4, clear_to_zero: b32 = true) -> (result: []Element) {
    size := size_of(Element) * len
    data := cast([^]Element) push_size(arena, size, alignment)
    result = data[:len]
    
    if clear_to_zero {   
        zero_slice(result)
    }
    
    return result
}

push_struct :: #force_inline proc(arena: ^Arena, $T: typeid, #any_int alignment: u64 = 4, clear_to_zero: b32= true) -> (result: ^T) {
    result = cast(^T) push_size(arena, size_of(T), alignment)
    
    if clear_to_zero {
        zero_struct(result)
    }
    
    return result
}

push_size :: #force_inline proc(arena: ^Arena, #any_int size_init: u64, #any_int alignment: u64 = 4) -> (result: [^]u8) {
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
push_string :: #force_inline proc(arena: ^Arena, s: string) -> (result: string) {
    buffer := push_slice(arena, u8, len(s))
    bytes  := transmute([]u8) s
    for r, i in bytes {
        buffer[i] = r
    }
    result = transmute(string) buffer
    
    return result
}

zero :: proc { zero_size, zero_struct, zero_slice }

zero_size :: #force_inline proc(memory: rawpointer, size: u64) {
    mem := (cast([^]u8)memory)[:size]
    for &b in mem {
        b = {}
    }
}
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

sub_arena :: #force_inline proc(sub_arena: ^Arena, arena: ^Arena, #any_int storage_size: u64, #any_int alignment: u64 = 4) {
    assert(sub_arena != arena)
    
    storage := push(arena, u8, storage_size, alignment)
    init_arena(sub_arena, storage)
}

arena_alignment_offset :: #force_inline proc(arena: ^Arena, #any_int alignment: u64 = 4) -> (result: u64) {
    pointer := transmute(u64) &arena.storage[arena.used]

    alignment_mask := alignment - 1
    if pointer & alignment_mask != 0 {
        result = alignment - (pointer & alignment_mask) 
    }
    
    return result
}

arena_remaining_size :: #force_inline proc(arena: ^Arena, #any_int alignment: u64 = 4) -> (result: u64) {
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