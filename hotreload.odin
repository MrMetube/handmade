package main

import win "core:sys/windows"

update_and_render    : UpdateAndRender
output_sound_samples : OutputSoundSamples

load_game_lib :: proc(source_dll_name, temp_dll_name, lock_name: win.wstring) -> (is_valid:b32, last_write_time: u64) {
    if game_lib == nil {
        assert(update_and_render    == nil, "Game.dll has already been initialized")
        assert(output_sound_samples == nil, "Game.dll has already been initialized")
    } else {
        if !win.FreeLibrary(game_lib) {
            // TODO Diagnotics
        }
    }
    
    if !win.GetFileAttributesExW(lock_name, win.GetFileExInfoStandard, nil) {
        win.CopyFileW(source_dll_name, temp_dll_name, false)
        last_write_time = get_last_write_time(source_dll_name)
        game_lib = win.LoadLibraryW(temp_dll_name)

        if (game_lib != nil) {
            update_and_render    = cast(UpdateAndRender)    win.GetProcAddress(game_lib, "update_and_render")
            output_sound_samples = cast(OutputSoundSamples) win.GetProcAddress(game_lib, "output_sound_samples")

            is_valid = update_and_render != nil && output_sound_samples != nil
        } else {
            // TODO Diagnostics
        }
    }

    if !is_valid {
        update_and_render    = nil
        output_sound_samples = nil
    }
    
    return is_valid, last_write_time
}

unload_game_lib :: proc() {
    if game_lib != nil {
        if !win.FreeLibrary(game_lib) {
            // TODO Diagnotics
        }
        game_lib = nil
    }
    update_and_render = nil
    output_sound_samples = nil
}


// ---------------------- Internal stuff


@(private="file")
game_lib : win.HMODULE

@(private="file")
UpdateAndRender    :: #type proc(memory: ^GameMemory, offscreen_buffer: Bitmap, input: Input)
@(private="file")
OutputSoundSamples :: #type proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer)