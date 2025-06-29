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


view_memory_size :: proc(#any_int value: u64) -> (u64, string) {
    if value < Kilobyte do return value,            " b"
    if value < Megabyte do return value / Kilobyte, "kb"
    if value < Gigabyte do return value / Megabyte, "Mb"
    if value < Terabyte do return value / Gigabyte, "Gb"
    if value < Petabyte do return value / Terabyte, "Tb"
    if value < Exabyte  do return value / Petabyte, "Pb"
    
    return value , "?"
}

view_order_of_magnitude :: proc(value: $T, width: Maybe(u16) = 5, precision: Maybe(u8) = 2) -> (result: View, magnitude: string) {
    v: f64
    v, magnitude = order_of_magnitude(value)
    
    when intrinsics.type_is_integer(T) {
        v = round(f64, v * 100) * 0.01
    }

    result = view_float(v, width = width, precision = precision)
    
    return result, magnitude
}

view_percentage :: proc { view_percentage_parts, view_percentage_ratio }
view_percentage_parts :: proc(a, b: $N)   -> (result: View) { return view_percentage(cast(f64) a / cast(f64) b) }
view_percentage_ratio :: proc(value: $F) -> (result: View) {
    result = view_float(value * 100, precision = 0, width = 2)
    return result
}
