#+vet !unused-procedures
package game

@(common="file")

import "base:intrinsics"


Arena :: struct {
    storage:    [] u8,
    used:       umm,
    temp_count: i32,
    
    block_count: i32,
    minimum_block_size: umm,
    
    allocation_flags: Platform_Allocation_Flags,
}

TemporaryMemory :: struct {
    arena: ^Arena,
    storage: [] u8,
    used:    umm,
}

Memory_Block_Footer :: struct {
    storage: [] u8,
    used:    umm,
}

PushParams :: struct {
    alignment: umm,
    flags:     bit_set[PushFlags],
}

PushFlags :: enum {
    ClearToZero,
}

////////////////////////////////////////////////

DefaultAlignment :: 4

DefaultPushParams :: PushParams {
    alignment = DefaultAlignment,
    flags     = {.ClearToZero},
}

no_clear       :: proc () -> PushParams { return { DefaultAlignment, {} }}
align_no_clear :: proc (#any_int alignment: umm, clear_to_zero: b32 = false) -> PushParams { return { alignment, clear_to_zero ? { .ClearToZero } : {} }}
align_clear    :: proc (#any_int alignment: umm, clear_to_zero: b32 = true ) -> PushParams { return { alignment, clear_to_zero ? { .ClearToZero } : {} }}

////////////////////////////////////////////////

bootstrap_arena :: proc ($type_with_arena: typeid, $arena_member: string, minimum_block_size: umm = 0, params := DefaultPushParams, allocation_flags := Platform_Allocation_Flags {} ) -> (result: ^type_with_arena){
    boot_strap := Arena { 
        minimum_block_size = minimum_block_size, 
        allocation_flags = allocation_flags,
    }
    
    result = push(&boot_strap, type_with_arena, params = params)
    bytes := slice_from_parts(u8, result, size_of(type_with_arena))
    
    offset := offset_of_by_string(type_with_arena, arena_member)
    dest := cast(^Arena) &bytes[offset]
    dest ^= boot_strap
    
    return result
}

set_minimum_block_size :: proc (arena: ^Arena, size: umm) {
    arena.minimum_block_size = size
}

clear_arena :: proc(arena: ^Arena) {
    assert(arena.temp_count == 0)
    
    for arena.block_count > 0 {
        free_last_block(arena)
    }
}

free_last_block :: proc (arena: ^Arena) {
    old_storage := arena.storage
    defer Platform.deallocate_memory(raw_data(old_storage))
    
    footer := get_footer(arena)
    arena.storage = footer.storage
    arena.used    = footer.used
    
    arena.block_count -= 1
}

////////////////////////////////////////////////

push :: proc { push_slice, push_struct, push_size, copy_string }
@(require_results)
push_slice :: proc(arena: ^Arena, $Element: typeid, #any_int count: u64, params := DefaultPushParams) -> (result: []Element) {
    params := params
    if params.alignment == DefaultAlignment {
        params.alignment = align_of(Element)
    }
    size := size_of(Element) * count
    result = slice_from_parts(Element, push_size(arena, size, params), count)
    
    return result
}

@(require_results)
push_struct :: proc(arena: ^Arena, $T: typeid, params := DefaultPushParams) -> (result: ^T) {
    params := params
    if params.alignment == DefaultAlignment {
        params.alignment = align_of(T)
    }
    result = cast(^T) push_size(arena, size_of(T), params)
    
    return result
}

get_footer :: proc (arena: ^Arena) -> (result: ^Memory_Block_Footer) {
    assert(arena.storage != nil)
    
    #no_bounds_check {
        result = auto_cast &arena.storage[len(arena.storage)]
    }
    
    return result
}

@(require_results)
push_size :: proc(arena: ^Arena, #any_int size_init: umm, params := DefaultPushParams) -> (result: pmm) {
    alignment_offset := arena_alignment_offset(arena, params.alignment)

    size := size_init + alignment_offset
    if arena.used + size >= cast(umm) len(arena.storage) {
        size = size_init // @note(viktor): the memory will allways be aligned now!
        
        if arena.minimum_block_size == 0 {
            arena.minimum_block_size = 2 * Megabyte
        }
        block_size := max(size + size_of(Memory_Block_Footer), arena.minimum_block_size)
        
        memory := Platform.allocate_memory(block_size, arena.allocation_flags)
        
        saved := Memory_Block_Footer {
            storage = arena.storage,
            used    = arena.used,
        }
        
        arena.storage = slice_from_parts(u8, memory, block_size - size_of(Memory_Block_Footer))
        arena.used = 0
        
        footer := get_footer(arena)
        footer ^= saved
        
        arena.block_count += 1
    }
    assert(arena.used + size <= cast(umm) len(arena.storage))
    
    result = &arena.storage[arena.used + alignment_offset]
    arena.used += size
    
    assert(size >= size_init)
    
    if .ClearToZero in params.flags {
        timed_block("ClearToZero")
        intrinsics.mem_zero(result, size)
    }
    
    return result
}

// @todo(viktor): This is a hack, because we link with the game translation unit twice. once at compile time and once at runtime. the compiletime PlatformApi is never able to be set otherwise
@(common) set_platform_api_in_the_statically_linker_game_code :: proc (api: Platform_Api) {
    Platform = api
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

arena_has_room_size :: proc(arena: ^Arena, #any_int size_init: umm, #any_int alignment: umm = DefaultAlignment) -> (result: b32) {
    size := arena_get_effective_size(arena, size_init, alignment)
    result = arena.used + size < cast(umm) len(arena.storage)
    return result
}


zero :: proc { zero_size, zero_slice }
zero_size :: proc(memory: pmm, size: u64) {
    intrinsics.mem_zero(memory, size)
}
zero_slice :: proc(data: []$T){
    intrinsics.mem_zero(raw_data(data), len(data) * size_of(T))
}

arena_get_effective_size :: proc(arena: ^Arena, size_init: umm, alignment: umm) -> (result: umm) {
    alignment_offset := arena_alignment_offset(arena, alignment)
    result =  size_init + alignment_offset
    return result
}

arena_alignment_offset :: proc(arena: ^Arena, #any_int alignment: umm = DefaultAlignment) -> (result: umm) {
    if arena.storage == nil do return 0
    if arena.used == auto_cast len(arena.storage) do return 0
    
    pointer := transmute(umm) &arena.storage[arena.used]

    alignment_mask := alignment - 1
    if pointer & alignment_mask != 0 {
        result = alignment - (pointer & alignment_mask) 
    }
    
    return result
}

arena_remaining_size :: proc(arena: ^Arena, #any_int alignment: umm = DefaultAlignment) -> (result: umm) {
    alignment_offset:= arena_alignment_offset(arena, alignment)
    result = (auto_cast len(arena.storage) - 1) - (arena.used + alignment_offset)
    
    return result
}

////////////////////////////////////////////////

begin_temporary_memory :: proc(arena: ^Arena) -> (result: TemporaryMemory) {
    result.arena   = arena
    result.used    = arena.used
    result.storage = arena.storage
    
    arena.temp_count += 1
    
    return result 
}

end_temporary_memory :: proc(temp_mem: TemporaryMemory) {
    arena := temp_mem.arena
    assert(arena.used >= temp_mem.used)
    assert(arena.temp_count > 0)
    
    for raw_data(arena.storage) != raw_data(temp_mem.storage) {
        free_last_block(arena)
    }
    
    arena.used = temp_mem.used
    arena.temp_count -= 1
}

check_arena :: proc(arena: ^Arena) {
    assert(arena.temp_count == 0)
}
