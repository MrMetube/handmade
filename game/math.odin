package game 

import "base:intrinsics"
import "core:math"

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


