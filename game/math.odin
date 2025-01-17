package game

import "base:intrinsics"
import "base:builtin"
import "core:math"
import "core:simd"

// ---------------------- ---------------------- ----------------------
// ---------------------- Types
// ---------------------- ---------------------- ----------------------

v2 :: [2]f32
v3 :: [3]f32
v4 :: [4]f32

Rectangle2 :: struct{ min, max: v2 }
Rectangle3 :: struct{ min, max: v3 }

Rectangle2i :: struct{ min, max: [2]i32 }
Rectangle3i :: struct{ min, max: [3]i32 }

// ---------------------- ---------------------- ----------------------
// ---------------------- Constants
// ---------------------- ---------------------- ----------------------

Tau :: 6.28318530717958647692528676655900576
Pi  :: 3.14159265358979323846264338327950288

E   :: 2.71828182845904523536

τ :: Tau
π :: Pi
e :: E

SqrtTwo   :: 1.41421356237309504880168872420969808
SqrtThree :: 1.73205080756887729352744634150587236
SqrtFive  :: 2.23606797749978969640917366873127623

Ln2  :: 0.693147180559945309417232121458176568
Ln10 :: 2.30258509299404568401799145468436421

MaxF64Precision :: 16 // Maximum number of meaningful digits after the decimal point for 'f64'
MaxF32Precision ::  8 // Maximum number of meaningful digits after the decimal point for 'f32'
MaxF16Precision ::  4 // Maximum number of meaningful digits after the decimal point for 'f16'

RadPerDeg :: Tau/360.0
DegPerRad :: 360.0/Tau

// ---------------------- ---------------------- ----------------------
// ---------------------- Scalar operations
// ---------------------- ---------------------- ----------------------

square :: proc { square_f, square_x4, square_x8 }
@(require_results) square_f :: #force_inline proc(x: f32) -> f32 { return x * x}
@(require_results) square_x4 :: #force_inline proc(x: simd.f32x4) -> simd.f32x4 { return x * x}
@(require_results) square_x8 :: #force_inline proc(x: simd.f32x8) -> simd.f32x8 { return x * x }

square_root :: simd.sqrt

lerp :: proc { lerp_1, lerp_2, lerp_3, lerp_4 }
@(require_results) lerp_1 :: #force_inline proc(from, to, t: f32) -> f32 {
    result := (1-t) * from + t * to

    return result
}
@(require_results) lerp_2 :: #force_inline proc(from, to, t: v2) -> v2 {
    result := (1-t) * from + t * to
    
    return result
}
@(require_results) lerp_3 :: #force_inline proc(from, to, t: v3) -> v3 {
    result := (1-t) * from + t * to
    
    return result
}
@(require_results) lerp_4 :: #force_inline proc(from, to, t: v4) -> v4 {
    result := (1-t) * from + t * to
    
    return result
}

safe_ratio_n :: proc { safe_ratio_n_1, safe_ratio_n_2, safe_ratio_n_3 }
@(require_results) safe_ratio_n_1 :: #force_inline proc(numerator, divisor, n: f32) -> f32 {
    ratio := n

    if divisor != 0 {
        ratio = numerator / divisor
    }

    return ratio
}
@(require_results) safe_ratio_n_2 :: #force_inline proc(numerator, divisor, n: v2) -> v2 {
    ratio := n

    if divisor != 0 {
        ratio = numerator / divisor
    }

    return ratio
}
@(require_results) safe_ratio_n_3 :: #force_inline proc(numerator, divisor, n: v3) -> v3 {
    ratio := n

    if divisor != 0 {
        ratio = numerator / divisor
    }

    return ratio
}

safe_ratio_0 :: proc { safe_ratio_0_1, safe_ratio_0_2, safe_ratio_0_3 }
@(require_results) safe_ratio_0_1 :: #force_inline proc(numerator, divisor: f32) -> f32 { return safe_ratio_n(numerator, divisor, 0) }
@(require_results) safe_ratio_0_2 :: #force_inline proc(numerator, divisor: v2)  -> v2  { return safe_ratio_n(numerator, divisor, 0) }
@(require_results) safe_ratio_0_3 :: #force_inline proc(numerator, divisor: v3)  -> v3  { return safe_ratio_n(numerator, divisor, 0) }

safe_ratio_1 :: proc { safe_ratio_1_1, safe_ratio_1_2, safe_ratio_1_3 }
@(require_results) safe_ratio_1_1 :: #force_inline proc(numerator, divisor: f32) -> f32 { return safe_ratio_n(numerator, divisor, 1) }
@(require_results) safe_ratio_1_2 :: #force_inline proc(numerator, divisor: v2)  -> v2  { return safe_ratio_n(numerator, divisor, 1) }
@(require_results) safe_ratio_1_3 :: #force_inline proc(numerator, divisor: v3)  -> v3  { return safe_ratio_n(numerator, divisor, 1) }

