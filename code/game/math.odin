package game

import "base:intrinsics"
import "base:builtin"
import "core:math"
import "core:simd"

// ---------------------- ---------------------- ----------------------
// ---------------------- Types
// ---------------------- ---------------------- ----------------------

Rectangle   :: struct($T: typeid) { min, max: T }
Rectangle2  :: Rectangle(v2)
Rectangle3  :: Rectangle(v3)
Rectangle2i :: Rectangle([2]i32)


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

@(require_results) square :: #force_inline proc(x: $T) -> T { return x * x }

square_root :: simd.sqrt

lerp :: proc { lerp_vf, lerp_t }
@(require_results) lerp_t :: #force_inline proc(from, to: $T, t: T) -> T {
    result := (1-t) * from + t * to
    
    return result
}
@(require_results) lerp_vf :: #force_inline proc(from, to: $V, t: f32) -> V where V != f32 {
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
        result.x = clamp(value.x, min.x, max.x)
        result.y = clamp(value.y, min.y, max.y)
        when len(T) >= 3 do result.z = clamp(value.z, min.z, max.z) 
        when len(T) >= 4 do result.w = clamp(value.w, min.w, max.w)
    } else {
        result = builtin.clamp(value, min, max)
    }

    return result
}

@(require_results) clamp_01 :: #force_inline proc(value: $T) -> (result:T) {
    when intrinsics.type_is_simd_vector(T) {
        result = simd.clamp(value, 0, 1)
    } else when intrinsics.type_is_array(T) {
        result.x = clamp_01(value.x)
        result.y = clamp_01(value.y)
        when len(T) >= 3 do result.z = clamp_01(value.z)
        when len(T) >= 4 do result.w = clamp_01(value.w)
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

mod :: proc { mod_f, mod_vf, mod_v }
@(require_results) mod_f :: proc(value: f32, divisor: f32) -> f32 {
    return math.mod(value, divisor)
}
@(require_results) mod_vf :: proc(value: [2]f32, divisor: f32) -> [2]f32 {
    return {math.mod(value.x, divisor), math.mod(value.y, divisor)}
}
@(require_results) mod_v :: proc(value: [2]f32, divisor: [2]f32) -> [2]f32 {
    return {math.mod(value.x, divisor.x), math.mod(value.y, divisor.y)}
}

round :: proc { round_f, round_v }
@(require_results) round_f :: #force_inline proc(f: f32, $T: typeid) -> T {
    if f < 0 do return cast(T) -math.round(-f)
    return cast(T) math.round(f)
}
@(require_results) round_v :: #force_inline proc(fs: [$N]f32, $T: typeid) -> [N]T where N > 1 {
    fs := fs
    for &e in fs do e = math.round(e) 
    return vec_cast(T, fs)
}

floor :: proc { floor_f, floor_v }
@(require_results) floor_f :: #force_inline proc(f: f32, $T: typeid) -> (i:T) {
    return cast(T) math.floor(f)
}
@(require_results) floor_v :: #force_inline proc(fs: [$N]f32, $T: typeid) -> [N]T {
    return vec_cast(T, simd.to_array(simd.floor(simd.from_array(fs))))
}

ceil :: proc { ceil_f, ceil_v }
@(require_results) ceil_f :: #force_inline proc(f: f32, $T: typeid) -> (i:T) {
    return cast(T) math.ceil(f)
}
@(require_results) ceil_v :: #force_inline proc(fs: [$N]f32, $T: typeid) -> [N]T {
    return vec_cast(T, simd.to_array(simd.ceil(simd.from_array(fs))))
}

truncate :: proc { truncate_f32, truncate_f32s }
@(require_results) truncate_f32 :: #force_inline proc(f: f32) -> i32 {
    return cast(i32) f
}
@(require_results) truncate_f32s :: #force_inline proc(fs: [$N]f32) -> [N]i32 where N > 1 {
    return vec_cast(i32, fs)
}


sin :: proc { sin_f }
@(require_results) sin_f :: #force_inline proc(angle: f32) -> f32 {
    return math.sin(angle)
}


cos :: proc { cos_f }
@(require_results) cos_f :: #force_inline proc(angle: f32) -> f32 {
    return math.cos(angle)
}


atan2 :: proc { atan2_f }

@(require_results) atan2_f :: #force_inline proc(y, x: f32) -> f32 {
    return math.atan2(y, x)
}



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

@(require_results) arm :: #force_inline proc(angle: f32) -> (result: v2) {
    result = v2{cos(angle), sin(angle)}
    return result
}

@(require_results) dot :: #force_inline proc(a, b: $V/[$N]f32) -> (result: f32) {
    result = a.x * b.x + a.y * b.y
    when N >= 3 do result += a.z * b.z
    when N >= 4 do result += a.w * b.w
    return result
}

@(require_results) project :: #force_inline proc(v, axis: $V) -> V {
    return v - 1 * dot(v, axis) * axis
}

@(require_results) length :: #force_inline proc(vec: $V) -> (result: f32) {
    length_squared := length_squared(vec)
    result = math.sqrt(length_squared)
    return result
}

