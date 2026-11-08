package build

import "core:fmt"
import "core:io"
import "core:os"

import "../code/render/shared"

create_shader_pack_file :: proc (shader_pack_path: string, optimize: bool) -> bool {
    Stage  :: enum { mesh, vertex, fragment }
    Shader :: struct {
        stages: bit_set[Stage],
        source:   string,
        data:   [Stage] struct { spirv: [] u8, read_end: ^os.File }
    }
    
    shaders: [shared.Shaders] Shader = {
        .zbias                  = { stages = { .mesh,   .fragment }, source = "code/render/zbias.slang" },
        .peel_composite         = { stages = { .vertex, .fragment }, source = "code/render/peel_composite.slang" },
        .multisample_resolve    = { stages = { .vertex, .fragment }, source = "code/render/multisample_resolve.slang" },
        .final_stretch          = { stages = { .vertex, .fragment }, source = "code/render/final_stretch.slang" },
        .multigrid_light_up     = { stages = { .vertex, .fragment }, source = "code/render/multigrid_light_up.slang" },
        .multigrid_light_down   = { stages = { .vertex, .fragment }, source = "code/render/multigrid_light_down.slang" },
        .depth_peel_to_lighting = { stages = { .vertex, .fragment }, source = "code/render/depth_peel_to_lighting.slang" },
    }
    
    storage_buffer := make([dynamic] u8, 0, 128*1024*1024)
    
    {
        procs: Procs
        
        for &shader in shaders {
            for stage in shader.stages {
                append(cmd, "slangc")
                append(cmd, shader.source)
                append(cmd, "-target", "spirv")
                append(cmd, "-fvk-use-c-layout")
                append(cmd, "-capability", "spvDescriptorHeapEXT")
                if !optimize { append(cmd, "-g") }
                if optimize { append(cmd, "-O2") }
                append(cmd, "-entry", fmt.tprintf("%sMain", stage))
                
                read_end, write_end, error := os.pipe(); assert(error == nil)
                
                proc_index := len(procs)
                run_command(cmd, async = &procs, stdout = write_end)
                os.close(write_end)
                
                shader.data[stage].read_end = read_end
            }
        }
        
        read_buffer: [4*1024] u8
        for &shader in shaders {
            for stage in shader.stages {
                it := &shader.data[stage]
                start := len(storage_buffer)
                
                for {
                    n, err := os.read(it.read_end, read_buffer[:])
                    if n > 0 { append(&storage_buffer, ..read_buffer[:n]) }
                    if err == .Broken_Pipe || err == .EOF { break }
                    assert(err == nil)
                }
                os.close(it.read_end)
                
                it.spirv = storage_buffer[start:]
            }
        }
        
        if !procs_flush(&procs) { return false }
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
        it := shaders[shader]
        
        first_stage := .mesh in it.stages ? Stage.mesh : .vertex
        
        info.first_stage_offset = data_offset
        info.first_stage_count  = cast(u64) len(it.data[first_stage].spirv)
        data_offset += info.first_stage_count
        
        info.fragment_offset = data_offset
        info.fragment_count  = cast(u64) len(it.data[.fragment].spirv)
        data_offset += info.fragment_count
        
        info.is_mesh_shader = .mesh in it.stages
    }
    
    w := os.to_writer(file)
    write_value(w, header)
    
    for it in shaders {
        first_stage := .mesh in it.stages ? Stage.mesh : .vertex
        write_bytes(w, it.data[first_stage].spirv)
        write_bytes(w, it.data[.fragment].spirv)
    }
    
    fmt.printf("INFO: generated packed shader data at %q (%v shaders)\n", full_path, len(shaders))
    return true
}