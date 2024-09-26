package main

import "core:math"

// timing, controller/keyboard input, bitmap buffer to use, sound buffer to use
game_update_and_render :: proc(offscreen_buffer: GameOffscreenBuffer, sound_buffer: GameSoundBuffer, xOffset, yOffset: i32) {
	// TODO: Allow sample offsets here for more robust platform options
	game_output_sound(sound_buffer)
	render_weird_gradient(offscreen_buffer, xOffset, yOffset)
}

GameSoundBuffer :: struct {
	samples            : [][2]i16,
	samples_per_second : u32,
}

game_output_sound :: proc(sound_buffer: GameSoundBuffer ){
	@(static)
	t_sine: f32 = 0
	tone_volumne :: 1000
	// tone_hz = 440 + u32(440 * f32(left_stick_y) / 60000)
	tone_hz :: 420
	wave_period := sound_buffer.samples_per_second / tone_hz

	for sample_out_index in 0..<len(sound_buffer.samples){
		sample_value := cast(i16) (math.sin(t_sine) * tone_volumne)

		sound_buffer.samples[sample_out_index] = {sample_value, sample_value}
		t_sine += math.TAU / f32(wave_period)
	}
}


GameOffscreenBuffer :: struct {
	memory : rawptr, // TODO should this just be [^]struct{bb, gg, rr, xx} ?
	width  : i32,
	height : i32,
}

render_weird_gradient :: proc(buffer: GameOffscreenBuffer , xOffset, yOffset: i32) {
	Color :: struct {
		b, g, r, pad: u8
	}

	bytes := cast([^]u8) buffer.memory
	row_index: i32 = 0

	for y in 0..<buffer.height {
		for x in 0..<buffer.width {
			pixel := cast(^Color) &bytes[row_index]
			pixel.b = u8(x + xOffset)
			pixel.g = u8(y + yOffset)
			row_index += size_of(Color)
		}
	}
}