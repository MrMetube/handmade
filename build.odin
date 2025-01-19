package main

import "core:os"
import win "core:sys/windows"
import "core:fmt"
import "core:log"
import "core:strings"
import "base:runtime"

when #config(BUILD, false) {

flags    :: " -vet-cast -vet-shadowing -error-pos-style:unix "
windows  :: " -subsystem:windows "
console  :: " -subsystem:console "
debug    :: " -debug "
internal :: " -define:INTERNAL=true "

optimizations :: " -o:none " when true else " -o:speed "
pedantic :: " -vet-unused-imports -warnings-as-errors -vet-unused-variables -vet-packages:main,game -vet-unused-procedures -vet-style "

src_path :: `.\build.odin`

main :: proc() {
    // TODO(viktor): maybe automatically copypasta the copypasta files?
    context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
    context.logger.lowest_level = .Info
    
    exe_path := os.args[0]
    rebuild_yourself(exe_path)
    
    if !os.exists(`.\build`) do os.make_directory(`.\build`)
    if !os.exists(`.\data`)  do os.make_directory(`.\data`) 
    
    debug_build := "debug.exe" 

    { // Game
        out := `.\build\game.dll`
        {
            delete_all_like(`.\build\game*.pdb`)
            
            // NOTE(viktor): the platform checks for this lock file when hot-reloading
            lock_path := `.\lock.tmp` 
            lock, err := os.open(lock_path, mode = os.O_CREATE)
            if err != nil do log.error(os.error_string(err))
            defer {
                os.close(lock)
                os.remove(lock_path)
            }
            
            fmt.fprint(lock, "WAITING FOR PDB")
            pdb := fmt.tprintf(` -pdb-name:.\build\game-%d.pdb`, random_number())
            run_command_or_exit(`C:\Odin\odin.exe`, `odin build game -build-mode:dll -out:`, out, pdb, flags, debug, internal, optimizations, /* pedantic */)
        }
    }

    { // Asset file Builder
        out := `.\build\asset_builder.exe`
        src := `.\game\asset_builder`
        run_command_or_exit(`C:\Odin\odin.exe`, `odin build `, src, ` -out:`, out, flags, console, debug, pedantic)
    }
    
    if is_running(debug_build) do os.exit(0)

    {// Platform
        copy_over(`.\game\common.odin`, `.\common.odin`, "package game", "package main")
        run_command_or_exit(`C:\Odin\odin.exe`, `odin build . -out:.\build\`, debug_build, flags, debug, windows, internal, optimizations, /* pedantic */)
    }
    
    os.exit(0)
}

copy_over :: proc(src_path, dst_path, package_line_to_delete, package_line_replacement: string) {
    src, ok := os.read_entire_file(src_path)
    if !ok {
        log.errorf("file %v could not be read", src_path)
        os.exit(1)
    }
    
    os.remove(dst_path)
    
    dst, _ := os.open(dst_path, os.O_CREATE)
    src_code, _ := strings.replace(cast(string) src, package_line_to_delete, "", 1)
    
    fmt.fprintln(dst, package_line_replacement)
    fmt.fprintfln(dst, copypasta_header, src_path)
    fmt.fprint(dst, src_code)
    os.close(dst)
}


modified_since :: proc(src, out: string) -> (result: b32) {
    // TODO(viktor): also allow for checking a whole dir for changes
    src_time := get_last_write_time_(src)
    out_time := get_last_write_time_(out)
    result = src_time > out_time
    
    return result
}

rebuild_yourself :: proc(exe_path: string) {
    log.Level_Headers = {
         0..<10 = "[DEBUG] ",
        10..<20 = "[INFO ] ",
        20..<30 = "[WARN ] ",
        30..<40 = "[ERROR] ",
        40..<50 = "[FATAL] ",
    }
    
    if modified_since(src_path, exe_path) {
        log.info("Rebuilding Build!")
        temp_path := fmt.tprintf("%s-temp", exe_path)
        
        delete_all_like(temp_path)
        
        run_command_or_exit(`C:\Odin\odin.exe`, "odin build ", src_path, " -out:", temp_path, " -file -define:BUILD=true ", pedantic)
        
        old_path := fmt.tprintf("%s-old", exe_path)
        if err := os.rename(exe_path,  old_path); err != nil do fmt.println(os.error_string(err))
        if err := os.rename(temp_path, exe_path); err != nil do fmt.println(os.error_string(err))
        
        run_command_or_exit(exe_path)
        
        os.exit(0)
    }
}

get_last_write_time_ :: proc(filename: string) -> (last_write_time: u64) {
    FILE_ATTRIBUTE_DATA :: struct {
        dwFileAttributes : win.DWORD,
        ftCreationTime   : win.FILETIME,
        ftLastAccessTime : win.FILETIME,
        ftLastWriteTime  : win.FILETIME,
        nFileSizeHigh    : win.DWORD,
        nFileSizeLow     : win.DWORD,
    }

    file_information : FILE_ATTRIBUTE_DATA
    if win.GetFileAttributesExW(win.utf8_to_wstring(filename), win.GetFileExInfoStandard, &file_information) {
        last_write_time = (cast(u64) (file_information.ftLastWriteTime.dwHighDateTime) << 32) | cast(u64) (file_information.ftLastWriteTime.dwLowDateTime)
    }
    return last_write_time
}

delete_all_like :: proc(pattern: string) {
    find_data := win.WIN32_FIND_DATAW{}

    handle := win.FindFirstFileW(win.utf8_to_wstring(pattern), &find_data)
    if handle == win.INVALID_HANDLE_VALUE {
        return
    }
    defer win.FindClose(handle)
    
    for {
        file_name, err := win.utf16_to_utf8(find_data.cFileName[:])
        assert(err == nil)
        file_path := fmt.tprintf(".\\build\\%v", file_name)
        
        if err := os.remove(file_path); err != nil {
            log.errorf("Failed to delete file: %s because of error: %s", file_path, os.error_string(os.get_last_error()))
        }

        if !win.FindNextFileW(handle, &find_data){
            break
        }
    }
}

is_running :: proc(exe_name: string) -> (running: b32) {
    snapshot := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPALL, 0)
    log.assert(snapshot != win.INVALID_HANDLE_VALUE, "could not take a snapshot of the running programms")
    defer win.CloseHandle(snapshot)

    process_entry := win.PROCESSENTRY32W{ dwSize = size_of(win.PROCESSENTRY32W)}

    if win.Process32FirstW(snapshot, &process_entry) {
        for {
            test_name, err := win.utf16_to_utf8(process_entry.szExeFile[:])
            log.assert(err == nil)
            if exe_name == test_name {
                return true
            }
            if !win.Process32NextW(snapshot, &process_entry) {
                break
            }
        }
    }

    return false
}

run_command_or_exit :: proc(program: string, args: ..string) {
    if !run_command(program, ..args) {
        os.exit(1)
    }
}

run_command :: proc(program: string, args: ..string) -> (success: b32) {
    startup_info := win.STARTUPINFOW{ cb = size_of(win.STARTUPINFOW) }
    process_info := win.PROCESS_INFORMATION{}
     
    os.set_current_directory("D:\\handmade")
    working_directory := win.utf8_to_wstring(os.get_current_directory())
    
    joined_args := strings.join(args, "")
    
    if len(args) == 0 {
        log.info("Running:", program,)
    } else {
        log.info("Running:", joined_args)
    }
    
    if win.CreateProcessW(
        win.utf8_to_wstring(program), 
        win.utf8_to_wstring(joined_args), 
        nil, nil, 
        win.FALSE, 0, 
        nil, working_directory, 
        &startup_info, &process_info,
    ) {
        
        win.WaitForSingleObject(process_info.hProcess, win.INFINITE)
        
        exit_code: win.DWORD
        win.GetExitCodeProcess(process_info.hProcess, &exit_code)
        success = exit_code == 0
        
        win.CloseHandle(process_info.hProcess)
        win.CloseHandle(process_info.hThread)
    } else {
        log.errorf("Failed to execute the command: %s %s with error %s", program, args, os.error_string(os.get_last_error()))
        success = false
    }
    return
}

random_number :: proc() ->(result: u32) {
    bytes: [4]byte
    _ = runtime.random_generator_read_bytes(runtime.default_random_generator(), bytes[:])
    result = (cast(^u32) raw_data(bytes[:]))^ & 255
    
    return result
}

copypasta_header :: `
/* @Generated @Copypasta from %v

    -------------------------------------------------------------
    -------------------------------------------------------------
    -------------------------------------------------------------
    -------------------------------------------------------------
    -------------------------------------------------------------

    IMPORTANT: Do not modify this file, all changes will be lost!
    
    -------------------------------------------------------------
    -------------------------------------------------------------
    -------------------------------------------------------------
    -------------------------------------------------------------
    -------------------------------------------------------------
    
*/`

} // end when #config(BUILD)