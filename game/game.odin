package game

import "base:intrinsics"

import "core:fmt"
import "core:math"  // TODO implement sine ourself

// TODO Copypasta from platform

OffscreenBufferColor :: struct{
	b, g, r, pad: u8
}

// TODO COPYPASTA from debug

DEBUG_code :: struct {
	read_entire_file  : proc_DEBUG_read_entire_file,
	write_entire_file : proc_DEBUG_write_entire_file,
	free_file_memory  : proc_DEBUG_free_file_memory,
}

proc_DEBUG_read_entire_file  :: #type proc(filename: string) -> (result: []u8)
proc_DEBUG_write_entire_file :: #type proc(filename: string, memory: []u8) -> b32
proc_DEBUG_free_file_memory  :: #type proc(memory: []u8)

// TODO Copypasta END

// TODO allow outputing vibration
Sample :: [2]i16
	
GameSoundBuffer :: struct {
	samples            : []Sample,
	samples_per_second : u32,
}

GameOffscreenBuffer :: struct {
	memory : []OffscreenBufferColor,
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
			stick_up , stick_down , stick_left , stick_right ,
			button_up, button_down, button_left, button_right,
 			dpad_up  , dpad_down  , dpad_left  , dpad_right  ,

			start, back,
			shoulder_left, shoulder_right,
			thumb_left   , thumb_right : GameInputButton,
		},
	},
}
#assert(size_of(GameInputController{}._buttons_array_and_enum.buttons) == size_of(GameInputController{}._buttons_array_and_enum._buttons_enum))

GameInput :: struct {
	seconds_to_advance_over_update: f32,

	using _mouse_buttons_array_and_enum : struct #raw_union {
		mouse_buttons: [5]GameInputButton,
		using _buttons_enum : struct {
			mouse_left,	mouse_right, mouse_middle, 
			mouse_extra1, mouse_extra2 : GameInputButton,
		},
	},
	mouse_position: [2]i32,
	mouse_wheel: i32,

	controllers: [5]GameInputController
}
#assert(size_of(GameInput{}._mouse_buttons_array_and_enum.mouse_buttons) == size_of(GameInput{}._mouse_buttons_array_and_enum._buttons_enum))


GameMemory :: struct {
	is_initialized: b32,
	// Note: REQUIRED to be cleared to zero at startup
	permanent_storage: []u8, 
	transient_storage: []u8,

	debug: DEBUG_code
}

GameState :: struct {
}

// timing
@(export)
game_update_and_render :: proc(memory: ^GameMemory, offscreen_buffer: GameOffscreenBuffer, input: GameInput){
	assert(size_of(GameState) <= len(memory.permanent_storage), "The GameState cannot fit inside the permanent memory")
	
	state := cast(^GameState) raw_data(memory.permanent_storage)

	if !memory.is_initialized {
		memory.is_initialized = true
	}

	for controller in input.controllers {
		if controller.is_analog {
			// NOTE use analog movement tuning
		} else {
			// NOTE Use digital movement tuning
		}
	}
	draw_rectangle(offscreen_buffer, cast_vec(f32, input.mouse_position), [2]f32{20, 100}, OffscreenBufferColor{b=125, r=240, g=200})
}

// NOTE: at the moment this has to be a really fast function. It shall not be slower than a 
// millisecond or so.
// TODO: reduce the pressure on the performance of this function by measuring
@(export)
game_output_sound_samples :: proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer){
	// TODO: Allow sample offsets here for more robust platform options
	game_state := cast(^GameState) raw_data(memory.permanent_storage)
}

draw_rectangle :: proc(buffer: GameOffscreenBuffer, position: [2]f32, size: [2]f32, color: OffscreenBufferColor){
	rounded_position := round(position)
	rounded_size := round(size)
	left, right := rounded_position.x, rounded_position.x + rounded_size.x
	top, bottom := rounded_position.y, rounded_position.y + rounded_size.y
	
	if left < 0 do left = 0
	if top  < 0 do top  = 0
	if right  > buffer.width  do right  = buffer.width
	if bottom > buffer.height do bottom = buffer.height

	for y in top..<bottom {
		for x in left..<right {
			pixel := &buffer.memory[y*buffer.width + x]
			pixel^ = color
		}
	}
}

@(optimization_mode="favor_size")
cast_vec :: #force_inline proc($T: typeid, value: [$N]$E) -> [N]T 
	where N > 1 && intrinsics.type_is_numeric(E) && intrinsics.type_is_numeric(T) 
	{
	result : [N]T = ---
	for e, i in value do result[i] = cast(T) value[i]
	return result
}

round :: proc {
	round_f32,
	round_2f32,
}

round_f32 :: proc(f: f32) -> (i:i32) {
	return cast(i32) (f + 0.5)
}

round_2f32 :: proc(fs: [2]f32) -> (is:[2]i32) {
	return cast_vec(i32, fs + 0.5)
}
