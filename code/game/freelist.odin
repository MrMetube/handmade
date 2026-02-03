package game

@(common="file")

// @todo(viktor): how can we handle a null arena properly?
FreeList :: struct ($T: typeid) {
    first_free: ^T,
    arena:      ^Arena,
}

////////////////////////////////////////////////

// @compilerbug first_free should just be = nil by default but that is broken on "odin version dev-2026-01:393fec2f6"
freelist_init :: proc (list: ^FreeList($T), backing: ^Arena, first_free : ^T = auto_cast cast(umm) 0) {
    list.arena      = backing
    list.first_free = first_free
}

////////////////////////////////////////////////

freelist_push :: proc (list: ^FreeList($T), params := DefaultPushParams) -> ^T {
    result, ok := list_pop_head(&list.first_free)
    
    if !ok {
        assert(list.arena != nil)
        result = push(list.arena, T, params)
    } else {
        if .ClearToZero in params.flags {
            result^ = {}
        }
    }
    
    return result
}

freelist_free :: proc (list: ^FreeList($T), element: ^T) {
    list_push(&list.first_free, element)
}

// @note(viktor): push the whole list: T, head -> tail onto the freelist
freelist_free_list :: proc (list: ^FreeList($T), head, tail: ^T) {
    tail.next = list.first_free
    list.first_free = head
}

freelist_empty :: proc (list: FreeList($T)) -> bool {
    result := list.first_free == nil
    return result
}