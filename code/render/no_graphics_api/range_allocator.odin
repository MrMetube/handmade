#+private
package gpu

import "base:intrinsics"
import "core:mem"

NodeIndex :: distinct u32

maximum_allocation_count :: (max(u32) - 1) / 2

unused_node :: max(NodeIndex)
top_bin_count :: 32
bins_per_leaf :: 8
leaf_bin_count :: top_bin_count * bins_per_leaf

RangeAllocator :: struct {
    element_size:     u64,
    capacity:         u32,
    max_allocations:  u32,
    allocation_count: u32,
    free_node_count:  u32,
    used_top_bins:    u32,              // bit_set, bit size must match top_bin_count
    used_leaf_bins: [top_bin_count] u8, // bit_set, bit size must match bins_per_leaf
    bin_indices:    [leaf_bin_count] NodeIndex, // @naming node_index_from_bin_index
    nodes:      [] RangeNode,
    free_nodes: [] NodeIndex,
}

RangeNode :: struct {
    offset: u32,
    size:   u32,
    bin_previous: NodeIndex,
    bin_next:     NodeIndex,
    neighbour_previous: NodeIndex,
    neighbour_next:     NodeIndex,
    used: bool,
}

default_node :: RangeNode {
    offset = 0,
    size   = 0,
    bin_previous = unused_node,
    bin_next     = unused_node,
    neighbour_previous = unused_node,
    neighbour_next     = unused_node,
    used = false,
}

range_allocator :: proc (byte_size: u64, max_allocations: u32, element_size: u64) -> RangeAllocator {
    assert(element_size != 0 && (element_size & (element_size - 1) == 0) && byte_size >= element_size)
    assert(max_allocations != 0 && max_allocations <= maximum_allocation_count)
    
    element_capacity := byte_size / element_size
    assert(element_capacity <= cast(u64) max(u32))
    
    node_capacity := max_allocations * 2 + 1
    result := RangeAllocator {
        element_size    = element_size,
        capacity        = cast(u32) element_capacity,
        max_allocations = max_allocations,
    }
    
    result.nodes      = make([] RangeNode, node_capacity, context.allocator)
    result.free_nodes = make([] NodeIndex, node_capacity, context.allocator)
    
    range_reset(&result)
    
    return result
}

range_allocate :: proc (ra: ^RangeAllocator, #any_int byte_size: u64) -> (offset: u32, token: NodeIndex) {
    offset = cast(u32) unused_node
    token  = unused_node
    
    assert(byte_size != 0)
    if ra.nodes == nil || ra.allocation_count == ra.max_allocations { return offset, token }
    
    requested_elements := 1 + (byte_size - 1) / ra.element_size
    if requested_elements > cast(u64) ra.capacity { return offset, token }
    
    size := cast(u32) requested_elements
    approximate_bin_index := size_to_bin_rounded_down(size)
    node_index := ra.bin_indices[approximate_bin_index]
    for {
        node, ok := range_get(ra, node_index)
        if !ok || node.size >= size { break }
        
        node_index = node.bin_next
    }
    
    find_lowest_set_bit :: proc (bits: u32, first_bit: u32) -> (u32, bool) {
        if first_bit >= 32 { return 0, false }
        
        bits := bits
        bits &= max(u32) << first_bit
        
        result := intrinsics.count_trailing_zeros(bits)
        ok := bits != 0
        return result, ok
    }
    
    if node_index == unused_node {
        minimum_bin_index := approximate_bin_index + 1
        top_bin_index := minimum_bin_index / bins_per_leaf
        
        leaf_bin_index: u32
        leaf_bin_index_ok: bool
        if top_bin_index < top_bin_count {
            leaf_bin_index, leaf_bin_index_ok = find_lowest_set_bit(cast(u32) ra.used_leaf_bins[top_bin_index], minimum_bin_index % bins_per_leaf)
        }
        
        if !leaf_bin_index_ok {
            top_bin_index_ok: bool
            top_bin_index, top_bin_index_ok = find_lowest_set_bit(ra.used_top_bins, top_bin_index + 1)
            if !top_bin_index_ok { return offset, token }
            
            leaf_bin_index = intrinsics.count_trailing_zeros(cast(u32) ra.used_leaf_bins[top_bin_index])
        }
        
        node_index = ra.bin_indices[top_bin_index * bins_per_leaf + leaf_bin_index]
    }
    
    node := &ra.nodes[node_index]
    original_size := node.size
    original_next_neighbour := node.neighbour_next
    assert(original_size >= size)
    range_remove_free_node(ra, node_index)
    
    node.size = size
    node.used = true
    ra.allocation_count += 1
    
    if original_size != size {
        remainder_index := range_acquire_node(ra)
        remainder := &ra.nodes[remainder_index]
        remainder.offset = node.offset + size
        remainder.size   = original_size - size
        remainder.neighbour_previous = node_index
        remainder.neighbour_next     = original_next_neighbour
        if next, ok := range_get(ra, original_next_neighbour); ok {
            next.neighbour_previous = remainder_index
        }
        node.neighbour_next = remainder_index
        range_insert_free_node(ra, remainder_index)
    }
    
    return node.offset, node_index
}

