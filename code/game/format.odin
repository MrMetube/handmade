#+vet !unused-procedures
package game

@(common="file")

import "core:fmt"
import "core:os"
import "core:io"
import "shared"

@(thread_local) console_buffer: [8 * Megabyte] u8

////////////////////////////////////////////////

@(printlike)
print_to_console :: proc (format: string, args: ..any, append_zero := false, console := os.stdout) {
    result := format_string(buffer = console_buffer[:], format = format, args = args, append_zero = append_zero)
    os.write_string(console, result)
}

// @todo(viktor): string and cstring is a bunch of @copypasta code, that sucks especially because all the format code changes is if it appends a zero at the end
@(printlike)
print_to_allocator :: proc (allocator: Allocator, format: string, args: ..any, append_zero := false) -> string {
    s := format_string(buffer = console_buffer[:], format = format, args = args, append_zero = append_zero)
    buffer := make(allocator, u8, len(s), no_clear())
    copy(buffer, s)
    result := transmute(string) buffer
    return result
}
@(printlike)
cprint_to_allocator :: proc (allocator: Allocator, format: string, args: ..any, append_zero := true) -> cstring {
    s, length := format_cstring(buffer = console_buffer[:], format = format, args = args, append_zero = append_zero)
    buffer := make(allocator, u8, length, no_clear())
    copy(buffer, slice_from_parts(u8, cast(^u8) s, length))
    result := cast(cstring) raw_data(buffer)
    return result
}

////////////////////////////////////////////////

print  :: print_to_console
aprint :: print_to_allocator
@(printlike) tprint  :: proc (format: string, args: ..any) -> string  { return print_to_allocator(allocator  = context.temp_allocator,  format = format, args = args, append_zero = false) }
@(printlike) sprint  :: proc (format: string, args: ..any) -> string  { return print_to_allocator(allocator  = context.allocator,       format = format, args = args, append_zero = false) }
@(printlike) ctprint :: proc (format: string, args: ..any) -> cstring { return cprint_to_allocator(allocator = context.temp_allocator,  format = format, args = args, append_zero = true)  }
@(printlike) cprint  :: proc (format: string, args: ..any) -> cstring { return cprint_to_allocator(allocator = context.allocator,       format = format, args = args, append_zero = true)  }

////////////////////////////////////////////////

@(printlike)
format_cstring :: proc (buffer: [] u8, format: string, args: ..any, append_zero := true) -> (result: cstring, length: int) {
    s := format_string(buffer, format, ..args, append_zero = append_zero)
    result = cast(cstring) raw_data(s)
    length = len(s)
    return result, length
}

@(printlike)
format_string :: proc (buffer: [] u8, format: string, args: ..any, append_zero := false) -> string {
    builder := make_string_builder(buffer)
    arg_index: int
    
    w := io.Writer { 
        procedure = proc (data: pmm, mode: io.Stream_Mode, input: [] byte, _: i64, _: io.Seek_From) -> (i64, io.Error) {
            builder := cast(^String_Builder) data
            
            #partial switch mode {
            case .Write:
                written := append(builder, ..input)
                assert(written == len(input))
                return cast(i64) written, nil
                
            case .Query: return io.query_utility({.Write, .Query})
            case:        return 0, .Unsupported
            }
        }, 
        data = &builder,
    }
    
    
    for iter := shared.make_format_iterator(format); part in shared.iterate_format(&iter) {
        switch part.kind {
        case .Escaped: append(&builder, '%')
        case .Text:    append_string(&builder, part.text)
        
        case .Percent:
            arg := args[arg_index]
            arg_index += 1
            
            fmt.fmt_value(&fmt.Info { writer = w }, arg, 'v')
        }
    }
    
    assert(arg_index == len(args))
    if append_zero { append(&builder, 0) }
    
    result := to_string(builder)
    return result
}