@(require_results) clamp :: #force_inline proc(value: $T, min, max: T) -> (result:T) {
    when intrinsics.type_is_simd_vector(T) {
        result = simd.clamp(value, min, max)
    } else when intrinsics.type_is_array(T) {
        E :: intrinsics.type_elem_type(T)
        when 2 * size_of(E) == size_of(T) {
            result = T{ clamp(value.x, min.x, max.x), clamp(value.y, min.y, max.y) }
        } else when 3 * size_of(E) == size_of(T) {
            result = T{ clamp(value.x, min.x, max.x), clamp(value.y, min.y, max.y), clamp(value.z, min.z, max.z) }
        } else when 4 * size_of(E) == size_of(T) {
            result = T{ clamp(value.x, min.x, max.x), clamp(value.y, min.y, max.y), clamp(value.z, min.z, max.z), clamp(value.w, min.w, max.w) }
        }
    } else {
        result = builtin.clamp(value, min, max)
    }

    return result
}

@(require_results) clamp_01 :: #force_inline proc(value: $T) -> (result:T) {
    when intrinsics.type_is_simd_vector(T) {
        zero :: cast(T) 0
        one  :: cast(T) 1
        result = simd.clamp(value, zero, one)
    } else when intrinsics.type_is_array(T) {
        E :: intrinsics.type_elem_type(T)
        when 2 * size_of(E) == size_of(T) {
            result = T{ clamp_01(value.x), clamp_01(value.y) }
        } else when 3 * size_of(E) == size_of(T) {
            result = T{ clamp_01(value.x), clamp_01(value.y), clamp_01(value.z) }
        } else when 4 * size_of(E) == size_of(T) {
            result = T{ clamp_01(value.x), clamp_01(value.y), clamp_01(value.z), clamp_01(value.w) }
        }
    } else {
        result = clamp(value, 0, 1)
    }

    return result
}

@(require_results) clamp_01_to_range :: #force_inline proc(min, t, max: f32) -> (result: f32) {
    range := max - min
    if range != 0 {
        result = clamp_01((t-min) / range)
    }
    return result
}

sign :: proc{ sign_i, sign_f }
@(require_results) sign_i  :: #force_inline proc(i: i32) -> i32 { return i >= 0 ? 1 : -1 }
@(require_results) sign_f  :: #force_inline proc(x: f32) -> f32 { return x >= 0 ? 1 : -1 }


// ---------------------- ---------------------- ----------------------
// ---------------------- Vector operations
// ---------------------- ---------------------- ----------------------

V3 :: proc { V3_x_yz, V3_xy_z }
@(require_results) V3_x_yz :: #force_inline proc(x: f32, yz: v2) -> v3 { return { x, yz.x, yz.y }}
@(require_results) V3_xy_z :: #force_inline proc(xy: v2, z: f32) -> v3 { return { xy.x, xy.y, z }}

V4 :: proc { V4_x_yzw, V4_xy_zw, V4_xyz_w, V4_x_y_zw, V4_x_yz_w, V4_xy_z_w }
@(require_results) V4_x_yzw  :: #force_inline proc(x: f32, yzw: v3) -> (result: v4) {
    result.x = x
    result.yzw = yzw
    return result
}
@(require_results) V4_xy_zw  :: #force_inline proc(xy: v2, zw: v2) -> (result: v4) {
    result.xy = xy
    result.zw = zw
    return result
}
@(require_results) V4_xyz_w  :: #force_inline proc(xyz: v3, w: f32) -> (result: v4) {
    result.xyz = xyz
    result.w = w
    return result
}
@(require_results) V4_x_y_zw :: #force_inline proc(x, y: f32, zw: v2) -> (result: v4) {
    result.x = x
    result.y = y
    result.zw = zw
    return result
}
@(require_results) V4_x_yz_w :: #force_inline proc(x: f32, yz: v2, w:f32) -> (result: v4) {
    result.x = x
    result.yz = yz
    result.w = w
    return result
}
@(require_results) V4_xy_z_w :: #force_inline proc(xy: v2, z, w: f32) -> (result: v4) {
    result.xy = xy
    result.z = z
    result.w = w
    return result
}

@(require_results) perpendicular :: #force_inline proc(v: v2) -> (result: v2) {
    result = { -v.y, v.x }
    return result
}

