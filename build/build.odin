#+vet unused shadowing cast unused-imports style unused-procedures unused-variables
package build

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:time"
import "core:thread"
import win "core:sys/windows"

// @todo(viktor): think about "#all_or_none" for structs. Do i make this mistake and should I take precautions?

optimizations    := false ? "-o:speed" : "-o:none"
PedanticGame     :: false
PedanticPlatform :: false

// @todo(viktor): get radlink working?
flags    := [] string { "-vet-cast", "-vet-shadowing", /* "-target:windows_amd64", "-microarch:native", "-linker:lld" */ }
// "-build-diagnostics"

debug    :: "-debug"
internal :: "-define:INTERNAL=true"

pedantic := [] string { "-warnings-as-errors", "-vet-unused-imports", "-vet-semicolon", "-vet-unused-variables", "-vet-style",  "-vet-unused-procedures" }

////////////////////////////////////////////////

build_dir :: `.\build\`
data_dir  :: `.\data`

code_dir          :: `..\code` 
game_dir          :: `..\code\game` 
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

- Pedantic build until no errors
  - all vets and checks
  - first only the game layer, then if that builds also do the platform layer

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
    platform,
    asset_builder,
    
    debugger, 
    renderdoc,
    
    run,
}

Tasks :: bit_set [Task]
BuildTasks := Tasks { .game, .platform, .asset_builder }
Tool_Tasks := Tasks { .debugger, .renderdoc }

tasks: Tasks

main :: proc () {
    context.allocator = context.temp_allocator

    for arg in os.args[1:] {
        switch arg {
          case "run":           tasks += { .run }
          
          case "game":          tasks += { .game }
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
    if !metaprogram_collect_data(&metaprogram, code_dir) do os.exit(1)
    if !metaprogram_collect_data(&metaprogram, game_dir) do os.exit(1)
    
    // @todo(viktor): let the metaprogramms define these attributes at initialization
    sb := strings.builder_make()
    fmt.sbprint(&sb, "-custom-attribute:")
    fmt.sbprint(&sb, "common", "api", "printlike", sep=",")
    custom_attribute_flag := strings.to_string(sb)
    
    sb = strings.builder_make()
    fmt.sbprint(&sb, "-vet-packages:")
    if PedanticPlatform do fmt.sbprint(&sb, "main,")
    if PedanticGame do fmt.sbprint(&sb, "game,")
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
            tasks += { .debugger }
        } else  {
            append(&cmd, raddbg_path)
            run_command(&cmd, async = &procs)
        }
    }
    
    if tasks & BuildTasks == {} do tasks += { .game, .platform }
    
    if tasks & Tool_Tasks != {} {
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
        if !check_printlikes(&metaprogram, game_dir) do os.exit(1)

        generate_platform_api(&metaprogram, `..\code\generated-platform_api.odin`, `..\code\game\generated-platform_api.odin`)
        
        delete_all_like(`.\game*.pdb`)
        delete_all_like(`.\game*.rdi`)
        
        // @note(viktor): the platform checks for this lock file when hot-reloading
        lock_path := `.\lock.tmp` 
        lock, err := os.open(lock_path, mode = os.O_CREATE)
        if err != nil do fmt.print("ERROR: ", os.error_string(err))
        
        defer {
            os.close(lock)
            os.remove(lock_path)
        }
        
        fmt.fprint(lock, "WAITING FOR PDB")
        
        pdb := fmt.tprintf(`-pdb-name:.\game-%d.pdb`, random_number())
        
        odin_build(&cmd, game_dir, `.\game.dll`)
        append(&cmd, "-build-mode:dll")
        append(&cmd, pdb)
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
    }
    
    if .platform in tasks { 
        if handle_running_exe_gracefully(debug_exe, .Skip) {
            if !check_printlikes(&metaprogram, code_dir) do os.exit(1)
            
            // @todo(viktor): these could be run in parallel with each other and the build of the game
            if !generate_game_api(&metaprogram, `..\code\generated-game_api.odin`) {
                fmt.println("ERROR: Could not generate game api")
                os.exit(1)
            }
            
            if !generate_commons(&metaprogram, `..\code\generated-commons.odin`) {
                fmt.println("ERROR: Could not extract declarations marked with @common")
                os.exit(1)
            }
            
            odin_build(&cmd, code_dir, `.\`+debug_exe)
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
        captures := all_like("capture*")
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
    
    _ = flush
    
    if len(cmd) != 0 {
        fmt.println("INFO: cmd was not cleared: ", strings.join(cmd[:], " "))
    }
    
    fmt.println("Done.")
}

usage :: proc () {
    fmt.printf(`Usage:
  %v [<options>]
