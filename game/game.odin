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

GameState :: struct {
	player : [2]f32,
}

// timing
@(export)
game_update_and_render :: proc(memory: ^GameMemory, offscreen_buffer: GameOffscreenBuffer, input: GameInput){
	assert(size_of(GameState) <= len(memory.permanent_storage), "The GameState cannot fit inside the permanent memory")

	state := cast(^GameState) raw_data(memory.permanent_storage)

	if !memory.is_initialized {
		state.player = {100,  100}
		memory.is_initialized = true
	}
	
	// NOTE: Clear the screen
	draw_rectangle(offscreen_buffer, {0,0}, cast_vec(f32, [2]i32{offscreen_buffer.width, offscreen_buffer.height}), {1,0,1})

	tiles_top := Tilemap{
		{1, 1, 1, 1,   1, 1, 1, 1,  1,  1, 1, 1, 1,   1, 1, 1, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 0},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 1, 1, 1,   1, 1, 1, 1,  0,  1, 1, 1, 1,   1, 1, 1, 1},
	}
	tiles_top2 := Tilemap{
		{1, 1, 1, 1,   1, 1, 1, 1,  1,  1, 1, 1, 1,   1, 1, 1, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{0, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 1, 1, 1,   1, 1, 1, 1,  0,  1, 1, 1, 1,   1, 1, 1, 1},
	}
	tiles_bottom := Tilemap{
		{1, 1, 1, 1,   1, 1, 1, 1,  0,  1, 1, 1, 1,   1, 1, 1, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 0},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 1, 1, 1,   1, 1, 1, 1,  1,  1, 1, 1, 1,   1, 1, 1, 1},
	}
	tiles_bottom2 := Tilemap{
		{1, 1, 1, 1,   1, 1, 1, 1,  0,  1, 1, 1, 1,   1, 1, 1, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{0, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 1, 1, 1,   1, 1, 1, 1,  1,  1, 1, 1, 1,   1, 1, 1, 1},
	}

	world := World{
		tile_offset = {-30, 0},
		tile_size = 60,
		tiles = {
			{tiles_top, tiles_top2},
			{tiles_bottom, tiles_bottom2},
		}
	}
	player_size: [2]f32 : {30, 45}
	player_bounds: [2]f32 : {30, 15}

	for controller, index in input.controllers {
		if controller.is_analog {
			// NOTE use analog movement tuning
		} else {
			// NOTE Use digital movement tuning
			// TODO only handle the keyboard for now
			if index != 0 do continue

			speed: f32 : 400
			direction : [2]f32
			if controller.button_left.ended_down {
				direction.x -= 1
			}
			if controller.button_right.ended_down {
				direction.x += 1
			}
			if controller.button_up.ended_down {
				direction.y -= 1
			}
			if controller.button_down.ended_down {
				direction.y += 1
			}

			direction = normalize(direction)
			new_position := state.player + direction * speed * input.delta_time

			move_is_valid: b32 = false

			half_size := player_size - player_bounds * 0.5
				
			player_draw_position := (new_position + player_size * {-0.5, -1})
			foo := player_draw_position+{0,player_size.y}-{0, player_bounds.y}
			move_is_valid  = is_world_point_empty(world, new_position) &&
				is_world_point_empty(world, foo) &&
				is_world_point_empty(world, foo + player_bounds)

			if move_is_valid {
				state.player = new_position
			}
		}
	}




	Gray :: GameColor{0.5,0.5,0.5}
	White :: GameColor{1,1,1}

	current_tile_index := point_to_tilemap_index(state.player, world.tile_size)
	current_tile := world.tiles[current_tile_index.y][current_tile_index.x]
	for row, ri in current_tile {
		for cell, ci in row {
			color : GameColor
			if cell == 1 {
				color = Gray
			} else {
				color = White
			}
			position := world.tile_offset + cast_vec(f32, [2]int{ci, ri}) * world.tile_size
			draw_rectangle(offscreen_buffer, position, world.tile_size, color)
		}
	}

	player_tile_position := point_to_tilemap_space(state.player, world.tile_size)
	player_draw_position := world.tile_offset + (player_tile_position + player_size * {-0.5, -1})
	draw_rectangle(offscreen_buffer, player_draw_position , player_size, {0, 0.59, 0.28})
	// draw_rectangle(offscreen_buffer, player_draw_position+{0,player_size.y}-{0, player_bounds.y} , player_bounds, {0, 0.28, 0.59})
	// draw_rectangle(offscreen_buffer, world.tile_offset + player_tile_position-2, 4, {0.89, 0, 0.98})
}





Tilemap :: [9][17]u32

World :: struct {
	tile_offset: [2]f32,
	tile_size:   [2]f32,

	tiles : [][]Tilemap,
}

point_to_tilemap_index :: proc(point, tile_size: [2]f32) -> [2]i32 {
	tilemap_size := tile_size*{len(Tilemap{}[0]), len(Tilemap{})}
	return truncate(point / tilemap_size)
}
 
point_to_tilemap_space :: proc(point, tile_size: [2]f32 ) -> [2]f32 {
	tilemap_size := tile_size*{len(Tilemap{}[0]), len(Tilemap{})}
	return mod(point, tilemap_size)
}

is_world_point_empty :: proc(world: World, point: [2]f32) -> b32 {
	empty : b32
	tile_index := point_to_tilemap_index(point, world.tile_size)
	if in_bounds(world.tiles, tile_index) {
		current_tile := world.tiles[tile_index.y][tile_index.x]
		point_in_tilemap := point_to_tilemap_space(point, world.tile_size)
		empty = is_tilemap_point_empty(&current_tile, point_in_tilemap, world.tile_size)
	}
	return empty
}

is_tilemap_point_empty :: proc(tilemap: ^Tilemap, point_in_tilemap, tile_size: [2]f32) -> b32 {
	empty : b32
	point_tile := truncate(point_in_tilemap / tile_size)
	if in_bounds(tilemap[:], point_tile) {
		tile := tilemap[point_tile.y][point_tile.x]
		empty = tile == 0
	}
	return empty
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