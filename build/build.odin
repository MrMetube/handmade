#+vet unused shadowing cast unused-imports style unused-procedures unused-variables
package build

import "core:fmt"
import "core:os"
import "core:strings"


// "-linker:radlink"
// "-build-diagnostics"

platform_flags := [] string { "-subsystem:windows", `-extra-linker-flags:/STACK:0x100000,0x100000` /* get a 1MB stack instead of the default 4kB */ }

PedanticGame     :: false
PedanticPlatform :: false

native   :: true
optimize :: false
internal :: "-define:INTERNAL=true"


/* 
 @todo(viktor):
 - once we have our own "sin()" we can get rid of the c-runtime with "-no-crt"
 - get rid of INTERNAL define
 */
 
////////////////////////////////////////////////
/*
Should the build script itself have flags or should it all be in the file?

- Metaprogram Plugins
  - print checker
  - code gen
  - (build HHAs)

- Debug build with no optimizations then run
  - debug symbols and start debugger

- GPU Debug
  - build and start through renderdoc
  
- Optimized build then run 
  - o:speed, target, microarch

*/
////////////////////////////////////////////////

code_dir :: "code"
game_dir :: "code/game"
game_package :: "game"
main_package :: "main"

main :: proc () {
    // @todo(viktor): handle being called from ./data instead of ./
    init_build(run_from_data = true)
    make_directory_if_not_exists("./data/build")

    vulkan_vertex_path   :: `build/vulkan.vertex.spirv`
    vulkan_fragment_path :: `build/vulkan.fragment.spirv`
    vulkan_composite_vertex_path   :: `build/vulkan.composite_vertex.spirv`
    vulkan_composite_fragment_path :: `build/vulkan.composite_fragment.spirv`
    vulkan_final_vertex_path       :: `build/vulkan.final_vertex.spirv`
    vulkan_final_fragment_path     :: `build/vulkan.final_fragment.spirv`
    vulkan_shader_stages := [] struct { source, stage, output: string } {
        { "code/vulkan.slang",           "vertex",   `data/build/vulkan.vertex.spirv` },
        { "code/vulkan.slang",           "fragment", `data/build/vulkan.fragment.spirv` },
        { "code/vulkan_composite.slang", "vertex",   `data/build/vulkan.composite_vertex.spirv` },
        { "code/vulkan_composite.slang", "fragment", `data/build/vulkan.composite_fragment.spirv` },
        { "code/vulkan_final.slang",     "vertex",   `data/build/vulkan.final_vertex.spirv` },
        { "code/vulkan_final.slang",     "fragment", `data/build/vulkan.final_fragment.spirv` },
    }
    for shader in vulkan_shader_stages {
        append(cmd, "slangc")
        append(cmd, shader.source)
        append(cmd, "-target", "spirv", "-profile", "spirv_1_5", "-emit-spirv-directly", "-fvk-use-entrypoint-name", "-fvk-use-c-layout", "-capability", "spvDescriptorHeapEXT", "-entry")
        // @todo -g for debug info
        append(cmd, fmt.tprintf("%sMain", shader.stage))
        append(cmd, "-stage")
        append(cmd, shader.stage)
        append(cmd, "-o")
        append(cmd, shader.output)
        run_command(cmd, async = procs)
    }
    procs_flush(procs)
    
    // @todo(viktor): these could also be parallelised
    metaprogram: Metaprogram
    if !metaprogram_collect_files_and_parse_package(&metaprogram, code_dir,   main_package)   do os.exit(1)
    if !metaprogram_collect_files_and_parse_package(&metaprogram, game_dir,   game_package)   do os.exit(1)
    // if !metaprogram_collect_files_and_parse_package(&metaprogram, render_dir, render_package) do os.exit(1)
    
    if !metaprogram_collect_plugin_data(&metaprogram, code_dir,   main_package)   do os.exit(1)
    if !metaprogram_collect_plugin_data(&metaprogram, game_dir,   game_package)   do os.exit(1)
    // if !metaprogram_collect_plugin_data(&metaprogram, render_dir, render_package) do os.exit(1)
    
    // @todo(viktor): let the metaprogramms define these attributes at initialization
    sb := strings.builder_make()
    fmt.sbprint(&sb, "-custom-attribute:")
    fmt.sbprint(&sb, "common", "api", "printlike", sep=",")
    custom_attribute_flag := strings.to_string(sb)
    
    sb = strings.builder_make()
    fmt.sbprint(&sb, "-vet-packages:")
    if PedanticGame     do fmt.sbprint(&sb, game_package, ",")
    // if PedanticRender   do fmt.sbprint(&sb, render_package, ",")
    if PedanticPlatform do fmt.sbprint(&sb, main_package, ",")
    fmt.sbprint(&sb, "hha")
    pedantic_vet_packages := strings.to_string(sb)
    
    if begin_build(cmd, "code/asset_builder", "asset_builder.exe") {
        build_meander()
        build_native(native)
        append(cmd, custom_attribute_flag)
        append(cmd, pedantic_vet_packages)
        build_pedantic(true)
        
        end_build(cmd)
    }
    
    {
        if !check_printlikes(&metaprogram, game_package) do os.exit(1)
        if !generate_platform_api(&metaprogram, "./code/generated-platform_api.odin", main_package, "./code/game/generated-platform_api.odin", game_package, true) do os.exit(1)
        
        delete_all_like("./build", `game-\d+\.rdi`)
        delete_all_like("./build", `game-\d+\.pdb`)
        
        // @todo(viktor): Share this definition
        // @note(viktor): the platform checks for this lock file when hot-reloading
        // @todo(viktor): use the new os once I know how to fprint into its handle
        lock_path := "./game.lock"
        lock, err := os.open(lock_path, {.Create})
        if err != nil do fmt.printf("ERROR: %v\n", err)
        defer {
            os.close(lock)
            os.remove(lock_path)
        }
        fmt.fprint(lock, "WAITING FOR PDB")
        
        if begin_build(cmd, "code/game", "game.dll") {
            append(cmd, "-build-mode:dll")
            append(cmd, fmt.tprintf(`-pdb-name:.\game-%d.pdb`, random_number()))
            
            build_meander()
            build_optimizations(optimize)
            build_native(native)
            
            if PedanticGame {
                append(cmd, pedantic_vet_packages)
                build_pedantic(PedanticGame)
            }
            
            append(cmd, custom_attribute_flag)
            append(cmd, internal)
            
            end_build(cmd)
        }
    }
    
    {
        if !check_printlikes(&metaprogram, main_package) do os.exit(1)
            
        // @todo(viktor): these could be run in parallel with each other and the build of the game
        if !generate_game_api(&metaprogram, "./code/generated-game_api.odin",     game_package, main_package) do os.exit(1)
        if !generate_commons(&metaprogram,  "./code/generated-commons-game.odin", main_package, game_package, "./game")   do os.exit(1)
        
        if begin_build(cmd, "code", "debug.exe", .Skip) {
            build_meander()
            build_optimizations(optimize)
            build_native(native)
            
            if PedanticPlatform {
                append(cmd, pedantic_vet_packages)
                build_pedantic(PedanticPlatform)
            }
            
            append(cmd, custom_attribute_flag)
            append(cmd, internal)
            append(cmd, ..platform_flags)
            build_define("VulkanVertexSpirvPath",   vulkan_vertex_path)
            build_define("VulkanFragmentSpirvPath", vulkan_fragment_path)
            build_define("VulkanCompositeVertexSpirvPath",   vulkan_composite_vertex_path)
            build_define("VulkanCompositeFragmentSpirvPath", vulkan_composite_fragment_path)
            build_define("VulkanFinalVertexSpirvPath",       vulkan_final_vertex_path)
            build_define("VulkanFinalFragmentSpirvPath",     vulkan_final_fragment_path)
            
            end_build(cmd)
        }
    }
    
    /* 
    
    @todo(viktor): run renderdoc
    
    if .renderdoc in tasks {
        fmt.println("INFO: Starting the Program with RenderDoc attached.")
        renderdoc_cmd := `C:\Program Files\RenderDoc\renderdoccmd.exe`
        renderdoc_gui := `C:\Program Files\RenderDoc\qrenderdoc.exe`
        
        os.change_directory("..")
        append(&cmd, renderdoc_cmd, `capture`, `-d`, data_dir, `-c`, `.\capture`, build_dir + debug_exe_path)
        run_command(&cmd)
        
        os.change_directory(data_dir)
        captures := all_like("capture.*")
        // @todo(viktor): What if we had multiple captures?
        if len(captures) == 1 {
            append(&cmd, renderdoc_gui, captures[0])
            run_command(&cmd)
            // @todo(viktor): Ask if old should be deleted?
            fmt.printfln("INFO: Cleanup old captures")
            for capture in captures {
                os.remove(capture)
            }
        } else if len(captures) == 0 {
            fmt.printfln("INFO: No captures made, not starting RenderDoc.")
        } else {
            fmt.printfln("INFO: More than one capture made, please select for yourself.")
            append(&cmd, "cmd", "/c", "start", ".")
            run_command(&cmd)
        }
    }
    
    */
    run_or_debug_according_to_args()
    
    fmt.printf("Done\n")
}
