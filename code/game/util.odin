package game 

// IMPORTANT TODO(viktor): @common_file

@common import "base:intrinsics"
@common import "base:runtime"
@common import "core:fmt"
@common import "core:simd/x86"

was_pressed :: #force_inline proc(button: InputButton) -> (result:b32) {
    result = button.half_transition_count > 1 || button.half_transition_count == 1 && button.ended_down
    return result
}

White     :: v4{1   ,1    ,1      , 1}
Gray      :: v4{0.5 ,0.5  ,0.5    , 1}
Black     :: v4{0   ,0    ,0      , 1}
Blue      :: v4{0.08, 0.49, 0.72  , 1}
Yellow    :: v4{0.91, 0.81, 0.09  , 1}
Orange    :: v4{1   , 0.71, 0.2   , 1}
Green     :: v4{0   , 0.59, 0.28  , 1}
Red       :: v4{1   , 0.09, 0.24  , 1}
DarkGreen :: v4{0   , 0.07, 0.0353, 1}
DarkBlue  :: v4{0.08, 0.08, 0.2   , 1}

color_wheel :: [?]v4 {
    {0.94, 0.18, 0.34, 1},
    {0.63, 0.24, 0.6 , 1},
    {0.96, 0.51, 0.55, 1},
    {0.6 , 0.21, 0.16, 1},
    {0.61, 0.82, 0.56, 1},
    {0.5 , 0.6 , 0.28, 1},
    {0.01, 0.71, 0.67, 1},
    {0.9 , 0.76, 0.16, 1},
    {0.4 , 0.06, 0.95, 1},
    {0.25, 0.47, 0.6 , 1},
    {0.93, 0.49, 0.23, 1},
    {0.55, 0.85, 0.4 , 1},
    {0.89, 0.68, 0.87, 1},
    {0.86, 1   , 0.53, 1},
    {0.1 , 0.56, 0.89, 1},
    {0.18, 0.75, 0.44, 1},
}


@common f32x8 :: #simd[8]f32
@common u32x8 :: #simd[8]u32
@common i32x8 :: #simd[8]i32

@common f32x4 :: #simd[4]f32
@common i32x4 :: #simd[4]i32

@common pmm :: rawptr
@common umm :: uintptr

////////////////////////////////////////////////
// Atomics

// TODO(viktor): this is shitty with if expressions even if there is syntax for if-value-ok
@common atomic_compare_exchange :: #force_inline proc "contextless" (dst: ^$T, old, new: T) -> (was: T, ok: b32) {
    ok_: bool
    was, ok_ = intrinsics.atomic_compare_exchange_strong(dst, old, new)
    ok = cast(b32) ok_
    return was, ok
}

@common volatile_load      :: intrinsics.volatile_load
@common volatile_store     :: intrinsics.volatile_store
@common atomic_add         :: intrinsics.atomic_add
@common read_cycle_counter :: intrinsics.read_cycle_counter
@common atomic_exchange    :: intrinsics.atomic_exchange

@(common, enable_target_feature="sse2,sse")
complete_previous_writes_before_future_writes :: proc "contextless" () {
    x86._mm_sfence()
    x86._mm_lfence()
}
@(common, enable_target_feature="sse2")
complete_previous_reads_before_future_reads :: proc "contextless" () {
    x86._mm_lfence()
}

////////////////////////////////////////////////


@common Kilobyte :: runtime.Kilobyte
@common Megabyte :: runtime.Megabyte
@common Gigabyte :: runtime.Gigabyte
@common Terabyte :: runtime.Terabyte

@common align2     :: #force_inline proc "contextless" (value: $T) -> T { return (value +  1) &~  1 }
@common align4     :: #force_inline proc "contextless" (value: $T) -> T { return (value +  3) &~  3 }
@common align8     :: #force_inline proc "contextless" (value: $T) -> T { return (value +  7) &~  7 }
@common align16    :: #force_inline proc "contextless" (value: $T) -> T { return (value + 15) &~ 15 }
@common align32    :: #force_inline proc "contextless" (value: $T) -> T { return (value + 31) &~ 31 }
@common align_pow2 :: #force_inline proc "contextless" (value: $T, alignment: T) -> T { return (value + (alignment-1)) &~ (alignment-1) }


@common safe_truncate :: proc{
    safe_truncate_u64,
    safe_truncate_i64,
}

@common safe_truncate_u64 :: #force_inline proc(value: u64) -> u32 {
    assert(value <= 0xFFFFFFFF)
    return cast(u32) value
}

@common safe_truncate_i64 :: #force_inline proc(value: i64) -> i32 {
    assert(value <= 0x7FFFFFFF)
    return cast(i32) value
}

@common vec_cast :: proc { vcast_2, vcast_3, vcast_4, vcast_vec }

@(common, require_results) vcast_2 :: #force_inline proc($T: typeid, x, y: $E) -> [2]T where T != E {
    return {cast(T) x, cast(T) y}
}
@(common, require_results) vcast_3 :: #force_inline proc($T: typeid, x, y, z: $E) -> [3]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z}
}
@(common, require_results) vcast_4 :: #force_inline proc($T: typeid, x, y, z, w: $E) -> [4]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z, cast(T) w}
}
@(common, require_results) vcast_vec :: #force_inline proc($T: typeid, v:[$N]$E) -> (result: [N]T) where T != E {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = cast(T) v[i]
    }
    return result
}

@(require_results) min_vec :: #force_inline proc(a,b: [$N]$E) -> (result: [N]E) where intrinsics.type_is_numeric(E) {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = min(a[i], b[i])
    }
    return result
}
@(require_results) max_vec :: #force_inline proc(a,b: [$N]$E) -> (result: [N]E) where intrinsics.type_is_numeric(E) {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = max(a[i], b[i])
    }
    return result
}
@(require_results) abs_vec :: #force_inline proc(a: [$N]$E) -> (result: [N]E) where intrinsics.type_is_numeric(E) {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = abs(a[i])
    }
    return result
}

modular_add :: #force_inline proc(value:^$N, addend, one_past_maximum: N) where intrinsics.type_is_numeric(N) {
    value^ += addend
    if value^ >= one_past_maximum {
        value^ = 0
    }
}

@common swap :: #force_inline proc(a, b: ^$T ) { a^, b^ = b^, a^ }


@(common, disabled=ODIN_DISABLE_ASSERT)
assert :: #force_inline proc(condition: $T, message := #caller_expression(condition), loc := #caller_location) where intrinsics.type_is_boolean(T) {
    if !condition {
        // TODO(viktor): We are not a console application
        fmt.print(loc, "Assertion failed")
        if len(message) > 0 {
            fmt.println(":", message)
        }
        
        when ODIN_DEBUG {
            runtime.debug_trap()
        } else {
            runtime.trap()
        }
    }
}
