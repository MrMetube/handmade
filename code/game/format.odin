#+vet !unused-procedures
package game

@(common="file")

import "base:intrinsics"
import "core:fmt"
import "core:os"

IsRunAsFile :: #config(IsRunAsFile, false)

/* @todo(viktor):

The higher goal should be to find all the kinds of ways to display data and make them orthogonal to the inputs shape
- Units
  - Numbers
    - Integer, Floating Point, Complex, Quaternion, Matrices
  - Bytes
    - Basis: Hex, Binary
    
- Collections
  - Structs
  - Arrays
  - Maps
  - Enums
  - Bitsets Bitfields
- As Code
- As Data
- Where to write the data
    - File, Console, Buffers,
- What for
    - Further use in program
    - Output: Transient, Persistent

////////////////////////////////////////////////

hexadecimal lower and uppercase could just be a flag for as well duodecimal

hexadecimal for floats is broken 

// fmt.t a 
// fmt.ct ca
    
// fmt.sb w
// fmt.f e

    respect padding

Other flags:
	+      always print a sign for numeric values
	-      pad with spaces on the right rather the left (left-justify the field)
	' '    (space) leave a space for elided sign in numbers (% d)
	0      pad with leading zeros rather than spaces

Flags are ignored by verbs that don't expect them.
*/

////////////////////////////////////////////////
////////////////////////////////////////////////


// FormatElement :: struct {
//     using data: struct #raw_union {
//         slice:   []u8,
//         literal: u64,
//     },
    
//     ////////////////////////////////////////////////
    
//     display_kind: enum {
//         Text,
//         Bits, 
//         Integer,
//         Float,
//     },
//     // Bits
//     basis: enum { Binary = 2, Octal = 8, Decimal = 10, Duodecimal = 12, Hexadecimal = 16, Base64 = 64, Custom, },
//     custom_basis: u8,
//     uppercase_characters: b32,
//     // Number
//     always_show_sign: b32,
//     // Float
//     precision: enum { Default, Maximum, Custom },
    
//     custom_precision: u8,
//     // Strings, Chars, Runes
//     // @todo(viktor): Escaping
    
//     ////////////////////////////////////////////////
//     // Formatting
//     width:     u32,
//     width_set: b32,
    
//     pad_from_right:    b32,
//     indentation_depth: u32,
    
//     custom_padding_rune:      rune,
//     use_custom_padding_rune:  b32,
// }

// /* 
//     Data is just data.
//     No special formatting syntax the user can just write a function to emit some Format Elements directly into the system.
//  */
// bar :: proc (inputs: ..any) {
//     buffer := console_buffer[:]
//     start: int
//     arg_index: int
//     skip: b32
    
//     scratch_space: [256]u8
//     ctx := FormatContext {
//         buffer  = { data = buffer }, 
//         builder = { data = scratch_space[:] },
//     }
    
//     temp: [128]FormatElement
//     elements: Array(FormatElement)
//     elements.data = temp[:]
    
//     for input in inputs {
//         append(&elements, FormatElement{literal = '"', display_kind = .Text, })
//         switch value in input {
//             case bool, b8, b16, b32, b64:
//                 boolean := any_cast(bool, value) ? "true" : "false"
//                 append(&elements, FormatElement{slice = transmute([]u8) boolean, display_kind = .Text, })
//             case string:
//                 append(&elements, FormatElement{slice = transmute([]u8) value, display_kind = .Text, })
//             case cstring:
//                 str := (cast([^]u8) value)[:len(value)]
//                 append(&elements, FormatElement{slice = transmute([]u8) str, display_kind = .Text, })
//             case int:
//                 append(&elements, FormatElement{literal = value, display_kind = .Integer, })
//             case:
//         }
//         append(&elements, FormatElement{literal = '"', display_kind = .Text, })
//         append(&elements, FormatElement{slice = transmute([]u8) string("\n"), display_kind = .Text, })
//     }
    
//     for &element in slice(elements) {
//         // append indentation
//         // apppend padding left
//         switch element.display_kind {
//             case .Text:
//                 if len(element.data.slice) == 0 {
//                     cstr := cast(cstring) cast([^]u8) &element.data.literal
//                     str := (cast([^]u8) cstr)[:len(cstr)]
//                     append_array_many(&ctx.buffer, str)
//                 } else {
//                     append_array_many(&ctx.buffer, element.data.slice)
//                 }
//             case .Bits:
//             case .Integer:
//             case .Float:
//         }
//         // apppend padding right
//     }

