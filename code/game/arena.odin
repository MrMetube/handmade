#+vet !unused-procedures
package game

@(common="file")

import "base:intrinsics"


Arena :: struct {
    // @todo(viktor): if we see performance problems here, maybe move storage and used out?
    current_block: ^Platform_Memory_Block,
    
    temp_count: i32,
    
    minimum_block_size: umm,
    allocation_flags: Platform_Allocation_Flags,
}

TemporaryMemory :: struct {
    arena: ^Arena,
    block: ^Platform_Memory_Block,
    used:  umm,
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
    
    for arena.current_block != nil {
        free_last_block(arena)
    }
}

free_last_block :: proc (arena: ^Arena) {
    block := arena.current_block
    arena.current_block = block.arena_previous_block
    
    Platform.deallocate_memory(block)
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

@(require_results)
push_size :: proc(arena: ^Arena, #any_int size_init: umm, params := DefaultPushParams) -> (result: pmm) {
    alignment_offset: umm
    if arena.current_block != nil {
        alignment_offset = arena_alignment_offset(arena, params.alignment)
    }
    size := size_init + alignment_offset
    
    if arena.current_block == nil || arena.current_block.used + size >= auto_cast len(arena.current_block.storage) {
        size = size_init // @note(viktor): the memory will allways be aligned now!
        
        if BoundsCheck & arena.allocation_flags != {} {
            arena.minimum_block_size = 0
            size = align_pow2(size, params.alignment)
        } else if arena.minimum_block_size == 0 {
            arena.minimum_block_size = 2 * Megabyte
        }
        
        block_size := max(size, arena.minimum_block_size)
        new_block  := Platform.allocate_memory(block_size, arena.allocation_flags)
        
        new_block.arena_previous_block = arena.current_block
        arena.current_block = new_block
    }
    assert(arena.current_block.used + size <= auto_cast len(arena.current_block.storage))
    assert(size >= size_init)
    
    alignment_offset = arena_alignment_offset(arena, params.alignment)
    result = &arena.current_block.storage[arena.current_block.used + alignment_offset]
    arena.current_block.used += size
    
    
    if .ClearToZero in params.flags {
        intrinsics.mem_zero(result, size_init)
    }
    
    return result
}

arena_alignment_offset :: proc(arena: ^Arena, #any_int alignment: umm = DefaultAlignment) -> (result: umm) {
    if arena.current_block.storage == nil do return 0
    if arena.current_block.used == auto_cast len(arena.current_block.storage) do return 0
    
    pointer := transmute(umm) &arena.current_block.storage[arena.current_block.used]

    alignment_mask := alignment - 1
    if pointer & alignment_mask != 0 {
        result = alignment - (pointer & alignment_mask) 
    }
    
    return result
}

// @todo(viktor): This is a hack, because we link with the game translation unit twice. once at compile time and once at runtime. the compiletime PlatformApi is never able to be set otherwise
@(common) set_platform_api_in_the_statically_linker_game_code :: proc (api: Platform_Api) {
    Platform = api
}

zero :: proc { zero_size, zero_slice }
zero_size :: proc(memory: pmm, size: u64) {
    intrinsics.mem_zero(memory, size)
}
zero_slice :: proc(data: []$T){
    intrinsics.mem_zero(raw_data(data), len(data) * size_of(T))
}

// @note(viktor): This is generally not for production use, this is probably
// only really something we need during testing, but who knows
@(require_results)
copy_string :: proc(arena: ^Arena, s: string) -> (result: string) {
    // @todo(viktor): handle zero sized allocations better in push_size
    if s == "" do return
    buffer := push_slice(arena, u8, len(s), no_clear())
    bytes  := transmute([]u8) s
    
    copy_slice(buffer, bytes)
    
    result = transmute(string) buffer
    
    return result
}

////////////////////////////////////////////////

begin_temporary_memory :: proc(arena: ^Arena) -> (result: TemporaryMemory) {
    result.arena = arena
    result.block = arena.current_block
    if result.block != nil {
        result.used  = arena.current_block.used
    }
    
    arena.temp_count += 1
    
    return result 
}

end_temporary_memory :: proc(temp_mem: TemporaryMemory) {
    arena := temp_mem.arena
    assert(arena.temp_count > 0)
    
    for arena.current_block != temp_mem.block {
        free_last_block(arena)
    }
    
    if arena.current_block != nil {
        assert(arena.current_block.used >= temp_mem.used)
        arena.current_block.used = temp_mem.used
    }
    
    arena.temp_count -= 1
}

check_arena :: proc(arena: ^Arena) {
    assert(arena.temp_count == 0)
}
