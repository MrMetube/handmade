#+vet !unused-procedures
#+no-instrumentation
package game

@(common="file")

import "base:intrinsics"
import "base:runtime"
import "core:time"

////////////////////////////////////////////////

@(init)
default_views :: proc "contextless" () {
    Default_Views[time.Duration] = proc (raw: pmm) -> (result: View_Proc_Result) {
        value := (cast(^time.Duration) raw)^
        result = view_time_duration(value)
        return result
    }
    
    Default_Views[time.Time] = proc (value: pmm) -> (result: View_Proc_Result) {
        value := (cast(^time.Time) value)^
        result = view_time(value)
        return result
    }
    
    Default_Views[runtime.Source_Code_Location] = proc (value: pmm) -> (result: View_Proc_Result) {
        value := (cast(^runtime.Source_Code_Location) value)^
        result = view_source_code_location(value)
        return result
    }
}

////////////////////////////////////////////////

// @todo(viktor): make precision and width parameters
view_percentage :: proc (a, b: $N)  -> (result: Temp_Views) { return view_percentage(cast(f64) a / cast(f64) b) }
view_percentage_ratio :: proc (value: $F) -> (result: Temp_Views) {
    begin_temp_views()
    append_temp_view(view_float(value * 100, precision = 2, width = 2))
    result = end_temp_views()
    return result
}

view_variable :: proc (value: $T, middle := " = ", expression := #caller_expression(value)) -> (Temp_Views) {
    begin_temp_views()
    append_temp_view(view_string(expression))
    append_temp_view(view_string(middle))
    append_temp_view(view_integer(value))
    return end_temp_views()
}

////////////////////////////////////////////////
// @todo(viktor): multi magnitude support, 10 Billion 583 Million 699 Thousand 496 and whatever
// @todo(viktor): should there be a view_debug which shows all the types instead of that being a flag on the format_context?

Magnitude :: struct ($T: typeid) { upper_bound: T, symbol: string }

Memory :: enum {
    bytes     = 0,
    kilobytes = 1,
    megabytes = 2,
    gigabytes = 3,
    petabytes = 4,
    exabytes  = 5,
}
bytes_table := [?] Magnitude (umm) {
    {1024,  "b"},
    {1024, "kb"},
    {1024, "Mb"},
    {1024, "Gb"},
    {1024, "Tb"},
    {1024, "Pb"},
    {   0, "Eb"},
}

Time_Unit :: enum {
    nanoseconds  = 0,
    microseconds = 1,
    milliseconds = 2,
    seconds      = 3,
    minutes      = 4,
    hours        = 5,
}
time_table := [?] Magnitude (time.Duration) {
    {1000, "ns"},
    {1000, "µs"},
    {1000, "ms"},
    {  60,  "s"},
    {  60,  "m"},
    {   0,  "h"},
}

view_magnitude_raw :: proc (value: $T, table: [] Magnitude (T), expand_lower := 0, precision: u8 = 0) -> (result: Temp_Views) {
    // @todo(viktor): there needs to be a better way to do this. make this best match strategy explicit
    begin_temp_views()
    
    view_best_magnitude :: proc (value: T, table: [] Magnitude (T)) -> (total_bound: Maybe(T)) {
        value := value
        
        total_bound = 1
        
        for magnitude, index in table {
            if index == len(table)-1 || abs(value) < magnitude.upper_bound {
                
                when intrinsics.type_is_integer(T) {
                    append_temp_view(view_integer(value))
                } else {
                    #assert(intrinsics.type_is_float(T))
                    append_temp_view(view_float(value, precision = 0))
                }
                append_temp_view(magnitude.symbol)
                
                return total_bound
            }
            value /= magnitude.upper_bound
            (&total_bound.(T))^ *= magnitude.upper_bound
        }
        
        return nil
    }
    
    value := value
    next := view_best_magnitude(value, table)
    
    expand_lower := expand_lower < 0 ? len(table) : expand_lower
    for bound, ok := next.? ; ok && expand_lower != 0 ; expand_lower -= 1 {
        append_temp_view(" ")
        
        value = modulus(value, bound)
        if value == 0 do break
        
        next = view_best_magnitude(value, table)
        bound, ok = next.?
    }
    
    // @todo(viktor): alternatively dont cutoff but show as decimal
    when false do if precision != 0 && next != 1 {
        below := table[(scale + best_index) - 1]
        rest := cast(f64) before / cast(f64) below.upper_bound
        append_temp_view(view_float(rest, precision = precision))
        append_temp_view(best_magnitude.symbol)
    }
    
    result = end_temp_views()
    return result
}

////////////////////////////////////////////////

amount_table_long := [?] Magnitude (u64) {
    {1000, ""},
    {1000, "Tsd."},
    {1000, "Mio."},
    {1000, "Mrd."},
    {1000, "Bio."},
    {1000, "Brd."},
    {1000, "Tr."},
    {0,    "Trd."},
}

amount_table_short := [?] Magnitude (u64) {
    {1000, ""},
    {1000, "K"},
    {1000, "M"},
    {1000, "B"},
    {1000, "T"},
    {   0, "Q"},
}

divider_table := [?] Magnitude (f64) {
    {1000, "."}, // quecto
    {1000, "."}, // ronto
    {1000, "."}, // yocto
    {1000, "."}, // zepto
    {1000, "."}, // atto
    {1000, "."}, // femto
    {1000, "."}, // pico
    {1000, "."}, // nano
    {1000, "."}, // micro
    {1000, "."}, // milli
    {1000, "."}, 
    {1000, "."}, // kilo
    {1000, "."}, // mega
    {1000, "."}, // giga
    {1000, "."}, // tera
    {1000, "."}, // peta
    {1000, "."}, // exa
    {1000, "."}, // zetta
    {1000, "."}, // yotta
    {1000, "."}, // ronna
    {   0, "."}, // quetta
}