//     fmt.fprint(os.stdout, cast(string) slice(ctx.buffer))
// }

////////////////////////////////////////////////
////////////////////////////////////////////////

FormatInfo :: struct {
    // general info
    width:     union { u32 }, // nil value means default width
    precision: union { u32 }, // nil value means default precision
    
    pad_on_the_right_side: b32, // @todo(viktor): Implement this and pad character for numbers i.e. space or 0
    
    // @todo(viktor): thousands divider (and which scale to use, see indian scale)
    
    // struct info
    expanded: b32, // @todo(viktor): better name
    
    // numeric info
    leading_base_specifier: b32, 
    always_print_sign:      b32, // @todo(viktor): Implement this
}

GeneralFormat :: struct {
    v: any,
    kind: enum {
        Default,
        OdinSyntaxOfValue,
        OdinSyntaxOfType,
    },
    info: FormatInfo,
}

BooleanFormat :: struct {
    v: union #no_nil { bool, b8, b16, b32, b64 },
    info: FormatInfo,
}

IntegerFormat :: struct {
    v: union #no_nil {
        int,  uint, uintptr,
        i8, i16, i32, i64, i128,
        u8, u16, u32, u64, u128, 
        i16le, i32le, i64le, i128le, u16le, u32le, u64le, u128le, // little endian
        i16be, i32be, i64be, i128be, u16be, u32be, u64be, u128be, // big endian
    },
    kind: union #no_nil {
        IntegerFormatBase,
        IntegerFormatAsCharacter,
    },
    info: FormatInfo,
}
IntegerFormatAsCharacter :: enum { 
    Character, Rune, // These are the same
    Unicode_Format,
}
IntegerFormatBase :: enum { 
    Decimal,
    
    Binary, 
    Octal, 
    Duodecimal, 
    Hexadecimal_Lowercase,
    Hexadecimal_Uppercase,
}

FloatFormat :: struct {
    v: union #no_nil {
        f64, 
        f16, f32, 
        f16le, f32le, f64le, // little endian
        f16be, f32be, f64be, // big endian
        
        // @note(viktor): These are just a bunch of floats internally
        complex32,    complex64,     complex128,
        quaternion64, quaternion128, quaternion256,
    },
    kind: FloatFormatKind,
    info: FormatInfo,
}

FloatFormatKind :: enum {
    Default,
    MaximumPercision,
    Scientific_Lowercase, 
    Scientific_Uppercase,
    
    Hexadecimal_Lowercase,
    Hexadecimal_Uppercase,
}

StringFormat :: struct {
    v: union #no_nil { string, cstring },
    kind: StringFormatKind,
    info: FormatInfo,
}
StringFormatKind :: enum {
    Default,
    DoubleQuoted_Escaped,
    Hexadecimal_Lowercase, 
    Hexadecimal_Uppercase, 
}

PointerFormat :: struct {
    v:    any,
    kind: PointerFormatKind,
    info: FormatInfo,
}
PointerFormatKind :: union #no_nil { PointerFormatKindDefault, IntegerFormatBase }
PointerFormatKindDefault :: enum { Default }

EnumFormat :: struct {
    v:    any,
    kind: EnumFormatKind,
    info: FormatInfo,
}
EnumFormatKind :: union #no_nil { EnumFormatKindDefault, IntegerFormatBase, FloatFormatKind }
EnumFormatKindDefault :: enum { Default }

////////////////////////////////////////////////

format_pointer :: proc(pointer: $P, kind: PointerFormatKind = .Default, leading_base_specifier : b32 = true) -> PointerFormat 
where intrinsics.type_is_pointer(P) || intrinsics.type_is_slice(P) {
    return { v = pointer, kind = kind, info = { leading_base_specifier = leading_base_specifier } }
}

format_enum :: proc(enum_value: $E, kind: EnumFormatKind = EnumFormatKindDefault.Default) -> EnumFormat
where intrinsics.type_is_enum(E) {
    return { v = enum_value, kind = kind }
}

////////////////////////////////////////////////

