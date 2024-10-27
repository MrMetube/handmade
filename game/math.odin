package game 

import "base:intrinsics"
import "core:math"

v2 :: [2]f32
v3 :: [3]f32
v4 :: [4]f32

dot :: proc(a, b: v2) -> f32 {
	return a.x * b.x + a.y * b.y
}

reflect :: proc(v, axis:v2) -> v2 {
	return v - 2 * dot(v, axis) * axis
}

// TODO(viktor): whats this called? half reflect / move along
dont_reflect_just_move_along_axis :: proc(v, axis:v2) -> v2 {
	return v - 1 * dot(v, axis) * axis
}

lerp :: #force_inline proc(a, b, t: f32) -> f32 {
	return (1-t) * a + t * b
}

square :: #force_inline proc(x: f32) -> f32 { 
	return x * x
}

length :: #force_inline proc(vec: $T/[$N]$E) -> (length:f32) where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) {
	square := vec * vec
	when N == 2 {
		sum_of_square := abs(vec.x + vec.y)
	} else when N == 3 {
		sum_of_square := abs(vec.x + vec.y + vec.z)
	} else when N == 4 {
		sum_of_square := abs(vec.x + vec.y + vec.z + vec.w)
	}
	length = math.sqrt(sum_of_square)
	return length
}

normalize :: #force_inline proc(vec: $T/[$N]$E) -> T where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) {
	length := length(vec)
	denom  := length == 0 ? 1 : length
	return vec / denom
}


