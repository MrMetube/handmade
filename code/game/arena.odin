package game

@(common="file")

Arena :: struct {
    storage:    []u8, // :Array
    used:       u64,
    temp_count: i32,
}

TemporaryMemory :: struct {
    arena: ^Arena,
    used:  u64,
}

PushParams :: struct {
    alignment: u32,
    flags:     bit_set[PushFlags],
}

PushFlags :: enum {
    ClearToZero,
}

DefaultAlignment :: 4

DefaultPushParams :: PushParams {
    alignment = DefaultAlignment,
    flags     = {.ClearToZero},
}

no_clear       :: proc () -> PushParams { return { DefaultAlignment, {} }}
align_no_clear :: proc (#any_int alignment: u32, clear_to_zero :b32= false) -> PushParams { return { alignment, clear_to_zero ? { .ClearToZero } : {} }}
align_clear    :: proc (#any_int alignment: u32, clear_to_zero :b32= true ) -> PushParams { return { alignment, clear_to_zero ? { .ClearToZero } : {} }}

init_arena :: proc(arena: ^Arena, storage: []u8) {
    arena.storage = storage
}

push :: proc { push_slice, push_struct, push_size, copy_string }
@(require_results)
push_slice :: proc(arena: ^Arena, $Element: typeid, #any_int count: u64, params := DefaultPushParams) -> (result: []Element) {
    size := size_of(Element) * count
    data := cast([^]Element) push_size(arena, size, params)
    result = data[:count]
    
    return result
}

@(require_results)
push_struct :: proc(arena: ^Arena, $T: typeid, params := DefaultPushParams) -> (result: ^T) {
    result = cast(^T) push_size(arena, size_of(T), params)
    
    return result
}

@(require_results)
push_size :: proc(arena: ^Arena, #any_int size_init: u64, params := DefaultPushParams) -> (result: pmm) {
    alignment_offset := arena_alignment_offset(arena, params.alignment)

    size := size_init + alignment_offset
    assert(arena.used + size < cast(u64) len(arena.storage))
    
    result = &arena.storage[arena.used + alignment_offset]
    arena.used += size
    
    assert(size >= size_init)
    
    if .ClearToZero in params.flags {
        timed_block("ClearToZero")
        
        cache_line :: [8]u64
        cache_line_size :: size_of(cache_line)
        cache_line_count: u64
        if size > cache_line_size {
            cache_line_count = size/cache_line_size
            cache_lines := (cast([^]cache_line) result)[:cache_line_count]
            for &w in cache_lines do w = 0
        }
        
        bytes := (cast([^]u8) result)[cache_line_count*cache_line_size:size]
        for &b in bytes do b = 0
    }
    
    return result
}

// @note(viktor): This is generally not for production use, this is probably
// only really something we need during testing, but who knows
@(require_results)
copy_string :: proc(arena: ^Arena, s: string) -> (result: string) {
    buffer := push_slice(arena, u8, len(s), no_clear())
    bytes  := transmute([]u8) s
    for r, i in bytes {
        buffer[i] = r
    }
    result = transmute(string) buffer
    
    return result
}


arena_has_room :: proc { arena_has_room_slice, arena_has_room_struct, arena_has_room_size }
@(require_results)
arena_has_room_slice :: proc(arena: ^Arena, $Element: typeid, #any_int len: u64, #any_int alignment: u64 = DefaultAlignment) -> (result: b32) {
    return arena_has_room_size(arena, size_of(Element) * len, alignment)
}

@(require_results)
arena_has_room_struct :: proc(arena: ^Arena, $T: typeid, #any_int alignment: u64 = DefaultAlignment) -> (result: b32) {
    return arena_has_room_size(arena, size_of(T), alignment)
}

arena_has_room_size :: proc(arena: ^Arena, #any_int size_init: u64, #any_int alignment: u64 = DefaultAlignment) -> (result: b32) {
    size := arena_get_effective_size(arena, size_init, alignment)
    result = arena.used + size < cast(u64)len(arena.storage)
    return result
}


zero :: proc { zero_size, zero_slice }
zero_size :: proc(memory: pmm, size: u64) {
    // :PointerArithmetic
    bytes := (cast([^]u8)memory)[:size]
    for &b in bytes {
        b = {}
    }
}
zero_slice :: proc(data: []$T){
    for &entry in data do entry = {}
}

sub_arena :: proc(sub_arena: ^Arena, arena: ^Arena, #any_int storage_size: u64, params: = DefaultPushParams) {
    assert(sub_arena != arena)
    
    storage := push(arena, u8, storage_size, params)
    init_arena(sub_arena, storage)
}

arena_get_effective_size :: proc(arena: ^Arena, size_init: u64, alignment: u64) -> (result: u64) {
    alignment_offset := arena_alignment_offset(arena, alignment)
    result =  size_init + alignment_offset
    return result
}

arena_alignment_offset :: proc(arena: ^Arena, #any_int alignment: u64 = DefaultAlignment) -> (result: u64) {
    pointer := transmute(u64) &arena.storage[arena.used]

    alignment_mask := alignment - 1
    if pointer & alignment_mask != 0 {
        result = alignment - (pointer & alignment_mask) 
    }
    
    return result
}

arena_remaining_size :: proc(arena: ^Arena, #any_int alignment: u64 = DefaultAlignment) -> (result: u64) {
    alignment_offset:= arena_alignment_offset(arena, alignment)
    result = (auto_cast len(arena.storage) - 1) - (arena.used + alignment_offset)
    
    return result
}

begin_temporary_memory :: proc(arena: ^Arena) -> (result: TemporaryMemory) {
    result.arena = arena
    result.used = arena.used
    
    arena.temp_count += 1
    
    return result 
}

end_temporary_memory :: proc(temp_mem: TemporaryMemory) {
    arena := temp_mem.arena
    assert(arena.used >= temp_mem.used)
    assert(arena.temp_count > 0)
    
    arena.used = temp_mem.used
    arena.temp_count -= 1
}

check_arena :: proc(arena: ^Arena) {
    assert(arena.temp_count == 0)
}