Options:
`, os.args[0])
    infos :            = [Task] string {
        .help          = "Print this usage information.",
        .run           = "Run the game.",
        
        .game          = "Rebuild the game. If it is running it will be hotreloaded.",
        .platform      = "Rebuild the platform, if the game isn't running.",
        .asset_builder = "Rebuild the asset builder.",
        
        .debugger      = "Start/Restart the debugger.",
        .renderdoc     = "Run the program with renderdoc attached and launch renderdoc with the capture after the program closes.",
    }
    // Ughh..
    width: int
    for task in Task do width = max(len(fmt.tprint(task)), width)
    format := fmt.tprintf("  %%-%vv - %%v\n", width)
    for text, task in infos do fmt.printf(format, task, text)
    
    os.exit(1)
}

Proc :: union { os2.Process, thread.Thread }
Procs :: [dynamic] Proc
Cmd   :: [dynamic] string



















Handle_Running_Exe :: enum {
    Skip,
    Abort, 
    Kill,
}

handle_running_exe_gracefully :: proc (exe_name: string, handling: Handle_Running_Exe) -> (ok: b32) {
    pid: u32
    ok, pid = is_running(exe_name)
    if ok {
        switch handling {
          case .Skip:
            fmt.printfln("INFO: Tried to build '%v', but the program is already running. Skipping build.", exe_name)
            return false
            
          case .Abort: 
            fmt.printfln("INFO: Tried to build '%v', but the program is already running. Aborting build!", exe_name)
            os.exit(0)
            
          case .Kill: 
            fmt.printfln("INFO: Tried to build '%v', but the program is already running.", exe_name)
            fmt.printfln("INFO: Killing running instance in order to build.")
            kill(pid)
            return true
        }
    }
    
    return true
}

odin_build :: proc (cmd: ^[dynamic]string, dir: string, out: string) {
    append(cmd, "odin")
    append(cmd, "build")
    append(cmd, dir)
    append(cmd, fmt.tprintf("-out:%v", out))
}









did_change :: proc (output_path: string, inputs: .. string, extension: string = ".odin") -> (result: bool) {
    output_info, err := os.stat(output_path)
    if err != nil {
        result = true
    } else {
        search: for input in inputs {
            files: [] os2.File_Info
            error: os2.Error
            if os.is_dir(input) {
                files, error = os2.read_all_directory_by_path(input, context.allocator)
                if error != nil {
                    fmt.printfln("ERROR: failed to read directory '%v' when checking for changes: %v", input, error)
                    break search
                }
            } else {
                file, stat_error := os2.stat(input, context.allocator)
                files = { file }
                if stat_error != nil {
                    fmt.printfln("ERROR: failed to read file '%v' when checking for changes: %v", input, error)
                    break search
                }
            }
            
            for file in files {
                if extension == "" || strings.ends_with(file.name, extension) {
                    if time.diff(file.modification_time, output_info.modification_time) < 0 {
                        result = true
                        break search
                    }
                }
            }
        }
    }
    
    return result
}

remove_if_exists :: proc (path: string) {
    if os.exists(path) do os.remove(path)
}

delete_all_like :: proc (pattern: string) {
    files := all_like(pattern)
    if len(files) == 0 do return
    
    for file in files {
        os.remove(file)
    }
    // fmt.printfln("INFO: deleted %v files with pattern '%v'", len(files), pattern)
}

all_like :: proc (pattern: string, allocator := context.temp_allocator) -> (result: [] string) {
    files: [dynamic] string
    files.allocator = allocator
    
    find_data := win.WIN32_FIND_DATAW{}
    handle := win.FindFirstFileW(win.utf8_to_wstring(pattern), &find_data)
    if handle == win.INVALID_HANDLE_VALUE do return files[:]
    defer win.FindClose(handle)
    
    for {
        file_name, err := win.utf16_to_utf8(find_data.cFileName[:])
        assert(err == nil)
        file_path := fmt.tprintf(`.\%v`, file_name)
        append(&files, file_path)
        
        if !win.FindNextFileW(handle, &find_data){
            break 
        }
    }
    
    return files[:]
}

is_running :: proc (exe_name: string) -> (running: b32, pid: u32) {
    snapshot := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPALL, 0)
    assert(snapshot != win.INVALID_HANDLE_VALUE, "could not take a snapshot of the running programms")
    defer win.CloseHandle(snapshot)
    
    process_entry := win.PROCESSENTRY32W{ dwSize = size_of(win.PROCESSENTRY32W)}
    
    if win.Process32FirstW(snapshot, &process_entry) {
        for {
            test_name, err := win.utf16_to_utf8(process_entry.szExeFile[:])
            assert(err == nil)
            if exe_name == test_name {
                return true, process_entry.th32ProcessID
            }
            if !win.Process32NextW(snapshot, &process_entry) {
                break
            }
        }
    }
    
    return false, 0
}

run_command :: proc (cmd: ^Cmd, or_exit := true, keep := false, stdout: ^string = nil, stderr: ^string = nil, async: ^Procs = nil) -> (success: bool) {
    fmt.printfln(`CMD: %v`, strings.join(cmd[:], ` `))
    
    process_description := os2.Process_Desc { command = cmd[:] }
    process: os2.Process
    state:   os2.Process_State
	output:  [] byte
	error:   [] byte
    err2:    os2.Error
    if async == nil {
        state, output, error, err2 = os2.process_exec(process_description, context.allocator)
    } else {
        process, err2 = os2.process_start(process_description)
        append(async, process)
    }
    
    if err2 != nil {
        fmt.printfln("ERROR: Failed to run command: %v %v %v", cast(string) output, cast(string) error, err2)
        success = false
    } else {
        if async == nil {
            if output != nil {
                if stdout != nil do stdout ^= string(output)
                else do fmt.println(string(output))
            }
            
            if error != nil {
                if stderr != nil do stderr ^= string(error)
                else do fmt.println(string(error))
                
                if or_exit do os.exit(state.exit_code)
            }
            
            if or_exit && !state.success do os.exit(state.exit_code)
            
            success = state.success
        } else {
            success = true
        }
    }
        
    if !keep do clear(cmd)
    
    return success
}

flush :: proc (procs: ^Procs) {
    for &p in procs {
        switch &value in p {
        case os2.Process:
            // @todo(viktor): handle the returned values
            _, _= os2.process_wait(value)
        case thread.Thread:
            thread.join(&value)
        }
    }
    
    clear(procs)
}

kill :: proc (pid: u32) {
    handle := win.OpenProcess(win.PROCESS_TERMINATE, false, pid)
    if handle != nil {
        win.TerminateProcess(handle, 0)
        win.CloseHandle(handle)
    }
}

make_directory_if_not_exists :: proc (path: string) -> (result: b32) {
    if !os.exists(path) {
        os.make_directory(path)
        result = true
    }
    return result
}

random_number :: proc () -> (result: u8) {
    return cast(u8) intrinsics.read_cycle_counter()
}