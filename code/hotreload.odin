package main

import win "core:sys/windows"

@(private="file")
game_lib: win.HMODULE

@(private="file")
renderer_libs: [128] win.HMODULE
@(private="file")
renderer_lib_count: int

load_game_lib :: proc (source_dll_name, temp_dll_name, lock_name: cstring16) -> (is_valid: bool, last_write_time: u64) {
    if game_lib == nil {
        assert(game == game_stubs, "game.dll has already been initialized")
    } else {
        if !win.FreeLibrary(game_lib) {
            // @logging 
            print("Failed to load game.dll\n")
        }
    }
    
    if !win.GetFileAttributesExW(lock_name, win.GetFileExInfoStandard, nil) {
        win.CopyFileW(source_dll_name, temp_dll_name, false)
        last_write_time = get_last_write_time(source_dll_name)
        game_lib = win.LoadLibraryW(temp_dll_name)
        
        if game_lib != nil {
            load_game_api(game_lib)
            
            // @todo: do we really need to depent on debug_frame_end here?
            is_valid = game.update_and_render != nil && game.output_sound_samples != nil && game.debug_frame_end != nil
        } else {
            // @logging 
            print("Failed to initialize game api\n")
        }
    }
    
    if !is_valid {
        game = game_stubs
    }
    
    return is_valid, last_write_time
}

unload_game_lib :: proc () {
    if game_lib != nil {
        if !win.FreeLibrary(game_lib) {
            // @logging 
        }
        game_lib = nil
    }
    game = game_stubs
}

load_renderer_lib_candidate :: proc (source_dll_name, temp_dll_name, lock_name: cstring16) -> (lib: win.HMODULE, is_valid: bool, last_write_time: u64) {
    if win.GetFileAttributesW(lock_name) != win.INVALID_FILE_ATTRIBUTES {
        return
    }
    
    if !win.CopyFileW(source_dll_name, temp_dll_name, false) do return
    last_write_time = get_last_write_time(source_dll_name)
    lib = win.LoadLibraryW(temp_dll_name)
    if lib == nil do return
    
    load_render_api(lib)
    is_valid = render.attach != nil &&
               render.allocate_texture != nil &&
               render.manage_textures != nil &&
               render.render != nil
    return
}

commit_renderer_lib :: proc (lib: win.HMODULE) -> bool {
    if lib == nil || renderer_lib_count == len(renderer_libs) do return false
    
    // Unlike game.dll, old renderer generations are intentionally pinned.
    // Driver callbacks and allocator procedures may still point into them. A
    // full renderer shutdown can release the generations in reverse order.
    renderer_libs[renderer_lib_count] = lib
    renderer_lib_count += 1
    return true
}

get_last_write_time :: proc (filename: cstring16) -> (last_write_time: u64) {
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


////////////////////////////////////////////////
// reimplement to allow the deferred_out to work

end_timed_block :: proc () {
    game.end_timed_block()
}

@(deferred_none=end_timed_block)
timed_block :: proc (name: string, loc := #caller_location) {
    game.begin_timed_block(name, loc)
}

@(deferred_out = end_timed_block)
timed_function :: proc (loc := #caller_location) { 
    game.begin_timed_block(loc.procedure, loc)
}

debug_end_data_block :: proc () {
    game.debug_end_data_block()
}

@(deferred_out = debug_end_data_block)
debug_data_block :: proc (name: string, loc := #caller_location) {
    game.debug_begin_data_block(name, loc)
}