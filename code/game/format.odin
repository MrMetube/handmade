#+vet !unused-procedures
// #+no-instrumentation
package game

@(common="file")

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:unicode/utf8"
import "core:fmt"
import "core:mem"

// @volatile This breaks if in the midst of a print we start another print on the same thread. we could use a cursor to know from where onwards we can use the buffer.
@(thread_local) console_buffer: [128 * Megabyte] u8

////////////////////////////////////////////////

/* 
    Can we abstract all these writes to allocators and dynamic arrays of them?
    Can we make a "file_allocator" that maps its memory to a file?
 */

@(printlike)
print_asdjlasd :: proc (_: string, args: ..any, flags: Format_Context_Flags = {}, console := os.stdout) {
}
@(printlike)
print_asdjlasasdadd :: proc (aaaaa,bbbb,bbbccc: string, args: ..any, flags: Format_Context_Flags = {}, console := os.stdout) {
}
@(printlike)
print_to_console :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, console := os.stdout) {
    result := format_string(buffer = console_buffer[:], format = format, args = args, flags = flags)
    os.write(console, transmute([]u8) result)
}

@(printlike)
print_to_allocator :: proc (allocator: runtime.Allocator, format: string, args: ..any, flags: Format_Context_Flags = {}) -> (result: string) {
    s := format_string(buffer = console_buffer[:], format = format, args = args, flags = flags)
    buffer := make([]u8, len(s), allocator)
    copy(buffer, s)
    result = transmute(string) buffer
    return result
}

////////////////////////////////////////////////

print  :: print_to_console
aprint :: print_to_allocator
@(printlike) tprint :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, allocator := context.temp_allocator) -> (result: string) { return print_to_allocator(allocator = allocator, format = format, args = args, flags = flags) }
@(printlike) sprint :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, allocator := context.allocator)      -> (result: string) { return print_to_allocator(allocator = allocator, format = format, args = args, flags = flags) }

////////////////////////////////////////////////

/* @todo(viktor): 
    - make ryu able to print fixed precision f32s
    - store defaults for floats, ints, structs, arrays and pointers explicitly
    - push context and defered pop context? to override defaults
*/

////////////////////////////////////////////////

Default_Views:      map[typeid] View_Proc
View_Proc        :: proc (value: pmm) -> View_Proc_Result
View_Proc_Result :: union{ View, Temp_Views, any }

////////////////////////////////////////////////

Temp_Views :: distinct [] View

View :: struct {
    value: any,

    // @todo(viktor): width only makes sense for single line values of fixed size, so maybe make it exclusive with multiline
    // @todo(viktor): extract width and pad_right_side into a special view, that wraps an any value, thereby also allowing multiline to correctly handle padding and alignment
    width:          u16,
    pad_right_side: b8,

    // @todo(viktor): ??? copy over format_context_flags from context and let a format element override the context for its data
    
    info: union {
        View_Integer,
        View_Float,
        View_Pointer,
        
        // @todo(viktor): View_String escaped (or as hex)?
        
        View_Struct,
        View_Array,
    },
}

View_Integer :: struct {
    value_size_in_bytes: int,
    flags:         Format_Number_Flags,
    positive_sign: Format_Number_Sign,
    
    base:      u8,
    is_signed: b8,
    
    /* 
    minimum_digits = 1;
    padding = 48;
    digits_per_comma = 0;
    comma_string = "";
    */
}
View_Float :: struct {
    value_size_in_bytes: int,
    flags:         Format_Number_Flags,
    positive_sign: Format_Number_Sign,
    
    precision_set: b8,
    precision:     u8,
    kind:          Format_Float_Kind,
    /* 
    -1,     // precision ?
    -1,     // ??
    YES,    // ??
    DECIMAL // decimal, scientific ?
    */
}
View_Pointer :: struct {
    // @todo(viktor): view_pointer is the only place where ctx.max_depth is relevant, so maybe just say, 
    /* 
    base: u8 = 16,
    minimum_digits: u8 = 1,
    padding: u8 = 48,
    digits_per_comma: u8 = 4,
    comma_string: string = "_",
     */
    // Maybe:
    //   follow_pointers_until_depth_reaches 
    //   or for i.e. double-linked-lists
    //   follow_unique/unseen_pointers_until_depth_reached
}
View_Struct :: struct {
    /* 
    draw_type_name: b32,
    separator_between_name_and_value: string, // " = "
    
    use_long_form_if_more_than_this_many_members: u8, // 5
    short_form_separator_between_fields: string, // ", "
    long_form_separator_between_fields: string, // "; "
    
    struct_begin_string: string, // "{"
    struct_end_string:   string, // "}"
    
    indentation_width: i32, // 4
    use_newlines_if_long_form: b32,
     */
}
View_Array :: struct {
    /* 
    array_begin_string: string, // "{"
    array_end_string:   string, // "}"
    array_separator:    string, // ", "
    
    printing_stopped_early_string: string, // "..."
    draw_separator_after_last_element: bool, // false;
    stop_printing_after_this_many_elements: i32, // 100;
     */
}

Format_Number_Sign   :: enum u8 { Never, Plus, Space }
Format_Float_Kind    :: enum u8 { Shortest, MaximumPercision, Scientific }
Format_Number_Flags  :: bit_set[ enum u8 { LeadingZero, PrependBaseSpecifier, Uppercase }; u8 ]
Format_Context_Flags :: bit_set[ enum u8 { PrependTypes, Multiline, AppendZero }; u8 ]

