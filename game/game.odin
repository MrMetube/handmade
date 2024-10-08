package game

import "base:intrinsics"

// TODO do these myself
import "core:fmt"

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

Sample :: [2]i16

// TODO allow outputing vibration
GameSoundBuffer :: struct {
	samples            : []Sample,
	samples_per_second : u32,
}

GameColor :: [3]f32

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
	delta_time: f32,

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

// timing
@(export)
game_update_and_render :: proc(memory: ^GameMemory, buffer: GameOffscreenBuffer, input: GameInput){
	assert(size_of(GameState) <= len(memory.permanent_storage), "The GameState cannot fit inside the permanent memory")

	state := cast(^GameState) raw_data(memory.permanent_storage)


	if !memory.is_initialized {
		state.player = {
			chunk_x = 0,
			chunk_y = 0,
			tile_x = 3,
			tile_y = 3,
			tile_position = 0.5,
		}

		memory.is_initialized = true
	}
	
	// NOTE: Clear the screen
	draw_rectangle(buffer, {0,0}, cast_vec(f32, [2]i32{buffer.width, buffer.height}), {1,0,1})
	chunk := cast(^Chunk) &memory.transient_storage[0] // TODO a chunk is too large for the stack
	chunk_00 := [?]u32{1, 1, 1, 1,   1, 1, 1, 1,  1,  1, 1, 1, 1,   1, 1, 1, 1,   1, 1, 1, 1,   1, 1, 1, 1,  1,  1, 1, 1, 1,   1, 1, 1, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_01 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_02 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_03 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 0,   0, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_04 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_05 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 0,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_06 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_07 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_08 := [?]u32{1, 1, 1, 1,   1, 1, 1, 1,  0,  1, 1, 1, 1,   1, 1, 1, 1,   1, 1, 1, 1,   1, 1, 0, 0,  0,  0, 0, 1, 1,   1, 1, 1, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_09 := [?]u32{1, 1, 1, 1,   1, 1, 1, 1,  0,  1, 1, 1, 1,   1, 1, 1, 1,   1, 1, 1, 1,   1, 1, 0, 0,  0,  0, 0, 1, 1,   1, 1, 1, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_10 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_11 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_12 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_13 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 0,   0, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_14 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_15 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_16 := [?]u32{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,   1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	chunk_17 := [?]u32{1, 1, 1, 1,   1, 1, 1, 1,  1,  1, 1, 1, 1,   1, 1, 1, 1,   1, 1, 1, 1,   1, 1, 1, 1,  1,  1, 1, 1, 1,   1, 1, 1, 1,    0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0}
	for i in 0..<len(chunk_00) do chunk[00][i] = chunk_00[i]
	for i in 0..<len(chunk_01) do chunk[01][i] = chunk_01[i]
	for i in 0..<len(chunk_02) do chunk[02][i] = chunk_02[i]
	for i in 0..<len(chunk_03) do chunk[03][i] = chunk_03[i]
	for i in 0..<len(chunk_04) do chunk[04][i] = chunk_04[i]
	for i in 0..<len(chunk_05) do chunk[05][i] = chunk_05[i]
	for i in 0..<len(chunk_06) do chunk[06][i] = chunk_06[i]
	for i in 0..<len(chunk_07) do chunk[07][i] = chunk_07[i]
	for i in 0..<len(chunk_08) do chunk[08][i] = chunk_08[i]
	for i in 0..<len(chunk_09) do chunk[09][i] = chunk_09[i]
	for i in 0..<len(chunk_10) do chunk[10][i] = chunk_10[i]
	for i in 0..<len(chunk_11) do chunk[11][i] = chunk_11[i]
	for i in 0..<len(chunk_12) do chunk[12][i] = chunk_12[i]
	for i in 0..<len(chunk_13) do chunk[13][i] = chunk_13[i]
	for i in 0..<len(chunk_14) do chunk[14][i] = chunk_14[i]
	for i in 0..<len(chunk_15) do chunk[15][i] = chunk_15[i]
	for i in 0..<len(chunk_16) do chunk[16][i] = chunk_16[i]
	for i in 0..<len(chunk_17) do chunk[17][i] = chunk_17[i]

	world := World{
		tile_size_in_meters = 1.4,
		tile_size_in_pixels = 60,

		chunks = {{chunk}}
	}
	world.meters_to_pixels = cast(f32) world.tile_size_in_pixels / world.tile_size_in_meters

	player_size: [2]f32 = {.75 * world.tile_size_in_meters, world.tile_size_in_meters}
	player_speed_in_mps: f32 : 6

	when false {
		// NOTE: this is here to test the bit layout of the chunk/tile bitfield
		man_chunk_x := state.player.chunk_tile.x >> WORLD_TILE_BITS
		man_chunk_y := state.player.chunk_tile.y >> WORLD_TILE_BITS
		man_tile_x  := state.player.chunk_tile.x & (1 << WORLD_TILE_BITS)-1
		man_tile_y  := state.player.chunk_tile.y & (1 << WORLD_TILE_BITS)-1
		chunk_tile  := state.player.chunk_tile
		assert(man_chunk_x == state.player.chunk_x)
		assert(man_chunk_y == state.player.chunk_y)
		assert(man_tile_x  == state.player.tile_x)
		assert(man_tile_y  == state.player.tile_y)
	}

	for controller, index in input.controllers {
		if controller.is_analog {
			// NOTE use analog movement tuning
		} else {
			// NOTE Use digital movement tuning
			direction : [2]f32
			if controller.button_left.ended_down {
				direction.x -= 1
			}
			if controller.button_right.ended_down {
				direction.x += 1
			}
			if controller.button_up.ended_down {
				direction.y += 1
			}
			if controller.button_down.ended_down {
				direction.y -= 1
			}
			direction = normalize(direction)

			new_position := state.player
			delta := direction * player_speed_in_mps * input.delta_time
			new_position.tile_position += direction * player_speed_in_mps * input.delta_time
			new_position = cannonicalize_position(world, new_position)

			player_left := new_position
			player_left.tile_position -= {0.5*player_size.x, 0}
			player_left = cannonicalize_position(world, player_left)

			player_right := new_position
			player_right.tile_position += {0.5*player_size.x, 0}
			player_right = cannonicalize_position(world, player_right)

			move_is_valid := is_world_position_empty(world, new_position) && is_world_position_empty(world, player_left) && is_world_position_empty(world, player_right)
			if move_is_valid {
				state.player = new_position
			}
		}
	}




	Gray  :: GameColor{0.5,0.5,0.5}
	White :: GameColor{1,1,1}
	Black :: GameColor{0,0,0}
	tile_offset := [2]f32{-30, cast(f32)buffer.height}


	center := [2]f32{cast(f32)buffer.width, cast(f32)buffer.height} * 0.5
	current_chunk := get_chunk(world, state.player)
	for row in -4..=4 {
		for col in -8..=8 {
			chunk := cast_vec(u32, (cast_vec(int, state.player.chunk_tile) + {col, row}))

			tile := get_chunk_tile(current_chunk, chunk.x, chunk.y)

			color := White
			if tile == 1 {
				color = Gray
			}
			if chunk == state.player.chunk_tile {
				color = Black
			}

			size := cast_vec(f32, [2]u32{world.tile_size_in_pixels, world.tile_size_in_pixels})
			// position := tile_offset + cast_vec(f32, state.player.chunk_tile * world.tile_size_in_pixels) + cast_vec(f32, chunk * world.tile_size_in_pixels) * {1, -1}  - {0, size.y}
			position : [2]f32
			position.x = center.x + cast(f32) (col * cast(int)world.tile_size_in_pixels)
			position.y = center.y - cast(f32) (row * cast(int)world.tile_size_in_pixels)
			draw_rectangle(buffer, position, size, color)
		}
	}

	player_chunk := [2]u32{state.player.chunk_x, state.player.chunk_y}
	player_tile  := [2]u32{state.player.tile_x, state.player.tile_y}
	// player_draw_position := tile_offset + (cast_vec(f32, player_tile * world.tile_size_in_pixels) + 
	// 	world.meters_to_pixels * state.player.tile_position) * {1, -1}  + world.meters_to_pixels * player_size * {-0.5, -1}
	player_draw_position := center + (state.player.tile_position * {1, -1} - player_size * {0.5, 1}) * world.meters_to_pixels
	draw_rectangle(buffer, player_draw_position, world.meters_to_pixels * player_size, {0, 0.59, 0.28})
}


GameState :: struct {
	player : WorldPosition,
}



World :: struct {
	tile_size_in_meters: f32,
	tile_size_in_pixels: u32,
	meters_to_pixels: f32,

	chunks : [][]^Chunk,
}

WORLD_TILE_BITS  :: 8
WORLD_CHUNK_BITS :: 32 - WORLD_TILE_BITS

CHUNK_SIZE :: 1 << WORLD_TILE_BITS
Chunk :: [CHUNK_SIZE][CHUNK_SIZE]u32
 

WorldPosition :: struct {
	using _ : struct #raw_union {
		chunk_tile: [2]u32,
		using _: bit_field u64 { // TODO is this worth it?
			tile_x:  u32 | WORLD_TILE_BITS,
			chunk_x: u32 | WORLD_CHUNK_BITS,
			tile_y:  u32 | WORLD_TILE_BITS,
			chunk_y: u32 | WORLD_CHUNK_BITS,
		}
	},
	
	tile_position: [2]f32,
}



cannonicalize_position :: #force_inline proc(world: World, point: WorldPosition) -> WorldPosition {
	result := point

	// NOTE: the world is assumed to be toroidal topology
	// if you leave on one end you end up the other end
	offset := floor(point.tile_position / world.tile_size_in_meters)
	result.chunk_tile    += cast_vec(u32, offset)
	result.tile_position -= cast_vec(f32, offset) * world.tile_size_in_meters

	assert(result.tile_position.x > 0 && result.tile_position.x <= world.tile_size_in_meters)
	assert(result.tile_position.y > 0 && result.tile_position.y <= world.tile_size_in_meters)

	return result
}

is_world_position_empty :: proc(world: World, point: WorldPosition) -> b32 {
	empty : b32
	current_chunk, ok := get_chunk(world, point)
	if ok {
		tile := get_chunk_tile(current_chunk, point.tile_x, point.tile_y)
		empty = tile == 0
	}
	return empty
}

get_chunk :: proc {
	get_chunk_pos,
	get_chunk_2,
}

get_chunk_pos :: proc(world: World, point: WorldPosition) -> (chunk: ^Chunk, ok: b32) #optional_ok {
	return get_chunk(world, point.chunk_x, point.chunk_y)
}
get_chunk_2 :: proc(world: World, chunk_x, chunk_y: u32) -> (chunk: ^Chunk, ok: b32) #optional_ok {
	if in_bounds(world.chunks, chunk_x, chunk_y) {
		return world.chunks[chunk_y][chunk_x], true
	}
	return
}

