package gpu

import "core:slice"

@(private="file") alignment :: 16

BumpAllocator :: struct {
    storage: GpuCpuRange(u8),
    offset:  u64,
}

// Storage must be nonempty, expose at least one address, and align every exposed address to 16 bytes.
bump_allocator :: proc (storage: GpuCpuRange(u8)) -> BumpAllocator {
    assert(storage.size_in_bytes != 0)
    assert(storage.cpu != nil && storage.gpu != nil)
    assert((transmute(u64) raw_data(storage.cpu)) % alignment == 0)
    assert((transmute(u64) storage.gpu)          % alignment == 0)
    result := BumpAllocator { storage, 0 }
    return result
}

bump_allocate        :: proc { bump_allocate_bytes, bump_allocate_type }
bump_allocate_atomic :: proc { bump_allocate_atomic_bytes, bump_allocate_atomic_type }

// The request must be nonzero. Reservations are rounded up to 16 bytes an empty allocation reports exhausted storage.
bump_allocate_bytes :: proc (bump: ^BumpAllocator, #any_int byte_size: u64) -> GpuCpuRange(u8) {
    assert(byte_size != 0)
    
    remaining := bump.storage.size_in_bytes - bump.offset
    if byte_size > remaining { return {} }
    
    allocation := GpuCpuRange(u8) {
        cpu = slice.from_ptr(&bump.storage.cpu[bump.offset], cast(int) byte_size),
        gpu = bump.storage.gpu[bump.offset:],
        size_in_bytes = byte_size,
    }
    
    aligned_size := (byte_size + alignment - 1) &~ (alignment - 1)
    bump.offset += min(aligned_size, remaining)
    
    return allocation
}

// Intended for concurrent bump allocation from worker threads. Successful concurrent calls to allocate_atomic() return disjoint ranges.
// The request must be nonzero. Reservations are rounded up to 16 bytes an empty allocation reports exhausted storage.
// Every other operation, including allocate(), reset(), move construction/assignment, and destruction, requires exclusive access.
// None may execute concurrently with allocate() or allocate_atomic().
bump_allocate_atomic_bytes :: proc (bump: ^BumpAllocator, #any_int byte_size: u64) -> GpuCpuRange(u8) {
    unimplemented()
}

bump_allocate_type :: proc (bump: ^BumpAllocator, $T: typeid/ [] $E, #any_int element_count: u64) -> GpuCpuRange(E) {
    #assert(align_of(E) <= alignment)
    allocation := bump_allocate(bump, element_count * size_of(E))
    result := transmute(GpuCpuRange(E)) allocation
    result.cpu = result.cpu[:element_count] // @cleanup
    return result
}

bump_allocate_atomic_type :: proc (bump: ^BumpAllocator, $T: typeid/ [] $E, #any_int element_count: u64) -> GpuCpuRange(E) {
    #assert(align_of(E) <= alignment)
    allocation := bump_allocate_atomic(bump, element_count * size_of(E))
    result := transmute(GpuCpuRange(E)) allocation
    result.cpu = result.cpu[:element_count] // @cleanup
    return result
}
    
// Reset invalidates every previous allocation.
bump_reset :: proc (bump: ^BumpAllocator) {
    bump.offset = 0
}

@(private="file")
offset_pointer :: proc (pointer: rawptr, offset: u64) -> rawptr {
    if pointer == nil { return pointer }
    result := transmute(rawptr) (transmute(u64) pointer + offset)
    return result
}