////////////////////////////////////////////////

View_Multiline_Format :: enum { Indent, Outdent, Linebreak }

// @todo(viktor): this could also take an enum which is then interpreted as a float
// @todo(viktor): this could also take complex numbers and quaternions
view_float :: proc (
    value: any, 
    width: u16 = 0, pad_right_side: b8 = false,
    flags: Format_Number_Flags = {}, positive_sign: Format_Number_Sign = .Never, 
    precision: Maybe(u8) = nil, kind: Format_Float_Kind = .Shortest,
    size := 0,
) -> (result: View) {
    type_info := type_info_of(value.id)
    core_info := runtime.type_info_core(type_info)
    _ = core_info.variant.(runtime.Type_Info_Float)
    
    result.value.data = value.data
    result.value.id = core_info.id
    
    result.width = width
    result.pad_right_side = pad_right_side
    
    size := size != 0 ? size : type_info.size
    info := View_Float {
        value_size_in_bytes = size,
        flags = flags,
        positive_sign = positive_sign,
        
        kind = kind,
    }
    
    if precision, ok := precision.?; ok {
        info.precision_set = true
        info.precision = precision
    }
    
    result.info = info
    
    return result
}

view_integer :: proc (
    value: any, 
    width: u16 = 0, pad_right_side: b8 = false,
    flags: Format_Number_Flags = {}, positive_sign: Format_Number_Sign = .Never, 
    base: u8 = 10,
    size := 0,
) -> (result: View) {
    type_info := type_info_of(value.id)
    core_info := runtime.type_info_core(type_info)
    int_info  := core_info.variant.(runtime.Type_Info_Integer)
    
    result.value.data = value.data
    result.value.id = core_info.id
    
    result.width = width
    result.pad_right_side = pad_right_side
    
    size := size != 0 ? size : type_info.size
    result.info = View_Integer {
        base = base,
        value_size_in_bytes = size,
        
        is_signed = auto_cast int_info.signed,
    }
    
    return result
}

view_pointer :: proc (
    value: any, 
    flags: Format_Number_Flags = {},
    
    base: u8 = 16,
    minimum_digits: u8 = 1,
    padding: u8 = 48,
    digits_per_comma: u8 = 4,
    comma_string: string = "_",
) -> (result: View_Pointer) {
    unimplemented()
}

////////////////////////////////////////////////
// @todo(viktor): implement all cases
// @todo(viktor): use temp views here where needed

/* 
A list of currently-supported views are below:
 - list? for pointer graphs like linked lists

 - `raw(expr)`: Ignores all views used in `expr`, including those automatically applied by type views.
*/

view_raw :: proc (value: $T) -> (result: View) {}

// - `sequence(expr)`: Interprets `expr` as an integer, encoding how many sub-expressions `expr` should expand to produce. This can be used in combination with the `table` view to easily generate tables, indexing amongst many arrays.
view_sequence :: proc (value: $T) { unimplemented() }
// - `rows(expr, ...)`: Interpreting all post-`expr` arguments as member names, only expands to show those members of `expr`.
view_rows :: proc (value: $T) { unimplemented() }
// - `omit(expr, ...)`: Interpreting all post-`expr` arguments as member names, expands to show all members of `expr`, except those with matching names.
view_omit :: proc (value: $T) { unimplemented() }

view_array :: proc (value: ^$T, count: $N) -> (result: [] T) {
    return (cast([^]T) value)[:count]
}

////////////////////////////////////////////////

Format_Context :: struct {
    dest: String_Builder,
    
    max_depth: u32,
    indentation: string,
    indentation_depth: u32,
    flags: Format_Context_Flags,
    
    /* 
    indentation_depth = 2;
    log_runtime_errors = true;
    */
} 

////////////////////////////////////////////////


@(private="file") temp_view_arena:     mem.Arena
@(private="file") temp_view_allocator: mem.Allocator

@(private="file") temp_view_buffer:       [1024] View
@(private="file") temp_view_inside_block: bool
@(private="file") temp_view_start_index:  u32
@(private="file") temp_view_next_index:   u32


begin_temp_views :: proc (width: Maybe(u16) = nil) {
    assert(!temp_view_inside_block)
    temp_view_inside_block = true
    // @incomplete what about width for TempViews, handle in format_string
    temp_view_start_index = temp_view_next_index
    
    if temp_view_allocator.procedure == nil {
        // @todo(viktor): find a better place for this
        buffer := make([] u8, 64*4096)
        mem.arena_init(&temp_view_arena, buffer)
        temp_view_allocator = mem.arena_allocator(&temp_view_arena)
        assert(temp_view_allocator.procedure != nil)
    }
}

append_temp_view :: proc (value: any) {
    assert(temp_view_inside_block)
    
    view: View
    switch data in value {
      case View: view = data
      case:      view = { value = data }
    }
    
    // @note(viktor): Sadly we cannot return pointers to stack variables from a view_* proc therefore we need to make a copy of the value
    info := type_info_of(view.value.id)
    
    size := info.size
    copied := make([] u8, size, temp_view_allocator)
    copy(copied, slice_from_parts_cast(u8, view.value.data, size))
    view.value.data = raw_data(copied)
    
    temp_view_buffer[temp_view_next_index] = view
    temp_view_next_index += 1
    assert(temp_view_next_index < len(temp_view_buffer))
}

