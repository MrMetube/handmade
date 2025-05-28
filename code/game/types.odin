#+vet !unused-procedures
package game

@(common="file")

Array :: struct ($T: typeid) {
    data:  []T,
    count: i64,
}
FixedArray :: struct ($N: i64, $T: typeid) {
    data:  [N]T,
    count: i64,
}

append :: proc { append_fixed_array, append_array, append_array_ }
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

// [Sentinel] -> <- [..] ->
//  -> <- [..] -> ...    <-
LinkedList :: struct($T: typeid) {
    prev, next: ^LinkedList(T),
    using data: T,
}

list_init_sentinel :: proc(sentinel: ^LinkedList($T)) {
    sentinel.next = sentinel
    sentinel.prev = sentinel
}

list_insert_before :: proc(list: ^$L/LinkedList($T), element: ^L) {
    element.prev = list
    element.next = list.next
    
    element.next.prev = element
    element.prev.next = element
}

list_insert_after :: proc(list: ^$L/LinkedList($T), element: ^L) {
    element.prev = list.prev
    element.next = list
    
    element.next.prev = element
    element.prev.next = element
}

list_remove :: proc(element: ^LinkedList($T)) {
    element.prev.next = element.next
    element.next.prev = element.prev
    
    element.next = nil
    element.prev = nil
}

///////////////////////////////////////////////

// [Head] -> [..] ... -> [..] -> [Tail]
SingleLinkedList :: struct($T: typeid) {
    using data: T,
    next:       ^SingleLinkedList(T),
}

// @todo(viktor): codefy removal from the list whilst iterating over it
// maybe a procedure is enough, please no iterator objects

list_push :: proc(head: ^^SingleLinkedList($T), elements: ..^SingleLinkedList(T)) {
    for element in elements {
        element.next = head^
        head        ^= element
    }
}

list_pop :: proc(head: ^^SingleLinkedList($T)) -> (result: ^SingleLinkedList(T), ok: b32) #optional_ok {
    if head^ != nil {
        result = head^
        head  ^= result.next
        
        ok = true
    }
    
    return result, ok
}