package main

import "base:intrinsics"

kilobytes :: #force_inline proc(value: $N) -> N where intrinsics.type_is_numeric(N) && size_of(N) == 8 { return value*1024 }
megabytes :: #force_inline proc(value: $N) -> N where intrinsics.type_is_numeric(N) && size_of(N) == 8 { return kilobytes(value)*1024 }
gigabytes :: #force_inline proc(value: $N) -> N where intrinsics.type_is_numeric(N) && size_of(N) == 8 { return megabytes(value)*1024 }
terabytes :: #force_inline proc(value: $N) -> N where intrinsics.type_is_numeric(N) && size_of(N) == 8 { return gigabytes(value)*1024 }

swap :: #force_inline proc(a, b: ^$T) {
    b^, a^ = a^, b^
}

safe_truncate :: proc{
    safe_truncate_u64,
    safe_truncate_i64,
}

safe_truncate_u64 :: #force_inline proc(value: u64) -> u32 {
    assert(value <= 0xFFFFFFFF)
    return cast(u32) value
}

safe_truncate_i64 :: #force_inline proc(value: i64) -> i32 {
    assert(value <= 0x7FFFFFFF)
    return cast(i32) value
}