@(private="file") 
RawAny :: struct {
    data: rawptr,
	id:   typeid,
}

////////////////////////////////////////////////

FormatContext :: struct {
    builder: FormatBuffer,
    buffer:  FormatBuffer,
    verb:    u8,
    value:   any,
    handled: b32,
}
FormatBuffer :: Array(u8)

PrintFlags :: bit_set[enum{ Newline }]

println :: proc(format: string, args: ..any, flags: PrintFlags = {}) {
    print_to_console(format = format, args = args, flags = { .Newline })
}

print :: proc { _print, print_to_console }
@(thread_local) console_buffer: [2048]u8
print_to_console :: proc (format: string, args: ..any, flags: PrintFlags = {}) {
    result := print(buffer = console_buffer[:], format = format, args = args, flags = flags)
    fmt.fprint(os.stdout, result)
}
_print :: proc (buffer: []u8, format: string, args: ..any, flags: PrintFlags = {}) -> string {
    timed_function()
    
    start: int
    arg_index: int
    skip: b32
    
    scratch_space: [256]u8
    ctx := FormatContext {
        buffer  = { data = buffer }, 
        builder = { data = scratch_space[:] },
    }
    
    for r, index in format {
        if skip { skip = false; continue }
        if r == '%' {
            if index > 0 {
                timed_block("print regular string content")
                s := fmt.bprint(rest(ctx.buffer), format[start:index])
                ctx.buffer.count += auto_cast len(s)
            }
            start = index+1
            
            if index+1 < len(format) && format[index+1] == '%' {
                s := fmt.bprint(rest(ctx.buffer), '%')
                ctx.buffer.count += auto_cast len(s)
                skip = true
                start += 1
            } else {
                // @todo(viktor): check index in bounds
                // @todo(viktor): check all args used
                arg := args[arg_index]
                arg_index += 1
                
                ctx.builder.count = 0
                ctx.handled = false 
                append(&ctx.builder, '%')
                
                width: u32
                ok: bool
                switch &value in arg {
                  case GeneralFormat: width, ok = value.info.width.?
                  case PointerFormat: width, ok = value.info.width.?
                  case StringFormat:  width, ok = value.info.width.?
                  case EnumFormat:    width, ok = value.info.width.?
                  case FloatFormat:   width, ok = value.info.width.?
                  case BooleanFormat: width, ok = value.info.width.?
                  case IntegerFormat: width, ok = value.info.width.?
                }
                
                if ok {
                    buffer: [64]u8
                    append(&ctx.builder, transmute([]u8) print(buffer[:], " %",width))
                }
                
                switch &value in arg {
                  case GeneralFormat:
                    if value.info.expanded do append(&ctx.builder, '#')
                    
                    switch value.kind {
                      case .Default:           ctx.verb = 'v'
                      case .OdinSyntaxOfValue: ctx.verb = 'w'
                      case .OdinSyntaxOfType:  ctx.verb = 'T'
                    }
                  
                    ctx.value = value.v
                  
                  case PointerFormat:
                    raw := transmute(RawAny) value.v
                    switch kind in value.kind {
                      case PointerFormatKindDefault: 
                        ctx.verb = 'p'
                        ctx.value = value.v
                        
                      case IntegerFormatBase: 
                        as_int := cast(uintptr) (cast(^rawptr) raw.data)^
                        print_integer(&ctx, { v = as_int, kind = kind })
                    }
                    
                  case cstring: print_string(&ctx, value, .Default, {})
                  case string:  print_string(&ctx, value, .Default, {})
                  case StringFormat:
                    switch value.kind {
                      case .Default:               print_string(&ctx, value.v, value.kind, value.info)
                      case .Hexadecimal_Lowercase: print_string(&ctx, value.v, value.kind, value.info)
                      case .Hexadecimal_Uppercase: print_string(&ctx, value.v, value.kind, value.info)
                      case .DoubleQuoted_Escaped:  ctx.verb = 'q'
                    }
                    ctx.value = value.v
                    
                  case EnumFormat:
                    switch kind in value.kind {
                      case EnumFormatKindDefault: 
                        ctx.verb = 's'
                        ctx.value = value.v
                        
                      case FloatFormatKind:
                        print_float(&ctx, { any_cast(f64, value.v), kind, value.info })
                        
                      case IntegerFormatBase:
                        print_integer(&ctx, { any_cast(int, value.v), kind, value.info })
                    }
                    
                  case bool: s := (value ? "true" : "false"); print_string(&ctx, s, .Default, {})
                  case b8:   s := (value ? "true" : "false"); print_string(&ctx, s, .Default, {})
                  case b16:  s := (value ? "true" : "false"); print_string(&ctx, s, .Default, {})
                  case b32:  s := (value ? "true" : "false"); print_string(&ctx, s, .Default, {})
                  case b64:  s := (value ? "true" : "false"); print_string(&ctx, s, .Default, {})
                  case BooleanFormat:
                    s := (any_cast(bool, value.v) ? "true" : "false")
                    print_string(&ctx, s, .Default, value.info)
                    
                  case FloatFormat:
                    print_float(&ctx, value)
                
                  case IntegerFormat:
                    print_integer(&ctx, value)
                    
                  case:
                    ctx.verb = 'v'
                    ctx.value = arg
                }
                
                if !ctx.handled {
                    timed_block("unhandled print verbs")
                    
                    append(&ctx.builder, ctx.verb)
                    mapped_format := cast(string) slice(ctx.builder)
                    s := fmt.bprintf(rest(ctx.buffer), mapped_format, ctx.value)
                    ctx.buffer.count += auto_cast len(s)
                    assert(ctx.buffer.count <= auto_cast len(ctx.buffer.data))
                }
            }
        }
    }
    
    s := fmt.bprint(rest(ctx.buffer), format[start:])
    ctx.buffer.count += auto_cast len(s)
    
    if .Newline in flags {
        _s := fmt.bprint(rest(ctx.buffer), '\n')
        ctx.buffer.count += auto_cast len(_s)
    }
    
    return cast(string) slice(ctx.buffer)
}

