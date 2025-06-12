#+vet !unused-procedures
package game

@(common="file")

import "base:builtin"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"

// @Cleanup once the foo.fourth[0].fourth issue is resolved
IsRunAsFile :: #config(IsRunAsFile, false)

// @volatile This breaks if in the midst of a print we start another print on the same thread
@(thread_local) console_buffer: [32 * Kilobyte]u8

print :: proc { format_string, print_to_console }
print_to_console :: proc (format: string, args: ..any, flags: FormatContextFlags = {}) {
    result := print(buffer = console_buffer[:], format = format, args = args, flags = flags)
    fmt.fprint(os.stdout, result)
}
println :: proc(format: string, args: ..any, flags: FormatContextFlags = {}) {
    print_to_console(format = format, args = args, flags = { .AppendNewlineToResult })
}



/* @todo(viktor): make the format_x procs usable by the user, so dont require a context if possible and such

// @todo(viktor): as hex, endianess for hex, thousands dividers,

ALL THE FORMATS should equal their syntax in odin code. Its stupid to have to ways where the default is less useful.
The %w flag sometimes hides types or other info we have in the course of formatting. just set the default to be as close to the 
original as possible.

The higher goal should be to find all the kinds of ways to display data and make them orthogonal to the inputs shape
- Units
  - Numbers
    - Floating Point
*/

////////////////////////////////////////////////

FormatElementKind :: enum u8 {
    Bytes,
    
    String, Character, 
    
    UnsignedInteger, SignedInteger,
    Float,
    
    Indent, Outdent, Linebreak,
}

FormatElement :: struct {
    // @todo(viktor): data kinda sucks
    using data: struct #raw_union {
        slice:   []u8,
        byte:      u8,
        literal16: u16, // @todo(viktor): better name
        literal32: u32, // @todo(viktor): better name
        literal64: u64, // @todo(viktor): better name
    },
    kind: FormatElementKind,
    
    // Numbers
    flags: FormatNumberFlags,
    positive_sign: enum u8 { Never, Plus, Space },
    bytes: u8,
    
    // Integer
    basis:     u8,
    basis_set: b8,
    
    // Float
    precision_set: b8,
    float_kind: FormatFloatKind,
    precision:     u8,
    
    // General
    width:     u16,
    width_set: b8,
    pad_right_side: b8,
    // @todo(viktor): string format, escaped, (as hex)
    
    // @todo(viktor): thousands divider (and which scale to use, see indian scale), 
    // ^ is this a userspace function?
    
    // @todo(viktor): copy over flags from context and let a format element override the context for its data
}

FormatFloatKind    :: enum u8 { Default, MaximumPercision, Scientific }
FormatNumberFlags  :: bit_set[ enum u8 { 
    LeadingZero, PrependBaseSpecifier, Uppercase,
}; u8 ]
FormatContextFlags :: bit_set[ enum u8 {
    PrependTypes, Multiline, AppendNewlineToResult
}; u8 ]

////////////////////////////////////////////////

format_number :: proc (value: $T) -> (result: FormatElement) {
    result.bytes = size_of(value)
    when size_of(T) == 1 {
        result.byte = transmute(u8) value
    } else when size_of(T) == 2 {
        result.literal16 = transmute(u16) value
    } else when size_of(T) == 4 {
        result.literal32 = transmute(u32) value
    } else when size_of(T) == 8 {
        result.literal64 = transmute(u64) value
    }
    return result
}

// @todo(viktor): this could also take an enum which is then interpreted as a float
format_float :: proc(width: i16 = -1, precision: i8 = -1, flags: FormatNumberFlags = {}, kind := FormatFloatKind.Default) -> (result: FormatElement) {
    result.flags = flags
    result.float_kind = kind
    
    if width >= 0 {
        result.width = cast(u16) width
        result.width_set = true
    }
    
    if precision >= 0 {
        result.precision = cast(u8) precision
        result.precision_set = true
    }
    
    return result
}

// @todo(viktor):  int as (Character, Rune,) Unicode_Format
// @todo(viktor): this could also take a pointer or an enum which are then interpreted as an integer
format_integer :: proc(width: i16 = -1, #any_int basis:i8=-1, flags: FormatNumberFlags = {}) -> (result: FormatElement) {
    result.flags = flags
    
    if basis > 0 {
        result.basis = cast(u8) basis
        result.basis_set = true
    }
    
    if width >= 0 {
        result.width = cast(u16) width
        result.width_set = true
    }
    
    return result
}

////////////////////////////////////////////////

FormatContext :: struct {
    dest:     StringBuilder,
    elements: Array(FormatElement),
    
    indentation: string,
    indentation_depth: u32,
    flags: FormatContextFlags,
}

////////////////////////////////////////////////


/* 
_print 
  1M
formatstring 
  4.6M base
  800k dont clear temp
  1.1M reenable odins floats
  1M compact FormatElement 84 -> 32 bytes
*/
@(private="file")
_elements: [2048]FormatElement

