package game

LinkedListEntry :: struct($T: typeid) {
    using data: T,
    prev, next: ^LinkedListEntry(T),
}

list_init_sentinel :: #force_inline proc(sentinel: ^LinkedListEntry($T)) {
    sentinel.next = sentinel
    sentinel.prev = sentinel
}

list_insert :: #force_inline proc(previous, element: ^LinkedListEntry($T)) {
    element.prev = previous
    element.next = previous.next
    
    element.next.prev = element
    element.prev.next = element
}

list_remove :: #force_inline proc(element: ^LinkedListEntry($T)) {
    element.prev.next = element.next
    element.next.prev = element.prev
    
    element.next = nil
    element.prev = nil
}

///////////////////////////////////////////////

SingleLinkedListEntry :: struct($T: typeid) {
    using data: T,
    next: ^SingleLinkedListEntry(T),
}

// :ListEntryRemovalInLoop
// TODO(viktor): if there is ever an iterator for list it should allow for removal of entries
// whilst iterating. See the tag for manual implementations of it and as targets for refactoring
// if the day ever comes.

list_push_sentinel :: #force_inline proc(sentinel: ^SingleLinkedListEntry($T), element: ^SingleLinkedListEntry(T)) {
    element^      = sentinel^
    sentinel.next = element
}

list_push :: #force_inline proc(head: ^^SingleLinkedListEntry($T), element: ^SingleLinkedListEntry(T)) {
    element.next = head^
    head^        = element
}

list_pop :: #force_inline proc(head: ^^SingleLinkedListEntry($T)) -> (result: ^SingleLinkedListEntry(T), ok: b32) #optional_ok {
    if head^ != nil {
        result = head^
        head^  = result.next
        
        ok = true
    }
    
    return result, ok
}