package build

import "base:intrinsics"

import "core:fmt"
import os "core:os/os2"
import "core:text/regex"
import "core:strings"
import win "core:sys/windows"

////////////////////////////////////////////////

// @todo(viktor): 
// integrate with vscode shortcuts
// readd renderdoc, and maybe simplify it
// windows subsystem: "-subsystem:windows", "-subsystem:console"



cmd   := &the_state.cmd
procs := &the_state.procs

////////////////////////////////////////////////
// Internal state

raddbg      :: `raddbg.exe`
raddbg_path :: `C:\tools\raddbg\`+ raddbg

Procs :: [dynamic] os.Process
Cmd   :: [dynamic] string

the_state := struct {
    cmd: Cmd,
    procs: Procs,

    current_output: string,
    outputs: map [string] bool,

    wait_on_procs: bool,
    run_from_data: bool
} {
    // Defaults
}

Handle_Running_Exe :: enum {
    Skip,
    Abort, 
    Kill,
}

////////////////////////////////////////////////

@(deferred_none=deinit_build)
init_build :: proc (run_from_data := false, wait := false) {
    gitignore_path := "./build/.gitignore"
    if !os.exists(gitignore_path) {
        data := "*\n!*.odin\n"
        _ = os.write_entire_file(gitignore_path, transmute([] u8) data)
    }
    
    if run_from_data {
        make_directory_if_not_exists("./data")
        the_state.run_from_data = true
    }
    the_state.wait_on_procs = wait
}

deinit_build :: proc () {
    if len(cmd) != 0 {
        fmt.printf("INFO: cmd was not cleared: `%v`\n", strings.join(cmd[:], " "))
    }
    
    if the_state.wait_on_procs {
        procs_flush(procs)
    } else {
        procs_close(procs)
    }
}

////////////////////////////////////////////////

begin_build :: proc (cmd: ^Cmd, package_directory: string, output_name: string, handling: Handle_Running_Exe = .Skip) -> bool {
    // @todo(viktor): check that we do not nest, or make this stateless(see current_output)
    result: bool
    
    if handle_running_exe_gracefully(output_name, handling) {
        os.change_directory("./build")
        
        append(cmd, "odin", "build")
        append(cmd, fmt.tprintf("../%v", package_directory))
        append(cmd, fmt.tprintf("-out:%v", output_name))
        result = true
        
        the_state.outputs[output_name] = true
        the_state.current_output = output_name
    }
    
    return result
}

build_meander :: proc (debug := "-debug", Cast := "-vet-cast", shadowing := "-vet-shadowing") {
    append(cmd, debug, Cast, shadowing)
}

build_optimizations :: proc (optimize: bool, optimized := "-o:speed", unoptimized := "-o:none") {
    append(cmd, optimize ? optimized : unoptimized)
}

build_native :: proc (native: bool, target := "-target:windows_amd64", microarch := "-microarch:native") {
    if native {
        append(cmd, target, microarch)
    }
}

build_pedantic :: proc (pedantic: bool, imports := "-vet-unused-imports", semicolon := "-vet-semicolon", variables := "-vet-unused-variables", style := "-vet-style", procedures := "-vet-unused-procedures") {
    if pedantic {
        append(cmd, imports, semicolon, variables, style, procedures)
    }
}

end_build :: proc (cmd: ^Cmd) {
    if run_command(cmd) {
        fmt.printf("  Build successful %v.\n", the_state.current_output)
    } else {
        the_state.outputs[the_state.current_output] = false
    }
    
    os.change_directory("..")
    the_state.current_output = ""
}

// @api just do this parsing and make arrays for each kind of command and its targets. 
// then let the user check this data, so we can conditionally build, run and debug 
// when nothing in build is passed, build everything
// when nothing in run / debug / renderdoc is passed 
// @todo(viktor): if needed make this user controlled and just handle the prefix and checking output steps
run_or_debug_according_to_args :: proc () {
    run_prefix := "run:"
    debug_prefix := "debug:"
    
    for argument in os.args[1:] {
        if strings.starts_with(argument, run_prefix) {
            rest := argument[len(run_prefix):]
            
            if success, found := the_state.outputs[rest]; found {
                if success {
                    if the_state.run_from_data {
                        os.change_directory("./data")
                    }
                
                    append(cmd, fmt.tprintf("../build/%v", rest))
                    run_command(cmd, async = procs)
                } else {
                    // @todo(viktor): notify user?
                }
            } else {
                // @todo(viktor): notify user?
            }
        } else if strings.starts_with(argument, debug_prefix) {
            rest := argument[len(debug_prefix):]
            append(cmd, raddbg_path)
            append(cmd, "--ipc")
            append(cmd, "select_target")
            append(cmd, rest)
            run_command(cmd)
            
            append(cmd, raddbg_path)
            append(cmd, "--ipc")
            append(cmd, "restart")
            run_command(cmd)
        }
    }
}

////////////////////////////////////////////////

is_running :: proc (exe_name: string) -> (running: bool, pid: u32) {
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

handle_running_exe_gracefully :: proc (exe_name: string, handling: Handle_Running_Exe) -> bool {
    for {
        ok, pid := is_running(exe_name)
        if ok {
            fmt.printf("INFO: Tried to build '%v', but the program is already running.\n", exe_name)
            switch handling {
            case .Skip:
                fmt.printf("  Skipping build.\n", exe_name)
                ok = false
                
            case .Abort: 
                fmt.printf("  Aborting build!\n", exe_name)
                os.exit(0)
                
            case .Kill: 
                fmt.printf("  Killing running instance.\n")
                
                // @cleanup
                process, err := os.process_open(auto_cast pid)
                if err != nil {
                    fmt.printf("  Failed to open '%v': %v\n", exe_name, err)
                    ok = false
                } else {
                    err = os.process_kill(process)
                    if err != nil {
                        fmt.printf("  Failed to kill '%v': %v\n", exe_name, err)
                        ok = false
                    } else {
                        err = os.process_close(process)
                        if err != nil {
                            fmt.printf("  Failed to close '%v': %v\n", exe_name, err)
                            ok = false
                        }
                    }
                }
            }
        }
        
        if !ok do break
    }
    
    return true
}

////////////////////////////////////////////////

// @todo(viktor): Find where the version where I could also pass os.stdin/stdout here
run_command :: proc (cmd: ^Cmd, or_exit := true, keep := false, stdout: ^string = nil, stderr: ^string = nil, async: ^Procs = nil) -> (success: bool) {
    fmt.printf("CMD: %v\n", strings.join(cmd[:], " "))
    
    process_description := os.Process_Desc { command = cmd[:] }
    process: os.Process
    state:   os.Process_State
	output:  [] byte
	error:   [] byte
    err2:    os.Error
    if async == nil {
        state, output, error, err2 = os.process_exec(process_description, context.allocator)
    } else {
        process, err2 = os.process_start(process_description)
        append(async, process)
    }
    
    if err2 != nil {
        fmt.printf("ERROR: Failed to run command: %v\n", err2)
        return false
    }
    
    if async == nil {
        if output != nil {
            if stdout != nil do stdout ^= cast(string) output
            else do fmt.println(cast(string) output)
        }
        
        if error != nil {
            if stderr != nil do stderr ^= cast(string) error
            else do fmt.println(cast(string) error)
            
            if or_exit do os.exit(state.exit_code)
        }
        
        if or_exit && !state.success do os.exit(state.exit_code)
        
        success = state.success
    } else {
        success = true
    }
    
    if !keep do clear(cmd)
    
    return success
}

procs_flush :: proc (procs: ^Procs) {
    for &p in procs {
        _, _ = os.process_wait(p)
    }
    
    clear(procs)
}

procs_close :: proc (procs: ^Procs) {
    for &p in procs {
        _ = os.process_close(p)
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

remove_if_exists :: proc (path: string) {
    if os.exists(path) do os.remove(path)
}

delete_all_like :: proc (path, pattern: string) {
    files := all_like(path, pattern)
    for file in files {
        os.remove(file)
    }
}

all_like :: proc (path, pattern: string, allocator := context.temp_allocator) -> [] string {
    dir, _ := os.read_all_directory_by_path(path, allocator)
    reg, _ := regex.create(pattern)
    
    result := make([dynamic] string, allocator)
    for file in dir {
        _, ok := regex.match(reg, file.name)
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