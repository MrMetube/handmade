package main

import "core:os"
import win "core:sys/windows"
import "core:fmt"
import "core:log"
import "core:strings"
import "base:runtime"

when #config(BUILD, false) {

pedantic :: "-vet-unused-imports -warnings-as-errors -vet-unused-variables -vet-packages:main,game -vet-unused-procedures -vet-style"
flags    :: "-vet-cast -vet-shadowing -error-pos-style:unix -subsystem:windows"
debug    :: "-debug -define:INTERNAL=true -o:none"

src_path :: `.\build.odin`

main :: proc() {
    // TODO(viktor): maybe automatically copypasta the copypasta files?
    context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
    
    exe_path := os.args[0]
    rebuild_yourself(exe_path)
    
    if !os.exists(`.\build`) do os.make_directory(`.\build`)
    if !os.exists(`.\data`)  do os.make_directory(`.\data`) 
    
    debug_build := "debug.exe" 

    { // Game
        delete_all_like(".\\build\\*.pdb")
        
        // NOTE(viktor): the platform checks for this lock file when hotreloading
        lock_path := `.\lock.tmp` 
        lock, err := os.open(lock_path, mode = os.O_CREATE)
        if err != nil do log.error(os.error_string(err))
        defer {
            os.close(lock)
            os.remove(lock_path)
        }
        
        fmt.fprint(lock, "WAITING FOR PDB")
        
        if !run_command_sync(`C:\Odin\odin.exe`, fmt.tprintf(`odin build game -build-mode:dll -out:.\build\game.dll -pdb-name:.\build\game-%d.pdb %s %s `, random_number(), flags, debug)) {
            os.exit(1)
        }
    }

    if is_running(debug_build) do os.exit(0)

    {// Platform
        
        { // copy over the common code
            common_game_path     := `.\game\common.odin`
            common_platform_path := `.\common.odin`
            file, ok := os.read_entire_file(common_game_path)
            if !ok {
                log.error("common.odin file could not be read")
                os.exit(1)
            }
            
            if os.exists(common_platform_path) do os.remove(common_platform_path)
            common, err := os.open(common_platform_path, os.O_CREATE)
            
            common_code, _ := strings.replace(cast(string) file, "package game", "", 1)
            if err != nil do log.error(os.error_string(err))
            
            fmt.fprintfln(common, common_platform_header, common_game_path)
            fmt.fprint(common, common_code)
            os.close(common)
        }
        
        if !run_command_sync(`C:\Odin\odin.exe`, fmt.tprintf(`odin build . -out:.\build\%v %s %s`, debug_build, flags, debug)) {
            os.exit(1)
        }
    }
    
    os.exit(0)
}

rebuild_yourself :: proc(exe_path: string) {
    log.Level_Headers = {
        0..<10 = "[DEBUG] ",
        10..<20 = "[INFO ] ",
        20..<30 = "[WARN ] ",
        30..<40 = "[ERROR] ",
        40..<50 = "[FATAL] ",
    }
   
    exe_last_write_time := get_last_write_time_(exe_path)
    src_last_write_time := get_last_write_time_(src_path)
    
    if src_last_write_time > exe_last_write_time {
        log.info("Rebuilding Build!")
        temp_path := fmt.tprintf("%s-temp", exe_path)
        
        delete_all_like(temp_path)
        
        if !run_command_sync(`C:\Odin\odin.exe`, fmt.tprintf("odin build %s -file -out:%s -define:BUILD=true", src_path, temp_path)) {
            os.exit(1)
        } 
        
        old_path := fmt.tprintf("%s-old", exe_path)
        if err := os.rename(exe_path,  old_path); err != nil do fmt.println(os.error_string(err))
        if err := os.rename(temp_path, exe_path); err != nil do fmt.println(os.error_string(err))
        
        if !run_command_sync(exe_path, "") {
            os.exit(1)
        }
        
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

// TODO(viktor): accept []string instead
run_command_sync :: proc(program, args: string) -> (success: b32) {
    log.info("Running: [", program,"]", args)
    startup_info := win.STARTUPINFOW{ cb = size_of(win.STARTUPINFOW) }
    process_info := win.PROCESS_INFORMATION{}
     
    os.set_current_directory("D:\\handmade")
    working_directory := win.utf8_to_wstring(os.get_current_directory())
    
    if win.CreateProcessW(
        win.utf8_to_wstring(program), 
        win.utf8_to_wstring(args), 
        nil, nil, 
        win.FALSE, 0, 
        nil, working_directory, 
        &startup_info, &process_info
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

common_platform_header :: `package main

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