#+vet !unused-procedures
#+no-instrumentation
package game

@(common="file")

import "core:fmt"
import "base:runtime"
import "core:time"

@(init)
view_init :: proc "contextless" () {
    context = runtime.default_context()
    
    if fmt._user_formatters == nil {
        user_formatters, err := new(map[typeid]fmt.User_Formatter, context.allocator)
        assert(err == nil)
        fmt.set_user_formatters(user_formatters)
    }
    
    err := fmt.register_user_formatter(View_Magnitude, View_Magnitude_Formatter)
    assert(err == .None)
    err = fmt.register_user_formatter(View_Percentage, View_Percentage_Formatter)
    assert(err == .None)
}

View_Magnitude :: struct {
    value:     f64,
    symbol:    string,
    precision: int,
}

View_Percentage :: struct {
    value: f64,
}

Magnitude :: struct($T: typeid) {
    upper_bound: T,
    symbol:      string,
}

Memory_Unit :: enum {
    Bytes,
    Kilobytes,
    Megabytes,
    Gigabytes,
    Terabytes,
    Petabytes,
    Exabytes,
}

Time_Unit :: enum {
    Nanoseconds,
    Microseconds,
    Milliseconds,
    Seconds,
    Minutes,
    Hours,
}

memory_magnitudes := [?]Magnitude(u64) {
    {1024, "B"},
    {1024, "kB"},
    {1024, "MB"},
    {1024, "GB"},
    {1024, "TB"},
    {1024, "PB"},
    {0,    "EB"},
}

duration_magnitudes := [?]Magnitude(time.Duration) {
    {1000, "ns"},
    {1000, "us"},
    {1000, "ms"},
    {60,   "s"},
    {60,   "min"},
    {0,    "h"},
}

amount_magnitudes := [?]Magnitude(u64) {
    {1000, ""},
    {1000, "K"},
    {1000, "M"},
    {1000, "B"},
    {1000, "T"},
    {0,    "Q"},
}

view_percentage :: proc { view_percentage_value, view_percentage_division }

view_percentage_division :: proc (dividend: $T, denominator: T) -> View_Percentage {
    value: f64
    if denominator != 0 do value = cast(f64)dividend / cast(f64)denominator
    return { value = value }
}

view_percentage_value :: proc (value: $T) -> View_Percentage {
    return { value = cast(f64)value }
}

View_Percentage_Formatter :: proc (info: ^fmt.Info, arg: any, verb: rune) -> bool {
    if verb != 'v' && verb != 'f' do return false
    view := cast(^View_Percentage)arg.data
    
    if !info.prec_set {
        info.prec = 2
        info.prec_set = true
    }
    fmt.fmt_float(info, view.value * 100, 64, 'f')
    fmt.fmt_rune(info, '%', 'v')
    return true
}

View_Magnitude_Formatter :: proc (info: ^fmt.Info, arg: any, verb: rune) -> bool {
    if verb != 'v' && verb != 'f' do return false
    view := cast(^View_Magnitude)arg.data
    
    if !info.prec_set {
        info.prec = view.precision
        info.prec_set = true
    }
    fmt.fmt_float(info, view.value, 64, 'f')
    fmt.fmt_string(info, view.symbol, 'v')
    return true
}

view_magnitude :: proc (value: $T, table: []Magnitude(T), first, last: int, precision := 0) -> View_Magnitude {
    assert(0 <= first && first < last && last <= len(table))
    assert(precision >= 0)
    
    scaled := cast(f64)value
    for magnitude, relative_index in table[first:last] {
        index := first + relative_index
        if index == last-1 || abs(scaled) < cast(f64)magnitude.upper_bound {
            return { value = scaled, symbol = magnitude.symbol, precision = precision }
        }
        scaled /= cast(f64)magnitude.upper_bound
    }
    
    unreachable()
}

view_memory_size :: proc (#any_int value: u64, first := Memory_Unit.Bytes, last := Memory_Unit.Exabytes, precision := 0) -> View_Magnitude {
    return view_magnitude(value, memory_magnitudes[:], int(first), int(last)+1, precision)
}

view_time_duration :: proc (value: time.Duration, first := Time_Unit.Nanoseconds, last := Time_Unit.Hours, precision := 0) -> View_Magnitude {
    return view_magnitude(value, duration_magnitudes[:], int(first), int(last)+1, precision)
}

view_seconds :: proc (value: f32, precision := 0) -> View_Magnitude {
    return view_time_duration(cast(time.Duration)(value * cast(f32)time.Second), precision = precision)
}

view_amount :: proc (#any_int value: u64, precision := 0) -> View_Magnitude {
    return view_magnitude(value, amount_magnitudes[:], 0, len(amount_magnitudes), precision)
}