dot :: proc { dot2, dot3, dot4 }
@(require_results) dot2 :: #force_inline proc(a, b: v2) -> f32 {
    return a.x * b.x + a.y * b.y
}
@(require_results) dot3 :: #force_inline proc(a, b: v3) -> f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z
}
@(require_results) dot4 :: #force_inline proc(a, b: v4) -> f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
}


project :: proc { project_2, project_3 }
@(require_results) project_2 :: #force_inline proc(v, axis: v2) -> v2 {
    return v - 1 * dot(v, axis) * axis
}
@(require_results) project_3 :: #force_inline proc(v, axis: v3) -> v3 {
    return v - 1 * dot(v, axis) * axis
}

@(require_results) reflect :: #force_inline proc(v, axis:v2) -> v2 {
    return v - 2 * dot(v, axis) * axis
}


length :: proc { length_2, length_3, length_4 }
@(require_results) length_2 :: #force_inline proc(vec: v2) -> (length:f32) {
    length_squared := length_squared(vec)
    length = math.sqrt(length_squared)
    return length
}
@(require_results) length_3 :: #force_inline proc(vec: v3) -> (length:f32) {
    length_squared := length_squared(vec)
    length = math.sqrt(length_squared)
    return length
}
@(require_results) length_4 :: #force_inline proc(vec: v4) -> (length:f32) {
    length_squared := length_squared(vec)
    length = math.sqrt(length_squared)
    return length
}

length_squared :: proc { length_squared_2, length_squared_3, length_squared_4 }
@(require_results) length_squared_2 :: #force_inline proc(vec: v2) -> f32 {
    return dot(vec, vec)
}
@(require_results) length_squared_3 :: #force_inline proc(vec: v3) -> f32 {
    return dot(vec, vec)
}
@(require_results) length_squared_4 :: #force_inline proc(vec: v4) -> f32 {
    return dot(vec, vec)
}

normalize :: proc { normalize_2, normalize_3, normalize_4 }
@(require_results) normalize_2 :: #force_inline proc(vec: v2) -> (result: v2) {
    result = vec / length(vec)
    return result
}
@(require_results) normalize_3 :: #force_inline proc(vec: v3) -> (result: v3) {
    result = vec / length(vec)
    return result
}
@(require_results) normalize_4 :: #force_inline proc(vec: v4) -> (result: v4) {
    result = vec / length(vec)
    return result
}


// NOTE(viktor): srgb_to_linear and linear_to_srgb assume a gamma of 2 instead of the usual 2.2
@(require_results)
srgb_to_linear :: #force_inline proc(srgb: v4) -> (result: v4) {
    result.r = square(srgb.r)
    result.g = square(srgb.g)
    result.b = square(srgb.b)
    result.a = srgb.a

    return result
}
@(require_results)
srgb_255_to_linear_1 :: #force_inline proc(srgb: v4) -> (result: v4) {
    inv_255: f32 = 1.0 / 255.0
    result = srgb * inv_255
    result = srgb_to_linear(result)

    return result
}

@(require_results)
linear_to_srgb :: #force_inline proc(linear: v4) -> (result: v4) {
    result.r = square_root(linear.r)
    result.g = square_root(linear.g)
    result.b = square_root(linear.b)
    result.a = linear.a

    return result
}
@(require_results)
linear_1_to_srgb_255 :: #force_inline proc(linear: v4) -> (result: v4) {
    result = linear_to_srgb(linear)
    result *= 255

    return result
}

// ---------------------- ---------------------- ----------------------
// ---------------------- Rectangle operations
// ---------------------- ---------------------- ----------------------

rectangle_min_dim :: proc { rectangle_min_dim_2, rectangle_min_dim_3, rectangle_min_dim_2i, rectangle_min_dim_3i }
@(require_results) rectangle_min_dim_2  :: #force_inline proc(min, dim: v2) -> Rectangle2 { return { min, min + dim }}
@(require_results) rectangle_min_dim_3  :: #force_inline proc(min, dim: v3) -> Rectangle3 { return { min, min + dim }}
@(require_results) rectangle_min_dim_2i :: #force_inline proc(min, dim: [2]i32) -> Rectangle2i { return { min, min + dim } }
@(require_results) rectangle_min_dim_3i :: #force_inline proc(min, dim: [3]i32) -> Rectangle3i { return { min, min + dim } }

rectangle_center_diameter :: proc { rectangle_center_diameter_2, rectangle_center_diameter_3 }
@(require_results) rectangle_center_diameter_2 :: #force_inline proc(center, diameter: v2) -> Rectangle2 {
    return { center - (diameter * 0.5), center + (diameter * 0.5) }
}
@(require_results) rectangle_center_diameter_3 :: #force_inline proc(center, diameter: v3) -> Rectangle3 {
    return { center - (diameter * 0.5), center + (diameter * 0.5) }
}

