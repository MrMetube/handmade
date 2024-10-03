package main

import "core:fmt"
import win "core:sys/windows"

game_update_and_render    := game_update_and_render_stub
game_output_sound_samples := game_output_sound_samples_stub

init_game_lib :: proc(source_dll_name: string) -> (is_valid:b32, last_write_time: u64) {
	w_source_dll_name := win.utf8_to_wstring(source_dll_name)
	temp_dll_name := win.utf8_to_wstring(fmt.tprint(source_dll_name, "temp.dll", sep="-"))
	
	if game_lib == nil {
		assert(game_update_and_render == game_update_and_render_stub, "Game.dll has already been initialized")
		assert(game_output_sound_samples == game_output_sound_samples_stub, "Game.dll has already been initialized")
	} else {
		if !win.FreeLibrary(game_lib) {
			// TODO Diagnotics
		}
	}

	win.CopyFileW(w_source_dll_name, temp_dll_name, false)
	last_write_time = get_last_write_time(source_dll_name)
	game_lib = win.LoadLibraryW(temp_dll_name)

	if (game_lib != nil) {
		game_update_and_render    = cast(proc_game_update_and_render)    win.GetProcAddress(game_lib, "game_update_and_render")
		game_output_sound_samples = cast(proc_game_output_sound_samples) win.GetProcAddress(game_lib, "game_output_sound_samples")

		is_valid = game_update_and_render != nil && game_output_sound_samples != nil
	} else {
		// TODO Diagnostics
	}

	if !is_valid {
		game_update_and_render    = game_update_and_render_stub
		game_output_sound_samples = game_output_sound_samples_stub
	}
	
	return is_valid, last_write_time
}



// ---------------------- Internal stuff


@(private="file")
game_lib : win.HMODULE

@(private="file")
proc_game_update_and_render    :: #type proc(memory: ^GameMemory, offscreen_buffer: GameOffscreenBuffer, input: GameInput)
@(private="file")
proc_game_output_sound_samples :: #type proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer)

@(private="file")
game_update_and_render_stub : proc_game_update_and_render = proc(memory: ^GameMemory, offscreen_buffer: GameOffscreenBuffer, input: GameInput) {}
@(private="file")
game_output_sound_samples_stub : proc_game_output_sound_samples = proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer) {}