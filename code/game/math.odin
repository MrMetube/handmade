#+vet !unused-procedures
#+no-instrumentation
package game

@(common="file")

import "base:intrinsics"
import "base:builtin"
import "core:math"
import "core:simd"

////////////////////////////////////////////////
// Types

v2  :: [2] f32
v3  :: [3] f32
v4  :: [4] f32
v2i :: [2] i32
v3i :: [3] i32
v4i :: [4] i32

m4 :: #column_major matrix[4,4] f32

Rectangle   :: struct($T: typeid) { min, max: T }
Rectangle2  :: Rectangle(v2)
Rectangle3  :: Rectangle(v3)
Rectangle2i :: Rectangle(v2i)

f32x4 :: #simd [4] f32
i32x4 :: #simd [4] i32

LaneWidth :: 16

// @todo(viktor): @metaprogram cant see decls in when blocks for now, so we put them in global scope
lane_f32 :: #simd [LaneWidth] f32
lane_u32 :: #simd [LaneWidth] u32
lane_i32 :: #simd [LaneWidth] i32

lane_pmm :: #simd [LaneWidth] pmm
lane_umm :: #simd [LaneWidth] umm
lane_f64 :: #simd [LaneWidth] f64
when LaneWidth != 1 {
} else {
    lane_f32 :: f32
    lane_u32 :: u32
    lane_i32 :: i32

    
    lane_pmm :: pmm
    lane_umm :: umm
    lane_f64 :: f64
}
lane_v2 :: [2] lane_f32
lane_v3 :: [3] lane_f32
lane_v4 :: [4] lane_f32

////////////////////////////////////////////////
// Constants

Tau :: 6.28318530717958647692528676655900576
Pi  :: 3.14159265358979323846264338327950288

E   :: 2.71828182845904523536

SqrtTwo   :: 1.41421356237309504880168872420969808
SqrtThree :: 1.73205080756887729352744634150587236
SqrtFive  :: 2.23606797749978969640917366873127623

Ln2  :: 0.693147180559945309417232121458176568
Ln10 :: 2.30258509299404568401799145468436421

MaxF64Precision :: 16 // Maximum number of meaningful digits after the decimal point for 'f64'
MaxF32Precision ::  8 // Maximum number of meaningful digits after the decimal point for 'f32'
MaxF16Precision ::  4 // Maximum number of meaningful digits after the decimal point for 'f16'

Infinity   :: math.INF_F32
Infinity64 :: math.INF_F64

RadiansPerDegree :: Tau / 360.0
DegreesPerRadian :: 360.0 / Tau

////////////////////////////////////////////////
// Scalar operations

square :: proc (x: $T) -> T where intrinsics.type_is_numeric(T) || intrinsics.type_is_array(T) || intrinsics.type_is_simd_vector(T) { return x * x }

square_root :: proc (x: $T) -> (result: T) where intrinsics.type_is_numeric(T) || intrinsics.type_is_array(T) || intrinsics.type_is_simd_vector(T) { 
    when intrinsics.type_is_array(T) {
        #unroll for i in 0..<len(T) {
            result[i] = simd.sqrt(x[i])
        }
    } else {
        result = simd.sqrt(x)
    }
    return result
 }
 
 power :: math.pow

linear_blend  :: proc{ linear_blend_v_e, linear_blend_e }
linear_blend_v_e :: proc (from: $V/[$N]$E, to: V, t: E) -> V {
    result := (1-t) * from + t * to
    
    return result
}
linear_blend_e :: proc (from: $T, to: T, t: T) -> T  {
    result := (1-t) * from + t * to
    
    return result
}

bilinear_blend :: proc (a, b, c, d: $V/[$N]$E, t: [2] E) -> (result: V) {
    la := (1-t.y) * (1-t.x)
    lb := (1-t.y) *    t.x
    lc :=    t.y  * (1-t.x)
    ld :=    t.y  *    t.x
    
    result = la * a + lb * b + lc * c + ld * d
    return result
}

sin_01 :: proc (t: $T) -> T {
    result := sin(Pi*t)
    return result
}

safe_ratio_n :: proc (numerator, divisor, n: $T) -> (result: T) {
    when intrinsics.type_is_array(T) {
        #unroll for i in 0..<len(T) {
            result[i] = safe_ratio_n(numerator[i], divisor[i], n[i])
        }
    } else {
        result = divisor != 0 ? numerator / divisor : n
    }
    return result
}
safe_ratio_0 :: proc (numerator, divisor: $T) -> T { return safe_ratio_n(numerator, divisor, 0) }
safe_ratio_1 :: proc (numerator, divisor: $T) -> T { return safe_ratio_n(numerator, divisor, 1) }