rectangle_center_half_diameter :: proc { rectangle_center_half_diameter_2, rectangle_center_half_diameter_3 }
@(require_results) rectangle_center_half_diameter_2 :: #force_inline proc(center, half_diameter: v2) -> Rectangle2 {
    return { center - half_diameter, center + half_diameter }
}
@(require_results) rectangle_center_half_diameter_3 :: #force_inline proc(center, half_diameter: v3) -> Rectangle3 {
    return { center - half_diameter, center + half_diameter }
}

rectangle_get_diameter :: proc { rectangle_get_diameter_2, rectangle_get_diameter_3 }
@(require_results) rectangle_get_diameter_2 :: #force_inline proc(rec: Rectangle2) -> (result: v2) {
    return rec.max - rec.min
}
@(require_results) rectangle_get_diameter_3 :: #force_inline proc(rec: Rectangle3) -> (result: v3) {
    return rec.max - rec.min
}

rectangle_add_radius :: proc { rectangle_add_radius_2, rectangle_add_radius_3 }
@(require_results) rectangle_add_radius_2 :: #force_inline proc(rec: Rectangle2, radius: v2) -> (result: Rectangle2) {
    result = rec
    result.min -= radius
    result.max += radius
    return result
}
@(require_results) rectangle_add_radius_3 :: #force_inline proc(rec: Rectangle3, radius: v3) -> (result: Rectangle3) {
    result = rec
    result.min -= radius
    result.max += radius
    return result
}

rectangle_add_offset :: proc { rectangle_add_offset_2, rectangle_add_offset_3 }
@(require_results) rectangle_add_offset_2 :: #force_inline proc(rec: Rectangle2, offset: v2) -> (result: Rectangle2) {
    result.min = rec.min + offset
    result.max = rec.max + offset
    
    return result
}
@(require_results) rectangle_add_offset_3 :: #force_inline proc(rec: Rectangle3, offset: v3) -> (result: Rectangle3) {
    result.min = rec.min + offset
    result.max = rec.max + offset
    
    return result
}

rectangle_contains :: proc { rectangle_contains_2, rectangle_contains_3 }
@(require_results) rectangle_contains_2 :: #force_inline proc(rec: Rectangle2, point: v2) -> b32 {
    return rec.min.x < point.x && point.x < rec.max.x && rec.min.y < point.y && point.y < rec.max.y
}
@(require_results) rectangle_contains_3 :: #force_inline proc(rec: Rectangle3, point: v3) -> b32 {
    return rec.min.x < point.x && point.x < rec.max.x && rec.min.y < point.y && point.y < rec.max.y && rec.min.z < point.z && point.z < rec.max.z
}

rectangle_intersects :: proc { rectangle_intersects_2, rectangle_intersects_3, rectangle_intersects_2i, rectangle_intersects_3i }
@(require_results) rectangle_intersects_2 :: #force_inline proc(a, b: Rectangle2) -> (result: b32) {
    result  = !(b.max.x <= a.min.x || b.min.x >= a.max.x) &&
              !(b.max.y <= a.min.y || b.min.y >= a.max.y)
    
    return result
}
@(require_results) rectangle_intersects_3 :: #force_inline proc(a, b: Rectangle3) -> (result: b32) {
    result  = !(b.max.x < a.min.x || b.min.x > a.max.x ||
                b.max.y < a.min.y || b.min.y > a.max.y ||
                b.max.z < a.min.z || b.min.z > a.max.z)
    
    return result
}
@(require_results) rectangle_intersects_2i :: #force_inline proc(a, b: Rectangle2i) -> (result: b32) {
    result  = !(b.max.x <= a.min.x || b.min.x >= a.max.x) &&
              !(b.max.y <= a.min.y || b.min.y >= a.max.y)
    
    return result
}
@(require_results) rectangle_intersects_3i :: #force_inline proc(a, b: Rectangle3i) -> (result: b32) {
    result  = !(b.max.x < a.min.x || b.min.x > a.max.x ||
                b.max.y < a.min.y || b.min.y > a.max.y ||
                b.max.z < a.min.z || b.min.z > a.max.z)
    
    return result
}

