#+vet !unused-procedures
package game

@(common="file")

import "base:builtin"
import "base:runtime"

// @todo(viktor): maybe get just rid of this boxing and use dynamic arrays, but then be sure that the correct allocators are used
Array :: struct ($T: typeid) {
    data: [dynamic] T,
}

FixedArray :: struct ($N: i64, $T: typeid) {
    data:  [N] T,
    count: i64,
}

append :: proc { 
    append_fixed_array, append_array, append_array_, append_fixed_array_, 
    append_array_many, append_fixed_array_many, 
    append_array_many_slice, append_fixed_array_many_slice,
    append_string, 
    builtin.append_elem, builtin.append_elems, builtin.append_soa_elems, builtin.append_soa_elem, 
}
@(require_results) append_array_ :: proc (a: ^Array($T)) -> (result: ^T) {
    set_len(&a.data, len(a.data)+1)
    result = last(a^)
    return result
}
@(require_results) append_fixed_array_ :: proc (a: ^FixedArray($N, $T)) -> (result: ^T) {
    result = &a.data[a.count]
    a.count += 1
    return result
}
append_array :: proc (a: ^Array($T), value: T) -> (result: ^T) {
    append(&a.data, value)
    result = last_array(a^)
    return result
}
append_fixed_array :: proc (a: ^FixedArray($N, $T), value: T) -> (result: ^T) {
    a.data[a.count] = value
    result = &a.data[a.count]
    a.count += 1
    return result
}
append_array_many :: proc (a: ^Array($T), values: ..T) -> (result: []T) {
    start := len(a.data)
    append(&a.data, ..values)
    result = a.data[start:]
    return result
}
append_array_many_slice :: proc (a: ^Array($T), values: []T) -> (result: []T) {
    start := len(a.data)
    append(&a.data, ..values)
    result = a.data[start:]
    return result
}
append_fixed_array_many :: proc (a: ^FixedArray($N, $T), values: ..T) -> (result: []T) {
    start := a.count
    for &value in values {
        a.data[a.count] = value
        a.count += 1
    }
    
    result = a.data[start:a.count]
    return result
}
append_fixed_array_many_slice :: proc (a: ^FixedArray($N, $T), values: [] T) -> (result: []T) {
    start := a.count
    for &value in values {
        a.data[a.count] = value
        a.count += 1
    }
    
    result = a.data[start:a.count]
    return result
}

make_array :: proc (arena: ^Arena, $T: typeid, #any_int capacity: i32, params := DefaultPushParams) -> (result: Array(T)) {
    alloc := arena_allocator(arena)
    result.data = make_dynamic_array(alloc, T, 0, capacity, params)
    result.data.allocator = runtime.nil_allocator()
    return result
}
make_array_with_slice :: proc (_data: [] $T) -> (result: Array(T)) {
    result.data = dynamic_array_from_parts(T, raw_data(_data), 0, len(_data))
    return result
}
make_array_allocator :: proc (allocator: Allocator, $T: typeid, #any_int capacity: i32, params := DefaultPushParams) -> (result: Array(T)) {
    result.data = make_dynamic_array(allocator, T, 0, capacity, params)
    return result
}

peek :: proc (a: [dynamic] $T) -> (result: ^T) { 
    assert(len(a) != 0)
    #no_bounds_check result = &a[len(a)-1]
    return result
}

slice :: proc { slice_fixed_array, slice_array, slice_array_pointer }
slice_fixed_array :: proc (array: ^FixedArray($N, $T)) -> []T {
    return array.data[:array.count]
}
slice_array :: proc (array: Array($T)) -> []T {
    return array.data[:]
}
slice_array_pointer :: proc (array: ^Array($T)) -> []T {
    return array.data[:array.count]
}

rest :: proc { rest_fixed_array, rest_array, rest_dynamic_array }
rest_fixed_array :: proc (array: ^FixedArray($N, $T)) -> []T {
    return array.data[array.count:]
}
rest_array :: proc (array: Array($T)) -> []T {
    return rest_dynamic_array(array.data)
}
rest_dynamic_array :: proc (array: [dynamic] $T) -> []T {
    #no_bounds_check _data := &array[len(array)]
    result := slice_from_parts(_data, cap(array))
    return result
}

last :: proc { last_array, last_slice }
last_array :: proc (a: Array($T)) -> ^T {
    result := &a.data[len(a.data)-1]
    return result
}
last_slice :: proc (a: [] $T) -> ^T {
    result := &a._data[len(a._data)-1]
    return result
}


set_len :: proc (array: ^[dynamic] $T, len: int) {
    assert(len <= cap(array))
    raw := cast(^Raw_Dynamic_Array) array
    raw.len = len
}

clear :: proc { builtin.clear_dynamic_array, builtin.clear_map, runtime.clear_soa_dynamic_array, clear_byte_buffer, array_clear, fixed_array_clear }
array_clear :: proc (a: ^Array($T)) {
    clear(&a.data)
}
fixed_array_clear :: proc (a: ^FixedArray($N, $T)) {
    a.count = 0
}

ordered_remove :: proc { builtin.ordered_remove, ordered_remove_array }
ordered_remove_array :: proc (a: ^Array($T), #any_int index: i64) {
    _data := slice(a^)
    copy(_data[index:], _data[index+1:])
    a.count -= 1
}
unordered_remove :: proc { builtin.unordered_remove, unordered_remove_array }
unordered_remove_array :: proc (a: ^Array($T), #any_int index: i64) {
    a.data[index] = a.data[a.count-1]
    a.count -= 1
}

