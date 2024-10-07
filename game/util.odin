package game 

import "base:intrinsics"
import "core:math"
import "core:simd"

mod :: proc(value: [2]f32, divisor: [2]f32) -> [2]f32 {
	return {math.mod(value.x, divisor.x), math.mod(value.y, divisor.y)}
}

length :: #force_inline proc(vec: $T/[$N]$E) -> (length:f32) where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) {
	sum_of_square := abs(vec.x * vec.x + vec.y * vec.y)
	if sum_of_square > 0 {
		length = math.sqrt(sum_of_square)
	}
	return length
}

normalize :: #force_inline proc(vec: $T/[$N]$E) -> T where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) {
	length := length(vec)
	denom  := length == 0 ? 1 : length
	return vec / denom
}


cast_vec :: #force_inline proc($T: typeid, value: [$N]$E) -> [N]T where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) && intrinsics.type_is_numeric(T) {
	// TODO check if this gets optimized to have no loop
	result : [N]T = ---
	#no_bounds_check {
		for e, i in value do result[i] = cast(T) value[i]
	}
	return result
}



in_bounds :: proc {
	in_bounds_array,
	in_bounds_slice,
}

in_bounds_array :: proc(arrays: [][$N]$T, index: [2]i32) -> b32 {
	return index.x >= 0 && index.x < cast(i32) len(arrays[0]) && index.y >= 0 && index.y < cast(i32) len(arrays)
}

in_bounds_slice :: proc(slices: [][]$T, index: [2]i32) -> b32 {
	return index.x >= 0 && index.x < cast(i32) len(slices[0]) && index.y >= 0 && index.y < cast(i32) len(slices)
}


// TODO convert all of these to platform-efficient versions

divmod :: math.divmod

round :: proc {
	round_f32,
	round_f32s,
}

round_f32 :: #force_inline proc(f: f32) -> i32 {
	return cast(i32) (f + 0.5)
}

round_f32s :: #force_inline proc(fs: [$N]f32) -> [N]i32 where N > 1 {
	return cast_vec(i32, fs + 0.5)
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