print_string :: proc(ctx: ^FormatContext, s: union #no_nil {string, cstring}, kind: StringFormatKind, info: FormatInfo) {
    timed_function()
    
    if kind == .DoubleQuoted_Escaped do return 
    
    bytes: []u8
    strlen: u32
    switch v in s {
      case string: 
        bytes = transmute([]u8) v
        strlen = cast(u32) len(v)
      case cstring: 
        strlen = cast(u32) len(v)
        bytes = (cast([^]u8) v)[:strlen]
    }
    
    
    if width, ok := info.width.?; ok {
        total_width := kind == .Default ? strlen : strlen * 2
        for _ in total_width ..< width do append(&ctx.buffer, cast(u8) ' ')
    }
        
    switch kind {
      case .Default:
        append(&ctx.buffer, bytes)
        ctx.handled = true
        
      case .Hexadecimal_Lowercase, .Hexadecimal_Uppercase:
        for i in 0 ..< len(bytes) {
            b := bytes[i]
            print_hex(ctx, cast(u64) b, 8, kind != .Hexadecimal_Lowercase, false)
        }
        ctx.handled = true
        
      case .DoubleQuoted_Escaped: unreachable()
    } 
}

print_float :: proc(ctx: ^FormatContext, format_info: FloatFormat) {
    timed_function()
    ctx.value = format_info.v

    if precision, ok := format_info.info.precision.(u32); ok {
        append(&ctx.builder, '.')
        buffer: [MaxF64Precision]u8
        append(&ctx.builder, transmute([]u8) print(buffer[:], "%", precision))
    }
    
    if format_info.info.leading_base_specifier do append(&ctx.builder, '#')
    
    switch format_info.kind {
      case .Default:               ctx.verb = 'f'
      case .MaximumPercision:      ctx.verb = 'g'
      case .Scientific_Lowercase:  ctx.verb = 'e'
      case .Scientific_Uppercase:  ctx.verb = 'E'
      case .Hexadecimal_Lowercase, .Hexadecimal_Uppercase: 
        is_uppercase : b32 = format_info.kind == .Hexadecimal_Uppercase
        when false {
            // @todo(viktor): Assumed to be true for now
            leading_base_specifier := format_info.info.leading_base_specifier || true
            
            placeholder : u64
            switch v in format_info.v {
              case f16:   print_float_as_hex(ctx, cast(f16) v, is_uppercase, leading_base_specifier)
              case f16le: print_float_as_hex(ctx, cast(f16) v, is_uppercase, leading_base_specifier)
              case f16be: print_float_as_hex(ctx, cast(f16) v, is_uppercase, leading_base_specifier)
              
              case f32:   print_float_as_hex(ctx, cast(f32) v, is_uppercase, leading_base_specifier)
              case f32le: print_float_as_hex(ctx, cast(f32) v, is_uppercase, leading_base_specifier)
              case f32be: print_float_as_hex(ctx, cast(f32) v, is_uppercase, leading_base_specifier)
              
              case f64:   print_float_as_hex(ctx, cast(f64) v, is_uppercase, leading_base_specifier)
              case f64le: print_float_as_hex(ctx, cast(f64) v, is_uppercase, leading_base_specifier)
              case f64be: print_float_as_hex(ctx, cast(f64) v, is_uppercase, leading_base_specifier)
            // @todo(viktor): add leading base specifier
            // @todo(viktor): Why do these not match the odin version? copy the hex values into the code and check them with asserts.
            // @todo(viktor): The bits are wrong
              case complex32:
                a := transmute([2]f16) v
                print_float_as_hex(ctx, a[0], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[1], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'i')
                
              case complex64:
                a := transmute([2]f32) v
                print_float_as_hex(ctx, a[0], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[1], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'i')
                
              case complex128:
                a := transmute([2]f64) v
                print_float_as_hex(ctx, a[0], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[1], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'i')
                
              case quaternion64:
                a := transmute([4]f16) v
                print_float_as_hex(ctx, a[3], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[0], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'i')
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[1], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'j')
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[2], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'k')
                
              case quaternion128:
                a := transmute([4]f32) v
                print_float_as_hex(ctx, a[3], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[0], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'i')
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[1], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'j')
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[2], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'k')
                
              case quaternion256:
                a := transmute([4]f64) v
                print_float_as_hex(ctx, a[3], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[0], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'i')
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[1], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'j')
                append(&ctx.buffer, '+')
                print_float_as_hex(ctx, a[2], is_uppercase, leading_base_specifier)
                append(&ctx.buffer, 'k')
                
            }
            
            ctx.handled = true
        } else {
            ctx.verb = is_uppercase ? 'H' : 'h'
        }
    }
}