@(require_results) length_squared :: #force_inline proc(vec: $V) -> f32 {
    return dot(vec, vec)
}

@(require_results) normalize :: #force_inline proc(vec: $V) -> (result: V) {
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

@(require_results) rectangle_min_max  :: #force_inline proc(min, max: $T) -> Rectangle(T) {
    return { min, max }
}
@(require_results) rectangle_min_diameter  :: #force_inline proc(min, dim: $T) -> Rectangle(T) {
    return { min, min + dim }
}
@(require_results) rectangle_center_diameter :: #force_inline proc(center, diameter: $T) -> Rectangle(T) {
    return { center - (diameter / 2), center + (diameter / 2) }
}
@(require_results) rectangle_center_half_diameter :: #force_inline proc(center, half_diameter: $T) -> Rectangle(T) {
    return { center - half_diameter, center + half_diameter }
}

@(require_results) inverted_infinity_rectangle :: #force_inline proc($R: typeid) -> (result: R) {
    T :: intrinsics.type_field_type(R, "min")
    #assert(intrinsics.type_is_subtype_of(R, Rectangle(T)))
    E :: intrinsics.type_elem_type(T)
    
    result.min = max(E)
    result.max = min(E)
    
    return result
}

@(require_results) rectangle_get_max      :: #force_inline proc(rect: Rectangle($T)) -> (result: T) { return rect.max }
@(require_results) rectangle_get_min      :: #force_inline proc(rect: Rectangle($T)) -> (result: T) { return rect.min }
@(require_results) rectangle_get_diameter :: #force_inline proc(rect: Rectangle($T)) -> (result: T) { return rect.max - rect.min }
@(require_results) rectangle_get_center   :: #force_inline proc(rect: Rectangle($T)) -> (result: T) { return rect.min + 0.5 * (rect.max - rect.min) }

@(require_results) rectangle_add_radius :: #force_inline proc(rect: $R/Rectangle($T), radius: T) -> (result: R) {
    result = rect
    result.min -= radius
    result.max += radius
    return result
}

@(require_results) rectangle_add_offset :: #force_inline proc(rect: $R/Rectangle($T), offset: T) -> (result: R) {
    result.min = rect.min + offset
    result.max = rect.max + offset
    
    return result
}

@(require_results) rectangle_contains :: #force_inline proc(rect: Rectangle($T), point: T) -> (result: b32) {
    result  = rect.min.x < point.x && point.x < rect.max.x 
    result &= rect.min.y < point.y && point.y < rect.max.y
    when len(T) >= 3 do result &= rect.min.z < point.z && point.z < rect.max.z
    return result
}

@(require_results) rectangle_intersects :: #force_inline proc(a, b: Rectangle($T)) -> (result: b32) {
    result  = !(b.max.x <= a.min.x || b.min.x >= a.max.x)
    result &= !(b.max.y <= a.min.y || b.min.y >= a.max.y)
    when len(T) >= 3 do result &= !(b.max.z <= a.min.z || b.min.z >= a.max.z)
    
    return result
}

@(require_results) rectangle_intersection :: #force_inline proc(a, b: $R/Rectangle($T)) -> (result: R) {
    result.min.x = max(a.min.x, b.min.x)
    result.min.y = max(a.min.y, b.min.y)
    
    result.max.x = min(a.max.x, b.max.x)
    result.max.y = min(a.max.y, b.max.y)
    
    when len(T) >= 3 {
        result.min.z = max(a.min.z, b.min.z)
        result.max.z = min(a.max.z, b.max.z)
    }
    return result
    
}

@(require_results) rectangle_union :: #force_inline proc(a, b: $R/Rectangle($T)) -> (result: R) {
    result.min.x = min(a.min.x, b.min.x)
    result.min.y = min(a.min.y, b.min.y)
    
    result.max.x = max(a.max.x, b.max.x)
    result.max.y = max(a.max.y, b.max.y)
    
    when len(T) >= 3 {
        result.min.z = min(a.min.z, b.min.z)
        result.max.z = max(a.max.z, b.max.z)
    }
        
    return result
}

@(require_results) rectangle_get_barycentric :: #force_inline proc(rect: Rectangle($T), p: T) -> (result: T) {
    result = safe_ratio_0(p - rect.min, rect.max - rect.min)

    return result
}

@(require_results) rectangle_xy :: #force_inline proc(rect: Rectangle3) -> (result: Rectangle2) {
    result.min = rect.min.xy
    result.max = rect.max.xy
    
    return result
}

@(require_results) rectangle_clamped_area :: #force_inline proc(rect: Rectangle2i) -> (result: i32) {
    dimension := rect.max - rect.min
    if dimension.x > 0 && dimension.y > 0 {
        result = dimension.x * dimension.y
    }
    
    return result
}

@(require_results) rectangle_has_area :: #force_inline proc(rect: Rectangle2i) -> (result: b32) {
    return rect.min.x < rect.max.x && rect.min.y < rect.max.y
}