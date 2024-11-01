package game 

import "base:intrinsics"
import "core:math"

v2 :: [2]f32
v3 :: [3]f32
v4 :: [4]f32

dot :: #force_inline proc(a, b: v2) -> f32 {
	return a.x * b.x + a.y * b.y
}

reflect :: #force_inline proc(v, axis:v2) -> v2 {
	return v - 2 * dot(v, axis) * axis
} 

// TODO(viktor): whats this called? project
dont_reflect_just_move_along_axis :: #force_inline proc(v, axis:v2) -> v2 {
	return v - 1 * dot(v, axis) * axis
}

lerp :: #force_inline proc(a, b, t: f32) -> f32 {
	return (1-t) * a + t * b
}

square :: #force_inline proc(x: f32) -> f32 { 
	return x * x
}

square_root :: math.sqrt

length :: #force_inline proc(vec: $T/[$N]$E) -> (length:f32) where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) {
	length_squared := length_squared(vec)
	length = math.sqrt(length_squared)
	return length
}

length_squared :: #force_inline proc(vec: $T/[$N]$E) -> f32 where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) {
	return dot(vec,vec)
}

normalize :: #force_inline proc(vec: $T/[$N]$E) -> T where N >= 1 && N <= 4 && intrinsics.type_is_numeric(E) {
	length := length(vec)
	return vec / length
}


