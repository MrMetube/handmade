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
game_update_and_render :: proc(memory: ^GameMemory, offscreen_buffer: GameOffscreenBuffer, input: GameInput){
	assert(size_of(GameState) <= len(memory.permanent_storage), "The GameState cannot fit inside the permanent memory")

	state := cast(^GameState) raw_data(memory.permanent_storage)


	if !memory.is_initialized {
		state.player = {
			tilemap_index = {0,0},
			tile_index = {3,3},
			tile_position = {1, 1},
		}

		memory.is_initialized = true
	}
	
	// NOTE: Clear the screen
	draw_rectangle(offscreen_buffer, {0,0}, cast_vec(f32, [2]i32{offscreen_buffer.width, offscreen_buffer.height}), {1,0,1})

	tiles_top := Tilemap{
		{1, 1, 1, 1,   1, 1, 1, 1,  1,  1, 1, 1, 1,   1, 1, 1, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 0},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 0},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 1, 1, 1,   1, 1, 1, 1,  0,  1, 1, 1, 1,   1, 1, 1, 1},
	}
	tiles_top2 := Tilemap{
		{1, 1, 1, 1,   1, 1, 1, 1,  1,  1, 1, 1, 1,   1, 1, 1, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{0, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},

		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 0, 0, 0,   0, 0, 0, 0,  0,  0, 0, 0, 0,   0, 0, 0, 1},
		{1, 1, 1, 1,   1, 1, 0, 0,  0,  0, 0, 1, 1,   1, 1, 1, 1},
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
		{1, 1, 1, 1,   1, 1, 0, 0,  0,  0, 0, 1, 1,   1, 1, 1, 1},
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
		tile_size_in_meters = 1.4,
		tile_size_in_pixels = 60,
		tile_offset = {-30, 0},
		tilemap_size = {17, 9},
		tiles = {
			{tiles_top, tiles_top2},
			{tiles_bottom, tiles_bottom2},
		}
	}
	world.meters_to_pixels = cast(f32) world.tile_size_in_pixels / world.tile_size_in_meters
	assert(world.tilemap_size.x == len(Tilemap{}[0]) && world.tilemap_size.y == len(Tilemap{}))

	player_size: [2]f32 = {.75 * world.tile_size_in_meters, world.tile_size_in_meters}
	player_speed_in_mps: f32 : 6

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
				direction.y -= 1
			}
			if controller.button_down.ended_down {
				direction.y += 1
			}
			direction = normalize(direction)

			new_position := state.player
			delta := direction * player_speed_in_mps * input.delta_time
			new_position.tile_position += direction * player_speed_in_mps * input.delta_time
			new_position = get_cannonical_position(world, new_position)
			
			player_left := new_position
			player_left.tile_position -= {0.5*player_size.x, 0}
			player_left = get_cannonical_position(world, player_left)

			player_right := new_position
			player_right.tile_position += {0.5*player_size.x, 0}
			player_right = get_cannonical_position(world, player_right)

			move_is_valid := is_world_point_empty(world, new_position) && is_world_point_empty(world, player_left) && is_world_point_empty(world, player_right)
			if move_is_valid {
				state.player = new_position
			}
		}
	}




	Gray  :: GameColor{0.5,0.5,0.5}
	White :: GameColor{1,1,1}
	Black :: GameColor{0,0,0}

	current_tile := get_tilemap(world, state.player.tilemap_index)
	for row, ri in current_tile {
		for cell, ci in row {
			tile_index := [2]i32{cast(i32)ci, cast(i32)ri}
			color : GameColor
			if state.player.tile_index == tile_index {
				color = Black
			} else if cell == 1 {
				color = Gray
			} else {
				color = White
			}
			position := world.tile_offset + cast_vec(f32, tile_index * world.tile_size_in_pixels) 
			size := cast_vec(f32, [2]i32{world.tile_size_in_pixels, world.tile_size_in_pixels})
			draw_rectangle(offscreen_buffer, position, size, color)
		}
	}

	player_draw_position := world.tile_offset + cast_vec(f32, state.player.tile_index * world.tile_size_in_pixels) + 
		world.meters_to_pixels * state.player.tile_position + world.meters_to_pixels * player_size * {-0.5, -1}
	draw_rectangle(offscreen_buffer, player_draw_position, world.meters_to_pixels * player_size, {0, 0.59, 0.28})
}


GameState :: struct {
	player : CanonicalPosition,
}




Tilemap :: [9][17]u32
 
World :: struct {
	tile_size_in_meters: f32,
	tile_size_in_pixels: i32,
	meters_to_pixels: f32,

	tilemap_size: [2]i32,

	tile_offset: [2]f32,
	tiles : [][]Tilemap,
}

CanonicalPosition :: struct {
	tilemap_index:    [2]i32,
	tile_index:    [2]i32,
	tile_position: [2]f32,
}



get_tilemap :: proc(world: World, tile_index: [2]i32) -> (tilemap: Tilemap, ok: b32) #optional_ok {
	if in_bounds(world.tiles, tile_index) {
		return world.tiles[tile_index.y][tile_index.x], true
	}
	return
}

get_cannonical_position :: #force_inline proc(world: World, point: CanonicalPosition) -> CanonicalPosition {
	result := point

	offset := floor(point.tile_position / world.tile_size_in_meters)

	result.tile_index    += offset
	result.tile_position -= cast_vec(f32, offset) * world.tile_size_in_meters

	assert(result.tile_position.x > 0 && result.tile_position.x < world.tile_size_in_meters)
	assert(result.tile_position.y > 0 && result.tile_position.y < world.tile_size_in_meters)

	if result.tile_index.x < 0 {
		result.tile_index.x = result.tile_index.x + world.tilemap_size.x
		result.tilemap_index.x -= 1
	}
	if result.tile_index.y < 0 {
		result.tile_index.y = result.tile_index.y + world.tilemap_size.y
		result.tilemap_index.y -= 1
	}
	if result.tile_index.x >= world.tilemap_size.x {
		result.tile_index.x = result.tile_index.x - world.tilemap_size.x
		result.tilemap_index.x += 1
	}
	if result.tile_index.y >= world.tilemap_size.y {
		result.tile_index.y = result.tile_index.y - world.tilemap_size.y
		result.tilemap_index.y += 1
	}

	return result
}

is_world_point_empty :: proc(world: World, point: CanonicalPosition) -> b32 {
	empty : b32
	current_tile, ok := get_tilemap(world, point.tilemap_index)
	if ok {
		empty = is_tilemap_point_empty(&current_tile, point)
	}
	return empty
}

is_tilemap_point_empty :: proc(tilemap: ^Tilemap, point: CanonicalPosition) -> b32 {
	empty : b32
	if in_bounds(tilemap[:], point.tile_index) {
		tile := tilemap[point.tile_index.y][point.tile_index.x]
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