clamp :: proc (value: $T, min, max: T) -> (result: T) {
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
clamp_01 :: proc (value: $T) -> T { return clamp(value, 0, 1) }

clamp_01_map_to_range :: proc (min: $T, t, max: T ) -> (result: T) {
    range := max - min
    if range != 0 {
        percent := (t-min) / range
        result = clamp_01(percent)
    }
    return result
}

sign :: proc{ sign_i, sign_f }
sign_i  :: proc (i: i32) -> i32 { return i >= 0 ? 1 : -1 }
sign_f  :: proc (x: f32) -> f32 { return x >= 0 ? 1 : -1 }

modulus :: proc { modulus_f, modulus_vf, modulus_v, modulus_i }
modulus_i :: proc (value: $I, divisor: I) -> I where intrinsics.type_is_integer(I) {
    return value % divisor
}
modulus_f :: proc (value: f32, divisor: f32) -> f32 {
    return math.mod(value, divisor)
}
modulus_vf :: proc (value: [$N]f32, divisor: f32) -> (result: [N]f32) where N > 1 {
    #unroll for i in 0..<N do result[i] = math.mod(value[i], divisor) 
    return result
}
modulus_v :: proc (value: [$N]f32, divisor: [N]f32) -> (result: [N]f32) {
    #unroll for i in 0..<N do result[i] = math.mod(value[i], divisor[i]) 
    return result
}

round :: proc { round_f, round_v }
round_f :: proc ($T: typeid, f: $F) -> T 
where !intrinsics.type_is_array(F)
{
    return  cast(T) (f < 0 ? -math.round(-f) : math.round(f))
}
round_v :: proc ($T: typeid, v: [$N]$F) -> (result: [N] T) {
    #unroll for i in 0..<N do result[i] = cast(T) math.round(v[i]) 
    return result
}

floor :: proc { floor_f, floor_v }
floor_f :: proc ($T: typeid, f: f32) -> (i: T) {
    return cast(T) math.floor(f)
}
floor_v :: proc ($T: typeid, fs: [$N]f32) -> [N] T {
    return vec_cast(T, simd.to_array(simd.floor(simd.from_array(fs))))
}

ceil :: proc { ceil_f, ceil_v }
ceil_f :: proc ($T: typeid, f: f32) -> (i: T) {
    return cast(T) math.ceil(f)
}
ceil_v :: proc ($T: typeid, fs: [$N]f32) -> [N] T {
    return vec_cast(T, simd.to_array(simd.ceil(simd.from_array(fs))))
}

truncate :: proc { truncate_f, truncate_v }
truncate_f :: proc ($T: typeid, f: f32) -> T {
    return cast(T) f
}
truncate_v :: proc ($T: typeid, fs: [$N]f32) -> [N]T where N > 1 {
    return vec_cast(T, fs)
}

fractional :: proc (x: $F) -> (fractional: F, integer: i32) {
    integer = cast(i32) x
    fractional = x - cast(F) integer
    return 
}

distance :: proc (to: $T, from: T) -> (result: T) {
    return abs(a - b)
}

log2 :: math.log2
sin  :: math.sin
cos  :: math.cos
tan  :: math.tan
acos :: proc (x: $T) -> (result: T) {
    when intrinsics.type_is_simd_vector(T) {
        a := simd.to_array(x)
        #unroll for i in 0..<len(T) do a[i] = acos(a[i])
        result = simd.from_array(a)
    } else {
        result = math.acos(x)
    }
    return result
}
atan2     :: proc { math.atan2_f64, math.atan2_f32, atan2_vec }
atan2_vec :: proc (v: [2] $T) -> (result: T) { return math.atan2(v.y, v.x) }

////////////////////////////////////////////////
// Vector operations

V3 :: proc { V3_x_yz, V3_xy_z }
V3_x_yz :: proc (x: $T, yz: [2] T) -> [3] T { return { x, yz.x, yz.y }}
V3_xy_z :: proc (xy: [2] $T, z: T) -> [3] T { return { xy.x, xy.y, z }}

Rect3 :: proc (xy: $R/Rectangle([2] $E), z_min, z_max: E) -> Rectangle([3] E) { 
    return { V3(xy.min, z_min), V3(xy.max, z_max)}
}

V4 :: proc { V4_x_yzw, V4_xy_zw, V4_xyz_w, V4_x_y_zw, V4_x_yz_w, V4_xy_z_w }
V4_x_yzw  :: proc (x: $T, yzw: [3] T) -> (result: [4] T) {
    result.x = x
    result.yzw = yzw
    return result
}
V4_xy_zw  :: proc (xy: [2]$T, zw: [2] T) -> (result: [4] T) {
    result.xy = xy
    result.zw = zw
    return result
}
V4_xyz_w  :: proc (xyz: [3]$T, w: T) -> (result: [4] T) {
    result.xyz = xyz
    result.w = w
    return result
}
V4_x_y_zw :: proc (x: $T, y: T, zw: [2] T) -> (result: [4] T) {
    result.x = x
    result.y = y
    result.zw = zw
    return result
}
V4_x_yz_w :: proc (x: $T, yz: [2] T, w:T) -> (result: [4] T) {
    result.x = x
    result.yz = yz
    result.w = w
    return result
}
V4_xy_z_w :: proc (xy: [2]$T, z, w: T) -> (result: [4] T) {
    result.xy = xy
    result.z = z
    result.w = w
    return result
}

v4_to_rgba :: proc (rgba: v4) -> (result: [4]u8) {
    result = vec_cast(u8, rgba * 255)
    return result
}
rgba_to_v4 :: proc (rgba: [4]u8) -> (result: v4) {
    result = vec_cast(f32, rgba)
    result /= 255
    return result
}

perpendicular :: proc (v: v2) -> (result: v2) {
    result = { -v.y, v.x }
    return result
}

arm :: proc (angle: $T) -> (result: [2] T) {
    result = {cos(angle), sin(angle)}
    return result
}

rotate :: proc (v: $V/[$N]$T, angle: T) -> (result: V) {
    rotor := arm(angle)
    result.x = v.x * rotor.x + v.y * -rotor.y
    result.y = v.x * rotor.y + v.y *  rotor.x
    return result
}

dot :: proc (a, b: $V) -> (result: element_type(V)) {
    when intrinsics.type_is_simd_vector(V) {
        result = simd.reduce_add_pairs(a * b)
    } else {
        #unroll for i in 0..<len(V) {
            result += a[i] * b[i]
        }
    }
    
    return result
}

