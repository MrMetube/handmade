package main

import win "core:sys/windows"

init_game_lib :: proc() -> (is_valid:b32) {
	if game_lib == nil {
		assert(game_update_and_render == game_update_and_render_stub, "Game.dll has already been initialized")
		assert(game_output_sound_samples == game_output_sound_samples_stub, "Game.dll has already been initialized")
	} else {
		if !win.FreeLibrary(game_lib) {
			// TODO Diagnotics
			_ = 123
		}
	}
	
	win.CopyFileW(win.utf8_to_wstring("game.dll"), win.utf8_to_wstring("temp_game.dll"), false)
	game_lib = win.LoadLibraryW(win.utf8_to_wstring("temp_game.dll"))

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
	
	return is_valid
}
@(private="file")
game_lib : win.HMODULE


game_update_and_render    := game_update_and_render_stub
game_output_sound_samples := game_output_sound_samples_stub

@(private="file")
proc_game_update_and_render    :: #type proc(memory: ^GameMemory, offscreen_buffer: GameOffscreenBuffer, input: GameInput)
@(private="file")
proc_game_output_sound_samples :: #type proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer)

@(private="file")
game_update_and_render_stub : proc_game_update_and_render = proc(memory: ^GameMemory, offscreen_buffer: GameOffscreenBuffer, input: GameInput) {}
@(private="file")
game_output_sound_samples_stub : proc_game_output_sound_samples = proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer) {}