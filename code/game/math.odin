#+vet !unused-procedures
package game

@(common="file")

import "base:intrinsics"
import "base:builtin"
import "core:math"
import "core:simd"

////////////////////////////////////////////////
// Types

v2 :: [2]f32
v3 :: [3]f32
v4 :: [4]f32


m4 :: matrix[4,4]f32

Rectangle   :: struct($T: typeid) { min, max: T }
Rectangle2  :: Rectangle(v2)
Rectangle3  :: Rectangle(v3)
Rectangle2i :: Rectangle([2]i32)

////////////////////////////////////////////////
// Constants

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

NegativeInfinity :: math.NEG_INF_F32
PositiveInfinity :: math.INF_F32

RadPerDeg :: Tau/360.0
DegPerRad :: 360.0/Tau

////////////////////////////////////////////////
// Scalar operations

square :: proc(x: $T) -> T where intrinsics.type_is_numeric(T) || intrinsics.type_is_array(T) || intrinsics.type_is_simd_vector(T) { return x * x }

square_root :: proc(x: $T) -> (result: T) where intrinsics.type_is_numeric(T) || intrinsics.type_is_array(T) || intrinsics.type_is_simd_vector(T) { 
    when intrinsics.type_is_array(T) {
        #unroll for i in 0..<len(T) {
            result[i] = simd.sqrt(x[i])
        }
    } else {
        result = simd.sqrt(x)
    }
    return result
 }

linear_blend  :: proc{ linear_blend_v_e, linear_blend_e }
linear_blend_v_e :: proc(from: $V/[$N]$E, to: V, t: E) -> V {
    result := (1-t) * from + t * to
    
    return result
}
linear_blend_e :: proc(from: $T, to: T, t: T) -> T  {
    result := (1-t) * from + t * to
    
    return result
}

bilinear_blend :: proc(a, b, c, d: $V/[$N]$E, t: [2]E) -> (result: V) {
    la := (1-t.y) * (1-t.x)
    lb := (1-t.y) *    t.x
    lc :=    t.y  * (1-t.x)
    ld :=    t.y  *    t.x
    
    result = la * a + lb * b + lc * c + ld * d
    return result
}

sin_01 :: proc(t: $T) -> T {
    result := sin(Pi*t)
    return result
}

safe_ratio_n :: proc(numerator, divisor, n: $T) -> (result: T) {
    result = divisor != 0 ? numerator / divisor : n
    return result
}
safe_ratio_0 :: proc(numerator, divisor: $T) -> T { return safe_ratio_n(numerator, divisor, 0) }
safe_ratio_1 :: proc(numerator, divisor: $T) -> T { return safe_ratio_n(numerator, divisor, 1) }

clamp :: proc(value: $T, min, max: T) -> (result: T) {
    when intrinsics.type_is_simd_vector(T) {
        result = simd.clamp(value, min, max)
    } else when intrinsics.type_is_array(T) {
        #unroll for i in 0..<len(T) {
            result[i] = clamp(value[i], min[i], max[i])
        }
    } else {
        result = builtin.clamp(value, min, max)
    }

    return result
}
clamp_01 :: proc(value: $T) -> T { return clamp(value, 0, 1) }

clamp_01_to_range :: proc(min: $T, t, max: T ) -> (result: T) {
    range := max - min
    if range != 0 {
        result = clamp_01((t-min) / range)
    }
    return result
}

sign :: proc{ sign_i, sign_f }
sign_i  :: proc(i: i32) -> i32 { return i >= 0 ? 1 : -1 }
sign_f  :: proc(x: f32) -> f32 { return x >= 0 ? 1 : -1 }

modulus :: proc { modulus_f, modulus_vf, modulus_v }
modulus_f :: proc(value: f32, divisor: f32) -> f32 {
    return math.mod(value, divisor)
}
modulus_vf :: proc(value: [$N]f32, divisor: f32) -> (result: [N]f32) where N > 1 {
    #unroll for i in 0..<N do result[i] = math.mod(value[i], divisor) 
    return result
}
modulus_v :: proc(value: [$N]f32, divisor: [N]f32) -> (result: [N]f32) {
    #unroll for i in 0..<N do result[i] = math.mod(value[i], divisor[i]) 
    return result
}

round :: proc { round_f, round_v }
round_f :: proc($T: typeid, f: f32) -> T {
    return  cast(T) (f < 0 ? -math.round(-f) : math.round(f))
}
round_v :: proc($T: typeid, v: [$N]f32) -> (result: [N]T) {
    #unroll for i in 0..<N do result[i] = cast(T) math.round(v[i]) 
    return result
}

