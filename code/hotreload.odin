package main

import win "core:sys/windows"

game_update_and_render:    UpdateAndRender
game_output_sound_samples: OutputSoundSamples
game_debug_frame_end:      DebugFrameEnd

load_game_lib :: proc(source_dll_name, temp_dll_name, lock_name: win.wstring) -> (is_valid:b32, last_write_time: u64) {
    if game_lib == nil {
        assert(game_update_and_render    == nil, "Game.dll has already been initialized")
        assert(game_output_sound_samples == nil, "Game.dll has already been initialized")
        assert(game_debug_frame_end      == nil, "Game.dll has already been initialized")
    } else {
        if !win.FreeLibrary(game_lib) {
            // TODO: Diagnotics
        }
    }
    
    if !win.GetFileAttributesExW(lock_name, win.GetFileExInfoStandard, nil) {
        win.CopyFileW(source_dll_name, temp_dll_name, false)
        last_write_time = get_last_write_time(source_dll_name)
        game_lib = win.LoadLibraryW(temp_dll_name)

        if (game_lib != nil) {
            game_update_and_render    = auto_cast win.GetProcAddress(game_lib, "update_and_render")
            game_output_sound_samples = auto_cast win.GetProcAddress(game_lib, "output_sound_samples")
            game_debug_frame_end      = auto_cast win.GetProcAddress(game_lib, "debug_frame_end")

            is_valid = game_update_and_render != nil && game_output_sound_samples != nil
        } else {
            // TODO: Diagnostics
        }
    }

    if !is_valid {
        game_update_and_render    = nil
        game_output_sound_samples = nil
    }
    
    return is_valid, last_write_time
}

unload_game_lib :: proc() {
    if game_lib != nil {
        if !win.FreeLibrary(game_lib) {
            // TODO: Diagnotics
        }
        game_lib = nil
    }
    game_update_and_render    = nil
    game_output_sound_samples = nil
    game_debug_frame_end      = nil
}

////////////////////////////////////////////////
// Internals

@(private="file")
game_lib: win.HMODULE

@(private="file")
UpdateAndRender    :: #type proc(memory: ^GameMemory, offscreen_buffer: Bitmap, input: Input)
@(private="file")
OutputSoundSamples :: #type proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer)
@(private="file")
DebugFrameEnd      :: #type proc(memory: ^GameMemory, frame_info: DebugFrameInfo)