@(private="file")
temp_buffer:  [1024]u8
// @todo(viktor): Get rid of this and maybe the other above as well
@(private="file")
temp_buffer2: [1024]u8

format_string :: proc (buffer: []u8, format: string, args: ..any, flags := FormatContextFlags{}) -> (result: string) {
    timed_function()
    
    ctx := FormatContext { 
        dest     = { data = buffer },
        elements = { data = _elements[:] },
        flags = flags,
        
        indentation = "  ",
    }
    
    { 
        // timed_block("parsing")
        
        start_of_text: int
        arg_index: u32
        for index: int; index < len(format); index += 1 {
            if format[index] == '%' {
                append_format_string(&ctx, format[start_of_text:index])
                
                start_of_text = index+1
                
                if index+1 < len(format) && format[index+1] == '%' {
                    index += 1
                    // @note(viktor): start_of_text now points at the percent sign and will append it next time saving processing one element
                } else {
                    // @todo(viktor): dont crash here and also report unused args. Can this be done at compile time?
                    arg := args[arg_index]
                    arg_index += 1
                    
                    // @todo(viktor): Would be ever want to display a raw FormatElement? if so put in a flag to make it use the normal path
                    switch format in arg {
                    case FormatElement: append(&ctx.elements, format)
                    case:               format_any(&ctx, arg)
                    }
                }
            }
        }
        append_format_string(&ctx, format[start_of_text:])
        
        for arg in args[arg_index:] {
            append_format_string(&ctx, "(Unused argument of type: ")
            raw := transmute(RawAny) arg
            format_type(&ctx, type_info_of(raw.id))
            append_format_string(&ctx, ") ")
        }
        
        if .AppendNewlineToResult in flags {
            append_format_character(&ctx, '\n')
        }
    }
    
    
    /* @todo(viktor): StringFormat
        DoubleQuoted_Escaped,
    */
    
    pad :: proc(dest: ^StringBuilder, count: i32) {
        for _ in 0..<count {
            append(dest, ' ')
        }
    }
    
    { 
        // timed_block("printing")
        
        elements: for &element in slice(ctx.elements) {
            temp := StringBuilder { data = temp_buffer[:] }
            
            switch element.kind {
              case .Indent:
                assert(.Multiline in ctx.flags)
                ctx.indentation_depth += 1
              case .Outdent:
                assert(.Multiline in ctx.flags)
                ctx.indentation_depth -= 1
              case .Linebreak:
                assert(.Multiline in ctx.flags)
                append(&ctx.dest, "\n")
                for _ in 0..<ctx.indentation_depth do append(&ctx.dest, ctx.indentation)
                
              case .Bytes:
                unimplemented()
                
              case .String:
                s := cast(string) element.slice
                append(&temp, s)
                
              case .Character:
                append(&temp, element.byte)
                
              case .UnsignedInteger:
                value := element.literal64
                format_unsigned_integer(&temp, value, &element)
                
              case .SignedInteger:
                value := (cast(^i64) &element.literal64)^
                format_signed_integer(&temp, value, &element)
                
              case .Float:
                builder := StringBuilder { data = temp_buffer2[:] }
                // @todo(viktor): 
                // switch format.kind {
                //   case .Hexadecimal_Lowercase: verb = 'h'
                //   case .Hexadecimal_Uppercase: verb = 'H'
                // }
                append(&builder, '%')
                if element.precision_set {
                    append(&builder, '.')
                    buffer: [MaxF64Precision]u8
                    append(&builder, fmt.bprintf(buffer[:], "%d", element.precision))
                }
                if .PrependBaseSpecifier in element.flags do append(&builder, '#')
                
                verb: u8
                switch element.float_kind {
                  case .Default: verb = 'f'
                  case .MaximumPercision: verb = 'f'
                  case .Scientific: verb = .Uppercase in element.flags ? 'E' : 'e'
                }
                
                append(&builder, verb)
                
                switch element.bytes {
                  case 2:
                    float := transmute(f16) element.literal16
                    s := fmt.bprintf(rest(temp), to_string(builder), float)
                    temp.count += auto_cast len(s)
                    
                  case 4:
                    float := transmute(f32) element.literal32
                    s := fmt.bprintf(rest(temp), to_string(builder), float)
                    temp.count += auto_cast len(s)
                    
                  case 8: 
                    float := transmute(f64) element.literal64
                    s := fmt.bprintf(rest(temp), to_string(builder), float)
                    temp.count += auto_cast len(s)
                    
                  case: unreachable()
                }
            }
            
            padding := max(0, cast(i32) element.width - cast(i32) temp.count)
            if element.width_set && !element.pad_right_side do pad(&ctx.dest, padding)
            defer if element.width_set && element.pad_right_side do pad(&ctx.dest, padding)
            
            append(&ctx.dest, to_string(temp))
        }
    }

    return to_string(ctx.dest)
}

