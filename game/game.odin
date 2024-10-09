package game

import "base:intrinsics"

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


MemoryArena :: struct {
	storage: []u8,
	used: u64 // TODO if I use a slice a can never get more than 4 Gb of memory
}

init_arena :: proc(arena: ^MemoryArena, storage: []u8) {
	arena.storage = storage
}

push_slice :: proc(arena: ^MemoryArena, $T: typeid, len: u64) -> []T {
	data := cast([^]T) push_size(arena, cast(u64) size_of(T) * len)
	return data[:len]
}

push_struct :: proc(arena: ^MemoryArena, $T: typeid) -> ^T {
	return cast(^T) push_size(arena, cast(u64)size_of(T))
}
push_size :: proc(arena: ^MemoryArena, size: u64) -> ^u8 {
	assert(arena.used + size < cast(u64)len(arena.storage))
	result := &arena.storage[arena.used]
	arena.used += size
	return result
}


tile_size_in_pixels :u32: 60
meters_to_pixels: f32

// timing
@(export)
game_update_and_render :: proc(memory: ^GameMemory, buffer: GameOffscreenBuffer, input: GameInput){
	assert(size_of(GameState) <= len(memory.permanent_storage), "The GameState cannot fit inside the permanent memory")

	state := cast(^GameState) raw_data(memory.permanent_storage)

	// ---------------------- ---------------------- ----------------------
	// ---------------------- Initialize
	// ---------------------- ---------------------- ----------------------

	if !memory.is_initialized {
		state.player = {
			chunk_x = 0,
			chunk_y = 0,
			tile_x = 1,
			tile_y = 3,
			tile_position = 0.5,
		}

		init_arena(&state.world_arena, memory.permanent_storage[size_of(GameState):])

		state.world = World{
			tilemap = push_struct(&state.world_arena, Tilemap)
		}

		tilemap := state.world.tilemap

		tilemap.tile_size_in_meters = 1.4 // TODO maybe change this to 1m
		tilemap.chunks_size = {128, 128, 128}
		tilemap.chunks = push_slice(
			&state.world_arena, 
			^Chunk, 
			cast(u64)(tilemap.chunks_size.x * tilemap.chunks_size.y * tilemap.chunks_size.z)
		)
		

		door_left, door_right: b32
		door_top, door_bottom: b32
		stair_up, stair_down: b32

		tiles_per_screen := [2]u32{17, 9}
		screen_row, screen_col, screen_height : u32
		for screen_index in u32(0) ..< 100 {
			random_choice : u32
			if stair_down || stair_up {
				random_choice = random_number[random_number_index] % 2
			} else {
				random_choice = random_number[random_number_index] % 3
			}
			random_number_index += 1

			if random_choice == 0 {
				door_right = true
			} else if random_choice == 1 {
				door_top = true
			} else {
				if screen_height == 1 {
					stair_down = true
				} else {
					stair_up = true
				}
			}

			for tile_y in 0..< tiles_per_screen.y {
				for tile_x in 0 ..< tiles_per_screen.x {
					abstile := TilemapPosition{
						chunk_tile = {
							screen_col * tiles_per_screen.x + tile_x,
							screen_row * tiles_per_screen.y + tile_y,
							screen_height,
						}
					}
					
					value: u32 = 3
					if tile_x == 0 && (!door_left || tile_y != tiles_per_screen.y / 2) {
						value = 2 
					}
					if tile_x == tiles_per_screen.x-1 && (!door_right || tile_y != tiles_per_screen.y / 2) {
						value = 2 
					}

					if stair_up && tile_x == tiles_per_screen.x / 2 && tile_y == tiles_per_screen.y / 2 {
						value = 4
					}
					if stair_down && tile_x == tiles_per_screen.x / 2 && tile_y == tiles_per_screen.y / 2 {
						value = 5
					}
					
					if tile_y == 0 && (!door_bottom || tile_x != tiles_per_screen.x / 2) {
						value = 2
					}
					if tile_y == tiles_per_screen.y-1 && (!door_top || tile_x != tiles_per_screen.x / 2) {
						value = 2
					}
					set_tile_value(&state.world_arena, tilemap, abstile, value)
				}
			}
			
			door_left   = door_right
			door_bottom = door_top
			if stair_down {
				stair_up   = true
				stair_down = false
			} else if stair_up {
				stair_up   = false
				stair_down = true
			} else {
				stair_up   = false
				stair_down = false
			}

			door_right  = false
			door_top    = false
			stair_up    = false
			// TODO random number generator
			if random_choice == 0 {
				screen_col += 1
			} else if random_choice == 1 {
				screen_row += 1
			} else {
				screen_height = screen_height == 1 ? 0 : 1
			}
		}

		memory.is_initialized = true
	}
	
	// ---------------------- ---------------------- ----------------------
	// ---------------------- Update
	// ---------------------- ---------------------- ----------------------

	// NOTE: Clear the screen
	draw_rectangle(buffer, {0,0}, cast_vec(f32, [2]i32{buffer.width, buffer.height}), {1, 0.09, 0.24})

	tilemap := state.world.tilemap	
	meters_to_pixels = f32(tile_size_in_pixels) / tilemap.tile_size_in_meters

	player_size: [2]f32 = {.75, 1} * tilemap.tile_size_in_meters
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
				direction.y += 1
			}
			if controller.button_down.ended_down {
				direction.y -= 1
			}
			direction = normalize(direction)


			delta := direction * player_speed_in_mps * input.delta_time
			if controller.shoulder_left.ended_down {
				delta *= 8
			}
			new_position := state.player
			new_position.tile_position += delta
			new_position = cannonicalize_position(tilemap, new_position)

			player_left := new_position
			player_left.tile_position -= {0.5*player_size.x, 0}
			player_left = cannonicalize_position(tilemap, player_left)

			player_right := new_position
			player_right.tile_position += {0.5*player_size.x, 0}
			player_right = cannonicalize_position(tilemap, player_right)

			move_is_valid := is_tilemap_position_empty(tilemap, new_position) && is_tilemap_position_empty(tilemap, player_left) && is_tilemap_position_empty(tilemap, player_right)
			if move_is_valid {
				state.player = new_position
			}
		}
	}




	Gray   :: GameColor{0.5,0.5,0.5}
	White  :: GameColor{1,1,1}
	Black  :: GameColor{0,0,0}
	Blue   :: GameColor{0.08, 0.49, 0.72}
	Orange :: GameColor{1, 0.71, 0.2}
	tile_offset := [2]f32{-30, cast(f32)buffer.height}


	screen_center := [2]f32{cast(f32)buffer.width, cast(f32)buffer.height} * 0.5
	for row in i32(-10)..=10 {
		for col in i32(-20)..=20 {
			chunk_tile := cast_vec(u32, (cast_vec(i32, state.player.chunk_tile) + {col, row, 0}))
			
			position := TilemapPosition{chunk_tile = chunk_tile}
			tile := get_tile_value_checked(tilemap, position)

			if tile != 0 {
				color := White
				if tile == 4 {
					color = Blue
				}
				if tile == 5 {
					color = Orange
				}
				if tile == 2 {
					color = Gray
				}
				if position.chunk_tile == state.player.chunk_tile {
					color = Black
				}

				size := [2]f32{cast(f32) tile_size_in_pixels, cast(f32)tile_size_in_pixels}
				center : [2]f32
				center.x = screen_center.x  +  cast(f32) (col * cast(i32) tile_size_in_pixels)  -  (state.player.tile_position.x * meters_to_pixels)
				center.y = screen_center.y  -  cast(f32) (row * cast(i32) tile_size_in_pixels)  +  (state.player.tile_position.y * meters_to_pixels)
				
				position := center - {1, -1} * cast(f32) tile_size_in_pixels * 0.5
				draw_rectangle(buffer, position, size, color)
			}
		}
	}


	position := [2]f32{
		screen_center.x - player_size.x * 0.5 * meters_to_pixels,
		screen_center.y,
	}
	draw_rectangle(buffer, position, meters_to_pixels * player_size, {0, 0.59, 0.28})
}

GameState :: struct {
	world_arena: MemoryArena,
	player : TilemapPosition,
	world: World,
}

World :: struct {
	tilemap: ^Tilemap
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