package game 

import "base:intrinsics"
import "core:math"
import "core:simd"

swap :: proc(a, b: ^$T) {
	b^, a^ = a^, b^
}

vec_cast :: proc { cast_vec, cast_vec_2 }

cast_vec_2 :: #force_inline proc($T: typeid, x, y: $E) -> [2]T {
	return {cast(T) x, cast(T) y}
}

cast_vec :: #force_inline proc($T: typeid, value: [$N]$E) -> [N]T where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) && intrinsics.type_is_numeric(T) {
	// TODO check if this gets optimized to have no loop
	result : [N]T = ---
	#no_bounds_check {
		for _, i in value do result[i] = cast(T) value[i]
	}
	return result
}

in_bounds :: proc {
	in_bounds_array_2d,
	in_bounds_array_3d,
	in_bounds_slice_2d,
	in_bounds_slice_3d,
	in_bounds_array_2,
	in_bounds_array_3,
	in_bounds_slice_2,
	in_bounds_slice_3,
}

in_bounds_array_2d :: #force_inline proc(arrays: [][$N]$T, index: [2]$I) -> b32 where intrinsics.type_is_integer(I) {
	return in_bounds_array_2(arrays, index.x, index.y)
}

in_bounds_slice_2d :: #force_inline proc(slices: [][]$T, index: [2]$I) -> b32 where intrinsics.type_is_integer(I) {
	return in_bounds_slice_2(slices, index.x, index.y)
}

in_bounds_array_2 :: #force_inline proc(arrays: [][$N]$T, x, y: $I) -> b32 where intrinsics.type_is_integer(I) {
	when intrinsics.type_is_unsigned(I) {
		return x < cast(I) len(arrays[0]) && y < cast(I) len(arrays)
	} else {
		return x >= 0 && x < cast(I) len(arrays[0]) && y >= 0 && y < cast(I) len(arrays)
	}
}

in_bounds_slice_2 :: #force_inline proc(slices: [][]$T, x, y: $I) -> b32 where intrinsics.type_is_integer(I) {
	when intrinsics.type_is_unsigned(I) {
		return x < cast(I) len(slices[0]) && y < cast(I) len(slices)
	} else {
		return x >= 0 && x < cast(I) len(slices[0]) && y >= 0 && y < cast(I) len(slices)
	}
}

in_bounds_array_3d :: #force_inline proc(arrays: [][$N][$M]$T, index: [3]$I) -> b32 where intrinsics.type_is_integer(I) {
	return in_bounds_array_3(arrays, index.x, index.y, index.z)
}

in_bounds_slice_3d :: #force_inline proc(slices: [][][]$T, index: [3]$I) -> b32 where intrinsics.type_is_integer(I) {
	return in_bounds_slice_3(slices, index.x, index.y, index.z)
}

in_bounds_array_3 :: #force_inline proc(arrays: [][$N][$M]$T, x, y, z: $I) -> b32 where intrinsics.type_is_integer(I) {
	when intrinsics.type_is_unsigned(I) {
		return x < cast(I) len(arrays[0][0]) && y < cast(I) len(arrays[0]) && z < cast(I) len(arrays)
	} else {
		return x >= 0 && x < cast(I) len(arrays[0][0]) && y >= 0 && y < cast(I) len(arrays[0]) && z >= 0 && z < cast(I) len(arrays)
	}
}

in_bounds_slice_3 :: #force_inline proc(slices: [][][]$T, x, y, z: $I) -> b32 where intrinsics.type_is_integer(I) {
	when intrinsics.type_is_unsigned(I) {
		return x < cast(I) len(slices[0][0]) && y < cast(I) len(slices[0]) && z < cast(I) len(slices)
	} else {
		return x >= 0 && x < cast(I) len(slices[0][0]) && y >= 0 && y < cast(I) len(slices[0]) && z >= 0 && z < cast(I) len(slices)
	}
}


// TODO convert all of these to platform-efficient versions

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
	return cast(i32) math.round(f)
}

round_f32s :: #force_inline proc(fs: [$N]f32) -> [N]i32 where N > 1 {
	fs := fs
	for &e in fs do e = math.round(e) 
	return cast_vec(i32, fs)
}


floor :: proc {
	floor_f32,
	floor_f32_simd,
}

floor_f32 :: #force_inline proc(f: f32) -> (i:i32) {
	return floor_f32_simd([1]f32{f})[0]
}

floor_f32_simd :: #force_inline proc(fs: [$N]f32) -> [N]i32 {
	return cast_vec(i32, simd.to_array(simd.floor(simd.from_array(fs))))
}


truncate :: proc {
	truncate_f32,
	truncate_f32s,
}

truncate_f32 :: #force_inline proc(f: f32) -> i32 {
	return cast(i32) f
}

truncate_f32s :: #force_inline proc(fs: [$N]f32) -> [N]i32 where N > 1 {
	return cast_vec(i32, fs)
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