format_any :: proc(ctx: ^FormatContext, arg: any) {
    switch value in arg {
      case string:  append_format_string(ctx, value)
      case cstring: append_format_string(ctx, string(value))
        
      case b8:   format_boolean(ctx, cast(b32) value)
      case b16:  format_boolean(ctx, cast(b32) value)
      case b32:  format_boolean(ctx,           value)
      case b64:  format_boolean(ctx, cast(b32) value)
      case bool: format_boolean(ctx, cast(b32) value)
        
      // @todo(viktor): rune
      case u8:      append_format_unsigned_integer(ctx, value)
      case u16:     append_format_unsigned_integer(ctx, value)
      case u32:     append_format_unsigned_integer(ctx, value)
      case u64:     append_format_unsigned_integer(ctx, value)
      case uint:    append_format_unsigned_integer(ctx, value)
      case uintptr: append_format_unsigned_integer(ctx, value)
        
      case i8:  append_format_signed_integer(ctx, value)
      case i16: append_format_signed_integer(ctx, value)
      case i32: append_format_signed_integer(ctx, value)
      case i64: append_format_signed_integer(ctx, value)
      case int: append_format_signed_integer(ctx, value)
        
      case any:    format_any(ctx, value)
      case nil:    format_pointer(ctx, nil)
      case rawptr: format_pointer(ctx, value)
        
      case:
        raw := transmute(RawAny) value
        type_info := type_info_of(raw.id)
        
        switch variant in type_info.variant {
          case runtime.Type_Info_Any,
               runtime.Type_Info_Boolean, 
               runtime.Type_Info_Integer, 
               runtime.Type_Info_String:
            unreachable()
            
          case runtime.Type_Info_Pointer:
            data := (cast(^pmm) raw.data)^
            format_pointer(ctx, data, variant.elem)
          case runtime.Type_Info_Multi_Pointer:
            data := (cast(^pmm) raw.data)^
            append_format_optional_type(ctx, raw.id)
            format_pointer(ctx, data, variant.elem)
          
          
          case runtime.Type_Info_Named:
            // @todo(viktor): Switch here
            if s, oks := variant.base.variant.(runtime.Type_Info_Struct); oks {
                append_format_string(ctx, variant.name)
                format_struct(ctx, raw.id, raw.data, s)
            } else if u, oku := variant.base.variant.(runtime.Type_Info_Union); oku {
                format_union(ctx, raw.id, raw.data, u)
            }
            
          case runtime.Type_Info_Struct:
            format_struct(ctx, raw.id, raw.data, variant)
          case runtime.Type_Info_Union:
            format_union(ctx, raw.id, raw.data, variant)
            
          case runtime.Type_Info_Dynamic_Array:
            slice := cast(^RawSlice) raw.data
            format_array(ctx, raw, variant.elem, slice.len)
          case runtime.Type_Info_Slice:
            slice := cast(^RawSlice) raw.data
            format_array(ctx, raw, variant.elem, slice.len)
          case runtime.Type_Info_Array:
            format_array(ctx, raw, variant.elem, variant.count)
            
          case runtime.Type_Info_Map:
            fmt.println("Unimplemented: maps")
            
          case runtime.Type_Info_Float:
          case runtime.Type_Info_Complex:
          case runtime.Type_Info_Quaternion:
            
          case runtime.Type_Info_Matrix:
            format_matrix(ctx, raw.id, raw.data, variant.elem, variant.column_count, variant.row_count, variant.layout == .Row_Major)

          case runtime.Type_Info_Rune:
            
          case runtime.Type_Info_Enum:
            fmt.println("Unimplemented: enums")
          /* 
            . enumerated array   [key0 = elem0, key1 = elem1, key2 = elem2, ...]
            . maps:              map[key0 = value0, key1 = value1, ...]
            . bit sets           {key0 = elem0, key1 = elem1, ...}
           */  
          case runtime.Type_Info_Enumerated_Array:
          case runtime.Type_Info_Bit_Set:
          case runtime.Type_Info_Bit_Field:
            
          case runtime.Type_Info_Parameters:
          case runtime.Type_Info_Procedure:
          case runtime.Type_Info_Simd_Vector:
          case runtime.Type_Info_Soa_Pointer:
          
          case runtime.Type_Info_Type_Id:
            format_type(ctx, type_info)
            
          case: 
            fmt.println(variant)
            unimplemented("This value is not handled yet")
        }
    }
}

// @todo(viktor): get rid of the runtime.type_infos and just pass the needed data

