package game

import "core:fmt"
import "core:math"  // TODO implement sine ourself

// TODO Copypasta from platform
SoundOutput :: struct {
	samples_per_second         : u32,
	num_channels               : u32,
	bytes_per_sample           : u32,
	sound_buffer_size_in_bytes : u32,
	running_sample_index       : u32,
	safety_bytes               : u32,
}

OffscreenBufferColor :: struct{
	b, g, r, pad: u8
}

// TODO Copypasta END

Sample :: [2]i16
	
GameSoundBuffer :: struct {
	samples            : []Sample,
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

GameInputController :: struct {
	is_connected: b32,
	is_analog: b32,

	stick_average: [2]f32,
	
	using _buttons_array_and_enum : struct #raw_union {
		buttons: [18]GameInputButton,
		using _buttons_enum : struct {
			stick_up    : GameInputButton,
			stick_down  : GameInputButton,
			stick_left  : GameInputButton,
			stick_right : GameInputButton,
			
			button_up    : GameInputButton,
			button_down  : GameInputButton,
			button_left  : GameInputButton,
			button_right : GameInputButton,

			dpad_up    : GameInputButton,
			dpad_down  : GameInputButton,
			dpad_left  : GameInputButton,
			dpad_right : GameInputButton,

			start : GameInputButton,
			back  : GameInputButton,

			shoulder_left  : GameInputButton,
			shoulder_right : GameInputButton,

			thumb_left  : GameInputButton,
			thumb_right : GameInputButton,
		},
	},
}
#assert(size_of(GameInputController{}._buttons_array_and_enum.buttons) == size_of(GameInputController{}._buttons_array_and_enum._buttons_enum))

// TODO COPYPASTA from debug
DEBUG_code :: struct {
	read_entire_file  : proc_DEBUG_read_entire_file,
	write_entire_file : proc_DEBUG_write_entire_file,
	free_file_memory  : proc_DEBUG_free_file_memory,
}

proc_DEBUG_read_entire_file  :: #type proc(filename: string) -> (result: []u8)
proc_DEBUG_write_entire_file :: #type proc(filename: string, memory: []u8) -> b32
proc_DEBUG_free_file_memory  :: #type proc(memory: []u8)

// TODO allow outputing vibration
GameInput :: struct {
	// TODO insert clock values here
	controllers: [5]GameInputController
}

GameMemory :: struct {
	is_initialized: b32,
	// Note: REQUIRED to be cleared to zero at startup
	permanent_storage: []u8, 
	transient_storage: []u8,

	debug: DEBUG_code
}

GameState :: struct {
	green_offset, blue_offset: i32,
	tone_hz:u32,
	t_sine: f32,
}

// timing
@export
game_update_and_render :: proc(memory: ^GameMemory, offscreen_buffer: GameOffscreenBuffer, input: GameInput){
	assert(size_of(GameState) <= len(memory.permanent_storage), "The GameState cannot fit inside the permanent memory")
	
	game_state := cast(^GameState) raw_data(memory.permanent_storage)

	if !memory.is_initialized {
		game_state.tone_hz = 420

		file := memory.debug.read_entire_file(#file)
		if file != nil {
			memory.debug.write_entire_file("D:/projekte/handmade/data/testfile.test", file)
			memory.debug.free_file_memory(file)
		}
		// TODO this may be more appropriate to do in the platform layer
		memory.is_initialized = true
	}

	// tone_hz = 440 + u32(440 * f32(left_stick_y) / 60000)

	for controller in input.controllers {
		if controller.is_analog {
			// NOTE use analog movement tuning
			game_state.green_offset += cast(i32) (4 * controller.stick_average.x)
			game_state.tone_hz = 420 + cast(u32)(210 * controller.stick_average.y)
		} else {
			// NOTE Use digital movement tuning
			if controller.stick_left.ended_down {
				game_state.green_offset -= 1
			}
			if controller.stick_right.ended_down {
				game_state.green_offset += 1
			}
		}

		if controller.button_down.ended_down {
			game_state.blue_offset += 1
		}
	}

	
	render_weird_gradient(offscreen_buffer, game_state.green_offset, game_state.blue_offset)
}

// NOTE: at the moment this has to be a really fast function. It shall not be slower than a 
// millisecond or so.
// TODO: reduce the pressure on the performance of this function by measuring
@export
game_output_sound_samples :: proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer){
	// TODO: Allow sample offsets here for more robust platform options
	game_state := cast(^GameState) raw_data(memory.permanent_storage)
	output_sound(sound_buffer, game_state)
}


output_sound :: proc(sound_buffer: GameSoundBuffer, game_state:^GameState){
	tone_volumne :: 1000
	wave_period := sound_buffer.samples_per_second / game_state.tone_hz

	for sample_out_index in 0..<len(sound_buffer.samples){
		sample_value := cast(i16) (math.sin(game_state.t_sine) * tone_volumne)

		sound_buffer.samples[sample_out_index] = {sample_value, sample_value}
		game_state.t_sine += math.TAU / f32(wave_period)
		if game_state.t_sine > math.TAU do game_state.t_sine -= math.TAU
	}
}

render_weird_gradient :: proc(buffer: GameOffscreenBuffer , greenOffset, blueOffset: i32) {
	for y in 0..<buffer.height {
		for x in 0..<buffer.width {
			pixel := &buffer.memory[y*buffer.width + x]
			pixel^ = { b = u8(y + blueOffset), g = u8(x + greenOffset) }
		}
	}
}