package main

import "core:fmt"
import win "core:sys/windows"

game_update_and_render    : proc_game_update_and_render
game_output_sound_samples : proc_game_output_sound_samples

init_game_lib :: proc(source_dll_name, temp_dll_name, lock_name: win.wstring) -> (is_valid:b32, last_write_time: u64) {
    if game_lib == nil {
        assert(game_update_and_render    == nil, "Game.dll has already been initialized")
        assert(game_output_sound_samples == nil, "Game.dll has already been initialized")
    } else {
        if !win.FreeLibrary(game_lib) {
            // TODO Diagnotics
        }
    }
    
    ignored : FILE_ATTRIBUTE_DATA
    if !win.GetFileAttributesExW(lock_name, win.GetFileExInfoStandard, &ignored) {
        win.CopyFileW(source_dll_name, temp_dll_name, false)
        last_write_time = get_last_write_time(source_dll_name)
        game_lib = win.LoadLibraryW(temp_dll_name)

        if (game_lib != nil) {
            game_update_and_render    = cast(proc_game_update_and_render)    win.GetProcAddress(game_lib, "game_update_and_render")
            game_output_sound_samples = cast(proc_game_output_sound_samples) win.GetProcAddress(game_lib, "game_output_sound_samples")

            is_valid = game_update_and_render != nil && game_output_sound_samples != nil
        } else {
            // TODO Diagnostics
        }
    }

    if !is_valid {
        game_update_and_render    = nil
        game_output_sound_samples = nil
    }
    
    return is_valid, last_write_time
}



// ---------------------- Internal stuff


@(private="file")
game_lib : win.HMODULE

@(private="file")
proc_game_update_and_render    :: #type proc(memory: ^GameMemory, offscreen_buffer: GameLoadedBitmap, input: GameInput)
@(private="file")
proc_game_output_sound_samples :: #type proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer)