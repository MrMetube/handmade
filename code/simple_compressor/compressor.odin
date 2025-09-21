package main

import "core:os"
import "core:fmt"
import "core:hash"
/* 
 @todo(viktor): 
 
 I     Figure out an efficient way to expand the LZ encoding to support > 255 size lookback and/or runs
 II    Add an entropy backend like Huffman, Arithmetic, something from the ANS family
 III   Add a hash lookout or other acceleration structure to the LZ encoder so that it isn't unusuably slow
 IV    Add better heuristics to the LZ compressor to get closer to an optimal parse
 V     Add preconditioners to test whether something better can be done for bitmaps(like differencing, deinterleaving by 4, etc.)
 VI    Add the concept of switchable compression mid-stream to allow different blocks to be encoded with different methods
 
 I*    Figure out how to multithread the encoding (maybe split the input into blocks that are each encoded and the concatenated?)
 II*   Figure out how to use SIMD in the encoding
 */

Stat_Kind :: enum {
    Literal, 
    Repeat,
    Copy,
}

Stat :: struct {
    count, total: int,
}

Stat_Group :: struct {
    uncompressed_bytes: int,
    compressed_bytes:   int,
    decompressed_bytes: int,
    
    uncompressed_bytes_hash: u32,
    compressed_bytes_hash:   u32,
    decompressed_bytes_hash: u32,
    
    stats: [Stat_Kind] Stat,
}

Compressor :: struct {
    name: string,
    compress: Compressor_Proc,
    decompress: Decompressor_Proc,
}

Compressor_Proc   :: #type proc (input: [] u8, output: ^[dynamic] u8, group: ^Stat_Group = nil)
Decompressor_Proc :: #type proc (input: [] u8, output: ^[dynamic] u8)

compressors := [?] Compressor {
    {"RLE", rle_compress, rle_decompress},
    {"LZ",  lz_compress,  lz_decompress },
}

////////////////////////////////////////////////

