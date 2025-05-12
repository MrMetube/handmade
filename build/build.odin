package build

import "base:intrinsics"

import "core:fmt"
import "core:log"
import "core:os"
import "core:os/os2"
import "base:runtime"
import "core:strings"
import "core:time"

import win "core:sys/windows"

flags    :: ` -error-pos-style:unix -vet-cast -vet-shadowing -subsystem:windows `
debug    :: " -debug "
internal :: " -define:INTERNAL=true " // TODO(viktor): get rid of this
pedantic :: " -vet-unused-imports -warnings-as-errors -vet-unused-variables -vet-style -vet-packages:main,game,hha -vet-unused-procedures" 
commoner :: " -custom-attribute:common "

optimizations    :: " -o:none " when true else " -o:speed "
PedanticGame     :: false
PedanticPlatform :: false

src_path :: `.\build\`   
exe_path :: `.\build\build.exe`

build_dir :: `.\build\`
data_dir  :: `.\data`

main :: proc() {
    context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
    context.logger.lowest_level = .Info
    
    go_rebuild_yourself()
    
    make_directory_if_not_exists(data_dir)
    
    err := os.set_current_directory(build_dir)
    assert(err == nil)
    
    if len(os.args) == 1 {
        build_game()
        build_platform()
    } else {
        for arg in os.args[1:] {
            switch arg {
                case "AssetBuilder": run_command_or_exit(`C:\Odin\odin.exe`, `odin build ..\code\game\asset_builder -out:.\asset_builder.exe`, flags, debug, commoner, pedantic)
                case "Game":         build_game()
                case "Platform":     build_platform()
            }
        }
    }
}

build_game :: proc() {
    out := `.\game.dll`
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
    run_command_or_exit(`C:\Odin\odin.exe`, `odin build ..\code\game -build-mode:dll -out:`, out, pdb, flags, debug, internal, commoner, optimizations, (pedantic when PedanticGame else ""))
}

build_platform :: proc() {
    debug_exe := "debug.exe" 
    if !is_running(debug_exe) {
        extract_common_and_exports()
        
        run_command_or_exit(`C:\Odin\odin.exe`, `odin build ..\code -out:.\`, debug_exe, flags, debug, internal, optimizations , (pedantic when PedanticPlatform else ""))
    }
}



















Error :: union { os2.Error, os.Error }

go_rebuild_yourself :: proc() -> Error {
    log.Level_Headers = { 0..<50 = "" }
    
    if strings.ends_with(os.get_current_directory(), "build") do os.set_current_directory("..")
    
    gitignore := fmt.tprint(build_dir, `\.gitignore`, sep="")
    if !os.exists(gitignore) {
        contents := "*\n!*.odin"
        os.write_entire_file(gitignore, transmute([]u8) contents)
    }
    
    src_dir  := os2.read_directory_by_path(src_path, -1, context.allocator) or_return
    exe_time := os2.modification_time_by_path(exe_path) or_return
    
    needs_to_rebuild: b32
    
    for file in src_dir {
        if file.type == .Regular {
            if strings.ends_with(file.name, ".odin") {   
                if time.diff(exe_time, file.modification_time) > 0 {
                    needs_to_rebuild = true
                    break
                }
            }
        }
    }
    
    if needs_to_rebuild {
        log.info("Rebuilding!")
        
        pdb_path, _ := strings.replace(exe_path, ".exe", ".pdb", -1)
        remove_if_exists(pdb_path)
         
        old_path := fmt.tprintf("%s-old", exe_path)
        os.rename(exe_path, old_path) or_return
        
        if !run_command(`C:\Odin\odin.exe`, "odin run ", src_path, " -out:", exe_path, debug, pedantic) {
            os.rename(old_path, exe_path) or_return
        }
        
        remove_if_exists(old_path)
        
        os.exit(0)
    }
    
    return nil
}

remove_if_exists :: proc(path: string) {
    if os.exists(path) do os.remove(path)
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
    if handle == win.INVALID_HANDLE_VALUE do return
    defer win.FindClose(handle)
    
    for {
        file_name, err := win.utf16_to_utf8(find_data.cFileName[:])
        assert(err == nil)
        file_path := fmt.tprintf(`.\%v`, file_name)
        
        if err := os.remove(file_path); err != nil && err != .FILE_NOT_FOUND {
            log.errorf("Failed to delete file: %s because of error: %s", file_path, err)
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
    
    
    working_directory := win.utf8_to_wstring(os.get_current_directory())
    joined_args := strings.join(args, "")
    
    log.info("CMD:", program, " - ", joined_args)
    
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

make_directory_if_not_exists :: proc(path: string) -> (result: b32) {
    if !os.exists(path) {
        os.make_directory(path)
        result = true
    }
    return result
}

random_number :: proc() ->(result: u32) {
    bytes: [4]byte
    _ = runtime.random_generator_read_bytes(runtime.default_random_generator(), bytes[:])
    result = (cast(^u32) raw_data(bytes[:]))^ & 255
    
    return result
}