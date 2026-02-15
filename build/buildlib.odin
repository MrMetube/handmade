package build

import "core:fmt"
import os "core:os/os2"
import "core:strings"
import "core:text/regex"
import "core:thread"
import "core:time"

Procs :: [dynamic] Proc
Cmd   :: [dynamic] string

Proc :: union { os.Process, thread.Thread }

Handle_Running_Exe :: enum {
    Skip,
    Abort, 
    Kill,
}

odin_build :: proc (cmd: ^[dynamic]string, dir: string, out: string) {
    append(cmd, "odin")
    append(cmd, "build")
    append(cmd, dir)
    append(cmd, fmt.tprintf("-out:%v", out))
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
            
            process, _ := os.process_open(auto_cast pid)
            _ = os.process_kill(process)
            _ = os.process_close(process)
            return true
        }
    }
    
    return true
}

did_change :: proc (output_path: string, inputs: .. string, extension: string = ".odin") -> (result: bool) {
    output_info, err := os.stat(output_path, context.temp_allocator)
    if err != nil {
        result = true
    } else {
        search: for input in inputs {
            files: [] os.File_Info
            error: os.Error
            if os.is_dir(input) {
                files, error = os.read_all_directory_by_path(input, context.allocator)
                if error != nil {
                    fmt.printfln("ERROR: failed to read directory '%v' when checking for changes: %v", input, error)
                    break search
                }
            } else {
                file, stat_error := os.stat(input, context.allocator)
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
    for file in files {
        os.remove(file)
    }
}

all_like :: proc (pattern: string, allocator := context.temp_allocator) -> ([] string) {
    working_directory, _ := os.get_working_directory(allocator)
    dir, _ := os.read_all_directory_by_path(working_directory, allocator)
    
    reg, _ := regex.create(pattern)
    
    result := make([dynamic] string, allocator)
    for file in dir {
        _, ok := regex.match(reg, file.name)
        if ok {
            append(&result, file.name)
        }
    }
    
    return result[:]
}

is_running :: proc (exe_name: string) -> (running: b32, pid: u32) {
    pids, _ := os.process_list(context.temp_allocator)
    for pid in pids {
        info, _ := os.process_info_by_pid(pid, {.Executable_Path}, context.temp_allocator)
        if strings.ends_with(info.executable_path, exe_name) {
            return true, auto_cast pid
        }
    }
    
    return false, 0
}

run_command :: proc (cmd: ^Cmd, or_exit := true, keep := false, stdout: ^string = nil, stderr: ^string = nil, async: ^Procs = nil) -> (success: bool) {
    fmt.printfln(`CMD: %v`, strings.join(cmd[:], ` `))
    
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
        case os.Process:
            // @todo(viktor): handle the returned values
            _, _= os.process_wait(value)
        case thread.Thread:
            thread.join(&value)
        }
    }
    
    clear(procs)
}

make_directory_if_not_exists :: proc (path: string) -> (result: b32) {
    if !os.exists(path) {
        os.make_directory(path)
        result = true
    }
    return result
}
