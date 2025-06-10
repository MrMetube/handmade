#+vet !unused-procedures
package game

@(common="file")

import "base:intrinsics"

Array :: struct ($T: typeid) {
    data:  []T,
    count: i64,
}
FixedArray :: struct ($N: i64, $T: typeid) {
    data:  [N]T,
    count: i64,
}

append :: proc { append_fixed_array, append_array, append_array_, append_array_many, append_fixed_array_many }
@(require_results) append_array_ :: proc(a: ^Array($T)) -> (result: ^T) {
    result = &a.data[a.count]
    a.count += 1
    return result
}
append_array :: proc(a: ^Array($T), value: T) -> (result: ^T) {
    a.data[a.count] = value
    result = append_array_(a)
    return result
}
append_fixed_array :: proc(a: ^FixedArray($N, $T), value: T) -> (result: ^T) {
    a.data[a.count] = value
    result = &a.data[a.count]
    a.count += 1
    return result
}
append_array_many :: proc(a: ^Array($T), values: []T) -> (result: []T) {
    start := a.count
    for &value in values {
        a.data[a.count] = value
        a.count += 1
    }
    
    result = a.data[start:a.count]
    return result
}
append_fixed_array_many :: proc(a: ^FixedArray($N, $T), values: []T) -> (result: []T) {
    start := a.count
    for &value in values {
        a.data[a.count] = value
        a.count += 1
    }
    
    result = a.data[start:a.count]
    return result
}

make_array :: proc(arena: ^Arena, $T: typeid, #any_int len: i32, params := DefaultPushParams) -> (result: Array(T)) {
    result.data = push_slice(arena, T, len, params)
    return result
}

slice :: proc{ slice_fixed_array, slice_array }
slice_fixed_array :: proc(array: ^FixedArray($N, $T)) -> []T {
    return array.data[:array.count]
}
slice_array :: proc(array: Array($T)) -> []T {
    return array.data[:array.count]
}

rest :: proc{ rest_fixed_array, rest_array }
rest_fixed_array :: proc(array: ^FixedArray($N, $T)) -> []T {
    return array.data[array.count:]
}
rest_array :: proc(array: Array($T)) -> []T {
    return array.data[array.count:]
}

////////////////////////////////////////////////
// [First] <- [..] ... <- [..] <- [Last] 
Deque :: struct($L: typeid) {
    first, last: ^L,
}

deque_prepend :: proc(deque: ^Deque($L), element: ^L) {
    if deque.first == nil {
        assert(deque.last == nil)
        deque.last  = element
        deque.first = element
    }  else {
        deque.last.next = element
        deque.last      = element
    }
}

deque_append :: proc(deque: ^Deque($L), element: ^L) {
    if deque.first == nil {
        assert(deque.last == nil)
        deque.last  = element
        deque.first = element
    }  else {
        deque.first.next = element
        deque.first      = element
    }
}

deque_remove_from_end :: proc(deque: ^Deque($L)) -> (result: ^L) {
    result = deque.last
    
    if result != nil {
        deque.last = result.next

        if result == deque.first {
            assert(result.next == nil)
            deque.first = nil
        }
    }
    
    return result
}

////////////////////////////////////////////////
// Double Linked List
// [Sentinel] -> <- [..] ->
//  -> <- [..] -> ...    <-

list_init_sentinel :: proc { list_init_sentinel_custom_member, list_init_sentinel_prev_next }
list_init_sentinel_prev_next     :: proc(sentinel: ^$T)                    { list_init_sentinel(sentinel, offset_of(sentinel.prev), offset_of(sentinel.next)) }
list_init_sentinel_custom_member :: proc(sentinel: ^$T, $prev, $next: umm) {
    get(sentinel, next) ^= sentinel
    get(sentinel, prev) ^= sentinel
}

list_prepend :: proc { list_prepend_custom_member, list_prepend_prev_next }
list_prepend_prev_next     :: proc(list: ^$T, element: ^T)                    { list_prepend(list, element, offset_of(list.prev), offset_of(list.next)) }
list_prepend_custom_member :: proc(list: ^$T, element: ^T, $prev, $next: umm) {
    element_next := get(element, next)
    element_prev := get(element, prev)
    
    element_prev^ = get(list, prev)^
    element_next^ = list
    
    element_next^.prev = element
    element_prev^.next = element
}

list_append :: proc { list_append_custom_member, list_append_prev_next }
list_append_prev_next     :: proc(list: ^$T, element: ^T)                    { list_append(list, element, offset_of(list.prev), offset_of(list.next)) }
list_append_custom_member :: proc(list: ^$T, element: ^T, $prev, $next: umm) {
    element_next := get(element, next)
    element_prev := get(element, prev)
    
    element_next^ = get(list, next)^
    element_prev^ = list
    
    element_next^.prev = element
    element_prev^.next = element
}

list_remove :: proc { list_remove_custom_member, list_remove_prev_next }
list_remove_prev_next     :: proc(element: ^$T)                    { list_remove(element, offset_of(element.prev), offset_of(element.next)) }
list_remove_custom_member :: proc(element: ^$T, $prev, $next: umm) {
    element_next := get(element, next)
    element_prev := get(element, prev)
    
    element_prev^.next = element_next^
    element_next^.prev = element_prev^
    
    element_next^ = nil
    element_prev^ = nil
}

///////////////////////////////////////////////
// Single Linked List
// [Head] -> [..] ... -> [..] -> [Tail]

list_push :: proc { list_push_next, list_push_custom_member }
list_push_next          :: proc (head: ^^$T, element: ^T)             { list_push(head, element, offset_of(T, next)) }
list_push_custom_member :: proc (head: ^^$T, element: ^T, $next: umm) {
    element_next := get(element, next) 
    #assert(type_of(element_next^) == ^T)

    element_next ^= head^
    head         ^= element
}

list_pop_head :: proc { list_pop_head_custom_member, list_pop_head_next }
list_pop_head_next          :: proc (head: ^^$T)             -> (result: ^T, ok: b32) #optional_ok { return list_pop_head(head, offset_of(head^.next)) }
list_pop_head_custom_member :: proc (head: ^^$T, $next: umm) -> (result: ^T, ok: b32) #optional_ok {
    if head^ != nil {
        result = head^
        head ^= get(result, next)^
        
        ok = true
    }
    return result, ok
}

///////////////////////////////////////////////

@(private="file") 
get :: proc(type: ^$T, $offset: umm ) -> (result: ^^T) {
    raw_link := cast([^]u8) type
    slot := cast(^^T) &raw_link[offset]
    return slot
}
