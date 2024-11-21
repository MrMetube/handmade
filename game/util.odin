package game 

import "base:intrinsics"
import "core:math"
import "core:simd"

swap :: proc(a, b: ^$T) {
    b^, a^ = a^, b^
}

vec_cast :: proc { 
    cast_vec_2, cast_vec_3, cast_vec_4,
    cast_vec_v2, cast_vec_v3, cast_vec_v4,
}

cast_vec_2 :: #force_inline proc($T: typeid, x, y: $E) -> [2]T where T != E {
    return {cast(T) x, cast(T) y}
}

cast_vec_3 :: #force_inline proc($T: typeid, x, y, z: $E) -> [3]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z}
}

cast_vec_4 :: #force_inline proc($T: typeid, x, y, z, w: $E) -> [4]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z, cast(T) w}
}

cast_vec_v2 :: #force_inline proc($T: typeid, v:[2]$E) -> [2]T where T != E {
    return cast_vec_2(T, v.x, v.y)
}

cast_vec_v3 :: #force_inline proc($T: typeid, v:[3]$E) -> [3]T where T != E {
    return cast_vec_3(T, v.x, v.y, v.z)
}

cast_vec_v4 :: #force_inline proc($T: typeid, v:[4]$E) -> [4]T where T != E {
    return cast_vec_4(T, v.x, v.y, v.z, v.w)
}



min_vec :: proc { min_vec_2, min_vec_3}
max_vec :: proc { max_vec_2, max_vec_3}

min_vec_2 :: #force_inline proc(a,b: [2]$E) -> [2]E where intrinsics.type_is_numeric(E) {
    return {min(a.x, b.x), min(a.y, b.y)}
}

min_vec_3 :: #force_inline proc(a,b: [3]$E) -> [3]E where intrinsics.type_is_numeric(E) {
    return {min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)}
}

max_vec_2 :: #force_inline proc(a,b: [2]$E) -> [2]E where intrinsics.type_is_numeric(E) {
    return {max(a.x, b.x), max(a.y, b.y)}
}

max_vec_3 :: #force_inline proc(a,b: [3]$E) -> [3]E where intrinsics.type_is_numeric(E) {
    return {max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)}
}


abs_vec :: proc { abs_vec_2, abs_vec_3 }
abs_vec_2 :: #force_inline proc(a: [2]$E) -> [2]E where intrinsics.type_is_numeric(E) {
    return {abs(a.x), abs(a.y)}
}
abs_vec_3 :: #force_inline proc(a: [3]$E) -> [3]E where intrinsics.type_is_numeric(E) {
    return {abs(a.x), abs(a.y), abs(a.z)}
}



// in_bounds :: proc {
// 	in_bounds_array_2d,
// 	in_bounds_array_3d,
// 	in_bounds_slice_2d,
// 	in_bounds_slice_3d,
// 	in_bounds_array_2,
// 	in_bounds_array_3,
// 	in_bounds_slice_2,
// 	in_bounds_slice_3,
// }

// in_bounds_array_2d :: #force_inline proc(arrays: [][$N]$T, index: [2]$I) -> b32 where intrinsics.type_is_integer(I) {
// 	return in_bounds_array_2(arrays, index.x, index.y)
// }

// in_bounds_slice_2d :: #force_inline proc(slices: [][]$T, index: [2]$I) -> b32 where intrinsics.type_is_integer(I) {
// 	return in_bounds_slice_2(slices, index.x, index.y)
// }

// in_bounds_array_2 :: #force_inline proc(arrays: [][$N]$T, x, y: $I) -> b32 where intrinsics.type_is_integer(I) {
// 	when intrinsics.type_is_unsigned(I) {
// 		return x < cast(I) len(arrays[0]) && y < cast(I) len(arrays)
// 	} else {
// 		return x >= 0 && x < cast(I) len(arrays[0]) && y >= 0 && y < cast(I) len(arrays)
// 	}
// }

// in_bounds_slice_2 :: #force_inline proc(slices: [][]$T, x, y: $I) -> b32 where intrinsics.type_is_integer(I) {
// 	when intrinsics.type_is_unsigned(I) {
// 		return x < cast(I) len(slices[0]) && y < cast(I) len(slices)
// 	} else {
// 		return x >= 0 && x < cast(I) len(slices[0]) && y >= 0 && y < cast(I) len(slices)
// 	}
// }

// in_bounds_array_3d :: #force_inline proc(arrays: [][$N][$M]$T, index: [3]$I) -> b32 where intrinsics.type_is_integer(I) {
// 	return in_bounds_array_3(arrays, index.x, index.y, index.z)
// }

// in_bounds_slice_3d :: #force_inline proc(slices: [][][]$T, index: [3]$I) -> b32 where intrinsics.type_is_integer(I) {
// 	return in_bounds_slice_3(slices, index.x, index.y, index.z)
// }

