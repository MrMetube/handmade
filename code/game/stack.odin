package game

import "base:intrinsics"

Stack :: struct($Array: typeid) where intrinsics.type_is_array(Array) {
    depth: u32,
    data:  Array,
}

stack_push :: #force_inline proc(using stack: ^Stack($A/[$N]$T), element: T) -> (result: ^T) {
    result  = &data[depth]
    result^ = element
    depth += 1
    return result
}

stack_peek :: #force_inline proc(using stack: ^Stack($A/[$N]$T)) -> (result: ^T) {
    if depth > 0 {
        result = &data[depth-1]
    }
    return result
}

stack_pop :: #force_inline proc(using stack: ^Stack($A/[$N]$T)) -> (result: ^T) {
    depth -= 1
    result = &data[depth]
    return result
}

/* Iterator example
    StackIterator :: struct($T: typeid, $Size: u32) {
        index: u32,
        stack: ^Stack(T,Size),
    }

    iter := stack_make_iterator(&stack)
    for it, it_index in stack_iterator(&iter) {
        
    }


    stack_make_iterator :: proc(using stack: ^Stack($T, $S)) -> (result: StackIterator(T, S)) {
        return { stack = stack }
    }
    stack_iterator :: proc(using iterator: ^StackIterator($T, $S)) -> (it: ^T, it_index: u32, ok: bool) {
        if ok = iterator.stack.depth > 0; ok {
            it = stack_pop(iterator.stack)
            it_index += 1
        }
        return it, it_index, ok
    }
*/