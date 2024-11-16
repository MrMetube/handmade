package util

import "base:intrinsics"

kilobytes :: proc(value: $N) -> N where intrinsics.type_is_numeric(N) && size_of(N) == 8 { return value*1024 }
megabytes :: proc(value: $N) -> N where intrinsics.type_is_numeric(N) && size_of(N) == 8 { return kilobytes(value)*1024 }
gigabytes :: proc(value: $N) -> N where intrinsics.type_is_numeric(N) && size_of(N) == 8 { return megabytes(value)*1024 }
terabytes :: proc(value: $N) -> N where intrinsics.type_is_numeric(N) && size_of(N) == 8 { return gigabytes(value)*1024 }

swap :: proc(a, b: ^$T) {
    b^, a^ = a^, b^
}

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