get_chunk_tile :: proc(chunk: ^Chunk, tile_x, tile_y: u32) -> (tile: u32) {
	if in_bounds(chunk[:], tile_x, tile_y) {
		tile = chunk[tile_y][tile_x]
	}
	return tile
}





// NOTE: at the moment this has to be a really fast function. It shall not be slower than a
// millisecond or so.
// TODO: reduce the pressure on the performance of this function by measuring
@(export)
game_output_sound_samples :: proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer){
	// TODO: Allow sample offsets here for more robust platform options
	game_state := cast(^GameState) raw_data(memory.permanent_storage)
}



draw_rectangle :: proc(buffer: GameOffscreenBuffer, position: [2]f32, size: [2]f32, color: GameColor){
	rounded_position := round(position)
	rounded_size     := round(size)
	offscreen_color  := game_color_to_buffer_color(color)

	left, right := rounded_position.x, rounded_position.x + rounded_size.x
	top, bottom := rounded_position.y, rounded_position.y + rounded_size.y

	if left < 0 do left = 0
	if top  < 0 do top  = 0
	if right  > buffer.width  do right  = buffer.width
	if bottom > buffer.height do bottom = buffer.height

	for y in top..<bottom {
		for x in left..<right {
			pixel := &buffer.memory[y*buffer.width + x]
			pixel^ = offscreen_color
		}
	}
}

game_color_to_buffer_color :: #force_inline proc(c: GameColor) -> OffscreenBufferColor {
	casted := cast_vec(u8, round(c * 255))
	return {r=casted.r, g=casted.g, b=casted.b}
}