////////////////////////////////////////////////

String_Builder :: Array(u8)

@(printlike)
appendf :: proc (a: ^String_Builder, format: string, args: ..any) -> (result: string) {
    buf := rest(a^)
    result = format_string(buf, format, ..args)
    set_len(&a.data, len(a.data) + len(result))
    return result
}

append_string :: proc (a: ^String_Builder, value: string) -> (result: string) {
    append_array_many_slice(a, (transmute([]u8) value))
    return cast(string) a.data[:]
}

make_string_builder :: proc { make_string_builder_buffer, make_string_builder_arena }
make_string_builder_buffer :: proc (buffer: [] u8) -> String_Builder {
    result := make_array_with_slice(buffer)
    return result
}
make_string_builder_arena :: proc (arena: ^Arena, #any_int len: i32, params := DefaultPushParams) -> (result: String_Builder) {
    buffer := push_slice(arena, u8, len, params)
    result = make_string_builder_buffer(buffer)
    return result
}

to_string :: proc (sb: String_Builder) -> string {
    return cast(string) sb.data[:]
}
to_cstring :: proc (sb: ^String_Builder) -> cstring {
    append(sb, 0)
    return cast(cstring) &sb.data[0]
}

////////////////////////////////////////////////
// @note(viktor): writing and reading need to be in sync or we get undefined behaviour. We could always write the type of a value in combination with that value and then on read assert that the next type to read is the same as the requested type of the parameter.
// @todo(viktor): most of these calls are untested and need to checked and verified

Byte_Buffer :: struct {
    bytes:        [] u8,
    read_cursor:  int,
    write_cursor: int,
}

make_byte_buffer :: proc (buffer: [] u8) -> (result: Byte_Buffer) {
    result = { bytes = buffer }
    return result
}

write_reserve :: proc (b: ^Byte_Buffer, $T: typeid) -> (result: ^T) {
    dest := b.bytes[b.write_cursor:]
    size := size_of(T)
    assert(len(dest) >= size)
    
    result = cast(^T) &dest[0]
    b.write_cursor += size
    
    return result
}

write_slice :: proc (b: ^Byte_Buffer, values: [] $T) {
    dest := b.bytes[write_cursor:]
    assert(len(dest) >= len(source))
    source := slice_from_parts(u8, raw_data(values), len(values) * size_of(T))
    copy(dest, source)
    b.write_cursor += len(source)
}

write :: proc (b: ^Byte_Buffer, value: $T) {
    dest := b.bytes[write_cursor:]
    assert(len(dest) >= size_of(T))
    value := value
    source := slice_from_parts(u8, &value, size_of(T))
    copy(dest, source)
    b.write_cursor += len(source)
}

write_align :: proc (b: ^Byte_Buffer, #any_int alignment: int) {
    // @todo(viktor): ensure that alignment is a power of two
    remainder := b.write_cursor % alignment
    if b.write_cursor % alignment != 0 {
        offset := alignment - remainder
        assert(b.write_cursor + offset < len(b.bytes))
        b.write_cursor += offset
    }
}

read_align :: proc (b: ^Byte_Buffer, #any_int alignment: int) {
    // @todo(viktor): ensure that alignment is a power of two
    remainder := b.read_cursor % alignment
    if b.read_cursor % alignment != 0 {
        offset := alignment - remainder
        assert(b.read_cursor + offset < len(b.bytes))
        b.read_cursor += offset
    }
}

read :: proc (b: ^Byte_Buffer, $T: typeid) -> (result: ^T) {
    source := b.bytes[b.read_cursor:]
    assert(size_of(T) <= len(source))
    
    result = cast(^T) &source[0]
    b.read_cursor += size_of(T)
    
    return result
}

read_slice :: proc (b: ^Byte_Buffer, $T: typeid/ [] $E, count: int) -> (result: [] E) {
    size := count * size_of(T)
    source := b.bytes[b.read_cursor:]
    assert(size <= len(source))
    result = source[:size]
    b.read_cursor += size
    
    return result
}

begin_reading :: proc (b: ^Byte_Buffer) { b.read_cursor = 0 }
can_read :: proc (b: ^Byte_Buffer) -> (result: bool) { return b.read_cursor < b.write_cursor }

clear_byte_buffer :: proc (b: ^Byte_Buffer) {
    b.read_cursor = 0
    b.write_cursor = 0
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

deque_remove_from_end :: proc (deque: ^Deque($L)) -> (result: ^L) {
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

list_push :: proc { list_push_next, list_push_next_pointer }
list_push_next :: proc (head: ^^$T, element: ^T) {
    list_push(head, element, &element.next)
}
list_push_next_pointer :: proc (head: ^^$T, element: ^T, next: ^^T) {
    next^ = head^
    head^ = element
}


list_pop_head:: proc { list_pop_head_next, list_pop_head_next_offset }
list_pop_head_next :: proc (head: ^^$T) -> (result: ^T, ok: b32) #optional_ok { 
    result, ok = list_pop_head(head, offset_of(T, next))
    return result, ok
}
list_pop_head_next_offset :: proc (head: ^^$T, $next_offset: umm) -> (result: ^T, ok: b32) #optional_ok {
    ok = head^ != nil
    if ok {
        result = head^
        next  := cast(^^T) (cast(umm) result + next_offset)
        head^  = next^
    }
    
    return result, ok
}
