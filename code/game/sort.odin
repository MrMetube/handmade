#+vet !unused-procedures
package game

SortEntry :: struct {
    sort_key: f32,
    index:    u32,
}

compare_sort_entries :: proc (a, b: SortEntry) -> b32 { return a.sort_key < b.sort_key }

radix_sort :: proc (entries: []SortEntry, temp_space: []SortEntry) #no_bounds_check {
    source, dest := entries, temp_space
    for byte_index in u32(0)..<4 {
        sort_key_offsets: [256]u32
        
        // 1 - Count how many entries of each key exist
        for entry in source {
            radix_value := sort_key_to_u32(entry.sort_key)
            radix_byte := (radix_value >> (byte_index * 8)) & 0xFF
            sort_key_offsets[radix_byte] += 1
        }
        
        // Change counts to offsets
        total: u32
        for &sort_key in sort_key_offsets {
            count := sort_key
            sort_key = total
            total += count
        }
        
        // 2 - Place elements into the right location
        for entry in source {
            radix_value := sort_key_to_u32(entry.sort_key)
            radix_byte := (radix_value >> (byte_index * 8)) & 0xFF
            
            index := sort_key_offsets[radix_byte]
            dest[index] = entry
            sort_key_offsets[radix_byte] += 1
        }
        
        swap(&source, &dest)
    }
}

// @todo(viktor): if we pass an empty slice we cause a stack overflow, handle this for all sorts
merge_sort :: proc (entries: []$T, temp_space: []T, comes_before: proc (a, b: T) -> b32) #no_bounds_check {
    count := len(entries)
    
    switch count {
      case 1: // No work to do
      case 2: 
        a := &entries[0]
        b := &entries[1]
        if #force_inline comes_before(b^, a^) {
            swap(a, b)
        }
      case:
        middle := count/2
        as := entries[:middle]
        bs := entries[middle:]
        
        merge_sort(as, temp_space, comes_before)
        merge_sort(bs, temp_space, comes_before)
        
        // @todo(viktor): This can probably be done with less memory, by being smarter 
        // about where we copy from and to.
        cs := Array(T) { data = temp_space }
        ai, bi: int
        for ai < len(as) && bi < len(bs) {
            a := &as[ai]
            b := &bs[bi]
            
            if #force_inline comes_before(b^, a^) {
                bi += 1
                append(&cs, b^)
            } else {
                ai += 1
                append(&cs, a^)
            }
        }
        
        append(&cs, as[ai:])
        append(&cs, bs[bi:])
        
        assert(cs.count == auto_cast len(entries))
        
        for c, index in slice(cs) {
            entries[index] = c
        }
    }
}

bubble_sort :: proc (entries: []SortEntry) {
    count := len(entries)
    for _ in 0 ..< count {
        sorted := true
        
        for inner in 0 ..< count-1 {
            a := &entries[inner]
            b := &entries[inner+1]
            if a.sort_key > b.sort_key {
                swap(a, b)
                sorted = false
            }
        }
        
        if sorted do break
    }
}

////////////////////////////////////////////////

sort_key_to_u32 :: proc (sort_key: f32) -> (result: u32) {
    result = transmute(u32) sort_key

    SignBit :: 0x8000_0000
    is_negative := (result & SignBit) != 0
    if is_negative {
        result = ~result
    } else {
        result |= SignBit
    }

    return result
}