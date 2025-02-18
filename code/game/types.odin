package game

// [First] <- [..] ... <- [..] <- [Last] 
Deque :: struct($L: typeid) {
    first, last: ^L
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
    using data: T,
    prev, next: ^LinkedList(T),
}

list_init_sentinel :: #force_inline proc(sentinel: ^LinkedList($T)) {
    sentinel.next = sentinel
    sentinel.prev = sentinel
}

list_insert :: #force_inline proc(previous, element: ^LinkedList($T)) {
    element.prev = previous
    element.next = previous.next
    
    element.next.prev = element
    element.prev.next = element
}

list_remove :: #force_inline proc(element: ^LinkedList($T)) {
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

// TODO(viktor): codefy removal from the list whilst iterating over it
// maybe a procedure is enough, please no iterator objects

list_push_after_head :: #force_inline proc(head: ^SingleLinkedList($T), element: ^SingleLinkedList(T)) {
    element^, head^ = head^, element^
    head.next = element
}

list_push :: #force_inline proc(head: ^^SingleLinkedList($T), elements: ..^SingleLinkedList(T)) {
    for element in elements {
        element.next = head^
        head^        = element
    }
}

list_pop :: #force_inline proc(head: ^^SingleLinkedList($T)) -> (result: ^SingleLinkedList(T), ok: b32) #optional_ok {
    if head^ != nil {
        result = head^
        head^  = result.next
        
        ok = true
    }
    
    return result, ok
}