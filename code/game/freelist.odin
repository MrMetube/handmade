package game

@(common="file")

// @todo(viktor): how can we handle a null arena properly?
FreeList :: struct ($T: typeid) {
    first_free: ^T,
    arena:      ^Arena,
}

////////////////////////////////////////////////

// @compilerbug first_free should just be = nil by default but that is broken on "odin version dev-2026-01:393fec2f6"
freelist_init :: proc (list: ^FreeList($T), backing: ^Arena, first_free : ^T = nil) {
    list.arena      = backing
    list.first_free = first_free
}

freelist_empty :: proc (list: FreeList($T)) -> bool {
    result := list.first_free == nil
    return result
}

////////////////////////////////////////////////

freelist_push_next :: proc (list: ^FreeList($T), params := DefaultPushParams) -> ^T {
    return freelist_push(list, &list.first_free.next, params)
}
freelist_push :: proc (list: ^FreeList($T), next: ^^T, params := DefaultPushParams) -> ^T {
    result, ok := list_pop_head(&list.first_free, next)
    
    if !ok {
        assert(list.arena != nil)
        sub_params := params
        sub_params.flags -= { .ClearToZero }
        result = push(list.arena, T, params)
    }
    
    if .ClearToZero in params.flags {
        result^ = {}
    }
    
    return result
}


freelist_free_next :: proc (list: ^FreeList($T), element: ^T) { 
    freelist_free(list, element, &element.next)
}
freelist_free :: proc (list: ^FreeList($T), element: ^T, next: ^^T) {
    list_push(&list.first_free, element, next)
}


// @note push the whole list: T, head -> tail onto the freelist
freelist_free_list :: proc (list: ^FreeList($T), head, tail: ^T) {
    tail.next       = list.first_free
    list.first_free = head
}
