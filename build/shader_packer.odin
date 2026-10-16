package build

import "core:fmt"
import "core:io"
import "core:os"

import "../code/render/shared"

create_shader_pack_file :: proc (shader_pack_path: string) {
    Shaders :: shared.Shaders
    Stage :: enum { vertex, fragment }
    
    shaders := [Shaders] string {
        .zbias                  = "code/render/zbias.slang",
        .peel_composite         = "code/render/peel_composite.slang",
        .multisample_resolve    = "code/render/multisample_resolve.slang",
        .final_stretch          = "code/render/final_stretch.slang",
        .multigrid_light_up     = "code/render/multigrid_light_up.slang",
        .multigrid_light_down   = "code/render/multigrid_light_down.slang",
        .depth_peel_to_lighting = "code/render/depth_peel_to_lighting.slang",
    }
    
    shader_spirv: [Shaders] [Stage] [] u8
    
    {
        read_ends: [Shaders] [Stage] ^os.File
        
        procs: Procs
        
        for source, shader in shaders {
            for stage in Stage {
                append(cmd, "slangc")
                append(cmd, source)
                append(cmd, "-target", "spirv")
                append(cmd, "-fvk-use-c-layout")
                append(cmd, "-capability", "spvDescriptorHeapEXT")
                if !optimize { append(cmd, "-g") }
                // @todo -O<level>
                append(cmd, "-entry", fmt.tprintf("%sMain", stage))
                
                read_end, write_end, pipe_error := os.pipe(); assert(pipe_error == nil)
                
                proc_index := len(procs)
                run_command(cmd, async = &procs, stdout = write_end)
                os.close(write_end)
                
                read_ends[shader][stage] = read_end
            }
        }
        
        // @todo just allocate a single large buffer and copy/os.read the outputs into it after another and store string/slices into that big buffer
        buf: [128*1024] u8
        for stages, shader in read_ends {
            for read_end, stage in stages {
                bytes: [dynamic] u8
                
                for {
                    n, err := os.read(read_end, buf[:])
                    if n > 0 { append(&bytes, ..buf[:n]) }
                    if err == .Broken_Pipe || err == .EOF { break }
                    assert(err == nil)
                }
                os.close(read_end)
                
                shader_spirv[shader][stage] = bytes[:]
            }
        }
        
        procs_flush(&procs)
    }
    
    full_path := fmt.tprintf("data/%v", shader_pack_path)
    file, err := os.open(full_path, { .Create, .Write, .Trunc })
    assert(err == nil)
    defer os.close(file)
    
    write_value :: proc (w: io.Writer, value: $T) {
        value := value
        n, err := io.write_ptr(w, &value, size_of(value))
        assert(err == nil && n == size_of(value))
    }
    
    write_bytes :: proc (w: io.Writer, bytes: [] u8) {
        n, err := io.write_full(w, bytes)
        assert(err == nil && n == len(bytes))
    }
    
    header: shared.ShaderPackHeader
    copy(header.magic[:], "SPAK") 
    header.version = 1
    
    data_offset := cast(u64) size_of(header)
    for &info, shader in header.infos {
        it := shader_spirv[shader]
        
        info.vertex_offset = data_offset
        info.vertex_count  = cast(u64) len(it[.vertex])
        data_offset += info.vertex_count
        
        info.fragment_offset = data_offset
        info.fragment_count  = cast(u64) len(it[.fragment])
        data_offset += info.fragment_count
    }
    
    w := os.to_writer(file)
    write_value(w, header)
    
    for it in shader_spirv {
        write_bytes(w, it[.vertex])
        write_bytes(w, it[.fragment])
    }
    
    fmt.printf("INFO: generated packed shader data at %q\n", full_path)
}