#+vet !unused-procedures
package game 

@(common="file") 

import "base:intrinsics"
import "base:runtime"

was_pressed :: proc(button: InputButton) -> b32 {
    return button.half_transition_count > 1 || button.half_transition_count == 1 && button.ended_down
}

is_down :: proc(button: InputButton) -> b32 {
    return button.ended_down
}

// ------- Low Contrast
// #C1B28B gray

// ------- High Contrast
// #009052 green

// #2EC4B6 sea green
// #7C7A8B taupe gray
// #FF7E6B salmon

// #C92F5F rose
// #12a4cc blue
// #9B1144 wine
// #fe163d red
// #e46738 hazel 
// #ffb433 orange 

Isabelline :: v4{0.96, 0.95, 0.94, 1}
Jasmine    :: v4{0.95, 0.82, 0.52  , 1}
DarkGreen  :: v4{0   , 0.07, 0.0353, 1}
Emerald    :: v4{0.21, 0.82, 0.54, 1}

White     :: v4{1   ,1    ,1      , 1}
Gray      :: v4{0.5 ,0.5  ,0.5    , 1}
Black     :: v4{0   ,0    ,0      , 1}
Blue      :: v4{0.08, 0.49, 0.72  , 1}
Orange    :: v4{1   , 0.71, 0.2   , 1}
Green     :: v4{0   , 0.59, 0.28  , 1}
Red       :: v4{1   , 0.09, 0.24  , 1}
DarkBlue  :: v4{0.08, 0.08, 0.2   , 1}

color_wheel :: [?]v4 {
    v4{0.3, 0.22, 0.34, 1},
    v4{0.08, 0.38, 0.43, 1},
    v4{0.99, 0.96, 0.69, 1},
    v4{1, 0.5, 0.07, 1},
    v4{0.92, 0.32, 0.44, 1},
    v4{0.38, 0.55, 0.28, 1}, 
    v4{1, 0.56, 0.45, 1},
    
    v4{0.53, 0.56, 0.6, 1},
    v4{0.51, 0.2, 0.02, 1},
    v4{0.83, 0.32, 0.07, 1},
    v4{0.98, 0.63, 0.25, 1},
    v4{0.5, 0.81, 0.66, 1},
    v4{1, 0.62, 0.7, 1},
    v4{0.49, 0.82, 0.51, 1},
    v4{1, 0.84, 0.4, 1},
    v4{0, 0.62, 0.72, 1},
    v4{0.9, 0.9, 0.92, 1},
}


f32x8 :: #simd[8]f32
u32x8 :: #simd[8]u32
i32x8 :: #simd[8]i32

f32x4 :: #simd[4]f32
i32x4 :: #simd[4]i32

pmm :: rawptr
umm :: uintptr

////////////////////////////////////////////////


Byte     :: 1
Kilobyte :: 1024 * Byte
Megabyte :: 1024 * Kilobyte
Gigabyte :: 1024 * Megabyte
Terabyte :: 1024 * Gigabyte
Petabyte :: 1024 * Terabyte
Exabyte  :: 1024 * Petabyte

align8     :: proc "contextless" (value: $T) -> T { return (value + (8-1)) &~ (8-1) }
align16    :: proc "contextless" (value: $T) -> T { return (value + (16-1)) &~ (16-1) }
align_pow2 :: proc "contextless" (value: $T, alignment: T) -> T { return (value + (alignment-1)) &~ (alignment-1) }

safe_truncate :: proc(value: $T, $R: typeid) -> R
where size_of(T) > size_of(R), intrinsics.type_is_integer(T), intrinsics.type_is_integer(R){
    assert(value <= cast(T) max(R))
    return cast(R) value
}

@(require_results) rec_cast :: proc($T: typeid, rec: $R/Rectangle([$N]$E)) -> Rectangle([N]T) where T != E {
    return { vec_cast(T, rec.min), vec_cast(T, rec.max)}
}
vec_cast :: proc { vcast_2, vcast_3, vcast_4, vcast_vec }
@(require_results) vcast_2 :: proc($T: typeid, x, y: $E) -> [2]T where T != E {
    return {cast(T) x, cast(T) y}
}
@(require_results) vcast_3 :: proc($T: typeid, x, y, z: $E) -> [3]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z}
}
@(require_results) vcast_4 :: proc($T: typeid, x, y, z, w: $E) -> [4]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z, cast(T) w}
}
@(require_results) vcast_vec :: proc($T: typeid, v:[$N]$E) -> (result: [N]T) where T != E {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = cast(T) v[i]
    }
    return result
}

@(require_results) min_vec :: proc(a,b: [$N]$E) -> (result: [N]E) where intrinsics.type_is_numeric(E) {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = min(a[i], b[i])
    }
    return result
}
@(require_results) max_vec :: proc(a,b: [$N]$E) -> (result: [N]E) where intrinsics.type_is_numeric(E) {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = max(a[i], b[i])
    }
    return result
}
@(require_results) abs_vec :: proc(a: [$N]$E) -> (result: [N]E) where intrinsics.type_is_numeric(E) {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = abs(a[i])
    }
    return result
}

swap :: proc(a, b: ^$T ) { a^, b^ = b^, a^ }


unused :: proc "contextless" (_: $T) {}

@(disabled=ODIN_DISABLE_ASSERT)
assert :: proc(condition: $B, message := #caller_expression(condition), loc := #caller_location, prefix:= "Assertion failed") where intrinsics.type_is_boolean(B) {
    if !condition {
        print("% %", loc, prefix)
        if len(message) > 0 {
            println(": %", message)
        }
        
        when ODIN_DEBUG {
             runtime.debug_trap()
        } else {
            runtime.trap()
        }
    }
}

slice_from_parts :: proc { slice_from_parts_cast, slice_from_parts_direct }
slice_from_parts_cast :: proc "contextless" ($T: typeid, data: pmm, #any_int count: i64) -> []T {
    // :PointerArithmetic
    return (cast([^]T)data)[:count]
}
slice_from_parts_direct :: proc "contextless" (data: ^$T, #any_int count: i64) -> []T {
    // :PointerArithmetic
    return (cast([^]T)data)[:count]
}