rectangle_intersection :: proc { rectangle_intersection_2, rectangle_intersection_3, rectangle_intersection_2i, rectangle_intersection_3i }
@(require_results) rectangle_intersection_2 :: #force_inline proc(a, b: Rectangle2) -> (result: Rectangle2) {
    result.min.x = max(a.min.x, b.min.x)
    result.min.y = max(a.min.y, b.min.y)
    
    result.max.x = min(a.max.x, b.max.x)
    result.max.y = min(a.max.y, b.max.y)
    
    return result
}
@(require_results) rectangle_intersection_3 :: #force_inline proc(a, b: Rectangle3) -> (result: Rectangle3) {
    result.min.x = max(a.min.x, b.min.x)
    result.min.y = max(a.min.y, b.min.y)
    result.min.z = max(a.min.z, b.min.z)
    
    result.max.x = min(a.max.x, b.max.x)
    result.max.y = min(a.max.y, b.max.y)
    result.max.z = min(a.max.z, b.max.z)
    
    return result
}
@(require_results) rectangle_intersection_2i :: #force_inline proc(a, b: Rectangle2i) -> (result: Rectangle2i) {
    result.min.x = max(a.min.x, b.min.x)
    result.min.y = max(a.min.y, b.min.y)
    
    result.max.x = min(a.max.x, b.max.x)
    result.max.y = min(a.max.y, b.max.y)
    
    return result
}
@(require_results) rectangle_intersection_3i :: #force_inline proc(a, b: Rectangle3i) -> (result: Rectangle3i) {
    result.min.x = max(a.min.x, b.min.x)
    result.min.y = max(a.min.y, b.min.y)
    result.min.z = max(a.min.z, b.min.z)
    
    result.max.x = min(a.max.x, b.max.x)
    result.max.y = min(a.max.y, b.max.y)
    result.max.z = min(a.max.z, b.max.z)
    
    return result
}

rectangle_union :: proc { rectangle_union_2, rectangle_union_3, rectangle_union_2i, rectangle_union_3i }
@(require_results) rectangle_union_2 :: #force_inline proc(a, b: Rectangle2) -> (result: Rectangle2) {
    result.min.x = min(a.min.x, b.min.x)
    result.min.y = min(a.min.y, b.min.y)
    
    result.max.x = max(a.max.x, b.max.x)
    result.max.y = max(a.max.y, b.max.y)
    
    return result
}
@(require_results) rectangle_union_3 :: #force_inline proc(a, b: Rectangle3) -> (result: Rectangle3) {
    result.min.x = min(a.min.x, b.min.x)
    result.min.y = min(a.min.y, b.min.y)
    result.min.z = min(a.min.z, b.min.z)
    
    result.max.x = max(a.max.x, b.max.x)
    result.max.y = max(a.max.y, b.max.y)
    result.max.z = max(a.max.z, b.max.z)
    
    return result
}
@(require_results) rectangle_union_2i :: #force_inline proc(a, b: Rectangle2i) -> (result: Rectangle2i) {
    result.min.x = min(a.min.x, b.min.x)
    result.min.y = min(a.min.y, b.min.y)
    
    result.max.x = max(a.max.x, b.max.x)
    result.max.y = max(a.max.y, b.max.y)
        
    return result
}
@(require_results) rectangle_union_3i :: #force_inline proc(a, b: Rectangle3i) -> (result: Rectangle3i) {
    result.min.x = min(a.min.x, b.min.x)
    result.min.y = min(a.min.y, b.min.y)
    result.min.z = min(a.min.z, b.min.z)
    
    result.max.x = max(a.max.x, b.max.x)
    result.max.y = max(a.max.y, b.max.y)
    result.max.z = max(a.max.z, b.max.z)
        
    return result
}
rectangle_get_barycentric :: proc { rectangle_get_barycentric_2, rectangle_get_barycentric_3 }
@(require_results) rectangle_get_barycentric_2 :: #force_inline proc(rect: Rectangle2, p: v2) -> (result: v2) {
    result = safe_ratio_0(p - rect.min, rect.max - rect.min)

    return result
}
@(require_results) rectangle_get_barycentric_3 :: #force_inline proc(rect: Rectangle3, p: v3) -> (result: v3) {
    result = safe_ratio_0(p - rect.min, rect.max - rect.min)

    return result
}

@(require_results) rectangle_xy :: #force_inline proc(rec: Rectangle3) -> (result: Rectangle2) {
    result.min = rec.min.xy
    result.max = rec.max.xy
    
    return result
}

rectangle_clamped_area :: #force_inline proc(rec: Rectangle2i) -> (result: i32) {
    dimension := rec.max - rec.min
    if dimension.x > 0 && dimension.y > 0 {
        result = dimension.x * dimension.y
    }
    
    return result
}

rectangle_has_area :: #force_inline proc(rec: Rectangle2i) -> (result: b32) {
    return rec.min.x < rec.max.x && rec.min.y < rec.max.y
}