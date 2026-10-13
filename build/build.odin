#+vet unused shadowing cast unused-imports style unused-procedures unused-variables
package build

import "core:fmt"
import "core:os"

// @study does radlink also accept this linker flag?
platform_flags := [] string { /* "-subsystem:windows", */ `-extra-linker-flags:/STACK:0x100000,0x100000` /* get a 1MB stack instead of the default 4kB */ }

PedanticGame     :: false
PedanticRender   :: false
PedanticPlatform :: false

optimize :: !false
native   :: true
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
    make_file_if_not_exists("./build/.gitignore", "*\n!*.odin")
    make_directory_if_not_exists("./data")
    make_directory_if_not_exists("./data/build")
    
    shaders := [] struct { source, stage, path, define: string } {
        { "code/render/zbias.slang",                  "vertex",   "build/zbias_vertex.spirv",                    "Path_z_bias_vertex"},
        { "code/render/zbias.slang",                  "fragment", "build/zbias_fragment.spirv",                  "Path_z_bias_fragment"},
        { "code/render/peel_composite.slang",         "vertex",   "build/peel_composite_vertex.spirv",           "Path_peel_composite_vertex"},
        { "code/render/peel_composite.slang",         "fragment", "build/peel_composite_fragment.spirv",         "Path_peel_composite_fragment"},
        { "code/render/multisample_resolve.slang",    "vertex",   "build/multisample_resolve_vertex.spirv",      "Path_multisample_resolve_vertex"},
        { "code/render/multisample_resolve.slang",    "fragment", "build/multisample_resolve_fragment.spirv",    "Path_multisample_resolve_fragment"},
        { "code/render/final_stretch.slang",          "vertex",   "build/final_stretch_vertex.spirv",            "Path_final_stretch_vertex"},
        { "code/render/final_stretch.slang",          "fragment", "build/final_stretch_fragment.spirv",          "Path_final_stretch_fragment"},
        { "code/render/multigrid_light_up.slang",     "vertex",   "build/multigrid_light_up_vertex.spirv",       "Path_multigrid_light_up_vertex"},
        { "code/render/multigrid_light_up.slang",     "fragment", "build/multigrid_light_up_fragment.spirv",     "Path_multigrid_light_up_fragment"},
        { "code/render/multigrid_light_down.slang",   "vertex",   "build/multigrid_light_down_vertex.spirv",     "Path_multigrid_light_down_vertex"},
        { "code/render/multigrid_light_down.slang",   "fragment", "build/multigrid_light_down_fragment.spirv",   "Path_multigrid_light_down_fragment"},
        { "code/render/depth_peel_to_lighting.slang", "vertex",   "build/depth_peel_to_lighting_vertex.spirv",   "Path_depth_peel_to_lighting_vertex"},
        { "code/render/depth_peel_to_lighting.slang", "fragment", "build/depth_peel_to_lighting_fragment.spirv", "Path_depth_peel_to_lighting_fragment"},
    }
    
    for shader in shaders {
        append(cmd, "slangc")
        append(cmd, shader.source)
        if !optimize { append(cmd, "-g") }
        append(cmd, "-target", "spirv", "-profile", "spirv_1_5", "-emit-spirv-directly", "-fvk-use-entrypoint-name", "-fvk-use-c-layout", "-capability", "spvDescriptorHeapEXT", "-entry")
        append(cmd, fmt.tprintf("%sMain", shader.stage))
        append(cmd, "-stage", shader.stage)
        append(cmd, "-o", fmt.tprintf("data/%s", shader.path))
        run_command(cmd, async = procs)
    }
    
    metaprogram: Metaprogram
    metaprogram_init(&metaprogram)
    custom_attribute_flag := metaprogram_custom_attribute_flag(&metaprogram)
    
    if !metaprogram_collect_files_and_parse_package(&metaprogram, code_dir,   main_package)   do os.exit(1)
    if !metaprogram_collect_files_and_parse_package(&metaprogram, game_dir,   game_package)   do os.exit(1)
    if !metaprogram_collect_files_and_parse_package(&metaprogram, render_dir, render_package) do os.exit(1)
    
    if !metaprogram_collect_plugin_data(&metaprogram, main_package)   do os.exit(1)
    if !metaprogram_collect_plugin_data(&metaprogram, game_package)   do os.exit(1)
    if !metaprogram_collect_plugin_data(&metaprogram, render_package) do os.exit(1)
    
    pedantic_packages: [dynamic; 4] string
    if PedanticGame     { append(&pedantic_packages, game_package)   }
    if PedanticRender   { append(&pedantic_packages, render_package) }
    if PedanticPlatform { append(&pedantic_packages, main_package)   }
    append(&pedantic_packages, "hha")
    
    if begin_build(cmd, "code/asset_builder", "asset_builder.exe") { // hha
        build_meander()
        build_native(native)
        append(cmd, custom_attribute_flag)
        build_pedantic(true)
        build_very_pedantic(true, ..pedantic_packages[:])
        
        end_build(cmd, async = procs)
    }
    
    if begin_build(cmd, "code/game", "game.dll") { // game
        if !check_printlikes(&metaprogram, game_package) do os.exit(1)
        
        if !generate_platform_api(&metaprogram, "./code/game/generated-platform_api.odin", game_package, { .commons, .global, .opaques }) do os.exit(1)
        
        delete_all_like("./build", `game-\d+\.rdi`)
        delete_all_like("./build", `game-\d+\.pdb`)
        
        create_build_lock("./build/game.lock")
        
        append(cmd, "-build-mode:dll")
        append(cmd, fmt.tprintf(`-pdb-name:./build/game-%d.pdb`, random_number()))
        
        build_meander()
        build_optimizations(optimize)
        build_native(native)
        
        build_pedantic(PedanticGame)
        build_very_pedantic(PedanticGame, ..pedantic_packages[:])
        
        append(cmd, custom_attribute_flag)
        if internal { build_define("INTERNAL", "true") }
        
        end_build(cmd, async = procs)
    }
    
    if begin_build(cmd, render_dir, "render.dll") { // render
        if !check_printlikes(&metaprogram, render_package) do os.exit(1)
        
        if !generate_platform_api(&metaprogram, "./code/render/generated-platform_api.odin", render_package, { .opaques })              do os.exit(1)
        if !generate_commons(&metaprogram,      "./code/render/generated-commons-game.odin", render_package, game_package,   "../game") do os.exit(1)
        if !generate_game_api(&metaprogram,     "./code/render/generated-game_api.odin",     game_package,   render_package)            do os.exit(1)
        
        delete_all_like("./build", `render-\d+\.rdi`)
        delete_all_like("./build", `render-\d+\.pdb`)
        
        create_build_lock("./build/render.lock")
        append(cmd, "-build-mode:dll")
        append(cmd, fmt.tprintf(`-pdb-name:./build/render-%d.pdb`, random_number()))
        
        build_meander()
        build_optimizations(optimize)
        build_native(native)
        append(cmd, custom_attribute_flag)
        if internal { build_define("INTERNAL", "true") }
        
        for shader in shaders {
            build_define(shader.define, shader.path)
        }
        
        end_build(cmd, async = procs)
    }
    
    procs_flush(procs)
    
    { // platform
        target :: "debug.exe"
        build_succeeded: bool
        
        if begin_build(cmd, "code", target, .Skip) {
            if !check_printlikes(&metaprogram, main_package) do os.exit(1)
            
            // @todo(viktor): these could be run in parallel with each other and the build of the game
            if !generate_game_api(&metaprogram,   "./code/generated-game_api.odin",       game_package,   main_package)               do os.exit(1)
            if !generate_render_api(&metaprogram, "./code/generated-render_api.odin",     render_package, main_package)               do os.exit(1)
            if !generate_commons(&metaprogram,    "./code/generated-commons-game.odin",   main_package,   game_package,   "./game")   do os.exit(1)
            if !generate_commons(&metaprogram,    "./code/generated-commons-render.odin", main_package,   render_package, "./render") do os.exit(1)
            if !generate_platform_api_bindings(&metaprogram, "./code/generated-platform_api.odin", main_package)                      do os.exit(1)
            
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
    
    check_cmd_and_close_procs()
}

////////////////////////////////////////////////

// @note the platform checks these lock files when hot-reloading
@(deferred_out=delete_build_lock)
create_build_lock :: proc (path: string) -> (string) {
    file, err := os.open(path, {.Create, .Trunc, .Write})
    if err != nil {
        fmt.printf("ERROR: %v\n", err)
    } else {
        fmt.printf("INFO: Created lock file at %q\n", path)
        fmt.fprint(file, "WAITING FOR PDB")
    }
    os.close(file)
    
    return path
}

delete_build_lock :: proc (path: string) {
    if os.exists(path) do os.remove(path)
}
