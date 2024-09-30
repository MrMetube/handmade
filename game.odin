package main

import "core:math"  // TODO implement sine ourself

GameSoundBuffer :: struct {
	samples            : [][2]i16,
	samples_per_second : u32,
}

GameOffscreenBuffer :: struct {
	memory : [^]OffscreenBufferColor,
	width  : i32,
	height : i32,
}

GameInputButton :: struct {
	half_transition_count: i32,
	ended_down : b32,
}

GameInputButtons :: enum {
	up, down, left, right,
	left_shoulder, right_shoulder,
}

GameInputController :: struct {
	is_analog: b32,

	start: [2]f32,
	end:   [2]f32,
	min:   [2]f32,
	max:   [2]f32,
	
	using _ : struct #raw_union {
		buttons: [GameInputButtons]GameInputButton,
		using _ : struct {
			up    : GameInputButton,
			down  : GameInputButton,
			left  : GameInputButton,
			right : GameInputButton,

			left_shoulder  : GameInputButton,
			right_shoulder : GameInputButton,
		},
	},
}

// TODO allow outputing vibration
GameInput :: struct {
	// TODO insert clock values here
	controllers: [4]GameInputController
}

GameMemory :: struct {
	is_initialized: b32,
	// Note: REQUIRED to be cleared to zero at startup
	permanent_storage: []u8, 
	transient_storage: []u8,
}

GameState :: struct {
	green_offset, blue_offset: i32,
	tone_hz:u32,
}

// timing, keyboard input
game_update_and_render :: proc(memory: ^GameMemory, offscreen_buffer: GameOffscreenBuffer, sound_buffer: GameSoundBuffer, input: GameInput){
	assert(size_of(GameState) <= len(memory.permanent_storage), "The GameState cannot fit inside the permanent memory")
	
	game_state := cast(^GameState) raw_data(memory.permanent_storage)

	if !memory.is_initialized {
		game_state.tone_hz = 420

		file := DEBUG_read_entire_file(#file)
		if file != nil {
			DEBUG_write_entire_file("D:/projekte/handmade/data/testfile.test", file)
			DEBUG_free_file_memory(file)
		}
		// TODO this may be more appropriate to do in the platform layer
		memory.is_initialized = true
	}

	// TODO deal with the dead zones properly
	// xOffset += cast(i32) (left_stick_x / 4096)
	// yOffset -= cast(i32) (left_stick_y / 4096)
	// tone_hz = 440 + u32(440 * f32(left_stick_y) / 60000)

	input0 := input.controllers[0]

	if input0.is_analog {
		// TODO analog movement tuning
		game_state.green_offset += cast(i32) (4 * input0.end.x)
		game_state.tone_hz = 420 + cast(u32)(210 * input0.end.y)
	} else {
		// TODO digital movement tuning

	}

	if input0.down.ended_down {
		game_state.blue_offset += 1
	}

	
	// TODO: Allow sample offsets here for more robust platform options
	game_output_sound(sound_buffer, game_state.tone_hz)
	render_weird_gradient(offscreen_buffer, game_state.green_offset, game_state.blue_offset)
}

game_output_sound :: proc(sound_buffer: GameSoundBuffer, tone_hz: u32){
	@(static)
	t_sine: f32 = 0
	tone_volumne :: 1000
	wave_period := sound_buffer.samples_per_second / tone_hz

	for sample_out_index in 0..<len(sound_buffer.samples){
		sample_value := cast(i16) (math.sin(t_sine) * tone_volumne)

		sound_buffer.samples[sample_out_index] = {sample_value, sample_value}
		t_sine += math.TAU / f32(wave_period)
	}
}

render_weird_gradient :: proc(buffer: GameOffscreenBuffer , greenOffset, blueOffset: i32) {
	bytes := buffer.memory
	row_index: i32 = 0

	for y in 0..<buffer.height {
		for x in 0..<buffer.width {
			pixel := &bytes[row_index]
			pixel.b = u8(y + blueOffset)
			pixel.g = u8(x + greenOffset)
			row_index += 1
		}
	}
}