floor :: proc { floor_f, floor_v }
floor_f :: proc($T: typeid, f: f32) -> (i: T) {
    return cast(T) math.floor(f)
}
floor_v :: proc($T: typeid, fs: [$N]f32) -> [N]T {
    return vec_cast(T, simd.to_array(simd.floor(simd.from_array(fs))))
}

ceil :: proc { ceil_f, ceil_v }
ceil_f :: proc($T: typeid, f: f32) -> (i: T) {
    return cast(T) math.ceil(f)
}
ceil_v :: proc($T: typeid, fs: [$N]f32) -> [N]T {
    return vec_cast(T, simd.to_array(simd.ceil(simd.from_array(fs))))
}

truncate :: proc { truncate_f32, truncate_f32s }
truncate_f32 :: proc($T: typeid, f: f32) -> T {
    return cast(T) f
}
truncate_f32s :: proc($T: typeid, fs: [$N]f32) -> [N]T where N > 1 {
    return vec_cast(T, fs)
}

sin :: proc { sin_f }
sin_f :: proc(angle: f32) -> f32 {
    return math.sin(angle)
}


cos :: proc { cos_f }
cos_f :: proc(angle: f32) -> f32 {
    return math.cos(angle)
}


atan2 :: proc { atan2_f }
atan2_f :: proc(y, x: f32) -> f32 {
    return math.atan2(y, x)
}

////////////////////////////////////////////////
// Vector operations

V3 :: proc { V3_x_yz, V3_xy_z }
V3_x_yz :: proc(x: f32, yz: v2) -> v3 { return { x, yz.x, yz.y }}
V3_xy_z :: proc(xy: v2, z: f32) -> v3 { return { xy.x, xy.y, z }}

Rect3 :: proc(xy: $R/Rectangle([2]$E), z_min, z_max: E) -> Rectangle([3]E) { 
    return { V3(xy.min, z_min), V3(xy.max, z_max)}
}

V4 :: proc { V4_x_yzw, V4_xy_zw, V4_xyz_w, V4_x_y_zw, V4_x_yz_w, V4_xy_z_w }
V4_x_yzw  :: proc(x: f32, yzw: v3) -> (result: v4) {
    result.x = x
    result.yzw = yzw
    return result
}
V4_xy_zw  :: proc(xy: v2, zw: v2) -> (result: v4) {
    result.xy = xy
    result.zw = zw
    return result
}
V4_xyz_w  :: proc(xyz: v3, w: f32) -> (result: v4) {
    result.xyz = xyz
    result.w = w
    return result
}
V4_x_y_zw :: proc(x, y: f32, zw: v2) -> (result: v4) {
    result.x = x
    result.y = y
    result.zw = zw
    return result
}
V4_x_yz_w :: proc(x: f32, yz: v2, w:f32) -> (result: v4) {
    result.x = x
    result.yz = yz
    result.w = w
    return result
}
V4_xy_z_w :: proc(xy: v2, z, w: f32) -> (result: v4) {
    result.xy = xy
    result.z = z
    result.w = w
    return result
}

perpendicular :: proc(v: v2) -> (result: v2) {
    result = { -v.y, v.x }
    return result
}

arm :: proc(angle: f32) -> (result: v2) {
    result = v2{cos(angle), sin(angle)}
    return result
}

dot :: proc(a, b: $V/[$N]$E) -> (result: E) {
    #unroll for i in 0..<N {
        result += a[i] * b[i]
    }
    
    return result
}

project :: proc(v, axis: $V) -> V {
    return v - 1 * dot(v, axis) * axis
}

length :: proc(vec: $V) -> (result: f32) {
    length_squared := length_squared(vec)
    result = square_root(length_squared)
    return result
}

length_squared :: proc(vec: $V) -> f32 {
    return dot(vec, vec)
}

normalize :: proc(vec: $V) -> (result: V) {
    result = vec / length(vec)
    return result
}
normalize_or_zero :: proc(vec: $V) -> (result: V) {
    len_sq := length_squared(vec)
    if len_sq > square(f32(0.0001)) {
        result = vec / square_root(len_sq)
    }
    return result
}


// ---------------------- ---------------------- ----------------------
// ---------------------- Rectangle operations
// ---------------------- ---------------------- ----------------------

