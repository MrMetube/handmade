#+vet unused shadowing cast unused-imports style unused-procedures unused-variables
package build

import "core:fmt"
import "core:os"


// "-build-diagnostics"

platform_flags := [] string { "-subsystem:windows", `-extra-linker-flags:/STACK:0x100000,0x100000` /* get a 1MB stack instead of the default 4kB */ }

PedanticGame     :: false
PedanticRender   :: false
PedanticPlatform :: false

native   :: true
optimize :: false
internal :: true


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

code_dir       :: "code"
game_package   :: "game"
render_package :: "render"
main_package   :: "main"
game_dir       :: code_dir+"/"+game_package
render_dir     :: code_dir+"/"+render_package

main :: proc () {
    // @todo(viktor): handle being called from ./data instead of ./
    init_build()
    make_directory_if_not_exists("./data")
    make_directory_if_not_exists("./data/build")

    vulkan_vertex_path   :: `build/vulkan.vertex.spirv`
    vulkan_fragment_path :: `build/vulkan.fragment.spirv`
    vulkan_composite_vertex_path   :: `build/vulkan.composite_vertex.spirv`
    vulkan_composite_fragment_path :: `build/vulkan.composite_fragment.spirv`
    vulkan_final_vertex_path       :: `build/vulkan.final_vertex.spirv`
    vulkan_final_fragment_path     :: `build/vulkan.final_fragment.spirv`
    vulkan_shader_stages := [] struct { source, stage, output: string } {
        { "code/render/vulkan.slang",           "vertex",   `data/build/vulkan.vertex.spirv` },
        { "code/render/vulkan.slang",           "fragment", `data/build/vulkan.fragment.spirv` },
        { "code/render/vulkan_composite.slang", "vertex",   `data/build/vulkan.composite_vertex.spirv` },
        { "code/render/vulkan_composite.slang", "fragment", `data/build/vulkan.composite_fragment.spirv` },
        { "code/render/vulkan_final.slang",     "vertex",   `data/build/vulkan.final_vertex.spirv` },
        { "code/render/vulkan_final.slang",     "fragment", `data/build/vulkan.final_fragment.spirv` },
    }
    for shader in vulkan_shader_stages {
        append(cmd, "slangc")
        append(cmd, shader.source)
        if !optimize { append(cmd, "-g") }
        append(cmd, "-target", "spirv", "-profile", "spirv_1_5", "-emit-spirv-directly", "-fvk-use-entrypoint-name", "-fvk-use-c-layout", "-capability", "spvDescriptorHeapEXT", "-entry")
        append(cmd, fmt.tprintf("%sMain", shader.stage))
        append(cmd, "-stage", shader.stage)
        append(cmd, "-o", shader.output)
        run_command(cmd, async = procs)
    }
    if !procs_flush(procs) do os.exit(1)
    
    // @todo(viktor): these could also be parallelised
    metaprogram: Metaprogram
    metaprogram_init(&metaprogram)
    custom_attribute_flag := metaprogram_custom_attribute_flag(&metaprogram)
    
    if !metaprogram_collect_files_and_parse_package(&metaprogram, code_dir,   main_package)   do os.exit(1)
    if !metaprogram_collect_files_and_parse_package(&metaprogram, game_dir,   game_package)   do os.exit(1)
    if !metaprogram_collect_files_and_parse_package(&metaprogram, render_dir, render_package) do os.exit(1)
    
    if !metaprogram_collect_plugin_data(&metaprogram, code_dir,   main_package)   do os.exit(1)
    if !metaprogram_collect_plugin_data(&metaprogram, game_dir,   game_package)   do os.exit(1)
    if !metaprogram_collect_plugin_data(&metaprogram, render_dir, render_package) do os.exit(1)
    
    pedantic_packages: [dynamic; 4] string
    if PedanticGame     { append(&pedantic_packages, game_package)   }
    if PedanticRender   { append(&pedantic_packages, render_package) }
    if PedanticPlatform { append(&pedantic_packages, main_package)   }
    append(&pedantic_packages, "hha")
    
    if begin_build(cmd, "code/asset_builder", "asset_builder.exe") {
        build_meander()
        build_native(native)
        append(cmd, custom_attribute_flag)
        build_pedantic(true)
        build_very_pedantic(true, ..pedantic_packages[:])
        
        end_build(cmd)
    }
    
    { // game
        if !check_printlikes(&metaprogram, game_package) do os.exit(1)
        if !generate_platform_api(&metaprogram, "./code/generated-platform_api.odin", main_package, "./code/game/generated-platform_api.odin", game_package, true) do os.exit(1)
        
        delete_all_like("./build", `game-\d+\.rdi`)
        delete_all_like("./build", `game-\d+\.pdb`)
        
        create_build_lock("./game.lock")
        
        if begin_build(cmd, "code/game", "game.dll") {
            append(cmd, "-build-mode:dll")
            append(cmd, fmt.tprintf(`-pdb-name:./build/game-%d.pdb`, random_number()))
            
            build_meander()
            build_optimizations(optimize)
            build_native(native)
            
            build_pedantic(PedanticGame)
            build_very_pedantic(PedanticGame, ..pedantic_packages[:])
            
            append(cmd, custom_attribute_flag)
            if internal { build_define("INTERNAL", "true") }
            
            end_build(cmd)
        }
    }

    { // render
        if !check_printlikes(&metaprogram, render_package) do os.exit(1)
        
        if !generate_commons(&metaprogram,  "./code/render/generated-commons-game.odin", render_package, game_package,   "../game") do os.exit(1)
        if !generate_game_api(&metaprogram, "./code/render/generated-game_api.odin",     game_package,   render_package)            do os.exit(1)
        
        delete_all_like("./build", `render-\d+\.rdi`)
        delete_all_like("./build", `render-\d+\.pdb`)
        
        create_build_lock("./render.lock")
        
        if begin_build(cmd, render_dir, "render.dll") {
            append(cmd, "-build-mode:dll")
            append(cmd, fmt.tprintf(`-pdb-name:./build/render-%d.pdb`, random_number()))
            
            build_meander()
            build_optimizations(optimize)
            build_native(native)
            append(cmd, custom_attribute_flag)
            if internal { build_define("INTERNAL", "true") }
            build_define("VulkanVertexSpirvPath",   vulkan_vertex_path)
            build_define("VulkanFragmentSpirvPath", vulkan_fragment_path)
            build_define("VulkanCompositeVertexSpirvPath",   vulkan_composite_vertex_path)
            build_define("VulkanCompositeFragmentSpirvPath", vulkan_composite_fragment_path)
            build_define("VulkanFinalVertexSpirvPath",       vulkan_final_vertex_path)
            build_define("VulkanFinalFragmentSpirvPath",     vulkan_final_fragment_path)
            
            end_build(cmd)
        }
    }
    
    { // platform
        if !check_printlikes(&metaprogram, main_package) do os.exit(1)
            
        // @todo(viktor): these could be run in parallel with each other and the build of the game
        if !generate_game_api(&metaprogram,   "./code/generated-game_api.odin",       game_package,   main_package) do os.exit(1)
        if !generate_render_api(&metaprogram, "./code/generated-render_api.odin",     render_package, main_package) do os.exit(1)
        if !generate_commons(&metaprogram,    "./code/generated-commons-game.odin",   main_package,   game_package,   "./game")   do os.exit(1)
        if !generate_commons(&metaprogram,    "./code/generated-commons-render.odin", main_package,   render_package, "./render") do os.exit(1)
        
        target :: "debug.exe"
        build_succeeded: bool
                
        if begin_build(cmd, "code", target, .Skip) {
            build_meander()
            build_optimizations(optimize)
            build_native(native)
            
            build_pedantic(PedanticPlatform)
            build_very_pedantic(PedanticPlatform, ..pedantic_packages[:])
            
            append(cmd, custom_attribute_flag)
            if internal { build_define("INTERNAL", "true") }
            append(cmd, ..platform_flags)
            build_succeeded = end_build(cmd)
        }
        
        if build_succeeded {
            if run(target) {
                append(cmd, fmt.tprintf("./build/%v", target))
                run_command(cmd, working_dir = "./data", detached = true)
            } else if debug(target) {
                prepare_debugger()
                raddbg_ipc("select_target", target)
                raddbg_ipc("restart")
            }
        }
    }
    
    fmt.printf("Done\n")
}

////////////////////////////////////////////////

// @note the platform checks these lock files when hot-reloading
@(deferred_out=delete_build_lock)
create_build_lock :: proc (path: string) -> (^os.File, string) {
    file, err := os.open(path, {.Create})
    if err != nil {
        fmt.printf("ERROR: %v\n", err)
    } else {
        fmt.fprint(file, "WAITING FOR PDB")
    }
    return file, path
}

delete_build_lock :: proc (file: ^os.File, path: string) {
    os.close(file)
    if os.exists(path) do os.remove(path)
}