cross2 :: proc (a, b: $V/[2]$E) -> (result: E) {
    // just the z term, 
    // isn't this also just the determinant? Yes!
    result = a.x * b.y - a.y * b.x
    return result
}
cross :: proc (a, b: $V/[3]$E) -> (result: V) {
    result = {
        a.y*b.z - a.z*b.y,
        a.z*b.x - a.x*b.z,
        a.x*b.y - a.y*b.x,
    }
    
    return result
}

reflect :: proc (v, axis: $V) -> V {
    return v - 2 * dot(v, axis) * axis
}
project :: proc (v, axis: $V) -> V {
    return v - 1 * dot(v, axis) * axis
}

length :: proc (vec: $V) -> (result: element_type(V)) {
    length_squared := length_squared(vec)
    result = square_root(length_squared)
    return result
}

length_squared :: proc (vec: $V) -> (result: element_type(V)) {
    result = dot(vec, vec)
    return result
}

normalize :: proc (vec: $V) -> (result: V) {
    result = vec / length(vec)
    return result
}
normalize_or_zero :: proc (vec: $V/[$N]$T) -> (result: V) {
    len_sq := length_squared(vec)
    when intrinsics.type_is_simd_vector(T) {
        len_mask := simd.lanes_gt(len_sq, 0.0000001)
        conditional_assign(len_mask, &result, vec / square_root(len_sq))
    } else {
        if len_sq > 0.0000001 {
            result = vec / square_root(len_sq)
        }
    }
    return result
}

linear_to_srgb_exact :: proc (l: v3) -> (s: v3) {
    l := l
    l = clamp_01(l)
    #unroll for i in 0..<len(l) {
        if l[i] <= 0.0031308 {
            s[i] = 12.92 * l[i]
        } else {
            s[i] = 1.055 * power(l[i], 1./2.4) - 0.055
        }
    }
    
    return s
}

////////////////////////////////////////////////
// Simd operations


conditional_assign :: proc (mask: $M, dest: ^$D, value: D) {
    when intrinsics.type_is_array(D) {
        #unroll for i in 0..<len(D) {
            conditional_assign(mask, &dest[i], value[i])
        }
    } else {
        simd.masked_store(dest, value, mask)
    }
}