format_array :: proc(ctx: ^FormatContext, raw: RawAny, type: ^runtime.Type_Info, count: int) {
    append_format_optional_type(ctx, raw.id)
    
    append_format_character(ctx, '{')
    append_format_multiline_formatting(ctx, .Indent)
    
    defer {
        append_format_multiline_formatting(ctx, .Outdent)
        append_format_multiline_formatting(ctx, .Linebreak)
        append_format_character(ctx, '}')
    }
    
    for index in 0..< count {
        if index != 0 do append_format_string(ctx, ", ")
        append_format_multiline_formatting(ctx, .Linebreak)
        
        field_offset := cast(umm) (index * type.size)
        
        field_ptr := cast(pmm) (cast(umm) raw.data + field_offset)
        field := any{ field_ptr, type.id }
        format_any(ctx, field)
    }
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

append_format_string :: proc(ctx: ^FormatContext, value: string) {
    if len(value) == 0 do return
    
    append(&ctx.elements, FormatElement{ 
        kind  = .String,
        slice = transmute([]u8) value,
    })
}
append_format_character :: proc(ctx: ^FormatContext, value: u8) {
    append(&ctx.elements, FormatElement{ 
        kind  = .Character,
        byte = value,
    })
}
append_format_multiline_formatting :: proc(ctx: ^FormatContext, kind: FormatElementKind) {
    if .Multiline not_in ctx.flags do return
    
    append(&ctx.elements, FormatElement{ 
        kind = kind,
    })
}

append_format_optional_type :: proc(ctx: ^FormatContext, type: typeid) {
    if .PrependTypes in ctx.flags {
        format_type(ctx, type_info_of(type))
    }
}

append_format_signed_integer :: proc(ctx: ^FormatContext, value: $T, basis :u8= 10, flags: FormatNumberFlags = {}) {
    append_format_integer(ctx, transmute(u64) (cast(i64) value), size_of(T), basis, flags, .SignedInteger)
}
append_format_unsigned_integer :: proc(ctx: ^FormatContext, value: $T, basis :u8= 10, flags: FormatNumberFlags = {}) {
    append_format_integer(ctx, cast(u64) value, size_of(T), basis, flags, .UnsignedInteger)
}
append_format_integer :: proc(ctx: ^FormatContext, data: u64, bytes: u8, basis :u8, flags: FormatNumberFlags, kind: FormatElementKind) {
    append(&ctx.elements, FormatElement{ 
        kind = kind,
        literal64 = data,
        
        bytes = bytes,
        basis = basis,
        basis_set = true,
        flags = flags,
    })
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

format_pointer :: proc(ctx: ^FormatContext, data: pmm, target_type: ^runtime.Type_Info = nil) {
    if target_type != nil {
        append_format_character(ctx, '&')
    }
    
    if target_type == nil || data == nil {
        value := data
        if value == nil {
            append_format_string(ctx, "nil") 
        } else {
            append_format_unsigned_integer(ctx, cast(umm) value, basis = 16, flags = { .PrependBaseSpecifier, .Uppercase })
        }
    } else {
        pointed_any := any { data, target_type.id }
        format_any(ctx, pointed_any)
    }
}

format_signed_integer :: proc(dest: ^StringBuilder, integer: i64, element: ^FormatElement) {
    negative := integer < 0
    if negative {
        append(dest, '-')
    } else if element.positive_sign == .Plus {
        append(dest, '+')
    } else if element.positive_sign == .Space {
        append(dest, ' ')
    } else {
        // @note(viktor): nothing
    }
    
    format_unsigned_integer(dest, cast(u64) abs(integer), element)
}

format_unsigned_integer :: proc(dest: ^StringBuilder, integer: u64, element: ^FormatElement) {
    digits := .Uppercase in element.flags ? "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" : "0123456789abcdefghijklmnopqrstuvwxyz"
    
    basis :u64= 10
    if element.basis_set do basis = cast(u64) element.basis
    assert(element.basis < auto_cast len(digits))
    
    integer := integer
    
    if .PrependBaseSpecifier in element.flags {
        switch basis {
          case 2:  append(dest, "0b")
          case 8:  append(dest, "0o")
          case 10: append(dest, "0d")
          case 12: append(dest, "0z")
          case 16: append(dest, "0x")
          case: 
        }
    }
    
    show_leading_zero := .LeadingZero in element.flags
    max_integer : u64
    if show_leading_zero {
        for _ in 0..<element.bytes do max_integer = (max_integer<<8) | 0xFF
    } else {
        max_integer = integer
    }
    
    power :u64= 1
    for power < max_integer {
        before := power
        power *= basis
        if max_integer / power < basis do break
    }
    
    for ; power > 0; power /= basis {
        div := integer / power
        integer -= div * power
        
        if show_leading_zero || div != 0 || integer == 0 {
            show_leading_zero = true
            append(dest, digits[div])
        }
    }
}

format_boolean :: proc(ctx: ^FormatContext, boolean: b32) {
    append_format_string(ctx, boolean ? "true" : "false")
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

format_struct :: proc(ctx: ^FormatContext, struct_type: typeid, data: pmm, variant: runtime.Type_Info_Struct) {
    append_format_optional_type(ctx, struct_type)
    
    append_format_character(ctx, '{')
    append_format_multiline_formatting(ctx, .Indent)
    
    defer {
        append_format_multiline_formatting(ctx, .Outdent)
        append_format_multiline_formatting(ctx, .Linebreak)
        append_format_character(ctx, '}')
    }
    
    for index in 0..< variant.field_count {
        if index != 0 do append_format_string(ctx, ", ")
        append_format_multiline_formatting(ctx, .Linebreak)
        
        append_format_string(ctx, variant.names[index])
        append_format_string(ctx, " = ")
        field_offset := variant.offsets[index]
        field_type   := variant.types[index]
        
        // @todo(viktor): what the hell
        if _, ok := field_type.variant.(runtime.Type_Info_Slice); ok {
            fmt.println("Unimplemented: members that are a slice type")
            continue
        } 
        
        field_ptr := cast(pmm) (cast(umm) data + field_offset)
        format_any(ctx, any{field_ptr, field_type.id})
    }
}

format_union :: proc(ctx: ^FormatContext, union_type: typeid, data: pmm, variant: runtime.Type_Info_Union) {
    tag_ptr := cast(pmm) (cast(umm) data + variant.tag_offset)
    tag : i64 = -1
    switch variant.tag_type.id {
      case u8:   tag = cast(i64) (cast(^u8)  tag_ptr)^
      case i8:   tag = cast(i64) (cast(^i8)  tag_ptr)^
      case u16:  tag = cast(i64) (cast(^u16) tag_ptr)^
      case i16:  tag = cast(i64) (cast(^i16) tag_ptr)^
      case u32:  tag = cast(i64) (cast(^u32) tag_ptr)^
      case i32:  tag = cast(i64) (cast(^i32) tag_ptr)^
      case u64:  tag = cast(i64) (cast(^u64) tag_ptr)^
      case i64:  tag =           (cast(^i64) tag_ptr)^
      case: panic("Invalid union tag type")
    }

    append_format_optional_type(ctx, union_type)
    
    if data == nil || !variant.no_nil && tag == 0 {
        append_format_string(ctx, "nil")
    } else {
        id := variant.variants[variant.no_nil ? tag : (tag-1)].id
        format_any(ctx, any{ data, id })
    }
}

format_matrix :: proc (ctx: ^FormatContext, matrix_type: typeid, data: pmm, type: ^runtime.Type_Info, #any_int column_count, row_count: umm, is_row_major: b32) {
    append_format_optional_type(ctx, matrix_type)
    
    append_format_character(ctx, '{')
    append_format_multiline_formatting(ctx, .Indent)
    
    defer {
        append_format_multiline_formatting(ctx, .Outdent)
        append_format_multiline_formatting(ctx, .Linebreak)
        append_format_character(ctx, '}')
    }
    
    step   := cast(umm) type.size
    stride := step * (is_row_major ? column_count : row_count)
    major  := is_row_major ? row_count : column_count
    minor  := is_row_major ? column_count : row_count
    
    at   := cast(umm) data
    size := stride * major
    end  := at + size
    for maj in 0..<major {
        defer at += stride
        
        append_format_multiline_formatting(ctx, .Linebreak)
        
        elem_at := at
        for min in 0..<minor {
            defer elem_at += step
            
            if min != 0 do append_format_string(ctx, ", ")
            format_any(ctx, any{cast(pmm) elem_at, type.id})
        }
        
        append_format_string(ctx, ", ")
    }
    assert(at == end)
}


format_type :: proc(ctx: ^FormatContext, type_info: ^runtime.Type_Info) {
    format_endianess :: proc(ctx: ^FormatContext, kind: runtime.Platform_Endianness) {
        switch kind {
          case .Platform: /* nothing */
          case .Little:   append_format_string(ctx, "le")
          case .Big:      append_format_string(ctx, "be")
        }
    }
    
    if type_info == nil {
        append_format_string(ctx, "nil")
    } else {
        switch info in type_info.variant {
          case runtime.Type_Info_Integer:
            if type_info.id == int {
                append_format_string(ctx, "int")
            } else if type_info.id == uint {
                append_format_string(ctx, "uint")
            } else if type_info.id == uintptr {
                append_format_string(ctx, "uintptr")
            } else {
                append_format_character(ctx, info.signed ? 'i' : 'u')
                append_format_unsigned_integer(ctx, type_info.size * 8)
                format_endianess(ctx, info.endianness)
            }
            
          case runtime.Type_Info_Float:
            append_format_character(ctx, 'f')
            append_format_unsigned_integer(ctx, type_info.size * 8)
            format_endianess(ctx, info.endianness)
            
          case runtime.Type_Info_Complex:
            append_format_string(ctx, "complex")
            append_format_unsigned_integer(ctx, type_info.size * 8)
            
          case runtime.Type_Info_Quaternion:
            append_format_string(ctx, "quaternion")
            append_format_unsigned_integer(ctx, type_info.size * 8)
            
          case runtime.Type_Info_Procedure:
            append_format_string(ctx, "proc")
            // @todo(viktor):  append_format_string(ctx, info.convention)
            if info.params == nil do append_format_string(ctx, "()")
            else {
                append_format_character(ctx, '(')
                ps := info.params.variant.(runtime.Type_Info_Parameters)
                for param, i in ps.types {
                    if i != 0 do append_format_string(ctx, ", ")
                    format_type(ctx, param)
                }
                append_format_character(ctx, ')')
            }
            if info.results != nil {
                append_format_string(ctx, " -> ")
                format_type(ctx, info.results)
            }
            
          case runtime.Type_Info_Parameters:
            count := len(info.types)
            if       count != 0 do append_format_character(ctx, '(')
            defer if count != 0 do append_format_character(ctx, ')')
            
            for i in 0..<count {
                if i != 0 do append_format_string(ctx, ", ")
                if i < len(info.names) {
                    append_format_string(ctx, info.names[i])
                    append_format_string(ctx, ": ")
                }
                format_type(ctx, info.types[i])
            }
            
          case runtime.Type_Info_Boolean:
            if type_info.id == bool {
                append_format_string(ctx, "bool")
            } else {
                append_format_character(ctx, 'b')
                append_format_unsigned_integer(ctx, type_info.size * 8)
            }
              
          case runtime.Type_Info_Named:   append_format_string(ctx, info.name)
          case runtime.Type_Info_String:  append_format_string(ctx, info.is_cstring ? "cstring" : "string")
          case runtime.Type_Info_Any:     append_format_string(ctx, "any")
          case runtime.Type_Info_Type_Id: append_format_string(ctx, "typeid")
          case runtime.Type_Info_Rune:    append_format_string(ctx, "rune")
          
          case runtime.Type_Info_Pointer: 
            if info.elem == nil {
                append_format_string(ctx, "rawptr")
            } else {
                append_format_character(ctx, '^')
                format_type(ctx, info.elem)
            }
            
          case runtime.Type_Info_Multi_Pointer:
            append_format_string(ctx, "[^]")
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Soa_Pointer:
            append_format_string(ctx, "#soa ^")
            format_type(ctx, info.elem)
            
            
          case runtime.Type_Info_Simd_Vector:
            append_format_string(ctx, "#simd[")
            append_format_unsigned_integer(ctx, info.count)
            append_format_character(ctx, ']')
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Matrix:
            if info.layout == .Row_Major do append_format_string(ctx, "#row_major ")
            append_format_string(ctx, "matrix[")
            append_format_unsigned_integer(ctx, info.row_count)
            append_format_character(ctx, ',')
            append_format_unsigned_integer(ctx, info.column_count)
            append_format_character(ctx, ']')
            format_type(ctx, info.elem)
                
          case runtime.Type_Info_Array:
            append_format_character(ctx, '[')
            append_format_unsigned_integer(ctx, info.count)
            append_format_character(ctx, ']')
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Enumerated_Array:
            if info.is_sparse do append_format_string(ctx, "#sparse ")
            append_format_character(ctx, '[')
            format_type(ctx, info.index)
            append_format_character(ctx, ']')
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Dynamic_Array:
            append_format_string(ctx, "[dynamic]")
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Slice:
            append_format_string(ctx, "[]")
            format_type(ctx, info.elem)
            
          case runtime.Type_Info_Struct:
            switch info.soa_kind {
              case .None:
              case .Fixed:
                append_format_string(ctx, "#soa[")
                append_format_unsigned_integer(ctx, info.soa_len)
                append_format_character(ctx, ']')
                format_type(ctx, info.soa_base_type)
              case .Slice:
                append_format_string(ctx, "#soa[]")
                format_type(ctx, info.soa_base_type)
              case .Dynamic:
                append_format_string(ctx, "#soa[dynamic]")
                format_type(ctx, info.soa_base_type)
            }
            
            append_format_string(ctx, "struct ")
            if .packed    in info.flags  do append_format_string(ctx, "#packed ")
            if .raw_union in info.flags  do append_format_string(ctx, "#raw_union ")
            if .no_copy   in info.flags  do append_format_string(ctx, "#no_copy ")
            if .align     in info.flags {
                append_format_string(ctx, "#align(")
                append_format_unsigned_integer(ctx, type_info.align)
                append_format_character(ctx, ')')
            }
            
            append_format_character(ctx, '{')
            append_format_multiline_formatting(ctx, .Indent)
            defer {
                append_format_multiline_formatting(ctx, .Outdent)
                append_format_multiline_formatting(ctx, .Linebreak)
                append_format_character(ctx, '}')
            }
            
            for i in 0..<info.field_count {
                if i != 0 do append_format_string(ctx, ", ")
                append_format_multiline_formatting(ctx, .Linebreak)
                
                if info.usings[i] do append_format_string(ctx, "using ")
                append_format_string(ctx, info.names[i])
                append_format_string(ctx, ": ")
                format_type(ctx, info.types[i])
            }
            
          case runtime.Type_Info_Union:
            append_format_string(ctx, "union ")
            if info.no_nil      do append_format_string(ctx, "#no_nil ")
            if info.shared_nil  do append_format_string(ctx, "#shared_nil ")
            if info.custom_align {
                append_format_string(ctx, "#align(")
                append_format_unsigned_integer(ctx, type_info.align)
                append_format_character(ctx, ')')
            }
            
            append_format_character(ctx, '{')
            append_format_multiline_formatting(ctx, .Indent)
            defer {
                append_format_multiline_formatting(ctx, .Outdent)
                append_format_multiline_formatting(ctx, .Linebreak)
                append_format_character(ctx, '}')
            }
            
            for variant, i in info.variants {
                if i != 0 do append_format_string(ctx, ", ")
                append_format_multiline_formatting(ctx, .Linebreak)
            
                format_type(ctx, variant)
            }
            
          case runtime.Type_Info_Enum:
            append_format_string(ctx, "enum ")
            format_type(ctx, info.base)
            
            append_format_character(ctx, '{')
            append_format_multiline_formatting(ctx, .Indent)
            defer {
                append_format_multiline_formatting(ctx, .Outdent)
                append_format_multiline_formatting(ctx, .Linebreak)
                append_format_character(ctx, '}')
            }
            
            for name, i in info.names {
                if i != 0 do append_format_string(ctx, ", ")
                append_format_multiline_formatting(ctx, .Linebreak)

                append_format_string(ctx, name)
            }
            
          case runtime.Type_Info_Map:
            append_format_string(ctx, "map[")
            format_type(ctx, info.key)
            append_format_character(ctx, ']')
            format_type(ctx, info.value)
            
          case runtime.Type_Info_Bit_Set:
            is_type :: proc(info: ^runtime.Type_Info, $T: typeid) -> bool {
                if info == nil { return false }
                _, ok := runtime.type_info_base(info).variant.(T)
                return ok
            }
            
            append_format_string(ctx, "bit_set[")
            switch {
              case is_type(info.elem, runtime.Type_Info_Enum):
                format_type(ctx, info.elem)
              case is_type(info.elem, runtime.Type_Info_Rune):
                // @todo(viktor): unicode
                // io.write_encoded_rune(w, rune(info.lower), true, &n) or_return
                append_format_string(ctx, "..=")
                unimplemented("support unicode encoding/decoding")
                // io.write_encoded_rune(w, rune(info.upper), true, &n) or_return
              case:
                append_format_unsigned_integer(ctx, info.lower)
                append_format_string(ctx, "..=")
                append_format_unsigned_integer(ctx, info.upper)
            }
            
            if info.underlying != nil {
                append_format_string(ctx, "; ")
                format_type(ctx, info.underlying)
            }
            append_format_character(ctx, ']')
            
          case runtime.Type_Info_Bit_Field:
            append_format_string(ctx, "bit_field ")
            format_type(ctx, info.backing_type)
            
            append_format_character(ctx, '{')
            append_format_multiline_formatting(ctx, .Indent)
            defer {
                append_format_multiline_formatting(ctx, .Outdent)
                append_format_multiline_formatting(ctx, .Linebreak)
                append_format_character(ctx, '}')
            }
         
            for i in 0..<info.field_count {
                if i != 0 do append_format_string(ctx, ", ")
                append_format_multiline_formatting(ctx, .Linebreak)
                
                append_format_string(ctx, info.names[i])
                append_format_character(ctx, ':')
                format_type(ctx, info.types[i])
                append_format_character(ctx, '|')
                append_format_unsigned_integer(ctx, info.bit_sizes[i])
            }
        }
    }
}

////////////////////////////////////////////////

@(private="file") 
RawSlice :: struct {
    data: rawptr,
    len:  int,
}
@(private="file") 
RawAny :: struct {
    data: rawptr,
	id:   typeid,
}

////////////////////////////////////////////////

when IsRunAsFile {

    ///////////////////// @copypasta
    Array :: struct ($T: typeid) {
        data:  []T,
        count: i64,
    }
    FixedArray :: struct ($N: i64, $T: typeid) {
        data:  [N]T,
        count: i64,
    }

    append :: proc { append_fixed_array, append_array, append_array_, append_array_many, append_fixed_array_many, append_string }
    @(require_results) append_array_ :: proc(a: ^Array($T)) -> (result: ^T) {
        result = &a.data[a.count]
        a.count += 1
        return result
    }
    append_array :: proc(a: ^Array($T), value: T) -> (result: ^T) {
        a.data[a.count] = value
        result = append_array_(a)
        return result
    }
    append_fixed_array :: proc(a: ^FixedArray($N, $T), value: T) -> (result: ^T) {
        a.data[a.count] = value
        result = &a.data[a.count]
        a.count += 1
        return result
    }
    append_string :: proc(a: ^StringBuilder, value: string) -> (result: string) {
        timed_function()
        return cast(string) append_array_many(a, transmute([]u8) value)
    }
    append_array_many :: proc(a: ^Array($T), values: []T) -> (result: []T) {
        start := a.count
        for &value in values {
            a.data[a.count] = value
            a.count += 1
        }
        
        result = a.data[start:a.count]
        return result
    }
    append_fixed_array_many :: proc(a: ^FixedArray($N, $T), values: []T) -> (result: []T) {
        start := a.count
        for &value in values {
            a.data[a.count] = value
            a.count += 1
        }
        
        result = a.data[start:a.count]
        return result
    }

    slice :: proc{ slice_fixed_array, slice_array }
    slice_fixed_array :: proc(array: ^FixedArray($N, $T)) -> []T {
        return array.data[:array.count]
    }
    slice_array :: proc(array: Array($T)) -> []T {
        return array.data[:array.count]
    }

    to_string :: proc(array: StringBuilder) -> string {
        return cast(string) array.data[:array.count]
    }
    
    rest :: proc{ rest_fixed_array, rest_array }
    rest_fixed_array :: proc(array: ^FixedArray($N, $T)) -> []T {
        return array.data[array.count:]
    }
    rest_array :: proc(array: Array($T)) -> []T {
        return array.data[array.count:]
    }
    
    timed_function :: proc() {}
    timed_block :: proc(s: string) {}
    begin_timed_block :: proc(s:string) -> string { return "" }
    end_timed_block :: proc(s: string) {}
    
    MaxF64Precision :: 16
    
    Byte     :: 1
    Kilobyte :: 1024 * Byte
    Megabyte :: 1024 * Kilobyte
    
        
    main :: proc() {
        foo := Foo{987, false, -69.420, { {1, true, 99.99, nil} } }
        
        Foo :: struct {
            first: i32,
            second: b32,
            third: f64,
            fourth: []Foo,
        }
        
        Bar :: union { Foo, i32 }
        Baz :: distinct Foo
        
        buffer:[128 * Kilobyte]u8
        a :i32= 123
        b := true
        c : pmm
        d: ^i32
        e: ^^i32 = &d
        f: ^^^i32 = &e
        dynamic_array :[dynamic]i32
        builtin.append(&dynamic_array, 1, -2, 3*3)
        
        map_string:map[string]b32
        map_string["foo"] = true
        map_string["bar"] = false
        
        _ = 0e01 // scientific float
        _ = 0h0123456789ABCDEF
        
        _ = 0b01
        _ = 0o01234567
        _ = 0d0123456789
        _ = 0z01234567890AB
        _ = 0x01234567890ABCDEF
        _ = 0x01234567890abcdef
        
        multi1: [^]u32
        multi2: [^]i32 = raw_data(dynamic_array)
        
        println("%", format_string(buffer[:], 
`string:  
Hello %! 100%% %, 

booleans: 
% %, % %

integers:
% % % %,
% % %
% % %
% % %
          
anys:
% %

pointers:
% % % % %

arrays:
% % %
% % %
%
% %
% %
% %
          
structs:
% 
%
%

maps:
% % @todo:

union:
% % % % 
% %

matrix:
% 
% 
%
%
          
enums:    % % % @todo:

unused:   `, 
            "World", cstring("Handmade"),
            
            bool(true), bool(false), b32(true), b32(false),
            
            i32(0), i32(1), u32(16), i32(-16),
            min(i32), max(i32), max(u32), 
            min(i64), max(i64), max(u64),
            min(i64), max(i64), max(u64),
            
            any(a), any(any(any(any(b)))), 
            
            &a, &b, c, d, &f,
            
            [?]i32{1, -2, 3*3}, []i32{1, -2, 3*3}, dynamic_array, 
            [?]i32{}, []i32{}, [dynamic]i32{},
            [32]u8{0..<16 = 1, 16..<24 = 2},
            foo.fourth[0].fourth,  foo.fourth,
            &foo.fourth[0].fourth, &foo.fourth,
            multi1, multi2,
            
            struct{ x: u32, y: i8, z: b32 }{ 12, -6, false }, 
            foo,
            Baz(foo),
            
            map_string, map[i32]i32{},
            
            Bar{}, Bar(123), Bar(foo), union{ u32, b32 }(true), 
            union #no_nil { b32, u32 }({}), union #no_nil { b32, u32 }(123),
            
                          matrix[3,4]i32 {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12},
            #column_major matrix[3,4]i32 {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12},
            #row_major    matrix[3,4]i32 {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12},
                          matrix[3,4]f32 {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12},
            
                          
            FormatElementKind.String, FormatElementKind{}, enum { AValue }.AValue,
            FormatElementKind.Outdent, 
            
            Bar{}, 
            #row_major    matrix[3,4]i32 {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12},
            struct {
                kind: FormatElementKind,
                using data: struct #raw_union {
                    slice:   []u8,
                    byte:  u8,
                    literal16: u16,
                    literal32: u32,
                    literal64: u64,
                },
                // Number
                bytes: u8,
                basis: u64,
                basis_set: b32,
                flags: FormatNumberFlags,
                
                // General
                width:     u32,
                width_set: b32,
                
                
            }{},
        ))
    }
    
    StringBuilder :: Array(u8)
    
    pmm :: rawptr
    umm :: uintptr
}