package game

import "base:intrinsics"
import "core:math"

// ---------------------- ---------------------- ----------------------
// ---------------------- Types
// ---------------------- ---------------------- ----------------------

v2 :: [2]f32
v3 :: [3]f32
v4 :: [4]f32

Rectangle2 :: struct{ min, max: v2 }
Rectangle3 :: struct{ min, max: v3 }

// ---------------------- ---------------------- ----------------------
// ---------------------- Constants
// ---------------------- ---------------------- ----------------------

TAU :: 6.28318530717958647692528676655900576
PI  :: 3.14159265358979323846264338327950288

E   :: 2.71828182845904523536

τ :: TAU
π :: PI
e :: E

SQRT_TWO   :: 1.41421356237309504880168872420969808
SQRT_THREE :: 1.73205080756887729352744634150587236
SQRT_FIVE  :: 2.23606797749978969640917366873127623

LN2  :: 0.693147180559945309417232121458176568
LN10 :: 2.30258509299404568401799145468436421

MAX_F64_PRECISION :: 16 // Maximum number of meaningful digits after the decimal point for 'f64'
MAX_F32_PRECISION ::  8 // Maximum number of meaningful digits after the decimal point for 'f32'
MAX_F16_PRECISION ::  4 // Maximum number of meaningful digits after the decimal point for 'f16'

RAD_PER_DEG :: TAU/360.0
DEG_PER_RAD :: 360.0/TAU

// ---------------------- ---------------------- ----------------------
// ---------------------- Scalar operations
// ---------------------- ---------------------- ----------------------

lerp :: #force_inline proc(a, b, t: f32) -> f32 {
    return (1-t) * a + t * b
}

square :: #force_inline proc(x: f32) -> f32 {
    return x * x
}

square_root :: math.sqrt

// ---------------------- ---------------------- ----------------------
// ---------------------- Vector operations
// ---------------------- ---------------------- ----------------------

// TODO(viktor): is this necessary?
V3 :: proc { v3_x, v3_z }

v3_x :: proc(x: f32, yz: v2) -> v3 { return { x, yz.x, yz.y }}
v3_z :: proc(xy: v2, z: f32) -> v3 { return { xy.x, xy.y, z }}

dot :: proc { dot2, dot3}
dot2 :: #force_inline proc(a, b: v2) -> f32 {
    return a.x * b.x + a.y * b.y
}
dot3 :: #force_inline proc(a, b: v3) -> f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z
}


project :: proc { project_2, project_3 }
project_2 :: #force_inline proc(v, axis: v2) -> v2 {
    return v - 1 * dot(v, axis) * axis
}
project_3 :: #force_inline proc(v, axis: v3) -> v3 {
    return v - 1 * dot(v, axis) * axis
}

reflect :: #force_inline proc(v, axis:v2) -> v2 {
    return v - 2 * dot(v, axis) * axis
}


length :: proc { length_2, length_3 }
length_2 :: #force_inline proc(vec: v2) -> (length:f32) {
    length_squared := length_squared(vec)
    length = math.sqrt(length_squared)
    return length
}
length_3 :: #force_inline proc(vec: v3) -> (length:f32) {
    length_squared := length_squared(vec)
    length = math.sqrt(length_squared)
    return length
}

length_squared :: proc { length_squared_2, length_squared_3 }
length_squared_2 :: #force_inline proc(vec: v2) -> f32 {
    return dot(vec, vec)
}
length_squared_3 :: #force_inline proc(vec: v3) -> f32 {
    return dot(vec, vec)
}

normalize :: proc { normalize_2, normalize_3 }

normalize_2 :: #force_inline proc(vec: v2) -> v2 {
    length := length(vec)
    return vec / length
}

normalize_3 :: #force_inline proc(vec: v3) -> v3 {
    length := length(vec)
    return vec / length
}

// ---------------------- ---------------------- ----------------------
// ---------------------- Rectangle operations
// ---------------------- ---------------------- ----------------------

