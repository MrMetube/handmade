package gpu

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
    assert((transmute(u64)          storage.gpu)  % alignment == 0)
    result := BumpAllocator { storage, 0 }
    return result
}

bump_allocate        :: proc { bump_allocate_bytes, bump_allocate_type, bump_allocate_slice }
bump_allocate_atomic :: proc { bump_allocate_atomic_bytes, bump_allocate_atomic_type, bump_allocate_atomic_slice }

// Zero-sized allocations return the nil value. 
// Reservations are rounded up to 16 bytes an empty allocation reports exhausted storage.
bump_allocate_bytes :: proc (bump: ^BumpAllocator, #any_int byte_size: u64, zero: bool = true) -> GpuCpuRange(u8) {
    if byte_size == 0 { return {} }
    
    remaining := bump.storage.size_in_bytes - bump.offset
    if byte_size > remaining { return {} }
    
    allocation := GpuCpuRange(u8) {
        cpu = bump.storage.cpu[bump.offset:][:byte_size],
        gpu = bump.storage.gpu[bump.offset:],
        size_in_bytes = byte_size,
    }
    
    if zero {
        for &b in allocation.cpu {
            b = 0
        }
    }
    
    aligned_size := (byte_size + alignment - 1) &~ (alignment - 1)
    bump.offset  += min(aligned_size, remaining)
    
    return allocation
}

// Intended for concurrent bump allocation from worker threads. 
// Successful concurrent calls to allocate_atomic() return disjoint ranges.
// Every other operation, including allocate(), reset() requires exclusive access.
// None may execute concurrently with allocate() or allocate_atomic().
bump_allocate_atomic_bytes :: proc (bump: ^BumpAllocator, #any_int byte_size: u64, zero: bool = true) -> GpuCpuRange(u8) {
    unimplemented()
}

bump_allocate_type :: proc (bump: ^BumpAllocator, $T: typeid, zero: bool = true) -> GpuCpuPointer(T) {
    #assert(align_of(T) <= alignment)
    allocation := bump_allocate(bump, size_of(T), zero)
    result := GpuCpuPointer (T) {
        cpu           = cast(^T)      raw_data(allocation.cpu),
        gpu           = transmute(^T) allocation.gpu,
        size_in_bytes = allocation.size_in_bytes,
    }
    return result
}

bump_allocate_atomic_type :: proc (bump: ^BumpAllocator, $T: typeid, zero: bool = true) -> GpuCpuPointer(T) {
    if size_of(T) == 0 { return nil }
    
    #assert(align_of(T) <= alignment)
    allocation := bump_allocate_atomic(bump, size_of(T), zero)
    result := GpuCpuPointer (T) {
        cpu           = raw_data(allocation.cpu),
        gpu           = cast(^T) allocation.gpu,
        size_in_bytes = allocation.size_in_bytes,
    }
    return result
}

bump_allocate_slice :: proc (bump: ^BumpAllocator, $T: typeid/ [] $E, #any_int element_count: u64, zero: bool = true) -> GpuCpuRange(E) {
    if element_count == 0 { return {} }
    
    #assert(align_of(E) <= alignment)
    allocation := bump_allocate(bump, element_count * size_of(E), zero)
    if allocation.cpu == nil { return {} }
    
    result := transmute(GpuCpuRange(E)) allocation
    result.cpu = result.cpu[:element_count] // @cleanup
    
    return result
}

bump_allocate_atomic_slice :: proc (bump: ^BumpAllocator, $T: typeid/ [] $E, #any_int element_count: u64, zero: bool = true) -> GpuCpuRange(E) {
    if element_count == 0 { return {} }
    
    #assert(align_of(E) <= alignment)
    allocation := bump_allocate_atomic(bump, element_count * size_of(E), zero)
    if allocation.cpu == nil { return {} }
    
    result := transmute(GpuCpuRange(E)) allocation
    result.cpu = result.cpu[:element_count] // @cleanup
    
    return result
}
    
// Reset invalidates every previous allocation.
bump_reset :: proc (bump: ^BumpAllocator) {
    bump.offset = 0
    // @todo should this also zero/pattern all memory in debug mode?
}