#+vet explicit-allocators !unused-procedures
package build

import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import "core:os"
import "core:text/regex"
import "core:strings"

////////////////////////////////////////////////

// @todo explain the args syntax (run|debug)[:<target.exe in build dir>]
_cmd:   Cmd
_procs: Procs
cmd   := &_cmd
procs := &_procs

////////////////////////////////////////////////
// Internal state

raddbg      :: "raddbg.exe"
raddbg_path :: "C:/tools/raddbg/"+ raddbg

Procs :: [dynamic] os.Process
Cmd   :: [dynamic] string

@(private="file")
current_output: string

Handle_Running_Exe :: enum {
    Skip,
    Abort, 
    Kill,
}

////////////////////////////////////////////////

check_cmd_and_close_procs :: proc () {
    if len(cmd) != 0 {
        fmt.printf("INFO: cmd was not cleared: `%v`\n", strings.join(cmd[:], " ", context.temp_allocator))
    }
    
    procs_close(procs)
}

////////////////////////////////////////////////

begin_build :: proc (cmd: ^Cmd, package_directory: string, output_name: string, handling: Handle_Running_Exe = .Skip) -> bool {
    assert(current_output == "")
    
    result: bool
    
    if handle_running_exe_gracefully(output_name, handling) {
        append(cmd, "odin", "build")
        append(cmd, fmt.tprintf("./%v", package_directory))
        append(cmd, fmt.tprintf("-out:./build/%v", output_name))
        result = true
        
        current_output = output_name
    }
    
    return result
}

build_meander :: proc (debug := "-debug", Cast := "-vet-cast", shadowing := "-vet-shadowing", linker := "-linker:radlink") {
    append(cmd, debug, Cast, shadowing, linker)
}

build_optimizations :: proc (optimize: bool, optimized := "-o:speed", unoptimized := "-o:none") {
    append(cmd, optimize ? optimized : unoptimized)
}

build_native :: proc (native: bool = true, target := "-target:windows_amd64", microarch := "-microarch:native") {
    if native {
        append(cmd, target, microarch)
    }
}

build_pedantic :: proc (pedantic: bool, imports := "-vet-unused-imports", semicolon := "-vet-semicolon", variables := "-vet-unused-variables", style := "-vet-style") {
    if pedantic {
        append(cmd, imports, semicolon, variables, style)
    }
}

build_very_pedantic :: proc (very_pedantic: bool, packages: ..string, procedures := "-vet-unused-procedures") {
    if very_pedantic {
        b := strings.builder_make(context.temp_allocator)
        fmt.sbprint(&b, "-vet-packages:")
        for p, index in packages {
            if index != 0 { fmt.sbprint(&b, ",") }
            fmt.sbprintf(&b, "%v", p)
        }
        append(cmd, strings.to_string(b), procedures)
    }
}

build_define :: proc (name: string, value: string) {
    append(cmd, fmt.tprintf("-define:%s=%s", name, value))
}

end_build :: proc (cmd: ^Cmd, async: ^Procs = nil) -> bool {
    success := run_command(cmd, async = async)
    if async == nil && success{
        fmt.printf("  Build successful %v.\n", current_output)
    }
    current_output = ""
    return success
}

////////////////////////////////////////////////

run :: proc (target: string) -> bool {
    return argument_requests("run", target)
}

debug :: proc (target: string) -> bool {
    return argument_requests("debug", target)
}

argument_requests :: proc (action, target: string) -> bool {
    requested := fmt.tprintf("%s:%s", action, target)
    for argument in os.args[1:] {
        if argument == action || argument == requested do return true
    }
    return false
}

prepare_debugger :: proc () {
    if ok, _ := is_running(raddbg); ok {
        fmt.printf("Debugger is running, stopping it.\n")
        raddbg_ipc("kill_all")
    } else {
        fmt.printf("Starting the Debugger.\n")
        append(cmd, raddbg_path)
        run_command(cmd, detached = true)
    }
}

raddbg_ipc :: proc (command: string, argument: string = "") {
    append(cmd, raddbg_path, "--ipc")
    append(cmd, command)
    if argument != "" { append(cmd, argument) }
    run_command(cmd)
}

////////////////////////////////////////////////

is_running :: proc (exe_name: string) -> (running: bool, pid: int) {
    pids, err := os.process_list(context.temp_allocator)
    if err != nil do return false, 0
    defer delete(pids, context.temp_allocator)
    
    for test_pid in pids {
        info, _ := os.process_info(test_pid, {.Executable_Path}, context.temp_allocator)
        found := .Executable_Path in info.fields && os.base(info.executable_path) == exe_name
        os.free_process_info(info, context.temp_allocator)
        if found {
            return true, test_pid
        }
    }
    
    return false, 0
}