main :: proc () {
    if len(os.args) == 5 {
        compressor_name := os.args[1]
        operation := os.args[2]
        input_file := os.args[3]
        output_file := os.args[4]
        
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
        
        compressor: Compressor
        for it in compressors do if it.name == compressor_name {
            compressor = it
            break
        }
        if compressor == {} {
            fmt.printfln("ERROR: unknown compressor selected: '%v'", compressor_name)
            usage()
        }
        
        stat_group: Stat_Group
        
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
            
            compressor.compress(input, &max_output)
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
            compressor.decompress(input[4:], &max_output)
            output = max_output[:]

        case "test":
            max_size := get_maximum_compressed_output_size(len(input))
            compressed := make([dynamic] u8, 4, max_size)
            output := make([dynamic] u8, 0, len(input))
            compressor.compress(input, &compressed, &stat_group)
            compressor.decompress(compressed[4:], &output)
            
            stat_group.uncompressed_bytes = len(input)
            stat_group.compressed_bytes   = len(compressed)
            stat_group.decompressed_bytes = len(output)
            
            stat_group.uncompressed_bytes_hash = hash.djb2(input)
            stat_group.compressed_bytes_hash   = hash.djb2(compressed[:])
            stat_group.decompressed_bytes_hash = hash.djb2(output[:])
            
            fmt.printfln("compression factor %.3v%%", cast(f64) stat_group.compressed_bytes / cast(f64) stat_group.uncompressed_bytes * 100)
            fmt.printfln("bytes:  % 12v -> % 12v -> % 12v (%v)", stat_group.uncompressed_bytes, stat_group.compressed_bytes, len(output), stat_group.uncompressed_bytes == stat_group.decompressed_bytes ? "matches" : "does not match")
            fmt.printfln("hashes:   0x%08X ->   0x%08X ->   0x%08X (%v)", stat_group.uncompressed_bytes_hash, stat_group.compressed_bytes_hash, stat_group.decompressed_bytes_hash, stat_group.uncompressed_bytes_hash == stat_group.decompressed_bytes_hash ? "matches" : "does not match")
            for value, stat in stat_group.stats {
                if value.count == 0 do continue
                fmt.printfln("  %8v: %v / %v", stat, value.count, value.total)
            }
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
    result = 256 + length * 8
    return result
}

increment_stat :: proc (group: ^Stat_Group, kind: Stat_Kind, value: int) {
    if group == nil do return
    group.stats[kind].count += 1
    group.stats[kind].total += value
}

////////////////////////////////////////////////

rle_compress : Compressor_Proc : proc (input: [] u8, output: ^[dynamic] u8, group: ^Stat_Group = nil) {
    max_count :: 255
    literals := make([dynamic] u8, 0, 255)
    literals.allocator = {}
    
    for index: int; index < len(input); {
        starting_value := input[index]
        run := 0
        for run < len(input) - index && run < max_count && input[index+run] == starting_value {
            run += 1
        }
        
        literal_count := len(literals)
        if index + 1 == len(input) || run > 1 || literal_count == cap(literals) {
            // @note(viktor): output a literal/run pair
            assert(literal_count <= max_count)
            
            increment_stat(group, .Literal, literal_count)
            increment_stat(group, .Repeat, run)
            
            append(output, cast(u8) literal_count)
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
    
    assert(len(literals) == 0)
}

rle_decompress : Decompressor_Proc : proc (input: [] u8, output: ^[dynamic] u8) {
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

lz_compress : Compressor_Proc : proc (input: [] u8, output: ^[dynamic] u8, group: ^Stat_Group = nil) {
    max_count :: 255
    literals := make([dynamic] u8, 0, max_count)
    literals.allocator = {}
    
    for index: int; index <= len(input); {
        best_run: int
        best_offset: int
        max_lookback := min(max_count, index)
        for window_begin := index - max_lookback; window_begin < index; window_begin += 1 {
            window_len := min(max_count, len(input) - window_begin)
            window_end := window_begin + window_len
            
            test_index := index
            window_index := window_begin
            test_run: int
            for window_index < window_end && test_index < len(input) && input[test_index] == input[window_index] {
                test_index   += 1
                window_index += 1
                test_run     += 1
            }
            
            if best_run < test_run {
                best_run = test_run
                best_offset = index - window_begin
            }
        }
        
        
        output_run := false
        if len(literals) != 0 {
            output_run = best_run > 4
        } else {
            output_run = best_run > 2
        }
        
        literal_count := len(literals)
        if index == len(input) || output_run || literal_count == cap(literals) {
            // @note(viktor): flush
            assert(literal_count <= max_count)
            
            
            if literal_count != 0 {
                increment_stat(group, .Literal, literal_count)
                
                append(output, cast(u8) literal_count)
                append(output, 0)
                append(output, ..literals[:])
                clear(&literals)
            }
            
            if output_run {
                increment_stat(group, best_offset >= best_run ? .Copy: .Repeat, best_run)
                
                assert(best_run    <= max_count)
                assert(best_offset <= max_count)
                append(output, cast(u8) best_run)
                append(output, cast(u8) best_offset)
            
                index += best_run
            }
        } else {
            // @note(viktor): buffer literals
            append(&literals, input[index])
            index += 1
        }
        
        if index == len(input) do break
    }
}

lz_decompress : Decompressor_Proc : proc (input: [] u8, output: ^[dynamic] u8) {
    for index: int; index < len(input); {
        count := cast(int) input[index]
        index += 1
        copy_distance := cast(int) input[index]
        index += 1
        
        #no_bounds_check source: [^] u8 = &output[len(output) - copy_distance]
        if copy_distance == 0 {
            source = &input[index] //[:count]
            index += count
        }
        
        for copy_index in 0..<count {
            append(output, source[copy_index])
        }
    }
}

////////////////////////////////////////////////

usage :: proc () {
    fmt.printfln("Usage: %v [Algorithm] compress   [raw file]        [compressed output file]", os.args[0])
    fmt.printfln("       %v [Algorithm] decompress [compressed file] [raw output file]", os.args[0])
    fmt.printfln("       %v [Algorithm] test       [test file]       [ignored]", os.args[0])
    for it in compressors do fmt.printfln("       [Algorithm] = '%v'", it.name)
    os.exit(1)
}