end_temp_views :: proc () -> (result: Temp_Views) {
    assert(temp_view_inside_block)
    temp_view_inside_block = false
    
    result = cast(Temp_Views) temp_view_buffer[temp_view_start_index : temp_view_next_index]
    return result
}

////////////////////////////////////////////////

@(printlike)
format_cstring :: proc (buffer: []u8, format: string, args: ..any, flags := Format_Context_Flags {}) -> (result: cstring) {
    s := format_string(buffer, format, ..args, flags = flags + { .AppendZero })
    result = cast(cstring) raw_data(s)
    return result
}

@(printlike)
format_string :: proc (buffer: []u8, format: string, args: ..any, flags := Format_Context_Flags{}) -> (result: string) {
    ctx := Format_Context { 
        dest  = make_string_builder_buffer(buffer),
        flags = flags,
        
        indentation = "  ",
        max_depth = 8,
    }
    
    // :PrintlikeChecking @volatile 
    // the loop structure is copied in the metaprogram to check the arg count, any changes here need to be propagated to there
    arg_index: u32
    start_of_text: int
    for index: int; index < len(format); index += 1 {
        if format[index] == '%' {
            part := format[start_of_text:index]
            if part != "" {
                format_any(&ctx, part)
            }
            start_of_text = index+1
            
            if index+1 < len(format) && format[index+1] == '%' {
                index += 1
                // @note(viktor): start_of_text now points at the percent sign and will append it next time saving processing one view
            } else {
                arg := args[arg_index]
                arg_index += 1
                
                // @incomplete Would be ever want to display a raw View? if so put in a flag to make it use the normal path
                format_any(&ctx, arg)
            }
        }
    }
    
    end := format[start_of_text:]
    format_any(&ctx, end)
    
    assert(arg_index == auto_cast len(args))
    
    if .AppendZero in flags {
        format_any(&ctx, rune(0))
    }
    
    temp_view_next_index = 0
    // Sigh...
    free_all(temp_view_allocator)
    return to_string(ctx.dest)
}

