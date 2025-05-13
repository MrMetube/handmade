package game

@(common="file")
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

list_push_after_head :: proc(head: ^SingleLinkedList($T), element: ^SingleLinkedList(T)) {
    element^, head^ = head^, element^
    head.next = element
}

list_push :: proc(head: ^^SingleLinkedList($T), elements: ..^SingleLinkedList(T)) {
    for element in elements {
        element.next = head^
        head^        = element
    }
}

list_pop :: proc(head: ^^SingleLinkedList($T)) -> (result: ^SingleLinkedList(T), ok: b32) #optional_ok {
    if head^ != nil {
        result = head^
        head^  = result.next
        
        ok = true
    }
    
    return result, ok
}