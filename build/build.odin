#+vet unused shadowing cast unused-imports style unused-procedures unused-variables
package build

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"

optimizations    := false ? "-o:speed" : "-o:none"
PedanticGame     :: false
PedanticRender   :: false
PedanticPlatform :: false

flags    := [] string { "-vet-cast", "-vet-shadowing", "-target:windows_amd64", "-microarch:native", "-linker:radlink" }
// "-build-diagnostics"

debug    :: "-debug"
internal :: "-define:INTERNAL=true"

pedantic := [] string { "-warnings-as-errors", "-vet-unused-imports", "-vet-semicolon", "-vet-unused-variables", "-vet-style",  "-vet-unused-procedures" }

////////////////////////////////////////////////

build_dir :: `.\build\`
data_dir  :: `.\data`

main_package      :: `main` 
code_dir          :: `..\code` 

game_package      :: `game` 
game_dir          :: `..\code\game` 

render_package    :: `render` 
render_dir        :: `..\code\render` 

asset_builder_dir :: `..\code\asset_builder` 

////////////////////////////////////////////////

raddbg      :: `raddbg.exe`
raddbg_path :: `C:\tools\raddbg\`+ raddbg

debug_exe :: `debug.exe`
debug_exe_path :: `.\`+debug_exe
 
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

Task :: enum {
    help,
    
    game,
    render,
    platform,
    asset_builder,
    
    debugger, 
    renderdoc,
    
    run,
}

Tasks :: bit_set [Task]
BuildTasks := Tasks { .game, .platform, .asset_builder, .render }
ToolTasks  := Tasks { .debugger, .renderdoc }

tasks: Tasks

main :: proc () {
    for arg in os.args[1:] {
        switch arg {
          case "run":           tasks += { .run }
          
          case "game":          tasks += { .game }
          case "render":        tasks += { .render }
          case "platform":      tasks += { .platform }
          case "asset_builder": tasks += { .asset_builder }
          
          case "debugger":      tasks += { .debugger }
          case "renderdoc":     tasks += { .renderdoc }
          case "help":          tasks += { .help }
          case:                 tasks += { .help }
        }
    }
    
    if .help in tasks do usage()
    
    ////////////////////////////////////////////////
    
    make_directory_if_not_exists(data_dir)
    { err := os.set_current_directory(build_dir); assert(err == nil) }
    
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
    
    cmd: Cmd
    procs: Procs
    if .debugger in tasks {
        if ok, _ := is_running(raddbg); ok {
            append(&cmd, raddbg_path)
            append(&cmd, "--ipc")
            append(&cmd, "kill_all")
            run_command(&cmd)
        } else  {
            append(&cmd, raddbg_path)
            run_command(&cmd, async = &procs)
        }
    }
    
    if tasks & BuildTasks == {} do tasks += { .game, .platform }
    
    if tasks & ToolTasks != {} {
        if !did_change(debug_exe_path, code_dir, game_dir, `.\`) {
            fmt.println("INFO: Skipping build, because no changes to the source files were detected.")
            tasks -= BuildTasks
        }
    }
    
    if .asset_builder in tasks {
        odin_build(&cmd, asset_builder_dir, `..\build\asset_builder.exe`)
        append(&cmd, debug)
        append(&cmd, ..flags)
        append(&cmd, custom_attribute_flag)
        append(&cmd, pedantic_vet_packages)
        append(&cmd, ..pedantic)
        run_command(&cmd)
    }
    
    if .game in tasks {
        if !check_printlikes(&metaprogram, game_package) do os.exit(1)
        if !generate_platform_api(&metaprogram, `..\code\generated-platform_api.odin`, main_package, `..\code\game\generated-platform_api.odin`, game_package, true) do os.exit(1)
        
        ////////////////////////////////////////////////
            
        delete_all_like(`game-\d+\.pdb`)
        delete_all_like(`game-\d+\.rdi`)
        
        // @todo(viktor): Share this definition
        // @note(viktor): the platform checks for this lock file when hot-reloading
        lock_path := `.\game.lock` 
        lock, err := os.open(lock_path, mode = os.O_CREATE)
        if err != nil do fmt.print("ERROR: ", os.error_string(err))
        defer {
            os.close(lock)
            os.remove(lock_path)
        }
        
        fmt.fprint(lock, "WAITING FOR PDB")
        
        // @todo(viktor): Share this definition
        dll_name := "game.dll"
        
        odin_build(&cmd, game_dir, dll_name)
        append(&cmd, "-build-mode:dll")
        append(&cmd, fmt.tprintf(`-pdb-name:.\game-%d.pdb`, random_number()))
        append(&cmd, debug)
        append(&cmd, ..flags)
        append(&cmd, custom_attribute_flag)
        append(&cmd, internal)
        append(&cmd, optimizations)
        if PedanticGame {
            append(&cmd, pedantic_vet_packages)
            append(&cmd, ..pedantic)
        }
        
        silence: string
        run_command(&cmd, stdout = &silence)
        fmt.printf("INFO: Successfully build %v\n", dll_name)
    }
    
    if .render in tasks {
        // @note(viktor): the platform api is imported through the game commons
        if !check_printlikes(&metaprogram, render_package) do os.exit(1)
        if !generate_platform_api(&metaprogram, `..\code\generated-platform_api.odin`, main_package, `..\code\render\generated-platform_api.odin`, render_package, false) do os.exit(1)
        if !generate_game_api(&metaprogram, `..\code\render\generated-game_api.odin`, game_package, render_package) do os.exit(1)
        if !generate_commons(&metaprogram,  `..\code\render\generated-commons.odin`,  render_package, game_package, "../game") do os.exit(1)
        
        ////////////////////////////////////////////////
        delete_all_like(`render-\d+\.pdb`)
        delete_all_like(`render-\d+\.rdi`)
        
        // @todo(viktor): Share this definition
        // @note(viktor): the platform checks for this lock file when hot-reloading
        lock_path := `.\render.lock` 
        lock, err := os.open(lock_path, mode = os.O_CREATE)
        if err != nil do fmt.print("ERROR: ", os.error_string(err))
        
        defer {
            os.close(lock)
            os.remove(lock_path)
        }
        
        fmt.fprint(lock, "WAITING FOR PDB")
        
        // @todo(viktor): Share this definition
        dll_name := "render.dll"
        
        odin_build(&cmd, render_dir, dll_name)
        append(&cmd, "-build-mode:dll")
        append(&cmd, fmt.tprintf(`-pdb-name:.\render-%d.pdb`, random_number()))
        append(&cmd, debug)
        append(&cmd, ..flags)
        append(&cmd, custom_attribute_flag)
        append(&cmd, internal)
        append(&cmd, optimizations)
        if PedanticRender {
            append(&cmd, pedantic_vet_packages)
            append(&cmd, ..pedantic)
        }
        
        silence: string
        run_command(&cmd, stdout = &silence)
        fmt.printf("INFO: Successfully build %v\n", dll_name)
    }
    
    if .platform in tasks { 
        if handle_running_exe_gracefully(debug_exe, .Skip) {
            if !check_printlikes(&metaprogram, main_package) do os.exit(1)
            
            // @todo(viktor): these could be run in parallel with each other and the build of the game
            if !generate_game_api(&metaprogram,   `..\code\generated-game_api.odin`,   game_package,   main_package) do os.exit(1)
            // if !generate_render_api(&metaprogram, `..\code\generated-render_api.odin`, render_package, main_package) do os.exit(1)
            
            if !generate_commons(&metaprogram, `..\code\generated-commons-game.odin`,   main_package, game_package,   "./game")   do os.exit(1)
            // if !generate_commons(&metaprogram, `..\code\generated-commons-render.odin`, main_package, render_package, "./render") do os.exit(1)
            
            odin_build(&cmd, code_dir, debug_exe_path)
            append(&cmd, debug)
            append(&cmd, ..flags)
            append(&cmd, custom_attribute_flag)
            append(&cmd, internal)
            append(&cmd, optimizations)
            if PedanticPlatform {
                append(&cmd, pedantic_vet_packages)
                append(&cmd, ..pedantic)
            }
            
            run_command(&cmd)
            fmt.printf("INFO: Successfully build %v\n", debug_exe_path)
        }
    }
    
    fmt.println("INFO: Build done.")
    
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
    
    if .run in tasks {
        fmt.println("INFO: Starting the Program.")
        if .debugger in tasks {
            append(&cmd, raddbg_path)
            append(&cmd, "--ipc")
            append(&cmd, "run")
        } else {
            os.change_directory("..")
            os.change_directory(data_dir)
            append(&cmd, "start")
            append(&cmd, debug_exe)
        }
        run_command(&cmd, async = &procs)
    } else if .debugger in tasks {
        if ok, _ := is_running(raddbg_path); !ok {
            append(&cmd, raddbg_path)
            run_command(&cmd, async = &procs)
        }
    }
    
    flush(&procs)
    
    if len(cmd) != 0 {
        fmt.println("INFO: cmd was not cleared: ", strings.join(cmd[:], " "))
    }
    
    fmt.println("Done.")
}

usage :: proc () {
    fmt.printf(`Usage:\n`)
    fmt.printf("  %v [<options>]\n", os.args[0])
    fmt.printf("Options:\n")
    infos :            = [Task] string {
        .help          = "Print this usage information.",
        .run           = "Run the game.",
        
        .game          = "Rebuild the game. If the game is running it will be hotreloaded.",
        .render        = "Rebuild the renderer. If the game is running it will be hotreloaded.",
        
        .platform      = "Rebuild the platform, if the game isn't running.",
        .asset_builder = "Rebuild the asset builder.",
        
        .debugger      = "Start/Restart the debugger.",
        .renderdoc     = "Run the program with renderdoc attached and launch renderdoc with the capture after the program closes.",
    }
    
    width: int
    for task in Task do width = max(len(fmt.tprint(task)), width)
    for text, task in infos do fmt.printf("  %-*v - %v\n", width, task, text)
    
    os.exit(1)
}

random_number :: proc () -> (result: u8) {
    return cast(u8) intrinsics.read_cycle_counter()
}