rectangle_min_max  :: proc(min, max: $T) -> Rectangle(T) {
    return { min, max }
}
rectangle_min_dimension  :: proc { rectangle_min_dimension_2, rectangle_min_dimension_v }
rectangle_min_dimension_2  :: proc(x: $E, y, w, h: E) -> Rectangle([2]E) {
    return min_dimension_v([2]E{x, y}, [2]E{w, h})
}
rectangle_min_dimension_v  :: proc(min: $T, dimension: T) -> Rectangle(T) {
    return { min, min + dimension }
}
rectangle_center_dimension :: proc(center: $T, dimension: T) -> Rectangle(T) {
    return { center - (dimension / 2), center + (dimension / 2) }
}
rectangle_center_half_dimension :: proc(center: $T, half_dimension: T) -> Rectangle(T) {
    return { center - half_dimension, center + half_dimension }
}

rectangle_inverted_infinity :: proc($R: typeid) -> (result: R) {
    T :: intrinsics.type_field_type(R, "min")
    #assert(intrinsics.type_is_subtype_of(R, Rectangle(T)))
    E :: intrinsics.type_elem_type(T)
    
    result.min = max(E)
    result.max = min(E)
    
    return result
}

get_dimension :: proc(rect: Rectangle($T)) -> (result: T) { return rect.max - rect.min }
get_center    :: proc(rect: Rectangle($T)) -> (result: T) { return rect.min + (rect.max - rect.min) / 2 }

add_radius :: proc(rect: $R/Rectangle($T), radius: T) -> (result: R) {
    result = rect
    result.min -= radius
    result.max += radius
    return result
}

scale_radius :: proc(rect: $R/Rectangle($T), factor: T) -> (result: R) {
    result = rect
    center := get_center(rect)
    result.min = linear_blend(center, result.min, factor)
    result.max = linear_blend(center, result.max, factor)
    return result
}

add_offset :: proc(rect: $R/Rectangle($T), offset: T) -> (result: R) {
    result.min = rect.min + offset
    result.max = rect.max + offset
    
    return result
}

contains :: proc(rect: Rectangle($T), point: T) -> (result: b32) {
    result = true
    #unroll for i in 0..<len(T) {
        result &&= rect.min[i] < point[i] && point[i] < rect.max[i] 
    }
    return result
}

intersects :: proc(a, b: Rectangle($T)) -> (result: b32) {
    result = true
    #unroll for i in 0..<len(T) {
        result &&= !(b.max[i] <= a.min[i] || b.min[i] >= a.max[i])
    }
    
    return result
}

get_intersection :: proc(a, b: $R/Rectangle($T)) -> (result: R) {
    #unroll for i in 0..<len(T) {
        result.min[i] = max(a.min[i], b.min[i])
        result.max[i] = min(a.max[i], b.max[i])
    }
    
    return result
    
}

get_union :: proc(a, b: $R/Rectangle($T)) -> (result: R) {
    #unroll for i in 0..<len(T) {
        result.min[i] = min(a.min[i], b.min[i])
        result.max[i] = max(a.max[i], b.max[i])
    }
    
    return result
}

get_barycentric :: proc(rect: Rectangle($T), p: T) -> (result: T) {
    result = safe_ratio_0(p - rect.min, rect.max - rect.min)

    return result
}

get_xy :: proc(rect: Rectangle3) -> (result: Rectangle2) {
    result.min = rect.min.xy
    result.max = rect.max.xy
    
    return result
}

// @note(viktor): Area without the points at the maximum
get_volume_or_zero :: get_area_or_zero
get_area_or_zero :: proc(rect: $R/Rectangle($T)) -> (result: T) {
    dimension := get_dimension(rect)
    result = 1
    #unroll for i in 0..<len(T) {
        result *= max(0, dimension[i])
    }
    return result
}

has_area :: proc(rect: $R/Rectangle($T)) -> (result: b32) {
    area := get_area_or_zero(rect)
    result = area != 0
    return result
}

// @note(viktor): Area with the points at the maximum
get_volume_or_zero_inclusive :: get_area_or_zero_inclusive
get_area_or_zero_inclusive :: proc(rect: $R/Rectangle($T)) -> (result: T) {
    dimension := get_dimension(rect) + 1
    result = 1
    #unroll for i in 0..<len(T) {
        result *= max(0, dimension[i])
    }
    return result
}

has_area_inclusive :: proc(rect: $R/Rectangle($T)) -> (result: b32) {
    area := get_area_or_zero_inclusive(rect)
    result = area != 0
    return result
}