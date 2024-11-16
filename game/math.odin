package game 

import "base:intrinsics"
import "core:math"

TAU          :: 6.28318530717958647692528676655900576
PI           :: 3.14159265358979323846264338327950288

E            :: 2.71828182845904523536

τ :: TAU
π :: PI
e :: E

SQRT_TWO     :: 1.41421356237309504880168872420969808
SQRT_THREE   :: 1.73205080756887729352744634150587236
SQRT_FIVE    :: 2.23606797749978969640917366873127623

LN2          :: 0.693147180559945309417232121458176568
LN10         :: 2.30258509299404568401799145468436421

MAX_F64_PRECISION :: 16 // Maximum number of meaningful digits after the decimal point for 'f64'
MAX_F32_PRECISION ::  8 // Maximum number of meaningful digits after the decimal point for 'f32'
MAX_F16_PRECISION ::  4 // Maximum number of meaningful digits after the decimal point for 'f16'

RAD_PER_DEG :: TAU/360.0
DEG_PER_RAD :: 360.0/TAU

v2 :: [2]f32
v3 :: [3]f32
v4 :: [4]f32

dot :: proc { dot2, dot3}

dot2 :: #force_inline proc(a, b: v2) -> f32 {
    return a.x * b.x + a.y * b.y
}

dot3 :: #force_inline proc(a, b: v3) -> f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z
}

reflect :: #force_inline proc(v, axis:v2) -> v2 {
    return v - 2 * dot(v, axis) * axis
} 

project :: #force_inline proc(v, axis:v2) -> v2 {
    return v - 1 * dot(v, axis) * axis
}

lerp :: #force_inline proc(a, b, t: f32) -> f32 {
    return (1-t) * a + t * b
}

square :: #force_inline proc(x: f32) -> f32 { 
    return x * x
}

square_root :: math.sqrt

length :: #force_inline proc(vec: $T/[$N]$E) -> (length:f32) where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) {
    length_squared := length_squared(vec)
    length = math.sqrt(length_squared)
    return length
}

length_squared :: #force_inline proc(vec: $T/[$N]$E) -> f32 where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) {
    return dot(vec, vec)
}

normalize :: #force_inline proc(vec: $T/[$N]$E) -> T where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) {
    length := length(vec)
    return vec / length
}




Rectangle :: struct{ min, max: v2 }

rect_min_dim :: #force_inline proc(min, dim: v2) -> Rectangle {
    return { min, min + dim }
}

rect_center_dim :: #force_inline proc(center, dim: v2) -> Rectangle {
    return { center - dim * 0.5, center + dim * 0.5 }
}

rect_center_half_dim :: #force_inline proc(center, half_dim: v2) -> Rectangle {
    return { center - half_dim, center + half_dim }
}

is_in_rectangle :: #force_inline proc(rec: Rectangle, point: v2) -> b32 {
    return point.x >= rec.min.x && point.y >= rec.min.y && point.x < rec.max.x && point.y < rec.max.y
}