print_float_as_hex :: proc(ctx: ^FormatContext, value: union #no_nil {f16, f32, f64}, is_uppercase: b32, leading_base_specifier: b32) {
    if leading_base_specifier {
        append(&ctx.buffer, '0')
        append(&ctx.buffer, is_uppercase ? 'H' : 'h')
    }
    
    placeholder: u64
    switch v in value {
      case f16: (cast(^f16) &placeholder) ^= v; print_hex(ctx, placeholder, 16, is_uppercase, false)
      case f32: (cast(^f32) &placeholder) ^= v; print_hex(ctx, placeholder, 32, is_uppercase, false)
      case f64: (cast(^f64) &placeholder) ^= v; print_hex(ctx, placeholder, 64, is_uppercase, false)
    }
}

print_hex :: proc(ctx: ^FormatContext, value: u64, bit_count: u32, upper_case: b32, is_signed: b32) {
    chars :string= upper_case ? "0123456789ABCDEF" : "0123456789abcdef"
    is_negative := value >> (bit_count-1) != 0
    if is_signed && is_negative {
        append(&ctx.buffer, '-')
    }
    
    value := value
    bytes := (cast([^]u8) &value)[:bit_count/8]
    is_leading_zero := true
    #reverse for bits in bytes {
        if (bits & 0xFF) != 0 || !is_leading_zero {
            a := (bits >> 4) & 0xF
            b := bits & 0xF
            if is_leading_zero && a != 0 do append(&ctx.buffer, chars[a])
            is_leading_zero &&= a == 0
            append(&ctx.buffer, chars[b])
        }
    }
}

