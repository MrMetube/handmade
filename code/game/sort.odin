package game

@(common="file")


SortEntry :: struct {
    sort_key: f32,
    index:    u32,
}

is_sorted :: proc(entries: []SortEntry) {
    count := len(entries)
    for index in 0 ..< count-1 {
        a := &entries[index]
        b := &entries[index+1]
        assert(a.sort_key <= b.sort_key)
    }
}

radix_sort :: proc(entries: []SortEntry, temp_space: []SortEntry) {
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

sort_key_to_u32 :: proc(sort_key: f32) -> (result: u32) {
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


merge_sort :: proc(entries: []SortEntry, temp_space: []SortEntry) {
    entries := entries
    count := len(entries)
    
    switch count {
      case 1: // No work to do
      case 2: 
        a := &entries[0]
        b := &entries[1]
        if a.sort_key > b.sort_key {
            swap(a, b)
        }
      case:
        as := entries[:count/2]
        bs := entries[count/2:]
        
        merge_sort(as, temp_space)
        merge_sort(bs, temp_space)
        
        // Merge as and bs
        InPlace :: false
        when InPlace {
            // NOTE(viktor): We need to block-copy a lot of elements.
            // We swap them one-by-one in a chain to their destination
            // and then swap what was their to its destination.
            // This is neither cache friendly nor efficient.
            
            to_merge := entries[:]
            for {
                // 1 - Skip all the as that are less or equal to b1
                ai: int
                b1 := bs[0].sort_key
                for ai < len(as) && as[ai].sort_key <= b1 {
                    ai += 1
                }
                
                if ai == len(as) do break
                
                // 2 - Swap entries so that c comes after b
                // [as,cs] [bs] => [as] [bs] [cs]
                
                cs := as[ai:]
                to_merge = to_merge[ai:]

                span  := len(to_merge)
                start := 0
                index := start
                
                src := to_merge[index]
                
                cn := len(cs)
                bn := len(bs)
                swap_count := 0
                for {
                    dst := index + (index >= cn ? -cn : bn)

                    destination := &to_merge[dst]
                    copy := destination^
                    destination^ = src
                    
                    swap_count += 1
                    
                    if dst == start {
                        if swap_count == span do break
                        
                        // We hit a cycle that does not contain all elements of bs and cs.
                        // (That implies that our shift amount divides our span without remainder.)
                        // Therefore we start at the first element not in the cycle and make another
                        // swap-cycle and repeat this a total of shift/span times.
                        start += 1
                        dst   += 1
                        copy  = to_merge[start]
                    }
                    
                    index = dst
                    src   = copy
                }
                
                // ==>
                // 3 - Repeat 1 with a' = b, b' = c
                // Note that we swapped the elements but not the slices themselves,
                // so we need to swap cs and bs lengths as well.
                as = to_merge[:len(bs)]
                bs = to_merge[len(bs):]
            }
        } else {
            // TODO(viktor): This can probably be done with less memory, by being smarter 
            // about where we copy from and to.
            ai, bi, ci: int
            for ai < len(as) && bi < len(bs) {
                a := as[ai]
                b := bs[bi]
                
                if a.sort_key <= b.sort_key {
                    ai += 1
                    temp_space[ci] = a
                    ci += 1
                } else {
                    bi += 1
                    temp_space[ci] = b
                    ci += 1
                }
            }
            
            for a in as[ai:] {
                temp_space[ci] = a
                ci += 1
            }
            
            for b in bs[bi:] {
                temp_space[ci] = b
                ci += 1
            }
            
            assert(ci == len(entries))
            
            for c, index in temp_space[:ci] {
                entries[index] = c
            }
        }
    }
}

bubble_sort :: proc(entries: []SortEntry) {
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