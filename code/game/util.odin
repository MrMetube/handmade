package game 

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:simd"

f32x4 :: #simd[4]f32
u32x4 :: #simd[4]u32
i32x4 :: #simd[4]i32
i16x8 :: #simd[8]i16

@(disabled=ODIN_DISABLE_ASSERT)
assert :: #force_inline proc(condition: b32, message := #caller_expression(condition), loc := #caller_location) {
    if !condition {
        // NOTE(viktor): if needed enclose the failure code in the cold proc to improve branch prediction
        // @(cold)
        // cold :: proc(message: string, loc: runtime.Source_Code_Location) {
            runtime.print_caller_location(loc)
            runtime.print_string(" Assertion failed")
            if len(message) > 0 {
                runtime.print_string(": ")
                runtime.print_string(message)
            }
            runtime.print_byte('\n')
            
            when ODIN_DEBUG {
                runtime.debug_trap()
            } else {
                runtime.trap()
            }
        // }
        // cold(message, loc)
    }
}

vec_cast :: proc { 
    cast_vec_2, cast_vec_3, cast_vec_4,
    cast_vec_v2, cast_vec_v3, cast_vec_v4,
}

@(require_results)
cast_vec_2 :: #force_inline proc($T: typeid, x, y: $E) -> [2]T where T != E {
    return {cast(T) x, cast(T) y}
}

@(require_results)
cast_vec_3 :: #force_inline proc($T: typeid, x, y, z: $E) -> [3]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z}
}

@(require_results)
cast_vec_4 :: #force_inline proc($T: typeid, x, y, z, w: $E) -> [4]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z, cast(T) w}
}

@(require_results)
cast_vec_v2 :: #force_inline proc($T: typeid, v:[2]$E) -> [2]T where T != E {
    return vec_cast(T, v.x, v.y)
}

@(require_results)
cast_vec_v3 :: #force_inline proc($T: typeid, v:[3]$E) -> [3]T where T != E {
    return vec_cast(T, v.x, v.y, v.z)
}

@(require_results)
cast_vec_v4 :: #force_inline proc($T: typeid, v:[4]$E) -> [4]T where T != E {
    return vec_cast(T, v.x, v.y, v.z, v.w)
}

min_vec :: proc { min_vec_2, min_vec_3}
max_vec :: proc { max_vec_2, max_vec_3}

@(require_results)
min_vec_2 :: #force_inline proc(a,b: [2]$E) -> [2]E where intrinsics.type_is_numeric(E) {
    return {min(a.x, b.x), min(a.y, b.y)}
}

@(require_results)
min_vec_3 :: #force_inline proc(a,b: [3]$E) -> [3]E where intrinsics.type_is_numeric(E) {
    return {min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)}
}

@(require_results)
max_vec_2 :: #force_inline proc(a,b: [2]$E) -> [2]E where intrinsics.type_is_numeric(E) {
    return {max(a.x, b.x), max(a.y, b.y)}
}

@(require_results)
max_vec_3 :: #force_inline proc(a,b: [3]$E) -> [3]E where intrinsics.type_is_numeric(E) {
    return {max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)}
}


abs_vec :: proc { abs_vec_2, abs_vec_3 }
@(require_results)
abs_vec_2 :: #force_inline proc(a: [2]$E) -> [2]E where intrinsics.type_is_numeric(E) {
    return {abs(a.x), abs(a.y)}
}
@(require_results)
abs_vec_3 :: #force_inline proc(a: [3]$E) -> [3]E where intrinsics.type_is_numeric(E) {
    return {abs(a.x), abs(a.y), abs(a.z)}
}


@(require_results)
rotate_left :: #force_inline proc(value: u32, amount: i32) -> u32 {
    // TODO: can odin insert rotate intrinsics
    masked := amount & 31
    return value << u32(masked) | value >> u32(32 - masked)
}

@(require_results)
rotate_right :: #force_inline proc(value: u32, amount: i32) -> u32 {
    // TODO: can odin insert rotate intrinsics
    masked := amount & 31
    return value >> u32(-masked) | value << u32(32 + masked)
}

pointer_step :: proc(t: ^$T, #any_int step: i64) ->(result: ^T) {
    ts := cast([^]T) t
    result = &ts[step]
    return result
}