format_any :: proc (ctx: ^Format_Context, arg: any) {
    if ctx.max_depth <= 0 do return
    
    // @todo(viktor): copy into temp and then apply padding/width 
    @(static)
    temp_buffer: [4096*16] u8
    
    temp := make_string_builder(temp_buffer[:])
    defer append(&ctx.dest, to_string(temp))
    // padding := max(0, cast(i32) view.width - cast(i32) temp.count)
    // if       !view.pad_right_side && view.width != 0 do for _ in 0..<padding do append(&ctx.dest, ' ')
    // defer if  view.pad_right_side && view.width != 0 do for _ in 0..<padding do append(&ctx.dest, ' ')
    
    switch value in arg {
      case any:    format_any(ctx, value)
      case typeid: draw_type(ctx, type_info_of(arg.id))
      
      case nil:    draw_pointer(ctx, nil)
      case rawptr: draw_pointer(ctx, value)
      
      case b8:   append(&temp, value ? "true" : "false")
      case b16:  append(&temp, value ? "true" : "false")
      case b32:  append(&temp, value ? "true" : "false")
      case b64:  append(&temp, value ? "true" : "false")
      case bool: append(&temp, value ? "true" : "false")
      
      case rune:
        // @todo(viktor): maybe do this myself
        buf, count := utf8.encode_rune(value)
        bytes := buf[:count]
        append(&temp, bytes)
        
      case string:    append(&temp, value)
      case cstring:   append(&temp, string(value))
      case string16:  append(&temp, fmt.tprint(value))
      case cstring16: append(&temp, fmt.tprint(value))
       
      case u8:      draw_unsigned_integer(&temp, view_integer(value))
      case u16:     draw_unsigned_integer(&temp, view_integer(value))
      case u32:     draw_unsigned_integer(&temp, view_integer(value))
      case u64:     draw_unsigned_integer(&temp, view_integer(value))
      case uint:    draw_unsigned_integer(&temp, view_integer(value))
      case uintptr: draw_unsigned_integer(&temp, view_integer(value))
      case u128:    unimplemented() // @incomplete
        
      case i8:   draw_signed_integer(&temp, view_integer(value))
      case i16:  draw_signed_integer(&temp, view_integer(value))
      case i32:  draw_signed_integer(&temp, view_integer(value))
      case i64:  draw_signed_integer(&temp, view_integer(value))
      case int:  draw_signed_integer(&temp, view_integer(value))
      case i128: unimplemented() // @incomplete
        
      // @todo(viktor): endianess
      case f16: format_float(&temp, view_float(value, size = size_of(f16)))
      case f32: format_float(&temp, view_float(value, size = size_of(f32)))
      case f64: format_float(&temp, view_float(value, size = size_of(f64)))
      
      case complex32: 
        format_any(ctx, real(value))
        format_any(ctx, view_float(imag(value), positive_sign = .Plus))
        format_any(ctx, 'i')
      case complex64: 
        format_any(ctx, real(value))
        format_any(ctx, view_float(imag(value), positive_sign = .Plus))
        format_any(ctx, 'i')
      case complex128:
        format_any(ctx, real(value))
        format_any(ctx, view_float(imag(value), positive_sign = .Plus))
        format_any(ctx, 'i')
      
      case quaternion64: 
        format_any(ctx, real(value))
        format_any(ctx, view_float(imag(value), positive_sign = .Plus))
        format_any(ctx, 'i')
        format_any(ctx, view_float(jmag(value), positive_sign = .Plus))
        format_any(ctx, 'j')
        format_any(ctx, view_float(kmag(value), positive_sign = .Plus))
        format_any(ctx, 'k')
      case quaternion128: 
        format_any(ctx, real(value))
        format_any(ctx, view_float(imag(value), positive_sign = .Plus))
        format_any(ctx, 'i')
        format_any(ctx, view_float(jmag(value), positive_sign = .Plus))
        format_any(ctx, 'j')
        format_any(ctx, view_float(kmag(value), positive_sign = .Plus))
        format_any(ctx, 'k')
      case quaternion256:
        format_any(ctx, real(value))
        format_any(ctx, view_float(imag(value), positive_sign = .Plus))
        format_any(ctx, 'i')
        format_any(ctx, view_float(jmag(value), positive_sign = .Plus))
        format_any(ctx, 'j')
        format_any(ctx, view_float(kmag(value), positive_sign = .Plus))
        format_any(ctx, 'k')
      
      case Temp_Views: 
        for view in value do format_any(ctx, view)
      
      case View:
        switch info in value.info {
          case:
            // @todo(viktor): We are ignoring the other fields for now
            format_any(ctx, value.value)
          case View_Integer:
            if info.is_signed do draw_signed_integer(&temp,   value)
            else do              draw_unsigned_integer(&temp, value)
          
          case View_Float:
            format_float(&temp, value)
            
          case View_Array, View_Struct, View_Pointer:
            unimplemented()
        }
        /* case .Indent:
            assert(.Multiline in ctx.flags)
            ctx.indentation_depth += 1
            
        case .Outdent:
            assert(.Multiline in ctx.flags)
            ctx.indentation_depth -= 1
            
        case .Linebreak:
            assert(.Multiline in ctx.flags)
            append(&ctx.dest, "\n")
            for _ in 0..<ctx.indentation_depth do append(&ctx.dest, ctx.indentation) 
        */
      
        
      case:
        type_info := type_info_of(value.id)
        
        switch variant in type_info.variant {
          case  runtime.Type_Info_Any,
                runtime.Type_Info_Type_Id,
                
                runtime.Type_Info_Rune,
                runtime.Type_Info_String,
                
                runtime.Type_Info_Boolean, 
                runtime.Type_Info_Integer, 
                runtime.Type_Info_Float,
               
                runtime.Type_Info_Complex, 
                runtime.Type_Info_Quaternion: unreachable()
            
          case runtime.Type_Info_Pointer:
            data := (cast(^pmm) value.data)^
            draw_pointer(ctx, data, variant.elem)
            
          case runtime.Type_Info_Multi_Pointer:
            data := (cast(^pmm) value.data)^
            format_optional_type(ctx, value.id)
            draw_pointer(ctx, data, variant.elem)
          
          case runtime.Type_Info_Named:
            // @important @todo(viktor): If the struct is an alias like v4 :: [4]f32 we currently print both types. but we should only print the alias
            if default, ok := Default_Views[value.id]; ok {
                format_any(ctx, default(value.data))
            } else {
                // @todo(viktor): only when in debug mode
                // append(&temp, variant.name)
                // format_any(ctx, ' ')
                format_any(ctx, any{data = value.data, id = variant.base.id})
            }
            
          case runtime.Type_Info_Struct:
            draw_struct(ctx, transmute(RawAny) value, variant)
            
          case runtime.Type_Info_Union:
            format_union(ctx, value.id, value.data, variant)
            
          case runtime.Type_Info_Dynamic_Array:
            slice := cast(^RawSlice) value.data
            raw_slice := RawAny{slice.data, value.id}
            draw_array(ctx, raw_slice, variant.elem, slice.len)
            
          case runtime.Type_Info_Slice:
            slice := cast(^RawSlice) value.data
            raw_slice := RawAny{slice.data, value.id}
            draw_array(ctx, raw_slice, variant.elem, slice.len)
            
          case runtime.Type_Info_Array:
            draw_array(ctx, transmute(RawAny) value, variant.elem, variant.count)
            
          case runtime.Type_Info_Matrix:
            format_matrix(ctx, value.id, value.data, variant.elem, variant.column_count, variant.row_count, variant.layout == .Row_Major)
          
          ////////////////////////////////////////////////
          ////////////////////////////////////////////////
          ////////////////////////////////////////////////
          // unimplemented - fallback to fmt
          
          case runtime.Type_Info_Enum:
            append(&temp, fmt.tprint(value))
            
          /* 
            . maps:              map[key0 = value0, key1 = value1, ...]
            . enumerated array   [key0 = elem0, key1 = elem1, key2 = elem2, ...]
            . bit sets           {key0 = elem0, key1 = elem1, ...}
           */  
          case runtime.Type_Info_Enumerated_Array:
            append(&temp, fmt.tprint(value))
          case runtime.Type_Info_Bit_Set:
            append(&temp, fmt.tprint(value))
          case runtime.Type_Info_Bit_Field:
            append(&temp, fmt.tprint(value))
          case runtime.Type_Info_Map:
            append(&temp, fmt.tprint(value))
            
          case runtime.Type_Info_Parameters:
            append(&temp, fmt.tprint(value))
          case runtime.Type_Info_Procedure:
            append(&temp, fmt.tprint(value))
          case runtime.Type_Info_Simd_Vector:
            append(&temp, fmt.tprint(value))
          case runtime.Type_Info_Soa_Pointer:
            append(&temp, fmt.tprint(value))
          
          case: 
            append(&temp, fmt.tprint(value))
            unimplemented("This value is not handled yet")
        }
    }
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

format_multiline_formatting :: proc (ctx: ^Format_Context, kind: View_Multiline_Format) {
    if ctx.max_depth <= 0 do return
    
    if .Multiline in ctx.flags {
        format_any(ctx, kind)
    }
}

format_optional_type :: proc (ctx: ^Format_Context, type: typeid) {
    if ctx.max_depth <= 0 do return
    
    if .PrependTypes in ctx.flags {
        draw_type(ctx, type_info_of(type))
        format_any(ctx, ' ')
    }
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

@(private="file") DigitsLowercase := "0123456789abcdefghijklmnopqrstuvwxyz"
@(private="file") DigitsUppercase := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

// @todo(viktor): 
// This is wrong when we use the format_integer subroutine view.flags += {.LeadingZero}
// as hexadecimal 0h (endianess relevant?)
format_float :: format_float_with_ryu when true else format_float_badly
format_float_with_ryu :: proc (dest: ^String_Builder, view: View) {
    precision: u32 = 6
    info := view.info.(View_Float)
    if info.precision_set do precision = cast(u32) info.precision
    
    buffer := rest(dest^)
    size := info.value_size_in_bytes
    
    if size == 8 {
        float := view.value.(f64)
        result := d2fixed_buffered(float, precision, buffer)
        // set_len(dest, len(dest) + len(result))
        dest.count += auto_cast len(result)
    } else if size == 4 {
        float := view.value.(f32)
        when false {
            result := f2s_buffered(float, buffer)
        } else {
            result := d2fixed_buffered(cast(f64) float, precision, buffer)
        }
        // set_len(dest, len(dest) + len(result))
        dest.count += auto_cast len(result)
    } else if size == 2 {
        // float := view.value.(f16)
        unimplemented()
    } else do panic("convert the general algorithm from ryu you laze bum")
    
    if .Uppercase in info.flags {
        for r, i in string(buffer) {
            if r >= 'a' && r <= 'z' {
                buffer[i] = cast(u8) ('A' + (r-'a'))
            }
        }
    }
}
format_float_badly :: proc (dest: ^String_Builder, view: View) {
    when false {
        fraction, integer := fractional(float)
        
        draw_signed_integer(dest, cast(i64) integer, view)
        
        precision: u8 = 6
        if .Precision in view.settings do precision = view.precision
        
        if fraction != 0 && precision != 0 {
            append(dest, '.')
            
            digits := .Uppercase in view.flags ? DigitsUppercase : DigitsLowercase
            
            val: i32
            for _ in 0..<precision {
                fraction, val = fractional(fraction * 10)
                if val >= 0 && val < auto_cast len(digits) {
                    append(dest, digits[val])
                } else { /* ??? */ }
            }
        }
    }
    unimplemented()
}

draw_signed_integer :: proc (dest: ^String_Builder, view: View) {
    integer: i64
    info := view.info.(View_Integer)
    
    switch value in view.value {
      case i8:   integer = cast(i64) value; info.value_size_in_bytes = size_of(i8)
      case i16:  integer = cast(i64) value; info.value_size_in_bytes = size_of(i16)
      case i32:  integer = cast(i64) value; info.value_size_in_bytes = size_of(i32)
      case i64:  integer =           value; info.value_size_in_bytes = size_of(i64)
      case int:  integer = cast(i64) value; info.value_size_in_bytes = size_of(int)
      case: unreachable()
    }
    
    if integer < 0 {
        append(dest, '-')
    } else if info.positive_sign == .Plus {
        append(dest, '+')
    } else if info.positive_sign == .Space {
        append(dest, ' ')
    } else {
        // @note(viktor): nothing
    }
    
    view := view
    view.value = cast(u64) abs(integer)
    draw_unsigned_integer(dest, view)
}

draw_unsigned_integer :: proc (dest: ^String_Builder, view: View) {
    // @todo(viktor): if we specify a width and .LeadingZero, we should limit those zeros to the width i guess. example: integer = 2 width = 2 -> "02" and not "00000002"
    integer: u64
    info := view.info.(View_Integer)
    switch value in view.value {
      case u8:      integer = cast(u64) value; info.value_size_in_bytes = size_of(u8)
      case u16:     integer = cast(u64) value; info.value_size_in_bytes = size_of(u16)
      case u32:     integer = cast(u64) value; info.value_size_in_bytes = size_of(u32)
      case u64:     integer =           value; info.value_size_in_bytes = size_of(u64)
      case uint:    integer = cast(u64) value; info.value_size_in_bytes = size_of(uint)
      case uintptr: integer = cast(u64) value; info.value_size_in_bytes = size_of(uintptr)
      case: unreachable()
    }
    
    digits := .Uppercase in info.flags ? DigitsUppercase : DigitsLowercase
    
    base := cast(u64) info.base
    assert(info.base < auto_cast len(digits))
    
    if .PrependBaseSpecifier in info.flags {
        // @todo(viktor): should this also be uppercased?
        switch base {
          case 2:  append(dest, "0b")
          case 8:  append(dest, "0o")
          case 12: append(dest, "0z")
          case 16: append(dest, "0x")
          case: // @note(viktor): base 10 and any other basis are ignored
        }
    }
    
    show_leading_zeros := .LeadingZero in info.flags
    max_integer: u64
    if show_leading_zeros {
        size := info.value_size_in_bytes
        for _ in 0..<size do max_integer = (max_integer<<8) | 0xFF
    } else {
        max_integer = integer
    }
    
    power: u64 = 1
    for power < max_integer {
        power *= base
        if max_integer / power < base do break
    }
    
    for ; power > 0; power /= base {
        div := integer / power
        integer -= div * power
        
        if show_leading_zeros || div != 0 || integer == 0 {
            show_leading_zeros = true
            append(dest, digits[div])
        }
    }
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

// @todo(viktor): `no_addr(expr)`: Disables explicit address visualization with pointer evaluations in `expr`.

draw_pointer :: proc (ctx: ^Format_Context, data: pmm, target_type: ^runtime.Type_Info = nil) {
    if ctx.max_depth <= 0 do return
    
    if target_type != nil {
        format_any(ctx, '&')
    }
    
    if target_type == nil || data == nil {
        value := data
        if value == nil {
            format_any(ctx, "nil")
        } else {
            format_any(ctx, view_integer(cast(umm) value, base = 16, flags = { .PrependBaseSpecifier, .Uppercase }))
        }
    } else {
        pointed_any := any { data, target_type.id }
        format_any(ctx, pointed_any)
    }
}

draw_array :: proc (ctx: ^Format_Context, raw: RawAny, type: ^runtime.Type_Info, count: int) {
    if ctx.max_depth <= 0 do return
    
    format_optional_type(ctx, raw.id)
    
    format_any(ctx, '{')
    format_multiline_formatting(ctx, .Indent)
    
    defer {
        format_multiline_formatting(ctx, .Outdent)
        format_multiline_formatting(ctx, .Linebreak)
        format_any(ctx, '}')
    }
    
    for index in 0..< count {
        if index != 0 do format_any(ctx, ", ")
        format_multiline_formatting(ctx, .Linebreak)
        
        offset := cast(umm) (index * type.size)
        
        index_ptr := cast(pmm) (cast(umm) raw.data + offset)
        field := any{ index_ptr, type.id }
        format_any(ctx, field)
    }
}

draw_struct :: proc (ctx: ^Format_Context, value: RawAny, variant: runtime.Type_Info_Struct) {
    if ctx.max_depth <= 0 do return
    ctx.max_depth -= 1
    defer ctx.max_depth += 1
        
    format_optional_type(ctx, value.id)
    
    format_any(ctx, '{')
    format_multiline_formatting(ctx, .Indent)
    
    defer {
        format_multiline_formatting(ctx, .Outdent)
        format_multiline_formatting(ctx, .Linebreak)
        format_any(ctx, '}')
    }
    
    for index in 0..< variant.field_count {
        if index != 0 do format_any(ctx, ", ")
        format_multiline_formatting(ctx, .Linebreak)
        
        format_any(ctx, variant.names[index])
        format_any(ctx, " = ")
        field_offset := variant.offsets[index]
        field_type   := variant.types[index]
        
        field_ptr := cast(pmm) (cast(umm) value.data + field_offset)
        field := any{field_ptr, field_type.id}
        format_any(ctx, field)
    }
}

format_union :: proc (ctx: ^Format_Context, union_type: typeid, data: pmm, variant: runtime.Type_Info_Union) {
    if ctx.max_depth <= 0 do return
    ctx.max_depth -= 1
    defer ctx.max_depth += 1
    
    tag_ptr := cast(pmm) (cast(umm) data + variant.tag_offset)
    tag: i64 = -1
    switch variant.tag_type.id {
      case u8:   tag = cast(i64) (cast(^u8)  tag_ptr)^
      case u16:  tag = cast(i64) (cast(^u16) tag_ptr)^
      case u32:  tag = cast(i64) (cast(^u32) tag_ptr)^
      case u64:  tag = cast(i64) (cast(^u64) tag_ptr)^
      case i8:   tag = cast(i64) (cast(^i8)  tag_ptr)^
      case i16:  tag = cast(i64) (cast(^i16) tag_ptr)^
      case i32:  tag = cast(i64) (cast(^i32) tag_ptr)^
      case i64:  tag =           (cast(^i64) tag_ptr)^
      case: panic("Invalid union tag type")
    }

    format_optional_type(ctx, union_type)
    
    if data == nil || !variant.no_nil && tag == 0 {
        format_any(ctx, "nil")
    } else {
        id := variant.variants[variant.no_nil ? tag : (tag-1)].id
        field := any{ data, id }
        format_any(ctx, field)
    }
}

format_matrix :: proc (ctx: ^Format_Context, matrix_type: typeid, data: pmm, type: ^runtime.Type_Info, #any_int column_count, row_count: umm, is_row_major: b32) {
    if ctx.max_depth <= 0 do return
    ctx.max_depth -= 1
    defer ctx.max_depth += 1
    
    format_optional_type(ctx, matrix_type)
    
    format_any(ctx, '{')
    format_multiline_formatting(ctx, .Indent)
    
    defer {
        format_multiline_formatting(ctx, .Outdent)
        format_multiline_formatting(ctx, .Linebreak)
        format_any(ctx, '}')
    }
    
    step   := cast(umm) type.size
    stride := step * (is_row_major ? column_count : row_count)
    major  := is_row_major ? row_count : column_count
    minor  := is_row_major ? column_count : row_count
    
    at   := cast(umm) data
    size := stride * major
    end  := at + size
    for _ in 0..<major {
        defer at += stride
        
        format_multiline_formatting(ctx, .Linebreak)
        
        elem_at := at
        for min in 0..<minor {
            defer elem_at += step
            
            if min != 0 do format_any(ctx, ", ")
            format_any(ctx, any{cast(pmm) elem_at, type.id})
        }
        
        format_any(ctx, ", ")
    }
    assert(at == end)
}


draw_type :: proc (ctx: ^Format_Context, type_info: ^runtime.Type_Info) {
    if ctx.max_depth <= 0 do return
    ctx.max_depth -= 1
    defer ctx.max_depth += 1
    
    format_endianess :: proc (ctx: ^Format_Context, kind: runtime.Platform_Endianness) {
        switch kind {
          case .Platform: /* nothing */
          case .Little:   format_any(ctx, "le")
          case .Big:      format_any(ctx, "be")
        }
    }
    
    if type_info == nil {
        format_any(ctx, "nil")
    } else {
        switch info in type_info.variant {
          case runtime.Type_Info_Integer:
            if type_info.id == int {
                format_any(ctx, "int")
            } else if type_info.id == uint {
                format_any(ctx, "uint")
            } else if type_info.id == uintptr {
                format_any(ctx, "uintptr")
            } else {
                format_any(ctx, info.signed ? 'i' : 'u')
                format_any(ctx, view_integer(type_info.size * 8))
                format_endianess(ctx, info.endianness)
            }
            
          case runtime.Type_Info_Float:
            format_any(ctx, 'f')
            format_any(ctx, view_integer(type_info.size * 8))
            format_endianess(ctx, info.endianness)
            
          case runtime.Type_Info_Complex:
            format_any(ctx, "complex")
            format_any(ctx, view_integer(type_info.size * 8))
            
          case runtime.Type_Info_Quaternion:
            format_any(ctx, "quaternion")
            format_any(ctx, view_integer(type_info.size * 8))
            
          case runtime.Type_Info_Procedure:
            format_any(ctx, "proc")
            // @todo(viktor):  format_any(ctx, info.convention)
            if info.params == nil do format_any(ctx, "()")
            else {
                format_any(ctx, '(')
                ps := info.params.variant.(runtime.Type_Info_Parameters)
                for param, i in ps.types {
                    if i != 0 do format_any(ctx, ", ")
                    draw_type(ctx, param)
                }
                format_any(ctx, ')')
            }
            if info.results != nil {
                format_any(ctx, " -> ")
                draw_type(ctx, info.results)
            }
            
          case runtime.Type_Info_Parameters:
            count := len(info.types)
            if       count != 0 do format_any(ctx, '(')
            defer if count != 0 do format_any(ctx, ')')
            
            for i in 0..<count {
                if i != 0 do format_any(ctx, ", ")
                if i < len(info.names) {
                    format_any(ctx, info.names[i])
                    format_any(ctx, ": ")
                }
                draw_type(ctx, info.types[i])
            }
            
          case runtime.Type_Info_Boolean:
            if type_info.id == bool {
                format_any(ctx, "bool")
            } else {
                format_any(ctx, 'b')
                format_any(ctx, view_integer(type_info.size * 8))
            }
              
          case runtime.Type_Info_Named:   format_any(ctx, info.name)
          case runtime.Type_Info_String:  format_any(ctx, info.is_cstring ? "cstring" : "string")
          case runtime.Type_Info_Any:     format_any(ctx, "any")
          case runtime.Type_Info_Type_Id: format_any(ctx, "typeid")
          case runtime.Type_Info_Rune:    format_any(ctx, "rune")
          
          case runtime.Type_Info_Pointer: 
            if info.elem == nil {
                format_any(ctx, "rawptr")
            } else {
                format_any(ctx, '^')
                draw_type(ctx, info.elem)
            }
            
          case runtime.Type_Info_Multi_Pointer:
            format_any(ctx, "[^]")
            draw_type(ctx, info.elem)
            
          case runtime.Type_Info_Soa_Pointer:
            format_any(ctx, "#soa ^")
            draw_type(ctx, info.elem)
            
            
          case runtime.Type_Info_Simd_Vector:
            format_any(ctx, "#simd[")
            format_any(ctx, view_integer(info.count))
            format_any(ctx, ']')
            draw_type(ctx, info.elem)
            
          case runtime.Type_Info_Matrix:
            if info.layout == .Row_Major do format_any(ctx, "#row_major ")
            format_any(ctx, "matrix[")
            format_any(ctx, view_integer(info.row_count))
            format_any(ctx, ',')
            format_any(ctx, view_integer(info.column_count))
            format_any(ctx, ']')
            draw_type(ctx, info.elem)
                
          case runtime.Type_Info_Array:
            format_any(ctx, '[')
            format_any(ctx, view_integer(info.count))
            format_any(ctx, ']')
            draw_type(ctx, info.elem)
            
          case runtime.Type_Info_Enumerated_Array:
            if info.is_sparse do format_any(ctx, "#sparse ")
            format_any(ctx, '[')
            draw_type(ctx, info.index)
            format_any(ctx, ']')
            draw_type(ctx, info.elem)
            
          case runtime.Type_Info_Dynamic_Array:
            format_any(ctx, "[dynamic]")
            draw_type(ctx, info.elem)
            
          case runtime.Type_Info_Slice:
            format_any(ctx, "[]")
            draw_type(ctx, info.elem)
            
          case runtime.Type_Info_Struct:
            switch info.soa_kind {
              case .None:
              case .Fixed:
                format_any(ctx, "#soa[")
                format_any(ctx, view_integer(info.soa_len))
                format_any(ctx, ']')
                draw_type(ctx, info.soa_base_type)
              case .Slice:
                format_any(ctx, "#soa[]")
                draw_type(ctx, info.soa_base_type)
              case .Dynamic:
                format_any(ctx, "#soa[dynamic]")
                draw_type(ctx, info.soa_base_type)
            }
            
            format_any(ctx, "struct ")
            if .packed    in info.flags  do format_any(ctx, "#packed ")
            if .raw_union in info.flags  do format_any(ctx, "#raw_union ")
            if .align     in info.flags {
                format_any(ctx, "#align(")
                format_any(ctx, view_integer(type_info.align))
                format_any(ctx, ')')
            }
            
            format_any(ctx, '{')
            format_multiline_formatting(ctx, .Indent)
            defer {
                format_multiline_formatting(ctx, .Outdent)
                format_multiline_formatting(ctx, .Linebreak)
                format_any(ctx, '}')
            }
            
            for i in 0..<info.field_count {
                if i != 0 do format_any(ctx, ", ")
                format_multiline_formatting(ctx, .Linebreak)
                
                if info.usings[i] do format_any(ctx, "using ")
                format_any(ctx, info.names[i])
                format_any(ctx, ": ")
                draw_type(ctx, info.types[i])
            }
            
          case runtime.Type_Info_Union:
            format_any(ctx, "union ")
            if info.no_nil      do format_any(ctx, "#no_nil ")
            if info.shared_nil  do format_any(ctx, "#shared_nil ")
            if info.custom_align {
                format_any(ctx, "#align(")
                format_any(ctx, view_integer(type_info.align))
                format_any(ctx, ')')
            }
            
            format_any(ctx, '{')
            format_multiline_formatting(ctx, .Indent)
            defer {
                format_multiline_formatting(ctx, .Outdent)
                format_multiline_formatting(ctx, .Linebreak)
                format_any(ctx, '}')
            }
            
            for variant, i in info.variants {
                if i != 0 do format_any(ctx, ", ")
                format_multiline_formatting(ctx, .Linebreak)
            
                draw_type(ctx, variant)
            }
            
          case runtime.Type_Info_Enum:
            format_any(ctx, "enum ")
            draw_type(ctx, info.base)
            
            format_any(ctx, '{')
            format_multiline_formatting(ctx, .Indent)
            defer {
                format_multiline_formatting(ctx, .Outdent)
                format_multiline_formatting(ctx, .Linebreak)
                format_any(ctx, '}')
            }
            
            for name, i in info.names {
                if i != 0 do format_any(ctx, ", ")
                format_multiline_formatting(ctx, .Linebreak)

                format_any(ctx, name)
            }
            
          case runtime.Type_Info_Map:
            format_any(ctx, "map[")
            draw_type(ctx, info.key)
            format_any(ctx, ']')
            draw_type(ctx, info.value)
            
          case runtime.Type_Info_Bit_Set:
            is_type :: proc (info: ^runtime.Type_Info, $T: typeid) -> bool {
                if info == nil { return false }
                _, ok := runtime.type_info_base(info).variant.(T)
                return ok
            }
            
            format_any(ctx, "bit_set[")
            switch {
              case is_type(info.elem, runtime.Type_Info_Enum):
                draw_type(ctx, info.elem)
              case is_type(info.elem, runtime.Type_Info_Rune):
                // @todo(viktor): unicode
                // io.write_encoded_rune(w, rune(info.lower), true, &n) or_return
                format_any(ctx, "..=")
                unimplemented("support unicode encoding/decoding")
                // io.write_encoded_rune(w, rune(info.upper), true, &n) or_return
              case:
                format_any(ctx, view_integer(info.lower))
                format_any(ctx, "..=")
                format_any(ctx, view_integer(info.upper))
            }
            
            if info.underlying != nil {
                format_any(ctx, "; ")
                draw_type(ctx, info.underlying)
            }
            format_any(ctx, ']')
            
          case runtime.Type_Info_Bit_Field:
            format_any(ctx, "bit_field ")
            draw_type(ctx, info.backing_type)
            
            format_any(ctx, '{')
            format_multiline_formatting(ctx, .Indent)
            defer {
                format_multiline_formatting(ctx, .Outdent)
                format_multiline_formatting(ctx, .Linebreak)
                format_any(ctx, '}')
            }
         
            for i in 0..<info.field_count {
                if i != 0 do format_any(ctx, ", ")
                format_multiline_formatting(ctx, .Linebreak)
                
                format_any(ctx, info.names[i])
                format_any(ctx, ':')
                draw_type(ctx, info.types[i])
                format_any(ctx, '|')
                format_any(ctx, view_integer(info.bit_sizes[i]))
            }
        }
    }
}