greater_equal :: simd.lanes_ge
greater_than  :: simd.lanes_gt
less_than     :: simd.lanes_lt
shift_left    :: simd.shl
shift_right   :: simd.shr
horizontal_add :: simd.reduce_add_pairs
maximum :: simd.max

extract_v4 :: proc (a: lane_v4, #any_int n: u32) -> (result: v4) {
    result.x = extract(a.x, n)
    result.y = extract(a.y, n)
    result.z = extract(a.z, n)
    result.w = extract(a.w, n)
    return result
}
extract_v3 :: proc (a: lane_v3, #any_int n: u32) -> (result: v3) {
    result.x = extract(a.x, n)
    result.y = extract(a.y, n)
    result.z = extract(a.z, n)
    return result
}
extract :: proc (a: $T/#simd[$N]$E, #any_int n: u32) -> (result: E) {
    when intrinsics.type_is_array(T) {
        #unroll for i in 0..<len(T) {
            result[i] = simd.extract(a[i], n)
        }
    } else {
        result = simd.extract(a, n)
    }
    return result
}

when LaneWidth != 1 {} else {
    conditional_assign :: proc (mask: $M, dest: ^$D, value: D) {
        mask := mask
        mask = mask == 0 ? 0 : 0xffffffff
        when intrinsics.type_is_array(D) {
            #unroll for i in 0..<len(D) {
                conditional_assign(mask, &dest[i], value[i])
            }
        } else {
            dest ^= cast(D) (((cast(^M)dest)^ &~ mask) | (transmute(M) value & mask))
        }
    }
    greater_equal  :: proc (a, b: $T) -> u32 { return a >= b ? 0xffffffff : 0}
    greater_than   :: proc (a, b: $T) -> u32 { return a >  b ? 0xffffffff : 0}
    less_than      :: proc (a, b: $T) -> u32 { return a <  b ? 0xffffffff : 0}
    horizontal_add :: proc (a: $T) -> T { return a}
    
    shift_left    :: proc (a: $T, n: u32) -> T { return a << n }
    shift_right   :: proc (a: $T, n: u32) -> T { return a >> n }
    maximum :: max
    extract :: proc (a: $T, n: u32) -> (result: T) { 
        when intrinsics.type_is_array(T) {
            #unroll for i in 0..<len(D) {
                result[i] = a[i]
            }
        } else {
            result = a
        }
        return result
     }
     extract_v4 :: proc (a: lane_v4, #any_int n: u32) -> (result: v4) {
        assert(n == 0)
        result = a
        return result
    }
    extract_v3 :: proc (a: lane_v3, #any_int n: u32) -> (result: v3) {
        assert(n == 0)
        result = a
        return result
    }
}

////////////////////////////////////////////////
// Rectangle operations

rectangle_min_dimension         :: proc { rectangle_min_dimension_2, rectangle_min_dimension_v }
rectangle_min_dimension_2       :: proc (x: $E, y, w, h: E)             -> Rectangle([2]E) { return rectangle_min_dimension_v([2]E{x, y}, [2]E{w, h}) }
rectangle_min_dimension_v       :: proc (min: $T, dimension: T)         -> Rectangle(T)    { return { min,                      min + dimension          } }
rectangle_min_max               :: proc (min, max: $T)                  -> Rectangle(T)    { return { min,                      max                      } }
rectangle_center_dimension      :: proc (center: $T, dimension: T)      -> Rectangle(T)    { return { center - (dimension / 2), center + (dimension / 2) } }
rectangle_center_half_dimension :: proc (center: $T, half_dimension: T) -> Rectangle(T)    { return { center - half_dimension,  center + half_dimension  } }

rectangle_origin_axis :: proc (origin, x_axis, y_axis: v2) -> (result: Rectangle2i) {
    result = rectangle_inverted_infinity(Rectangle2i)
    
    points := [?]v2{
        origin, 
        origin + x_axis, 
        origin          + y_axis, 
        origin + x_axis + y_axis,
    }
    
    for p in points {
        fp := floor(i32, p)
        cp  := ceil(i32, p)
        result.min = min_vec(result.min, fp)
        result.max = max_vec(result.max, cp)
    }
    
    return result
}

rectangle_inverted_infinity :: proc ($R: typeid) -> (result: R) {
    T :: intrinsics.type_field_type(R, "min")
    #assert(intrinsics.type_is_subtype_of(R, Rectangle(T)))
    E :: intrinsics.type_elem_type(T)
    
    result.min = max(E)
    result.max = min(E)
    
    return result
}

