package main

import win "core:sys/windows"

@(private="file") game_lib:   win.HMODULE
@(private="file") render_lib: win.HMODULE

Dll :: struct {
    name: cstring16,
    lock: cstring16,
    temp: cstring16,
    
    is_valid:   bool,
    write_time: u64,
}

load_game_lib :: proc (dll: Dll) -> (is_valid: bool, last_write_time: u64) {
    if game_lib == nil {
        assert(game == game_stubs, "game.dll has already been initialized")
    }
    
    unload_game_api()
    
    game_lib, last_write_time = load_dll(dll)
    if game_lib == nil do return false, last_write_time
    
    load_game_api(game_lib)
    // @todo: do we really need to depend on debug_frame_end here?
    is_valid = game.update_and_render != nil && game.output_sound_samples != nil && game.debug_frame_end != nil
    if !is_valid {
        unload_game_api()
    }
    return is_valid, last_write_time
}

load_render_lib :: proc (dll: Dll) -> (is_valid: bool, last_write_time: u64) {
    if render_lib == nil {
        assert(render == render_stubs, "render.dll has already been initialized")
    }
    
    render_lib, last_write_time = load_dll(dll)
    if render_lib == nil do return false, last_write_time
    
    load_render_api(render_lib)
    is_valid = render.attach != nil && render.allocate_texture != nil && render.manage_textures != nil && render.render != nil && render.reload_or_shutdown != nil
    if !is_valid {
        unload_render_api()
    }
    return is_valid, last_write_time
}

load_dll :: proc (dll: Dll) -> (lib: win.HMODULE, last_write_time: u64) {
    if win.GetFileAttributesW(dll.lock) != win.INVALID_FILE_ATTRIBUTES {
        return nil, 0
    }
    
    if !win.CopyFileW(dll.name, dll.temp, false) do return nil, 0
    last_write_time = get_last_write_time(dll.name)
    lib = win.LoadLibraryW(dll.temp)
    return lib, last_write_time
}

needs_to_be_reloaded :: proc (dll: Dll) -> bool {
    result := get_last_write_time(dll.name) != dll.write_time
    return result
}

////////////////////////////////////////////////

unload_render_api :: proc () {
    unload_api(&render_lib, &render, render_stubs)
}

unload_game_api :: proc () {
    unload_api(&game_lib, &game, game_stubs)
}

unload_api :: proc (lib: ^win.HMODULE, api: ^$T, stubs: T) {
    if lib^ != nil {
        if !win.FreeLibrary(lib^) {
            // @logging 
        }
        lib^ = nil
    }
    api^ = stubs
}

////////////////////////////////////////////////

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