handle_running_exe_gracefully :: proc (exe_name: string, handling: Handle_Running_Exe) -> bool {
    ok, pid := is_running(exe_name)
    if ok {
        fmt.printf("INFO: Tried to build '%v', but the program is already running.\n", exe_name)
        switch handling {
        case .Skip:
            fmt.printf("  Skipping build.\n")
            return false
            
        case .Abort: 
            fmt.printf("  Aborting build!\n")
            os.exit(0)
            
        case .Kill:
            // @note if the exe was started from the debugger it should already be killed by the kill_all command before the build was started
            if running, _ := is_running(raddbg); !running {
                fmt.printf("  Killing running instance.\n")
                
                process, err := os.process_open(pid)
                if err != nil {
                    fmt.printf("  Failed to open '%v': %v\n", exe_name, err)
                    return false
                }
                
                err = os.process_kill(process)
                if err != nil {
                    fmt.printf("  Failed to kill '%v': %v\n", exe_name, err)
                    return false
                }
                _, _ = os.process_wait(process)
            }
        }
    }
    
    return true
}

////////////////////////////////////////////////

Command_Console :: union {
    ^string,
    ^os.File,
}
run_command :: proc (cmd: ^Cmd, working_dir := "", or_exit := true, keep := false, stdout: Command_Console = nil, stderr: Command_Console = nil, async: ^Procs = nil, detached := false) -> (success: bool) {
    assert(async == nil || !detached)
    fmt.printf("CMD: %v\n", strings.join(cmd[:], " ", context.temp_allocator))
    
    process_description := os.Process_Desc { command = cmd[:], working_dir = working_dir }
    state:   os.Process_State
	output:  [] byte
	error:   [] byte
    err2:    os.Error
    
    if async == nil && !detached {
        state, output, error, err2 = os.process_exec(process_description, context.allocator)
    } else {
        process: os.Process
        if async != nil {
            process_description.stdout = os.stdout
            process_description.stderr = os.stderr
        }
        if err, ok := stderr.(^os.File); ok do process_description.stderr = err
        if out, ok := stdout.(^os.File); ok do process_description.stdout = out
        process, err2 = os.process_start(process_description)
        if err2 == nil && !detached {
            append(async, process)
        }
    }
    
    if err2 != nil {
        fmt.printf("ERROR: Failed to run command: %v\n", err2)
    } else {
        if async == nil && !detached {
            if output != nil {
                switch out in stdout {
                case nil:      fmt.println(cast(string) output)
                case ^string:  out^ = cast(string) output
                case ^os.File: // nothing, already passed on exec
                }
            }
            
            if error != nil {
                switch out in stderr {
                case nil:      fmt.eprintln(cast(string) error)
                case ^string:  out^ = cast(string) error
                case ^os.File: // nothing, already passed on exec
                }
            }
            
            if or_exit && (!state.success || state.exit_code != 0) do os.exit(state.exit_code)
            
            success = state.success
        } else {
            success = true
        }
    }
    
    if !keep do clear(cmd)
    
    return success
}

procs_flush :: proc (procs: ^Procs) -> bool {
    success := true
    for p in procs {
        state, wait_error := os.process_wait(p)
        if wait_error != nil {
            fmt.printfln("Wait error: %v", wait_error)
            success = false
        }
        
        if !state.success || state.exit_code != 0 {
            fmt.eprintf("ERROR: Command exited with code %v\n", state.exit_code)
            success = false
        }
    }
    
    clear(procs)
    
    return success
}

procs_close :: proc (procs: ^Procs) {
    for p in procs {
        _ = os.process_terminate(p)
    }
    
    clear(procs)
}

////////////////////////////////////////////////

make_directory_if_not_exists :: proc (path: string) -> bool {
    result: bool
    if !os.exists(path) {
        os.make_directory(path)
        result = true
    }
    return result
}

make_file_if_not_exists :: proc (path: string, content: string) -> bool {
    result: bool
    if !os.exists(path) {
        _ = os.write_entire_file(path, content)
        result = true
    }
    return result
}

remove_if_exists :: proc (path: string) {
    if os.exists(path) do os.remove(path)
}

delete_all_like :: proc (path, pattern: string) {
    files := all_like(path, pattern, context.temp_allocator)
    for file in files {
        os.remove(file)
    }
}

all_like :: proc (path, pattern: string, allocator := context.temp_allocator) -> [] string {
    dir, _ := os.read_all_directory_by_path(path, allocator)
    reg, _ := regex.create(pattern, permanent_allocator = context.temp_allocator, temporary_allocator = context.temp_allocator)
    
    result := make([dynamic] string, allocator)
    for file in dir {
        _, ok := regex.match(reg, file.name, permanent_allocator = context.temp_allocator, temporary_allocator = context.temp_allocator)
        if ok {
            append(&result, file.fullpath)
        }
    }
    
    return result[:]
}

////////////////////////////////////////////////

random_number :: proc () -> u8 {
    return cast(u8) intrinsics.read_cycle_counter()
}