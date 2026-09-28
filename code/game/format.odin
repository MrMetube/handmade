#+vet !unused-procedures
// #+no-instrumentation
package game

@(common="file")

import "core:fmt"
import "core:os"
import "core:io"
import "shared"

// @volatile This breaks if in the midst of a print we start another print on the same thread. we could use a cursor to know from where onwards we can use the buffer.
@(thread_local) console_buffer: [8 * Megabyte] u8

////////////////////////////////////////////////

@(printlike)
print_to_console :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, console := os.stdout) {
    result := format_string(buffer = console_buffer[:], format = format, args = args, flags = flags)
    os.write(console, transmute([]u8) result)
}

// @todo(viktor): string and cstring is a bunch of @copypasta code, that sucks especially because all the format code changes is if it appends a zero at the end
@(printlike)
print_to_allocator :: proc (allocator: Allocator, format: string, args: ..any, flags: Format_Context_Flags = {}) -> string {
    s := format_string(buffer = console_buffer[:], format = format, args = args, flags = flags)
    buffer := make(allocator, u8, len(s), no_clear())
    copy(buffer, s)
    result := transmute(string) buffer
    return result
}
@(printlike)
cprint_to_allocator :: proc (allocator: Allocator, format: string, args: ..any, flags: Format_Context_Flags = {}) -> cstring {
    s, length := format_cstring(buffer = console_buffer[:], format = format, args = args, flags = flags)
    buffer := make(allocator, u8, length, no_clear())
    copy(buffer, slice_from_parts(u8, cast(^u8) s, length))
    result := cast(cstring) raw_data(buffer)
    return result
}

////////////////////////////////////////////////

print  :: print_to_console
aprint :: print_to_allocator
@(printlike) tprint  :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, allocator := context.temp_allocator) -> string  { return print_to_allocator(allocator = allocator, format = format, args = args, flags = flags) }
@(printlike) sprint  :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, allocator := context.allocator)      -> string  { return print_to_allocator(allocator = allocator, format = format, args = args, flags = flags) }
@(printlike) ctprint :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, allocator := context.temp_allocator) -> cstring { return cprint_to_allocator(allocator = allocator, format = format, args = args, flags = flags) }
@(printlike) cprint  :: proc (format: string, args: ..any, flags: Format_Context_Flags = {}, allocator := context.allocator)      -> cstring { return cprint_to_allocator(allocator = allocator, format = format, args = args, flags = flags) }

////////////////////////////////////////////////

Format_Context_Flags :: bit_set[ enum u8 { PrependTypes, Multiline, AppendZero }; u8 ]

@(printlike)
format_cstring :: proc (buffer: []u8, format: string, args: ..any, flags := Format_Context_Flags {}) -> (result: cstring, length: int) {
    s := format_string(buffer, format, ..args, flags = flags + { .AppendZero })
    result = cast(cstring) raw_data(s)
    length = len(s)
    return result, length
}

@(printlike)
format_string :: proc (buffer: []u8, format: string, args: ..any, flags := Format_Context_Flags{}) -> string {
    builder := make_string_builder(buffer)
    arg_index: int
    
    w := io.Writer { 
        procedure = proc (data: pmm, mode: io.Stream_Mode, input: []byte, _: i64, _: io.Seek_From) -> (i64, io.Error) {
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
        data = &builder
    }
    
    
    for iter := shared.make_format_iterator(format); part in shared.iterate_format(&iter) {
        switch part.kind {
        case .Escaped: append(&builder, '%')
        case .Text:    append_string(&builder, part.text)
        
        case .Percent:
            assert(arg_index < len(args))
            
            fmt.fmt_value(&fmt.Info { writer = w }, args[arg_index], 'v')
            
            arg_index += 1
        }
    }
    
    assert(arg_index == len(args))
    if .AppendZero in flags do append(&builder, 0)
    
    result := to_string(builder)
    return result
}