rectangle_min_dim :: proc { rectangle_min_dim_2, rectangle_min_dim_3 }
rectangle_min_dim_2 :: #force_inline proc(min, dim: v2) -> Rectangle2 {
    return { min, min + dim }
}
rectangle_min_dim_3 :: #force_inline proc(min, dim: v3) -> Rectangle3 {
    return { min, min + dim }
}

rectangle_center_diameter :: proc { rectangle_center_diameter_2, rectangle_center_diameter_3 }
rectangle_center_diameter_2 :: #force_inline proc(center, diameter: v2) -> Rectangle2 {
    return { center - diameter * 0.5, center + diameter * 0.5 }
}
rectangle_center_diameter_3 :: #force_inline proc(center, diameter: v3) -> Rectangle3 {
    return { center - diameter * 0.5, center + diameter * 0.5 }
}

rectangle_center_half_diameter :: proc { rectangle_center_half_diameter_2, rectangle_center_half_diameter_3 }
rectangle_center_half_diameter_2 :: #force_inline proc(center, half_diameter: v2) -> Rectangle2 {
    return { center - half_diameter, center + half_diameter }
}
rectangle_center_half_diameter_3 :: #force_inline proc(center, half_diameter: v3) -> Rectangle3 {
    return { center - half_diameter, center + half_diameter }
}

rectangle_add :: proc { rectangle_add_2, rectangle_add_3 }
rectangle_add_2 :: #force_inline proc(rec: Rectangle2, radius: v2) -> (result: Rectangle2) {
    result = rec
    result.min -= radius
    result.max += radius
    return result
}
rectangle_add_3 :: #force_inline proc(rec: Rectangle3, radius: v3) -> (result: Rectangle3) {
    result = rec
    result.min -= radius
    result.max += radius
    return result
}

rectangle_contains :: proc { rectangle_contains_2, rectangle_contains_3 }
rectangle_contains_2 :: #force_inline proc(rec: Rectangle2, point: v2) -> b32 {
    return rec.min.x < point.x && point.x < rec.max.x && rec.min.y < point.y && point.y < rec.max.y
}
rectangle_contains_3 :: #force_inline proc(rec: Rectangle3, point: v3) -> b32 {
    return rec.min.x < point.x && point.x < rec.max.x && rec.min.y < point.y && point.y < rec.max.y && rec.min.z < point.z && point.z < rec.max.z
}

rectangle_intersect :: proc { rectangle_intersect_2, rectangle_intersect_3 }
rectangle_intersect_2 :: #force_inline proc(a, b: Rectangle2) -> (result: b32) {
    assert((b.max.x >= a.min.x && b.min.x <= a.max.x) == !(b.max.x < a.min.x || b.min.x > a.max.x))
    assert((b.max.y >= a.min.y && b.min.y <= a.max.y) == !(b.max.y < a.min.y || b.min.y > a.max.y))
    
    result  = !(b.max.x < a.min.x || b.min.x > a.max.x)
    result &= !(b.max.y < a.min.y || b.min.y > a.max.y)
    
    return result
}
rectangle_intersect_3 :: #force_inline proc(a, b: Rectangle3) -> (result: b32) {
    assert((b.max.x >= a.min.x && b.min.x <= a.max.x) == !(b.max.x < a.min.x || b.min.x > a.max.x))
    assert((b.max.y >= a.min.y && b.min.y <= a.max.y) == !(b.max.y < a.min.y || b.min.y > a.max.y))
    assert((b.max.z >= a.min.z && b.min.z <= a.max.z) == !(b.max.z < a.min.z || b.min.z > a.max.z))

    result  = !(b.max.x < a.min.x || b.min.x > a.max.x ||
                b.max.y < a.min.y || b.min.y > a.max.y ||
                b.max.z < a.min.z || b.min.z > a.max.z)
    
    return result
}