print_integer :: proc(ctx: ^FormatContext, format_info: IntegerFormat) {
    timed_function()
    ctx.value = format_info.v

    if format_info.info.leading_base_specifier do append(&ctx.builder, '#')
    
    switch kind in format_info.kind {
      case IntegerFormatBase:
        switch kind {
          case .Binary:                ctx.verb = 'b'
          case .Octal:                 ctx.verb = 'o'
          case .Decimal:               ctx.verb = 'd'
          case .Duodecimal:            ctx.verb = 'z'
          case .Hexadecimal_Lowercase, .Hexadecimal_Uppercase:
            is_uppercase : b32 = kind == .Hexadecimal_Uppercase
            
            if format_info.info.leading_base_specifier {
                append(&ctx.buffer, '0')
                append(&ctx.buffer, is_uppercase ? 'X' : 'x')
            }
            
            switch v in format_info.v {
              case int:     print_hex(ctx, cast(u64) v, 8*size_of(int),     is_uppercase, true)
              case uint:    print_hex(ctx, cast(u64) v, 8*size_of(uint),    is_uppercase, false)
              case uintptr: print_hex(ctx, cast(u64) v, 8*size_of(uintptr), is_uppercase, false)
              
              case i8:      print_hex(ctx, cast(u64) v, 8,   is_uppercase, true)
              case u8:      print_hex(ctx, cast(u64) v, 8,   is_uppercase, false)
              
              case i16:     print_hex(ctx, cast(u64) v, 16,  is_uppercase, true)
              case i16le:   print_hex(ctx, cast(u64) v, 16,  is_uppercase, true)
              case i16be:   print_hex(ctx, cast(u64) v, 16,  is_uppercase, true)
              case u16:     print_hex(ctx, cast(u64) v, 16,  is_uppercase, false)
              case u16le:   print_hex(ctx, cast(u64) v, 16,  is_uppercase, false)
              case u16be:   print_hex(ctx, cast(u64) v, 16,  is_uppercase, false)
              
              case i32:     print_hex(ctx, cast(u64) v, 32,  is_uppercase, true)
              case i32le:   print_hex(ctx, cast(u64) v, 32,  is_uppercase, true)
              case i32be:   print_hex(ctx, cast(u64) v, 32,  is_uppercase, true)
              case u32:     print_hex(ctx, cast(u64) v, 32,  is_uppercase, false)
              case u32le:   print_hex(ctx, cast(u64) v, 32,  is_uppercase, false)
              case u32be:   print_hex(ctx, cast(u64) v, 32,  is_uppercase, false)
              
              case i64:     print_hex(ctx, cast(u64) v, 64,  is_uppercase, true)
              case i64le:   print_hex(ctx, cast(u64) v, 64,  is_uppercase, true)
              case i64be:   print_hex(ctx, cast(u64) v, 64,  is_uppercase, true)
              case u64:     print_hex(ctx,           v, 64,  is_uppercase, false)
              case u64le:   print_hex(ctx, cast(u64) v, 64,  is_uppercase, false)
              case u64be:   print_hex(ctx, cast(u64) v, 64,  is_uppercase, false)
             
              case i128:    
                print_hex(ctx, cast(u64) (v >> 64), 64, is_uppercase, false)
                print_hex(ctx, cast(u64) v, 64, is_uppercase, true)
              case i128le:  
                print_hex(ctx, cast(u64) (v >> 64), 64, is_uppercase, false)
                print_hex(ctx, cast(u64) v, 64, is_uppercase, true)
              case i128be:  
                print_hex(ctx, cast(u64) (v >> 64), 64, is_uppercase, false)
                print_hex(ctx, cast(u64) v, 64, is_uppercase, true)
              case u128:    
                print_hex(ctx, cast(u64) (v >> 64), 64, is_uppercase, false)
                print_hex(ctx, cast(u64) v, 64, is_uppercase, false)
              case u128le:  
                print_hex(ctx, cast(u64) (v >> 64), 64, is_uppercase, false)
                print_hex(ctx, cast(u64) v, 64, is_uppercase, false)
              case u128be:  
                print_hex(ctx, cast(u64) (v >> 64), 64, is_uppercase, false)
                print_hex(ctx, cast(u64) v, 64, is_uppercase, false)
            }
            
            ctx.handled = true
        }
        
      case IntegerFormatAsCharacter:
        switch kind {
          case .Character, .Rune: ctx.verb = 'c'
          case .Unicode_Format:   ctx.verb = 'U'
        }
    }
}

// @todo(viktor): maybe move into util?
any_cast :: proc($T: typeid, value: any) -> T {
    raw := transmute(RawAny) value
    return (cast(^T) raw.data)^
}

