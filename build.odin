#+feature dynamic-literals

package build

import "base:intrinsics"
import "core:os"
import win "core:sys/windows"
import "core:fmt"
import "core:log"
import "core:strings"
import "base:runtime"

flags    :: ` -error-pos-style:unix -vet-cast -vet-shadowing -subsystem:windows -linker:radlink `
debug    :: " -debug "
internal :: " -define:INTERNAL=true "
pedantic :: " -vet-unused-imports -warnings-as-errors -vet-unused-variables  -vet-style -vet-packages:main,game,hha -vet-unused-procedures" 

optimizations    := false ? " -o:speed " : " -o:none "

GamePedantic     :: false
PlatformPedantic :: false

src_path :: `.\build.odin`
exe_path :: `.\build\build.exe`

build_dir :: `.\build`
data_dir  :: `.\data`

Target :: enum {
    Game,
    Platform,
    AssetBuilder,
}
TargetFlags :: bit_set[Target]

TargetNames := map[string]Target {
    "Game"         = .Game,
    "Platform"     = .Platform,
    "AssetBuilder" = .AssetBuilder,
}

main :: proc() {
    context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
    context.logger.lowest_level = .Info
    
    targetsToBuild := TargetFlags{}
    for arg in os.args[1:] {
        if v, ok := TargetNames[arg]; ok {
            targetsToBuild += {v}
        }
    }
    if card(targetsToBuild) == 0 do targetsToBuild = ~targetsToBuild
    
    // TODO(viktor): clean up the initial build turd (ie. .\handmade.exe)
    // TODO(viktor): confirm in which directory we are running, handle subdirectories
    go_rebuild_yourself(exe_path)
    
    if !os.exists(build_dir) do os.make_directory(build_dir)
    if !os.exists(data_dir)  do os.make_directory(data_dir) 
    
    {
        err := os.set_current_directory(build_dir)
        assert(err == nil)
    }

    // TODO(viktor): parallel and serial build steps
    if .AssetBuilder in targetsToBuild {
        run_command_or_exit(`C:\Odin\odin.exe`, `odin build ..\code\game\asset_builder -out:.\asset_builder.exe`, flags, debug, pedantic)
    }

    if .Game in targetsToBuild {
        out := `.\game.dll`
        {
            delete_all_like(`.\game*.pdb`)
            
            // NOTE(viktor): the platform checks for this lock file when hot-reloading
            lock_path := `.\lock.tmp` 
            lock, err := os.open(lock_path, mode = os.O_CREATE)
            if err != nil do log.error(os.error_string(err))
            defer {
                os.close(lock)
                os.remove(lock_path)
            }
            
            fmt.fprint(lock, "WAITING FOR PDB")
            pdb := fmt.tprintf(` -pdb-name:.\game-%d.pdb`, random_number())
            run_command_or_exit(`C:\Odin\odin.exe`, `odin build ..\code\game -build-mode:dll -out:`, out, pdb, flags, debug, internal, optimizations, (pedantic when GamePedantic else ""))
        }
    }
    
    debug_exe := "debug.exe" 
    if .Platform in targetsToBuild && !is_running(debug_exe) {
        copy_over(`..\code\game\common.odin`, `..\code\copypasta_common.odin`, "package game", "package main")
        run_command_or_exit(`C:\Odin\odin.exe`, `odin build ..\code -out:.\`, debug_exe, flags, debug, internal, optimizations , (pedantic when PlatformPedantic else ""))
    }
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

go_rebuild_yourself :: proc(exe_path: string) {
    log.Level_Headers = { 0..<50 = "" }
    
    if modified_since(src_path, exe_path) {
        log.info("Rebuilding!")
        temp_path := fmt.tprintf("%s-temp", exe_path)
        
        delete_all_like(temp_path) 
        
        run_command_or_exit(`C:\Odin\odin.exe`, "odin build ", src_path, " -out:", temp_path, " -file ", pedantic)
        
        old_path := fmt.tprintf("%s-old", exe_path)
        if err := os.rename(exe_path,  old_path); err != nil do fmt.println(os.error_string(err))
        if err := os.rename(temp_path, exe_path); err != nil do fmt.println(os.error_string(err))
        
        exe := os.args[0]
        args := os.args
        args[0] = " "
        run_command_or_exit(exe, ..args) 
        
        os.exit(0)
    }
}

get_last_write_time_ :: proc(filename: string) -> (last_write_time: u64) {
    FILE_ATTRIBUTE_DATA :: struct {
        dwFileAttributes:  win.DWORD,
        ftCreationTime:    win.FILETIME,
        ftLastAccessTime:  win.FILETIME,
        ftLastWriteTime:   win.FILETIME,
        nFileSizeHigh:     win.DWORD,
        nFileSizeLow:      win.DWORD,
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
        file_path := fmt.tprintf(`.\%v`, file_name)
        
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

/* TODO(viktor): cmd.exe /C also 
    STARTF_USESHOWWINDOW :: 0x00000001
    startup_info := win.STARTUPINFOW{
        cb          = size_of(win.STARTUPINFOW),
        dwFlags     = STARTF_USESHOWWINDOW,
        wShowWindow = auto_cast win.SW_HIDE,
    }
 */
run_command_or_exit :: proc(program: string, args: ..string) {
    if !run_command(program, ..args) {
        os.exit(1)
    }
}

run_command :: proc(program: string, args: ..string) -> (success: b32) {
    startup_info := win.STARTUPINFOW{ cb = size_of(win.STARTUPINFOW) }
    process_info := win.PROCESS_INFORMATION{}
    
    
    working_directory := win.utf8_to_wstring(os.get_current_directory())
    
    joined_args := strings.join(args, "")
    
    log.info("Running:", program, " - ", joined_args)
    
    if win.CreateProcessW(
        win.utf8_to_wstring(program), 
        win.utf8_to_wstring(joined_args), 
        nil, nil, 
        win.TRUE, 0, 
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