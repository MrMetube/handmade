package game 

import "base:intrinsics"
import "base:runtime"

was_pressed :: #force_inline proc(button: InputButton) -> (result:b32) {
    result = button.half_transition_count > 1 || button.half_transition_count == 1 && button.ended_down
    return result
}

White     :: v4{1   ,1    ,1      , 1}
Gray      :: v4{0.5 ,0.5  ,0.5    , 1}
Black     :: v4{0   ,0    ,0      , 1}
Blue      :: v4{0.08, 0.49, 0.72  , 1}
Yellow    :: v4{0.91, 0.81, 0.09  , 1}
Orange    :: v4{1   , 0.71, 0.2   , 1}
Green     :: v4{0   , 0.59, 0.28  , 1}
Red       :: v4{1   , 0.09, 0.24  , 1}
DarkGreen :: v4{0   , 0.07, 0.0353, 1}
DarkBlue  :: v4{0.08, 0.08, 0.2   , 1}

color_wheel :: [?]v4 {
    {0.94, 0.18, 0.34, 1},
    {0.63, 0.24, 0.6 , 1},
    {0.96, 0.51, 0.55, 1},
    {0.6 , 0.21, 0.16, 1},
    {0.61, 0.82, 0.56, 1},
    {0.5 , 0.6 , 0.28, 1},
    {0.01, 0.71, 0.67, 1},
    {0.9 , 0.76, 0.16, 1},
    {0.4 , 0.06, 0.95, 1},
    {0.25, 0.47, 0.6 , 1},
    {0.93, 0.49, 0.23, 1},
    {0.55, 0.85, 0.4 , 1},
    {0.89, 0.68, 0.87, 1},
    {0.86, 1   , 0.53, 1},
    {0.1 , 0.56, 0.89, 1},
    {0.18, 0.75, 0.44, 1},
}

f32x8 :: #simd[8]f32
u32x8 :: #simd[8]u32
i32x8 :: #simd[8]i32

f32x4 :: #simd[4]f32
i32x4 :: #simd[4]i32

@(disabled=ODIN_DISABLE_ASSERT)
assert :: #force_inline proc(condition: $T, message := #caller_expression(condition), loc := #caller_location) where intrinsics.type_is_boolean(T) {
    if !condition {
        // TODO(viktor): We are not a console application
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

modular_add :: #force_inline proc(value:^$N, addend, one_past_maximum: N) where intrinsics.type_is_numeric(N) {
    value^ += addend
    if value^ >= one_past_maximum {
        value^ = 0
    }
}