////////////////////////////////////////////////

when IsRunAsFile {
    main :: proc() {
        
        Foo :: struct {
            first: i32,
            second: b32,
            third: f64,
            fourth: []Foo,
        }
        foo := Foo{987, false, -69.420, { {1, true, 99, {}} } }
        
        println("Hello World")
        
        bar(false, true, "Hello World", cstring("A C string"), 123)
        // println("Hello %\n", "World")
        // fmt.printfln("%m", 1024*1024*64)
        
        // compare("%%", "%v",  GeneralFormat{ })
        // println("\n----------------\nStructs\n----------------")
        // compare(foo, "%v",  GeneralFormat{ })
        // compare(foo, "%#v", GeneralFormat{ info = { expanded = true } })
        // compare(foo, "%w",  GeneralFormat{ kind = .OdinSyntaxOfValue})
        // compare(foo, "%T",  GeneralFormat{ kind = .OdinSyntaxOfType})
        
        // println("\n----------------\nBoolean\n----------------")
        // compare(false, "%t", BooleanFormat{})
        // compare(true,  "%t", BooleanFormat{})
        
        // println("\n----------------\nPointers\n----------------")
        // dummy: rawptr
        // compare(&foo, "%p", format_pointer(dummy))
        // compare(foo.fourth, "%p", format_pointer(dummy))
        // compare(dummy,      "%p", format_pointer(dummy))
        
        // compare(&foo, "%p", format_pointer(dummy))
        // compare(&foo, "%#p", format_pointer(dummy, leading_base_specifier = false))
        
        // compare(&foo.first, "%b", format_pointer(dummy, .Binary))
        // compare(&foo.first, "%d", format_pointer(dummy, .Decimal))
        // compare(&foo.first, "%o", format_pointer(dummy, .Octal))
        // compare(&foo.first, "%z", format_pointer(dummy, .Duodecimal))
        // compare(&foo.first, "%x", format_pointer(dummy, .Hexadecimal_Lowercase))
        // compare(&foo.first, "%X", format_pointer(dummy, .Hexadecimal_Uppercase))
        
        // println("\n----------------\nFloats\n----------------")
        // compare(foo.third, "%f", FloatFormat{kind = .Default})
        // compare(foo.third, "%g", FloatFormat{kind = .MaximumPercision})
        // compare(foo.third, "%e", FloatFormat{kind = .Scientific_Lowercase})
        // compare(foo.third, "%E", FloatFormat{kind = .Scientific_Uppercase})
        // compare(foo.third, "%h", FloatFormat{kind = .Hexadecimal_Lowercase})
    
        // compare(cast(f16) foo.third, "%h", FloatFormat{kind = .Hexadecimal_Lowercase})
        // compare(cast(f32) foo.third, "%h", FloatFormat{kind = .Hexadecimal_Lowercase})
        // compare(foo.third, "%h", FloatFormat{kind = .Hexadecimal_Lowercase})
        // compare(cast(f16) foo.third, "%H", FloatFormat{kind = .Hexadecimal_Uppercase})
        // compare(cast(f32) foo.third, "%H", FloatFormat{kind = .Hexadecimal_Uppercase})
        // compare(foo.third, "%H", FloatFormat{kind = .Hexadecimal_Uppercase})
        // x :f64= 0hD457
        // fmt.printfln("%h", x)
        // fmt.printfln("%h", foo.third)
        // fmt.printfln("%h", f64(0h0d47))
            
        // c: complex128 = 1 + 20i
        // q: quaternion256 = 1 + 20i + 400j + 8000k
        // compare(c, "%f", FloatFormat{})
        // compare(q, "%f", FloatFormat{})
        // compare(c, "%h", FloatFormat{ kind = .Hexadecimal_Lowercase })
        // compare(q, "%h", FloatFormat{ kind = .Hexadecimal_Lowercase })
        
        // println("\n----------------\nIntegers\n----------------")
        // compare(foo.first, "%b", IntegerFormat{kind = .Binary})
        // compare(foo.first, "%d", IntegerFormat{kind = .Decimal})
        // compare(foo.first, "%o", IntegerFormat{kind = .Octal})
        // compare(foo.first, "%z", IntegerFormat{kind = .Duodecimal})
        // compare(foo.first, "%x", IntegerFormat{kind = .Hexadecimal_Lowercase})
        // compare(foo.first, "%X", IntegerFormat{kind = .Hexadecimal_Uppercase})
        
        // info := FormatInfo { leading_base_specifier = true }
        // compare(foo.first, "%#b", IntegerFormat{kind = .Binary,                info = info})
        // compare(foo.first, "%#o", IntegerFormat{kind = .Octal,                 info = info})
        // compare(foo.first, "%#d", IntegerFormat{kind = .Decimal,               info = info})
        // compare(foo.first, "%#z", IntegerFormat{kind = .Duodecimal,            info = info})
        // compare(foo.first, "%#x", IntegerFormat{kind = .Hexadecimal_Lowercase, info = info})
        // compare(foo.first, "%#X", IntegerFormat{kind = .Hexadecimal_Uppercase, info = info})
        
        // compare(max(i64), "%d", IntegerFormat{})
        // compare(min(i64), "%d", IntegerFormat{})
        // compare(max(u64), "%d", IntegerFormat{})
        
        // compare(69, "%r", IntegerFormat{kind = .Rune})
        // compare(cast(i32) 'ô', "%r", IntegerFormat{kind = .Rune})
        // compare(69, "%c", IntegerFormat{kind = .Character})
        // compare(cast(i32) 'ô', "%c", IntegerFormat{kind = .Character})
        // compare(69, "%U", IntegerFormat{kind = .Unicode_Format})
        
        // println("\n----------------\nStrings\n----------------")
        // compare("Hello \"World\"", "%s", StringFormat{kind = .Default})
        // compare("Hello \"World\"", "%q", StringFormat{kind = .DoubleQuoted_Escaped})
        // compare("E", "%3x", StringFormat{kind = .Hexadecimal_Lowercase, info = { width = 3 }})
        // compare("E", "%3X", StringFormat{kind = .Hexadecimal_Uppercase, info = { width = 3 }})
        // compare(" Hello \"World\"", "%x", StringFormat{kind = .Hexadecimal_Lowercase})
        // compare(" Hello \"World\"", "%X", StringFormat{kind = .Hexadecimal_Uppercase})
        // cs :cstring= "Hello Sailor"
        // compare(cs, "%s", StringFormat{kind = .Default})
        
        // println("\n----------------\nEnums\n----------------")
        // compare(IntegerFormatBase.Duodecimal, "%v", format_enum(IntegerFormatBase.Duodecimal))
        // compare(IntegerFormatBase.Duodecimal, "%s", format_enum(IntegerFormatBase.Duodecimal))
        // compare(IntegerFormatBase.Duodecimal, "%d", format_enum(IntegerFormatBase.Duodecimal, .Decimal))
        
        // println("\n----------------\nWidth and Precision\n----------------")
        // compare("'ATextWith20Letters'", "%19s",   StringFormat{ info = { width = 20 } })
        // compare("'ATextWith20Letters'", "%21s",   StringFormat{ info = { width = 22 } })
        
        // compare(foo.third, "%g",    FloatFormat{ kind = .MaximumPercision })
        // compare(foo.third, "%8f",   FloatFormat{ info = { width = 8 } })
        // compare(foo.third, "%.f",   FloatFormat{ info = { precision = 0 } })
        // compare(foo.third, "%.2f",  FloatFormat{ info = { precision = 2 } })
        // compare(foo.third, "%8.3f", FloatFormat{ info = { width = 8, precision = 3 } })
    }
    
    compare :: proc(value: $T, odin_format: string, format_struct: $F) {
        format_struct := format_struct
        
        format_struct.v = value
        
        print("odin: "); fmt.printfln(odin_format, value)
        print("mine: "); println("%", format_struct)
    }
}
    
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

    append :: proc { append_fixed_array, append_array, append_array_, append_array_many, append_fixed_array_many }
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

    rest :: proc{ rest_fixed_array, rest_array }
    rest_fixed_array :: proc(array: ^FixedArray($N, $T)) -> []T {
        return array.data[array.count:]
    }
    rest_array :: proc(array: Array($T)) -> []T {
        return array.data[array.count:]
    }
    
    timed_function :: proc() {}
    timed_block :: proc(s: string) {}
    
    MaxF64Precision :: 16
}