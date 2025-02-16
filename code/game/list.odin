package game

// :LinkedListIteration
// TODO(viktor): make an iterator that sparks joy
LinkedList :: struct($T: typeid) {
    using data: T,
    prev, next: ^LinkedList(T),
}

// TODO(viktor): just return the sentinel and call it make?
list_init_sentinel :: #force_inline proc(sentinel: ^LinkedList($T)) {
    sentinel.next = sentinel
    sentinel.prev = sentinel
}

// TODO(viktor): insert literal
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

SingleLinkedList :: struct($T: typeid) {
    using data: T,
    next:       ^SingleLinkedList(T),
}

// :ListEntryRemovalInLoop
// TODO(viktor): if there is ever an iterator for list it should allow for removal of entries
// whilst iterating. See the tag for manual implementations of it and as targets for refactoring
// if the day ever comes.

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