// in_bounds_array_3 :: #force_inline proc(arrays: [][$N][$M]$T, x, y, z: $I) -> b32 where intrinsics.type_is_integer(I) {
// 	when intrinsics.type_is_unsigned(I) {
// 		return x < cast(I) len(arrays[0][0]) && y < cast(I) len(arrays[0]) && z < cast(I) len(arrays)
// 	} else {
// 		return x >= 0 && x < cast(I) len(arrays[0][0]) && y >= 0 && y < cast(I) len(arrays[0]) && z >= 0 && z < cast(I) len(arrays)
// 	}
// }

// in_bounds_slice_3 :: #force_inline proc(slices: [][][]$T, x, y, z: $I) -> b32 where intrinsics.type_is_integer(I) {
// 	when intrinsics.type_is_unsigned(I) {
// 		return x < cast(I) len(slices[0][0]) && y < cast(I) len(slices[0]) && z < cast(I) len(slices)
// 	} else {
// 		return x >= 0 && x < cast(I) len(slices[0][0]) && y >= 0 && y < cast(I) len(slices[0]) && z >= 0 && z < cast(I) len(slices)
// 	}
// }


// TODO convert all of these to platform-efficient versions
sign :: proc{ sign_i, sign_u, sign_vi, sign_vu }

sign_i :: #force_inline proc(i: i32) -> i32 {
    return i < 0 ? -1 : 1
}
sign_u :: #force_inline proc(i: u32) -> i32 {
    return cast(i32) i < 0 ? -1 : 1
}
sign_vi :: #force_inline proc(a: [2]i32) -> [2]i32 {
    return {sign(a.x), sign(a.y)}
}
sign_vu :: #force_inline proc(a: [2]u32) -> [2]i32 {
    return {sign(a.x), sign(a.y)}
}

mod :: proc {
    mod_d,
    mod_ds,
}

mod_d :: proc(value: [2]f32, divisor: f32) -> [2]f32 {
    return {math.mod(value.x, divisor), math.mod(value.y, divisor)}
}

mod_ds :: proc(value: [2]f32, divisor: [2]f32) -> [2]f32 {
    return {math.mod(value.x, divisor.x), math.mod(value.y, divisor.y)}
}

round :: proc {
    round_f32,
    round_f32s,
}

round_f32 :: #force_inline proc(f: f32) -> i32 {
    // TODO(viktor): 
    if f < 0 do return cast(i32) -math.round(-f)
    return cast(i32) math.round(f)
}

round_f32s :: #force_inline proc(fs: [$N]f32) -> [N]i32 where N > 1 {
    fs := fs
    for &e in fs do e = math.round(e) 
    return vec_cast(i32, fs)
}


floor :: proc {
    floor_f32,
    floor_f32_simd,
}

floor_f32 :: #force_inline proc(f: f32) -> (i:i32) {
    return cast(i32) math.floor(f)
}

floor_f32_simd :: #force_inline proc(fs: [$N]f32) -> [N]i32 {
    return vec_cast(i32, simd.to_array(simd.floor(simd.from_array(fs))))
}

ceil :: proc {
    ceil_f32,
    ceil_f32_simd,
}

ceil_f32 :: #force_inline proc(f: f32) -> (i:i32) {
    return cast(i32) math.ceil(f)
}

ceil_f32_simd :: #force_inline proc(fs: [$N]f32) -> [N]i32 {
    return vec_cast(i32, simd.to_array(simd.ceil(simd.from_array(fs))))
}




truncate :: proc {
    truncate_f32,
    truncate_f32s,
}

truncate_f32 :: #force_inline proc(f: f32) -> i32 {
    return cast(i32) f
}

truncate_f32s :: #force_inline proc(fs: [$N]f32) -> [N]i32 where N > 1 {
    return vec_cast(i32, fs)
}


sin :: proc {
    sin_f32,
    sin_f32_simd,	
}

sin_f32 :: #force_inline proc(angle: f32) -> f32 {
    return math.sin(angle)
}

sin_f32_simd :: #force_inline proc(angle: [$N]f32) -> [N]f32 {
    
}


cos :: proc {
    cos_f32,
    cos_f32_simd,	
}

cos_f32 :: #force_inline proc(angle: f32) -> f32 {
    return math.cos(angle)
}

cos_f32_simd :: #force_inline proc(angle: [$N]f32) -> [N]f32 {

}


atan2 :: proc {
    atan2_f32,
    atan2_f32_simd,	
}

atan2_f32 :: #force_inline proc(y, x: f32) -> f32 {
    return math.atan2(y, x)
}

atan2_f32_simd :: #force_inline proc(y, x: [$N]f32) -> [N]f32 {
    
}

rotate_left :: #force_inline proc(value: u32, amount: i32) -> u32 {
    // TODO: can odin insert rotate intrinsics
    masked := amount & 31
    return value << u32(masked) | value >> u32(32 - masked)
}

rotate_right :: #force_inline proc(value: u32, amount: i32) -> u32 {
    // TODO: can odin insert rotate intrinsics
    masked := amount & 31
    return value >> u32(-masked) | value << u32(32 + masked)
}