range_free :: proc (ra: ^RangeAllocator, token: NodeIndex) {
    node := &ra.nodes[token]
    assert(node.used)
    
    // Merge with unused previous node
    if previous, ok := range_get(ra, node.neighbour_previous); ok && !previous.used {
        previous_index := node.neighbour_previous
        
        range_remove_free_node(ra, previous_index)
        node.offset = previous.offset
        node.size  += previous.size
        node.neighbour_previous = previous.neighbour_previous
        range_release_node(ra, previous_index)
    }
    
    // Merge with unused next node
    if next, ok := range_get(ra, node.neighbour_next); ok && !next.used {
        next_index := node.neighbour_next
        
        range_remove_free_node(ra, next_index)
        node.size += next.size
        node.neighbour_next = next.neighbour_next
        range_release_node(ra, next_index)
    }
    
    if previous, ok := range_get(ra, node.neighbour_previous); ok {
        previous.neighbour_next = token
    }
    if next, ok := range_get(ra, node.neighbour_next); ok {
        next.neighbour_previous = token
    }
    
    range_insert_free_node(ra, token)
    ra.allocation_count -= 1
}

range_reset :: proc (ra: ^RangeAllocator) {
    if ra.nodes == nil { return }
    assert(ra.free_nodes != nil && ra.capacity != 0 && ra.max_allocations != 0)
    
    ra.allocation_count = 0
    ra.free_node_count  = cast(u32) len(ra.nodes)
    ra.used_top_bins    = 0
    
    mem.zero_slice(ra.used_leaf_bins[:])
    for &bin_index in ra.bin_indices { bin_index = unused_node }
    
    for &node, index in ra.nodes {
        node = default_node
        ra.free_nodes[index] = cast(NodeIndex) index
    }
    
    node_index := range_acquire_node(ra)
    ra.nodes[node_index].size = ra.capacity
    range_insert_free_node(ra, node_index)
}

range_acquire_node :: proc (ra: ^RangeAllocator) -> NodeIndex {
    assert(ra.free_node_count != 0)
    ra.free_node_count -= 1
    result := ra.free_nodes[ra.free_node_count]
    return result
}

range_release_node :: proc (ra: ^RangeAllocator, node_index: NodeIndex) {
    assert(ra.free_node_count < cast(u32) len(ra.nodes))
    ra.nodes[node_index] = default_node
    ra.free_nodes[ra.free_node_count] = node_index
    ra.free_node_count += 1
} 

range_insert_free_node :: proc (ra: ^RangeAllocator, node_index: NodeIndex) {
    node := &ra.nodes[node_index]
    
    bin_index := size_to_bin_rounded_down(node.size)
    top_bin_index  := bin_index / bins_per_leaf
    leaf_bin_index := bin_index % bins_per_leaf
    
    node.used = false
    node.bin_previous = unused_node
    node.bin_next     = ra.bin_indices[bin_index]
    if next, ok := range_get(ra, node.bin_next); ok {
        next.bin_previous = node_index
    }
    ra.bin_indices[bin_index] = node_index
    ra.used_leaf_bins[top_bin_index] |= 1 << leaf_bin_index
    ra.used_top_bins |= 1 << top_bin_index
}

range_remove_free_node :: proc (ra: ^RangeAllocator, node_index: NodeIndex) {
    node := &ra.nodes[node_index]
    assert(!node.used)
    
    if previous, ok := range_get(ra, node.bin_previous); ok {
        previous.bin_next = node.bin_next
        if next, next_ok := range_get(ra, node.bin_next); next_ok {
            next.bin_previous = node.bin_previous
        }
    } else {
        bin_index := size_to_bin_rounded_down(node.size)
        top_bin_index  := bin_index / bins_per_leaf
        leaf_bin_index := bin_index % bins_per_leaf
        
        assert(ra.bin_indices[bin_index] == node_index)
        ra.bin_indices[bin_index] = node.bin_next
        if next, next_ok := range_get(ra, node.bin_next); next_ok {
            next.bin_previous = unused_node
        } else {
            ra.used_leaf_bins[top_bin_index] &~= 1<< leaf_bin_index
            if ra.used_leaf_bins[top_bin_index] == 0 {
                ra.used_top_bins &~=1 << top_bin_index
            }
        }
    }
    
    node.bin_previous = unused_node
    node.bin_next     = unused_node
}

////////////////////////////////////////////////

range_get :: proc (ra: ^RangeAllocator, index: NodeIndex) -> (^RangeNode, bool) {
    result: ^RangeNode
    if index != unused_node {
        result = &ra.nodes[index]
    }
    return result, result != nil
}

mantissa_bits  :: 3
mantissa_value :: 1 << mantissa_bits
mantissa_mask  :: mantissa_value - 1

size_to_bin_rounded_down :: proc (size: u32) -> u32 {
    if size < mantissa_value { return size }
    
    mantissa_start_bit := 31 - intrinsics.count_leading_zeros(size) - mantissa_bits
    result := ((mantissa_start_bit + 1) << mantissa_bits) | ((size >> mantissa_start_bit) & mantissa_mask)
    return result
}
 