get_dimension :: proc (rect: Rectangle($T)) -> (result: T) { return rect.max - rect.min }
get_center    :: proc (rect: Rectangle($T)) -> (result: T) { return rect.min + (rect.max - rect.min) / 2 }

add_radius :: proc (rect: $R/Rectangle($T), radius: T) -> (result: R) {
    result = rect
    result.min -= radius
    result.max += radius
    return result
}

scale_radius :: proc (rect: $R/Rectangle($T), factor: T) -> (result: R) {
    result = rect
    center := get_center(rect)
    result.min = linear_blend(center, result.min, factor)
    result.max = linear_blend(center, result.max, factor)
    return result
}

add_offset :: proc (rect: $R/Rectangle($T), offset: T) -> (result: R) {
    result.min = rect.min + offset
    result.max = rect.max + offset
    
    return result
}

contains :: proc (rect: Rectangle($T), point: T) -> (result: b32) {
    result = true
    #unroll for i in 0..<len(T) {
        result &&= rect.min[i] <= point[i] && point[i] < rect.max[i] 
    }
    return result
}

contains_inclusive :: proc (rect: Rectangle($T), point: T) -> (result: b32) {
    result = true
    #unroll for i in 0..<len(T) {
        result &&= rect.min[i] <= point[i] && point[i] <= rect.max[i] 
    }
    return result
}

dimension_contains :: proc (dimension: $V/[$N]$T, point: V) -> (result: b32) {
    result = true
    #unroll for i in 0..<N {
        result &&= 0 <= point[i] && point[i] < dimension[i] 
    }
    return result
}

contains_rect :: proc (a: $R/Rectangle($T), b: R) -> (result: b32) {
    u := get_union(a, b)
    result = a == u
    return result
}

intersects :: proc (a, b: Rectangle($T)) -> (result: b32) {
    result = true
    #unroll for i in 0..<len(T) {
        result &&= !(b.max[i] <= a.min[i] || b.min[i] >= a.max[i])
    }
    
    return result
}

get_intersection :: proc (a, b: $R/Rectangle($T)) -> (result: R) {
    #unroll for i in 0..<len(T) {
        result.min[i] = max(a.min[i], b.min[i])
        result.max[i] = min(a.max[i], b.max[i])
    }
    
    return result
    
}

get_union :: proc (a, b: $R/Rectangle($T)) -> (result: R) {
    #unroll for i in 0..<len(T) {
        result.min[i] = min(a.min[i], b.min[i])
        result.max[i] = max(a.max[i], b.max[i])
    }
    
    return result
}

get_barycentric :: proc (rect: Rectangle($T), p: T) -> (result: T) {
    result = safe_ratio_0(p - rect.min, rect.max - rect.min)

    return result
}

get_xy :: proc (rect: Rectangle3) -> (result: Rectangle2) {
    result.min = rect.min.xy
    result.max = rect.max.xy
    
    return result
}

rectangle_modulus :: proc (rect: $R/Rectangle($T), p: T) -> (result: T) {
    dim := get_dimension(rect)
    offset := p - rect.min
    result = (((offset % dim) + dim) % dim) + rect.min
    assert(contains(rect, result))
    return result
}

// @note(viktor): Area without the points at the maximum
get_volume_or_zero :: get_area_or_zero
get_area_or_zero :: proc (rect: $R/Rectangle($T)) -> (result: T) {
    dimension := get_dimension(rect)
    result = 1
    #unroll for i in 0..<len(T) {
        result *= max(0, dimension[i])
    }
    return result
}

has_area :: proc (rect: $R/Rectangle($T)) -> (result: bool) {
    area := get_area_or_zero(rect)
    result = area != 0
    return result
}

// @note(viktor): Area with the points at the maximum
get_volume_or_zero_inclusive :: get_area_or_zero_inclusive
get_area_or_zero_inclusive :: proc (rect: $R/Rectangle($T)) -> (result: T) {
    dimension := get_dimension(rect) + 1
    result = 1
    #unroll for i in 0..<len(T) {
        result *= max(0, dimension[i])
    }
    return result
}

has_area_inclusive :: proc (rect: $R/Rectangle($T)) -> (result: b32) {
    area := get_area_or_zero_inclusive(rect)
    result = area != 0
    return result
}

////////////////////////////////////////////////

element_type :: intrinsics.type_elem_type