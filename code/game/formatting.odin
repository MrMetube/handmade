#+vet !unused-procedures
package game

@(common="file")

import "base:intrinsics"


order_of_magnitude :: proc(value: $T) -> (f64, string) {
    value := cast(f64) value
    if value < 1e-9 do return value * 1e12, "p"
    if value < 1e-6 do return value * 1e9,  "n"
    if value < 1e-3 do return value * 1e6,  "μ"
    if value < 1e0  do return value * 1e3,  "m"
    if value < 1e3  do return value * 1e0,  ""
    if value < 1e6  do return value * 1e-3,  "k"
    if value < 1e9  do return value * 1e-6,  "M"
    if value < 1e12 do return value * 1e-9,  "G"
    if value < 1e15 do return value * 1e-12, "T"
    if value < 1e18 do return value * 1e-15, "P"
    if value < 1e21 do return value * 1e-18, "E"
    
    return value, "?"
}


format_memory_size :: proc(#any_int value: u64) -> (u64, string) {
    if value < Kilobyte do return value,            " b"
    if value < Megabyte do return value / Kilobyte, "kb"
    if value < Gigabyte do return value / Megabyte, "Mb"
    if value < Terabyte do return value / Gigabyte, "Gb"
    if value < Petabyte do return value / Terabyte, "Tb"
    if value < Exabyte  do return value / Petabyte, "Pb"
    
    return value , "?"
}

format_order_of_magnitude :: proc(value: $T, format: FormatElement = {}) -> (result: FormatElement, magnitude: string) {
    v: f64
    v, magnitude = order_of_magnitude(value)
    
    result = format
    result.kind = .Float
    
    when intrinsics.type_is_integer(T) {
        v = round(f64, v * 100) * 0.01
        if !result.precision_set {
            result.precision_set = true
            result.precision = 2
        }
    }
    
    if !result.width_set {
        result.width_set = true
        result.width = 5
    }
    
    number := format_number(v)
    result.data = number.data
    result.bytes = number.bytes
    
    return result, magnitude
}
                
format_percentage :: proc(value: f32) -> (result: FormatElement) {
    result.kind = .Float
    
    number := format_number(value)
    result.data = number.data
    result.bytes = number.bytes
    
    result.precision = 2
    result.precision_set = true
    result.width = 5
    result.width_set = true
    
    return result
}
