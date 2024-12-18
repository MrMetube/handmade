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

square :: #force_inline proc(x: f32) -> f32 {
    return x * x
}

square_root :: math.sqrt

lerp :: proc { lerp_1, lerp_2, lerp_3 }
lerp_1 :: #force_inline proc(a, b, t: f32) -> f32 {
    result := (1-t) * a + t * b

    return result
}

lerp_2 :: #force_inline proc(a, b, t: v2) -> v2 {
    result := (1-t) * a + t * b
    
    return result
}

lerp_3 :: #force_inline proc(a, b, t: v3) -> v3 {
    result := (1-t) * a + t * b
    
    return result
}

safe_ratio_n :: proc { safe_ratio_n_1, safe_ratio_n_2, safe_ratio_n_3 }
safe_ratio_n_1 :: #force_inline proc(numerator, divisor, n: f32) -> f32 {
    ratio := n

    if divisor != 0 {
        ratio = numerator / divisor
    }

    return ratio
}

safe_ratio_n_2 :: #force_inline proc(numerator, divisor, n: v2) -> v2 {
    ratio := n

    if divisor != 0 {
        ratio = numerator / divisor
    }

    return ratio
}

safe_ratio_n_3 :: #force_inline proc(numerator, divisor, n: v3) -> v3 {
    ratio := n

    if divisor != 0 {
        ratio = numerator / divisor
    }

    return ratio
}

safe_ratio_0 :: proc { safe_ratio_0_1, safe_ratio_0_2, safe_ratio_0_3 }
safe_ratio_0_1 :: #force_inline proc(numerator, divisor: f32) -> f32 { return safe_ratio_n(numerator, divisor, 0) }
safe_ratio_0_2 :: #force_inline proc(numerator, divisor: v2)  -> v2  { return safe_ratio_n(numerator, divisor, 0) }
safe_ratio_0_3 :: #force_inline proc(numerator, divisor: v3)  -> v3  { return safe_ratio_n(numerator, divisor, 0) }

safe_ratio_1 :: proc { safe_ratio_1_1, safe_ratio_1_2, safe_ratio_1_3 }
safe_ratio_1_1 :: #force_inline proc(numerator, divisor: f32) -> f32 { return safe_ratio_n(numerator, divisor, 1) }
safe_ratio_1_2 :: #force_inline proc(numerator, divisor: v2)  -> v2  { return safe_ratio_n(numerator, divisor, 1) }
safe_ratio_1_3 :: #force_inline proc(numerator, divisor: v3)  -> v3  { return safe_ratio_n(numerator, divisor, 1) }

clamp :: #force_inline proc(value, min, max: f32) -> f32 {
    result := value
    
    if result < min {
        result = min
    } else if result > max {
        result = max
    }

    return result
}

clamp_01 :: proc { clamp_01_1, clamp_01_2, clamp_01_3 }
clamp_01_1 :: #force_inline proc(value:f32) -> (result:f32) {
    result = clamp(value, 0, 1)

    return result
}
clamp_01_2 :: #force_inline proc(value:v2) -> (result:v2) {
    result = v2{ clamp_01(value.x), clamp_01(value.y) }
    
    return result
}
clamp_01_3 :: #force_inline proc(value:v3) -> (result:v3) {
    result = v3{ clamp_01(value.x), clamp_01(value.y), clamp_01(value.z) }
    
    return result
}

// ---------------------- ---------------------- ----------------------
// ---------------------- Vector operations
// ---------------------- ---------------------- ----------------------

// TODO(viktor): is this necessary?
V3 :: proc { V3_x, V3_z }
V3_x :: proc(x: f32, yz: v2) -> v3 { return { x, yz.x, yz.y }}
V3_z :: proc(xy: v2, z: f32) -> v3 { return { xy.x, xy.y, z }}

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
    result  = !(b.max.x <= a.min.x || b.min.x >= a.max.x)
    result &= !(b.max.y <= a.min.y || b.min.y >= a.max.y)
    
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

rectangle_get_barycentric :: proc { rectangle_get_barycentric_2, rectangle_get_barycentric_3 }
rectangle_get_barycentric_2 :: #force_inline proc(rect: Rectangle2, p: v2) -> (result: v2) {
    result = safe_ratio_0(p - rect.min, rect.max - rect.min)

    return result
}
rectangle_get_barycentric_3 :: #force_inline proc(rect: Rectangle3, p: v3) -> (result: v3) {
    result = safe_ratio_0(p - rect.min, rect.max - rect.min)

    return result
}