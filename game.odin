package main

import "core:math"

GameSoundBuffer :: struct {
	samples            : [][2]i16,
	samples_per_second : u32,
}

GameOffscreenBuffer :: struct {
	memory : rawptr, // TODO should this just be [^]struct{bb, gg, rr, xx} ?
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
	
	// TODO maybe [enum]array // TODO xbox/ps raw union ?
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
	controllers: [4]GameInputController
}

// timing, controller/keyboard input
game_update_and_render :: proc(offscreen_buffer: GameOffscreenBuffer, sound_buffer: GameSoundBuffer, input: GameInput){
	@(static)
	greenOffset, blueOffset: i32
	// TODO deal with the dead zones properly
	// xOffset += cast(i32) (left_stick_x / 4096)
	// yOffset -= cast(i32) (left_stick_y / 4096)
	@(static)
	tone_hz:u32 = 420
	// tone_hz = 440 + u32(440 * f32(left_stick_y) / 60000)

	input0 := input.controllers[0]

	if input0.is_analog {
		// TODO analog movement tuning
		greenOffset += cast(i32) (4 * input0.end.x)
		tone_hz = 420 + cast(u32)(210 * input0.end.y)
	} else {
		// TODO digital movement tuning

	}

	if input0.down.ended_down {
		blueOffset += 1
	}

	
	// TODO: Allow sample offsets here for more robust platform options
	game_output_sound(sound_buffer, tone_hz)
	render_weird_gradient(offscreen_buffer, greenOffset, blueOffset)
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
	Color :: struct {
		b, g, r, pad: u8
	}

	bytes := cast([^]u8) buffer.memory
	row_index: i32 = 0

	for y in 0..<buffer.height {
		for x in 0..<buffer.width {
			pixel := cast(^Color) &bytes[row_index]
			pixel.b = u8(y + blueOffset)
			pixel.g = u8(x + greenOffset)
			row_index += size_of(Color)
		}
	}
}