Decimal_Amount :: enum {
    quecto,
    ronto,
    yocto,
    zepto,
    atto,
    femto,
    pico,
    nano,
    micro,
    milli,
    unit,
    kilo,
    mega,
    giga,
    tera,
    peta,
    exa,
    zetta,
    yotta,
    ronna,
    quetta,
}
Integer_Amount :: enum {
    unit,
    kilo,
    mega,
    giga,
    tera,
    peta,
    exa,
    zetta,
    yotta,
    ronna,
    quetta,
}

// @todo(viktor): width
view_magnitude :: proc (value: $T, precision: u8 = 0) -> (result: Temp_Views) where intrinsics.type_is_integer(T) {
    @(static, rodata)
    integer_table := [?] Magnitude (T) {
        {1000, ""}, 
        /* 
        {10, " "},  // unit
        {10, "da"}, // deca
        {10, "h"},  // hecta
        */
        {1000, "k"}, // kilo
        {1000, "M"}, // mega
        {1000, "G"}, // giga
        {1000, "T"}, // tera
        {1000, "P"}, // peta
        {1000, "E"}, // exa
        {1000, "Z"}, // zetta
        {1000, "Y"}, // yotta
        {1000, "R"}, // ronna
        {   0, "Q"}, // quetta
    }
    result = view_magnitude_raw(value, integer_table[:], precision = precision)
    return result
}
view_magnitude_decimal :: proc (value: $T, precision: u8 = 0) -> (result: Temp_Views) where intrinsics.type_is_float(T) {
    @(static, rodata)
    decimal_table := [?] Magnitude (T) {
        {1000, "q"}, // quecto
        {1000, "r"}, // ronto
        {1000, "y"}, // yocto
        {1000, "z"}, // zepto
        {1000, "a"}, // atto
        {1000, "f"}, // femto
        {1000, "p"}, // pico
        {1000, "n"}, // nano
        {1000, "µ"}, // micro
        {1000, "m"}, // milli
        /* {10, "m"}, // milli {10, "c"}, // centi {10, "d"}, // deci */
        {1000, ""}, 
        /* {10, "da"}, // deca {10, "h"},  // hecta */
        {1000, "k"}, // kilo
        {1000, "M"}, // mega
        {1000, "G"}, // giga
        {1000, "T"}, // tera
        {1000, "P"}, // peta
        {1000, "E"}, // exa
        {1000, "Z"}, // zetta
        {1000, "Y"}, // yotta
        {1000, "R"}, // ronna
        {   0, "Q"}, // quetta
    }
    // @todo(viktor): here a scale parameter would be useful
    result = view_magnitude_raw(value, decimal_table[Decimal_Amount.unit:], precision = precision)
    return result
}

////////////////////////////////////////////////
// Time

view_memory_size :: proc (#any_int value: umm, expand_lower := 0, precision: u8 = 0) -> (result: Temp_Views) {
    return view_magnitude_raw(value, bytes_table[:], expand_lower = expand_lower, precision = precision)
}

view_time_duration :: proc (value: time.Duration, expand_lower := 0, precision: u8 = 0) -> (result: Temp_Views) {
    return view_magnitude_raw(value, time_table[:], expand_lower = expand_lower, precision = precision)
}
view_seconds :: proc (value: f32, expand_lower := 0, precision: u8 = 0) -> (result: Temp_Views) {
    return view_time_duration(cast(time.Duration) (value * cast(f32) time.Second), expand_lower = expand_lower, precision = precision)
}

view_time :: proc (value: time.Time) -> (result: Temp_Views) {
    t := value
    y, mon, d := time.date(t)
    h, min, s := time.clock(t)
    ns := (t._nsec - (t._nsec/1e9 + time.UNIX_TO_ABSOLUTE)*1e9) % 1e9
    
    begin_temp_views()

    append_temp_view(view_integer(cast(i64) y,   width = 4))
    append_temp_view('-')
    if mon < .October {
        // @note(viktor): Workaround as we do not handle width combined with .LeadingZero flag correctly
        append_temp_view('0')
        append_temp_view(view_integer(cast(i64) mon, width = 1))
    } else {
        append_temp_view(view_integer(cast(i64) mon, width = 2))
    }
    append_temp_view('-')
    append_temp_view(view_integer(cast(i64) d,   width = 2))
    append_temp_view(' ')
    
    append_temp_view(view_integer(cast(i64) h,   width = 2))
    append_temp_view(':')
    append_temp_view(view_integer(cast(i64) min, width = 2))
    append_temp_view(':')
    append_temp_view(view_integer(cast(i64) s,   width = 2))
    append_temp_view('.')
    append_temp_view(view_integer((ns),          width = 9))
    append_temp_view(" +0000 UTC")
    
    result = end_temp_views()
    return result
}

////////////////////////////////////////////////

view_source_code_location :: proc (value: runtime.Source_Code_Location, show_procedure := false) -> (result: Temp_Views) {
    begin_temp_views()
    
    append_temp_view(value.file_path)
            
    when ODIN_ERROR_POS_STYLE == .Default {
        open  :: '(' 
        close :: ')'
    } else when ODIN_ERROR_POS_STYLE == .Unix {
        open  :: ':' 
        close :: ':'
    } else {
        #panic("Unhandled ODIN_ERROR_POS_STYLE")
    }
    
    append_temp_view(open)
    
    append_temp_view(view_integer(u64(value.line)))
    if value.column != 0 {
        append_temp_view(':')
        append_temp_view(view_integer(u64(value.column)))
    }

    append_temp_view(close)
    
    if show_procedure {
        append_temp_view(value.procedure)
    }
    
    result = end_temp_views()
    return result
}