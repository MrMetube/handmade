package game 

import "base:intrinsics"
import "core:math"
import "core:simd"

kilobytes :: #force_inline proc(#any_int value: u64) -> u64 { return value * 1024 }
megabytes :: #force_inline proc(#any_int value: u64) -> u64 { return kilobytes(value) * 1024 }
gigabytes :: #force_inline proc(#any_int value: u64) -> u64 { return megabytes(value) * 1024 }
terabytes :: #force_inline proc(#any_int value: u64) -> u64 { return gigabytes(value) * 1024 }

atomic_compare_exchange :: #force_inline proc "contextless" (dst: ^$T, old, new: T) -> (was: T, ok: b32) {
    ok_: bool
    was, ok_ = intrinsics.atomic_compare_exchange_strong(dst, old, new)
    ok = cast(b32) ok_
    return was, ok
}

complete_previous_writes_before_future_writes :: #force_inline proc "contextless" () {
    // TODO(viktor): what should that actually be
    intrinsics.atomic_thread_fence(.Seq_Cst)
}

swap :: proc(a, b: ^$T) {
    b^, a^ = a^, b^
}

vec_cast :: proc { 
    cast_vec_2, cast_vec_3, cast_vec_4,
    cast_vec_v2, cast_vec_v3, cast_vec_v4,
}

@(require_results)
cast_vec_2 :: #force_inline proc($T: typeid, x, y: $E) -> [2]T where T != E {
    return {cast(T) x, cast(T) y}
}

@(require_results)
cast_vec_3 :: #force_inline proc($T: typeid, x, y, z: $E) -> [3]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z}
}

@(require_results)
cast_vec_4 :: #force_inline proc($T: typeid, x, y, z, w: $E) -> [4]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z, cast(T) w}
}

@(require_results)
cast_vec_v2 :: #force_inline proc($T: typeid, v:[2]$E) -> [2]T where T != E {
    return vec_cast(T, v.x, v.y)
}

@(require_results)
cast_vec_v3 :: #force_inline proc($T: typeid, v:[3]$E) -> [3]T where T != E {
    return vec_cast(T, v.x, v.y, v.z)
}

@(require_results)
cast_vec_v4 :: #force_inline proc($T: typeid, v:[4]$E) -> [4]T where T != E {
    return vec_cast(T, v.x, v.y, v.z, v.w)
}



min_vec :: proc { min_vec_2, min_vec_3}
max_vec :: proc { max_vec_2, max_vec_3}

@(require_results)
min_vec_2 :: #force_inline proc(a,b: [2]$E) -> [2]E where intrinsics.type_is_numeric(E) {
    return {min(a.x, b.x), min(a.y, b.y)}
}

@(require_results)
min_vec_3 :: #force_inline proc(a,b: [3]$E) -> [3]E where intrinsics.type_is_numeric(E) {
    return {min(a.x, b.x), min(a.y, b.y), min(a.z, b.z)}
}

@(require_results)
max_vec_2 :: #force_inline proc(a,b: [2]$E) -> [2]E where intrinsics.type_is_numeric(E) {
    return {max(a.x, b.x), max(a.y, b.y)}
}

@(require_results)
max_vec_3 :: #force_inline proc(a,b: [3]$E) -> [3]E where intrinsics.type_is_numeric(E) {
    return {max(a.x, b.x), max(a.y, b.y), max(a.z, b.z)}
}


abs_vec :: proc { abs_vec_2, abs_vec_3 }
@(require_results)
abs_vec_2 :: #force_inline proc(a: [2]$E) -> [2]E where intrinsics.type_is_numeric(E) {
    return {abs(a.x), abs(a.y)}
}
@(require_results)
abs_vec_3 :: #force_inline proc(a: [3]$E) -> [3]E where intrinsics.type_is_numeric(E) {
    return {abs(a.x), abs(a.y), abs(a.z)}
}


// TODO convert all of these to platform-efficient versions
sign :: proc{ sign_i, sign_u, sign_vi, sign_vu }

@(require_results)
sign_i :: #force_inline proc(i: i32) -> i32 {
    return i < 0 ? -1 : 1
}
@(require_results)
sign_u :: #force_inline proc(i: u32) -> i32 {
    return cast(i32) i < 0 ? -1 : 1
}
@(require_results)
sign_vi :: #force_inline proc(a: [2]i32) -> [2]i32 {
    return {sign(a.x), sign(a.y)}
}
@(require_results)
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

@(require_results)
round_f32 :: #force_inline proc(f: f32) -> i32 {
    if f < 0 do return cast(i32) -math.round(-f)
    return cast(i32) math.round(f)
}

@(require_results)
round_f32s :: #force_inline proc(fs: [$N]f32) -> [N]i32 where N > 1 {
    fs := fs
    for &e in fs do e = math.round(e) 
    return vec_cast(i32, fs)
}


floor :: proc {
    floor_f32,
    floor_f32_simd,
}

@(require_results)
floor_f32 :: #force_inline proc(f: f32) -> (i:i32) {
    return cast(i32) math.floor(f)
}

@(require_results)
floor_f32_simd :: #force_inline proc(fs: [$N]f32) -> [N]i32 {
    return vec_cast(i32, simd.to_array(simd.floor(simd.from_array(fs))))
}

ceil :: proc {
    ceil_f32,
    ceil_f32_simd,
}

@(require_results)
ceil_f32 :: #force_inline proc(f: f32) -> (i:i32) {
    return cast(i32) math.ceil(f)
}

@(require_results)
ceil_f32_simd :: #force_inline proc(fs: [$N]f32) -> [N]i32 {
    return vec_cast(i32, simd.to_array(simd.ceil(simd.from_array(fs))))
}




truncate :: proc {
    truncate_f32,
    truncate_f32s,
}

@(require_results)
truncate_f32 :: #force_inline proc(f: f32) -> i32 {
    return cast(i32) f
}

@(require_results)
truncate_f32s :: #force_inline proc(fs: [$N]f32) -> [N]i32 where N > 1 {
    return vec_cast(i32, fs)
}


sin :: proc {
    sin_f32,
    sin_f32_simd,	
}

@(require_results)
sin_f32 :: #force_inline proc(angle: f32) -> f32 {
    return math.sin(angle)
}

@(require_results)
sin_f32_simd :: #force_inline proc(angle: [$N]f32) -> [N]f32 {
    
}


cos :: proc {
    cos_f32,
}

@(require_results)
cos_f32 :: #force_inline proc(angle: f32) -> f32 {
    return math.cos(angle)
}


atan2 :: proc {
    atan2_f32,
}

@(require_results)
atan2_f32 :: #force_inline proc(y, x: f32) -> f32 {
    return math.atan2(y, x)
}

@(require_results)
rotate_left :: #force_inline proc(value: u32, amount: i32) -> u32 {
    // TODO: can odin insert rotate intrinsics
    masked := amount & 31
    return value << u32(masked) | value >> u32(32 - masked)
}

@(require_results)
rotate_right :: #force_inline proc(value: u32, amount: i32) -> u32 {
    // TODO: can odin insert rotate intrinsics
    masked := amount & 31
    return value >> u32(-masked) | value << u32(32 + masked)
}