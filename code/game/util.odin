#+vet !unused-procedures
package game 

@(common="file") 
import "base:intrinsics"
import "base:runtime"
import "core:simd/x86"

was_pressed :: proc(button: InputButton) -> b32 {
    return button.half_transition_count > 1 || button.half_transition_count == 1 && button.ended_down
}

is_down :: proc(button: InputButton) -> b32 {
    return button.ended_down
}

// ------- Low Contrast
// #C1B28B gray

// ------- High Contrast
// #009052 green

// #2EC4B6 sea green
// #7C7A8B taupe gray
// #FF7E6B salmon

// #C92F5F rose
// #12a4cc blue
// #9B1144 wine
// #fe163d red
// #e46738 hazel 
// #ffb433 orange 

Isabelline :: v4{0.96, 0.95, 0.94, 1}
Jasmine    :: v4{0.95, 0.82, 0.52  , 1}
DarkGreen  :: v4{0   , 0.07, 0.0353, 1}
Emerald    :: v4{0.21, 0.82, 0.54, 1}

White     :: v4{1   ,1    ,1      , 1}
Gray      :: v4{0.5 ,0.5  ,0.5    , 1}
Black     :: v4{0   ,0    ,0      , 1}
Blue      :: v4{0.08, 0.49, 0.72  , 1}
Orange    :: v4{1   , 0.71, 0.2   , 1}
Green     :: v4{0   , 0.59, 0.28  , 1}
Red       :: v4{1   , 0.09, 0.24  , 1}
DarkBlue  :: v4{0.08, 0.08, 0.2   , 1}

color_wheel :: [?]v4 {
    v4{0.3, 0.22, 0.34, 1},
    v4{0.08, 0.38, 0.43, 1},
    v4{0.99, 0.96, 0.69, 1},
    v4{1, 0.5, 0.07, 1},
    v4{0.92, 0.32, 0.44, 1},
    v4{0.38, 0.55, 0.28, 1}, 
    v4{1, 0.56, 0.45, 1},
    
    v4{0.53, 0.56, 0.6, 1},
    v4{0.51, 0.2, 0.02, 1},
    v4{0.83, 0.32, 0.07, 1},
    v4{0.98, 0.63, 0.25, 1},
    v4{0.5, 0.81, 0.66, 1},
    v4{1, 0.62, 0.7, 1},
    v4{0.49, 0.82, 0.51, 1},
    v4{1, 0.84, 0.4, 1},
    v4{0, 0.62, 0.72, 1},
    v4{0.9, 0.9, 0.92, 1},
}


f32x8 :: #simd[8]f32
u32x8 :: #simd[8]u32
i32x8 :: #simd[8]i32

f32x4 :: #simd[4]f32
i32x4 :: #simd[4]i32

pmm :: rawptr
umm :: uintptr

////////////////////////////////////////////////
// Atomics

// @todo(viktor): this is shitty with if expressions even if there is syntax for if-value-ok
atomic_compare_exchange :: proc "contextless" (dst: ^$T, old, new: T) -> (was: T, ok: b32) {
    ok_: bool
    was, ok_ = intrinsics.atomic_compare_exchange_strong(dst, old, new)
    ok = cast(b32) ok_
    return was, ok
}

volatile_load      :: intrinsics.volatile_load
volatile_store     :: intrinsics.volatile_store
atomic_add         :: intrinsics.atomic_add
read_cycle_counter :: intrinsics.read_cycle_counter
atomic_exchange    :: intrinsics.atomic_exchange

// @todo(viktor): Is this correct? How can I validated this?
@(enable_target_feature="sse2,sse")
complete_previous_writes_before_future_writes :: proc "contextless" () {
    x86._mm_sfence()
    x86._mm_lfence()
}
@(enable_target_feature="sse2")
complete_previous_reads_before_future_reads :: proc "contextless" () {
    x86._mm_lfence()
}

////////////////////////////////////////////////


Byte     :: 1
Kilobyte :: 1024 * Byte
Megabyte :: 1024 * Kilobyte
Gigabyte :: 1024 * Megabyte
Terabyte :: 1024 * Gigabyte
Petabyte :: 1024 * Terabyte
Exabyte  :: 1024 * Petabyte

align8  :: proc "contextless" (value: $T) -> T { return (value + (8-1)) &~ (8-1) }
align16 :: proc "contextless" (value: $T) -> T { return (value + (16-1)) &~ (16-1) }
align_pow2 :: proc "contextless" (value: $T, alignment: T) -> T { return (value + (alignment-1)) &~ (alignment-1) }


safe_truncate :: proc{
    safe_truncate_u64,
    safe_truncate_i64,
}

safe_truncate_u64 :: proc(value: u64) -> u32 {
    assert(value <= 0xFFFFFFFF)
    return cast(u32) value
}

