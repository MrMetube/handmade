package main

import "core:os"
import "core:fmt"
import win "core:sys/windows"

game := game_stubs

@(private="file")
game_lib: win.HMODULE

load_game_lib :: proc(source_dll_name, temp_dll_name, lock_name: win.wstring) -> (is_valid:b32, last_write_time: u64) {
    if game_lib == nil {
        assert(game == game_stubs, "game.dll has already been initialized")
    } else {
        if !win.FreeLibrary(game_lib) {
            // @Logging 
            fmt.println("Failed to load game.dll")
        }
    }
    
    if !win.GetFileAttributesExW(lock_name, win.GetFileExInfoStandard, nil) {
        win.CopyFileW(source_dll_name, temp_dll_name, false)
        last_write_time = get_last_write_time(source_dll_name)
        game_lib = win.LoadLibraryW(temp_dll_name)
        
        if game_lib != nil {
            load_game_api(game_lib)
            
            is_valid = game.update_and_render != nil && game.output_sound_samples != nil
        } else {
            // @Logging 
            fmt.println("Failed to initialize game api")
            fmt.println(os.error_string(os.get_last_error()))
        }
    }

    if !is_valid {
        game = game_stubs
    }
    
    return is_valid, last_write_time
}

unload_game_lib :: proc() {
    if game_lib != nil {
        if !win.FreeLibrary(game_lib) {
            // @Logging 
        }
        game_lib = nil
    }
    game = game_stubs
}

get_last_write_time :: proc(filename: win.wstring) -> (last_write_time: u64) {
    FILE_ATTRIBUTE_DATA :: struct {
        dwFileAttributes: win.DWORD,
        ftCreationTime:   win.FILETIME,
        ftLastAccessTime: win.FILETIME,
        ftLastWriteTime:  win.FILETIME,
        nFileSizeHigh:    win.DWORD,
        nFileSizeLow:     win.DWORD,
    }

    file_information: FILE_ATTRIBUTE_DATA
    if win.GetFileAttributesExW(filename, win.GetFileExInfoStandard, &file_information) {
        last_write_time = (cast(u64) (file_information.ftLastWriteTime.dwHighDateTime) << 32) | cast(u64) (file_information.ftLastWriteTime.dwLowDateTime)
    }
    return last_write_time
}
