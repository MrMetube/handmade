#+vet !unused-procedures
package game

@(common="file")

import "base:runtime"

make_array :: proc (arena: ^Arena, $T: typeid, #any_int capacity: i32, params := DefaultPushParams) -> [dynamic] T {
    alloc := arena_allocator(arena)
    result := make_dynamic_array(alloc, T, 0, capacity, params)
    result.allocator = {}
    return result
}
make_array_with_slice :: proc (data: [] $T) -> [dynamic] T {
    result := dynamic_array_from_parts(T, raw_data(data), 0, len(data))
    return result
}
make_array_allocator :: proc (allocator: Allocator, $T: typeid, #any_int capacity: i32, params := DefaultPushParams) -> [dynamic] T {
    result := make_dynamic_array(allocator, T, 0, capacity, params)
    return result
}

peek :: proc (a: [dynamic] $T) ->^T { 
    assert(len(a) != 0)
    #no_bounds_check result = &a[len(a)-1]
    return result
}

rest :: proc { rest_dynamic_array }
rest_dynamic_array :: proc (array: [dynamic] $T) -> []T {
    #no_bounds_check data := &array[len(array)]
    result := slice_from_parts(data, cap(array))
    return result
}

last :: proc { last_array, last_slice, last_fixed }
last_array :: proc (a: [dynamic] $T) -> ^T {
    result := &a[len(a)-1]
    return result
}
last_slice :: proc (a: [] $T) -> ^T {
    result := &a[len(a)-1]
    return result
}
last_fixed :: proc (a: ^[dynamic; $N] $T) -> ^T {
    result := &a[len(a)-1]
    return result
}


set_len :: proc (array: ^[dynamic] $T, len: int) {
    assert(len <= cap(array))
    raw := cast(^Raw_Dynamic_Array) array
    raw.len = len
}
set_len_fixed :: proc (array: ^[dynamic; $N] $T, len: int) {
    assert(len <= cap(array))
    raw := cast(^Raw_) array
    raw.len = len
}

////////////////////////////////////////////////

String_Builder :: distinct [dynamic] u8

@(printlike)
appendf :: proc (builder: ^String_Builder, format: string, args: ..any) -> string {
    array := cast(^[dynamic] u8) builder
    buf := rest(array^)
    
    result := format_string(buf, format, ..args)
    set_len(array, len(array) + len(result))
    
    return result
}

append_string :: proc (a: ^String_Builder, value: string) -> string {
    append(a, ..(transmute([]u8) value))
    return cast(string) a[:]
}

make_string_builder :: proc { make_string_builder_arena, make_string_builder_buffer }
make_string_builder_arena :: proc (arena: ^Arena, #any_int len: i32, params := DefaultPushParams) -> String_Builder {
    buffer := push_slice(arena, u8, len, params)
    result := make_string_builder(buffer)
    return result
}
make_string_builder_buffer :: proc (buffer: [] u8) -> String_Builder {
    result := cast(String_Builder) make_array_with_slice(buffer)
    return result
}

to_string :: proc (sb: String_Builder) -> string {
    return cast(string) sb[:]
}
to_cstring :: proc (sb: ^String_Builder) -> cstring {
    append(sb, 0)
    return cast(cstring) &sb[0]
}

////////////////////////////////////////////////
// [First] <- [..] ... <- [..] <- [Last] 
Deque :: struct($L: typeid) {
    first, last: ^L,
}

deque_prepend :: proc (deque: ^Deque($L), element: ^L) {
    if deque.first == nil {
        assert(deque.last == nil)
        deque.last  = element
        deque.first = element
    }  else {
        element.next = deque.last
        deque.last   = element
    }
}

deque_append :: proc (deque: ^Deque($L), element: ^L) {
    if deque.first == nil {
        assert(deque.last == nil)
        deque.last  = element
        deque.first = element
    }  else {
        deque.first.next = element
        deque.first      = element
    }
}

deque_remove_from_end :: proc (deque: ^Deque($L)) -> ^L {
    result := deque.last
    
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

list_init_sentinel :: proc (sentinel: ^$T) {
    sentinel.next = sentinel
    sentinel.prev = sentinel
}

list_prepend :: proc (list: ^$T, element: ^T) {
    element.prev = list.prev
    element.next = list
    
    element.next.prev = element
    element.prev.next = element
}

list_append :: proc (list: ^$T, element: ^T) {
    element.next = list.next
    element.prev = list
    
    element.next.prev = element
    element.prev.next = element
}

list_remove :: proc (element: ^$T) {
    element.prev.next = element.next
    element.next.prev = element.prev
    
    element.next = nil
    element.prev = nil
}

///////////////////////////////////////////////
// Single Linked List
// [Head] -> [..] ... -> [..] -> [Tail]

list_push_next :: proc (head: ^^$T, element: ^T) {
    list_push(head, element, &element.next)
}
list_push :: proc (head: ^^$T, element: ^T, next: ^^T) {
    next^ = head^
    head^ = element
}


list_pop_head_next :: proc (head: ^^$T) -> (^T, bool) #optional_ok { 
    result, ok := list_pop_head_pointer(head, head^.next)
    return result, ok
}
// @note next is a ^^T so that we don't read the value unless head^ is not nil.
list_pop_head :: proc (head: ^^$T, next: ^^T) -> (^T, bool) #optional_ok { 
    result: ^T
    ok:     bool
    
    if head^ != nil {
        ok = true
        result = head^
        head^  = next^
    }
    
    return result, ok
}
