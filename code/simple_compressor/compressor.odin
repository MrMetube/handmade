package main

import "core:os"
import "core:fmt"
import "core:hash"

main :: proc () {
    if len(os.args) == 4 {
        operation := os.args[1]
        input_file := os.args[2]
        output_file := os.args[3]
        
        input, ok := os.read_entire_file(input_file)
        if !ok {
            fmt.printfln("ERROR: failed to read input '%v': %v", input_file, os.error_string(os.get_last_error()))
            os.exit(1)
        }
        
        out, err := os.open(output_file, os.O_CREATE)
        if err != nil {
            fmt.printfln("ERROR: failed to open output '%v': %v", output_file, os.error_string(os.get_last_error()))
            os.exit(1)
        }
        output: [] u8
        switch operation {
        case: 
            fmt.printfln("ERROR: unknown operation selected: '%v'", operation)
            usage()
            
        case "compress":
            max_size := get_maximum_compressed_output_size(len(input))
            max_output := make([dynamic] u8, 4, max_size)
            max_output.allocator = {}
            
            fmt.printfln("compressing %v...", input_file)
            
            compress(input, &max_output)
            length := len(input)
            copy(max_output[:4], (transmute(^[4] u8) &length)[:])
            output = max_output[:]
            
        case "decompress":
            if len(input) < 4 {
                fmt.printfln("ERROR: invalid input file.")
                os.exit(1)
            }
            
            input_length := (transmute(^u32) &input[:4][0])^
            max_output := make([dynamic] u8, 0, input_length)
            fmt.printfln("decompressing %v...", input_file)
            max_output.allocator = {}
            decompress(input[4:], &max_output)
            output = max_output[:]

        case "test":
            max_size := get_maximum_compressed_output_size(len(input))
            compressed := make([dynamic] u8, 4, max_size)
            output := make([dynamic] u8, 0, len(input))
            compress(input, &compressed)
            decompress(compressed[4:], &output)
            
            fmt.printfln("input is        % 10v bytes (hash 0x%0X)", len(input), hash.djb2(input))
            fmt.printfln("compressed is   % 10v bytes (hash 0x%0X)", len(compressed[:]), hash.djb2(compressed[:]))
            fmt.printfln("decompressed is % 10v bytes (hash 0x%0X)", len(output[:]), hash.djb2(output[:]))
        }
        
        if output != nil {
            fmt.println("writing...")
            os.write(out, output[:])
            fmt.println("done!")
            
            fmt.printfln("input was % 10v bytes (hash 0x%0X)", len(input), hash.djb2(input))
            fmt.printfln("output is % 10v bytes (hash 0x%0X)", len(output), hash.djb2(output))
        }
    } else {
        fmt.println("ERROR: Wrong number of arguments")
        usage()
    }
}

////////////////////////////////////////////////

get_maximum_compressed_output_size :: proc (length: int) -> (result: int) {
    // @todo(viktor): actually compute this accurately
    result = length * 2
    return result
}

compress :: proc (input: [] u8, output: ^[dynamic] u8) {
    lz_compress(input, output)
}

decompress :: proc (input: [] u8, output: ^[dynamic] u8) {
    lz_decompress(input, output)
}

////////////////////////////////////////////////

rle_compress :: proc (input: [] u8, output: ^[dynamic] u8) {
    max_count :: 255
    literals := make([dynamic] u8, 0, 255)
    literals.allocator = {}
    
    for index: int; index < len(input); {
        starting_value := input[index]
        run := 1
        for run < len(input) - index && run < max_count && input[index+run] == starting_value {
            run += 1
        }
        
        if run > 1 || len(literals) == cap(literals) {
            // @note(viktor): output a literal/run pair
            assert(len(literals) <= max_count)
            append(output, cast(u8) len(literals))
            append(output, ..literals[:])
            clear(&literals)
            
            assert(run <= max_count)
            append(output, cast(u8) run)
            append(output, starting_value)
            
            index += run
        } else {
            // @note(viktor): encode a literal
            append(&literals, starting_value)
            
            index += 1
        }
    }
}

rle_decompress :: proc (input: [] u8, output: ^[dynamic] u8) {
    for index: int; index < len(input); {
        literal_count := input[index]
        index += 1
        
        append(output, ..input[index:][:literal_count])
        index += cast(int) literal_count
        
        rep_count := input[index]
        index += 1
        
        rep_value := input[index]
        index += 1
        for _ in 0..<rep_count {
            append(output, rep_value)
        }
        
    }
}

////////////////////////////////////////////////

usage :: proc () {
    fmt.printfln("Usage: %v compress   [raw file]        [compressed output file]", os.args[0])
    fmt.printfln("       %v decompress [compressed file] [raw output file]", os.args[0])
    os.exit(1)
}