safe_truncate_i64 :: proc(value: i64) -> i32 {
    assert(value <= 0x7FFFFFFF)
    return cast(i32) value
}

rec_cast :: proc { rcast_2 }
@(require_results) rcast_2 :: proc($T: typeid, rec: $R/Rectangle([2]$E)) -> Rectangle([2]T) where T != E {
    return { vec_cast(T, rec.min), vec_cast(T, rec.max)}
}
vec_cast :: proc { vcast_2, vcast_3, vcast_4, vcast_vec }
@(require_results) vcast_2 :: proc($T: typeid, x, y: $E) -> [2]T where T != E {
    return {cast(T) x, cast(T) y}
}
@(require_results) vcast_3 :: proc($T: typeid, x, y, z: $E) -> [3]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z}
}
@(require_results) vcast_4 :: proc($T: typeid, x, y, z, w: $E) -> [4]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z, cast(T) w}
}
@(require_results) vcast_vec :: proc($T: typeid, v:[$N]$E) -> (result: [N]T) where T != E {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = cast(T) v[i]
    }
    return result
}

@(require_results) min_vec :: proc(a,b: [$N]$E) -> (result: [N]E) where intrinsics.type_is_numeric(E) {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = min(a[i], b[i])
    }
    return result
}
@(require_results) max_vec :: proc(a,b: [$N]$E) -> (result: [N]E) where intrinsics.type_is_numeric(E) {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = max(a[i], b[i])
    }
    return result
}
@(require_results) abs_vec :: proc(a: [$N]$E) -> (result: [N]E) where intrinsics.type_is_numeric(E) {
    #no_bounds_check #unroll for i in 0..<N {
        result[i] = abs(a[i])
    }
    return result
}

swap :: proc(a, b: ^$T ) { a^, b^ = b^, a^ }


unused :: proc "contextless" (_: $T) {}

@(disabled=ODIN_DISABLE_ASSERT)
assert :: proc(condition: $B, message := #caller_expression(condition), loc := #caller_location, prefix:= "Assertion failed") where intrinsics.type_is_boolean(B) {
    if !condition {
        // @todo(viktor): We are not a console application
        print("% %", loc, prefix)
        if len(message) > 0 {
            println(": %", message)
        }
        
        when ODIN_DEBUG {
             runtime.debug_trap()
        } else {
            runtime.trap()
        }
    }
}

order_of_magnitude :: proc(value: $T) -> (T, string) {
    when intrinsics.type_is_float(T) {
        if value < 1e-9  { return value * 1e12, "p"}
        if value < 1e-6  { return value * 1e9,  "n"}
        if value < 1e-3  { return value * 1e6,  "μ"} // @todo(viktor): fix the debug console encoding or font or whatever to actually display 'μ' correctly
        if value < 1e0   { return value * 1e3,  "m"}
    }
    
    if value < 1e3   { return value,        " "}
    if value < 1e6   { return value / 1e3,  "k"}
    if value < 1e9   { return value / 1e6,  "M"}
    
    when size_of(T) >= 8 {
        if value < 1e12  { return value / 1e9,  "G"}
        if value < 1e15  { return value / 1e12, "T"}
    }
    
    return value, "?"
}


format_memory_size :: proc(#any_int value: u64) -> (u64, string) {
    if value < Kilobyte  { return value,            " b"}
    if value < Megabyte  { return value / Kilobyte, "kb"}
    if value < Gigabyte  { return value / Megabyte, "Mb"}
    if value < Terabyte  { return value / Gigabyte, "Gb"}
    return value / Terabyte , "Tb"
}


format_order_of_magnitude_int :: proc(value: $T, info: FormatInfo = {}) -> (IntegerFormat, string) 
where intrinsics.type_is_integer(T) {
    v, magnitude := order_of_magnitude(value)
    return IntegerFormat{ v = v, info = info}, magnitude
}
format_order_of_magnitude_float :: proc(value: $T, info: FormatInfo = {}) -> (FloatFormat, string)
where intrinsics.type_is_float(T) {
    v, magnitude := order_of_magnitude(value)
    return FloatFormat{ v = v, info = info}, magnitude
}
        
format_percentage :: proc(value: f32) -> FloatFormat {
    return { v = round(f32, value * 100) * 0.01, info = { precision = 2, width = 5 } }
}

slice_from_parts :: proc { slice_from_parts_cast, slice_from_parts_direct }
slice_from_parts_cast :: proc "contextless" ($T: typeid, data: pmm, #any_int count: i64) -> []T {
    // :PointerArithmetic
    return (cast([^]T)data)[:count]
}
slice_from_parts_direct :: proc "contextless" (data: ^$T, #any_int count: i64) -> []T {
    // :PointerArithmetic
    return (cast([^]T)data)[:count]
}