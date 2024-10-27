package game

import "core:fmt"
import "base:intrinsics"

// TODO Copypasta from platform
// TODO Offscreenbuffer color and y-axis being down should not leak into the game layer
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

    stick_average: v2,

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


Arena :: struct {
    storage: []u8,
    used: u64 // TODO if I use a slice a can never get more than 4 Gb of memory
}

init_arena :: proc(arena: ^Arena, storage: []u8) {
    arena.storage = storage
}

push_slice :: proc(arena: ^Arena, $T: typeid, len: u64) -> []T {
    data := cast([^]T) push_size(arena, cast(u64) size_of(T) * len)
    return data[:len]
}

push_struct :: proc(arena: ^Arena, $T: typeid) -> ^T {
    return cast(^T) push_size(arena, cast(u64)size_of(T))
}
push_size :: proc(arena: ^Arena, size: u64) -> ^u8 {
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
        DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/structuredArt.bmp")
        state.backdrop  = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/forest_small.bmp")
        state.player[1] = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/SoldierRight.bmp")
        state.player[0] = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/SoldierLeft.bmp")
		state.player_index = 1
		
        state.player_pos = {
            chunk_x = 0,
            chunk_y = 0,
            tile_x = 5,
            tile_y = 5,
            offset = 0,
        }
		state.camera_position = {
            chunk_x = 0,
            chunk_y = 0,
            tile_x = 8,
            tile_y = 3,
            offset = 0.5,
        }

        init_arena(&state.world_arena, memory.permanent_storage[size_of(GameState):])

        state.world = World{
            tilemap = push_struct(&state.world_arena, Tilemap)
        }

        tilemap := state.world.tilemap

        tilemap.tile_size_in_meters = 1
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
            // TODO random number generator
            random_choice : u32
            if stair_down || stair_up {
                random_choice = random_number[random_number_index] % 2
            } else {
                random_choice = random_number[random_number_index] % 3
            }
            random_number_index += 1
            
            created_stair: b32
            if random_choice == 0 {
                door_right = true
            } else if random_choice == 1 {
                door_top = true
            } else {
                created_stair = true
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
                    if tile_x == 0                    && (!door_left  || tile_y != tiles_per_screen.y / 2) {
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
                    
                    if tile_y == 0                    && (!door_bottom || tile_x != tiles_per_screen.x / 2) {
                        value = 2
                    }
                    if tile_y == tiles_per_screen.y-1 && (!door_top    || tile_x != tiles_per_screen.x / 2) {
                        value = 2
                    }
                    set_tile_value(&state.world_arena, tilemap, abstile, value)
                }
            }
            
            door_left   = door_right
            door_bottom = door_top

            if created_stair {
				swap(&stair_up, &stair_down)
            } else {
                stair_up   = false
                stair_down = false
            }

            door_right  = false
            door_top    = false

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

    tilemap := state.world.tilemap	
    meters_to_pixels = f32(tile_size_in_pixels) / tilemap.tile_size_in_meters

    player_size: v2 = {0.75, 1} * tilemap.tile_size_in_meters
    for controller in input.controllers {
        if controller.is_analog {
            // NOTE use analog movement tuning
        } else {
            // NOTE Use digital movement tuning
            dd_player_pos : v2
            if controller.button_left.ended_down {
                dd_player_pos.x -= 1
				state.player_index = 0
            }
            if controller.button_right.ended_down {
                dd_player_pos.x += 1
				state.player_index = 1
            }
            if controller.button_up.ended_down {
                dd_player_pos.y += 1
            }
            if controller.button_down.ended_down {
                dd_player_pos.y -= 1
            }

			if dd_player_pos.x != 0 && dd_player_pos.y != 0 {
				dd_player_pos = normalize(dd_player_pos) 
			}

			player_speed_in_mpss: f32 : 10
            speed := player_speed_in_mpss
            if controller.shoulder_left.ended_down {
                speed *= 5
            }
			dd_player_pos *= speed

            new_player_pos := state.player_pos
            
			// TODO(viktor): ODE here
			dd_player_pos += -1.5 * state.d_player_pos

			new_player_pos.offset = 0.5*dd_player_pos * square(input.delta_time) + 
				state.d_player_pos * input.delta_time + 
				state.player_pos.offset
			state.d_player_pos = dd_player_pos * input.delta_time + state.d_player_pos

            new_player_pos = cannonicalize_position(tilemap, new_player_pos)

            player_left := new_player_pos
            player_left.offset.x -= 0.5*player_size.x
            player_left = cannonicalize_position(tilemap, player_left)

            player_right := new_player_pos
            player_right.offset.x += 0.5*player_size.x
            player_right = cannonicalize_position(tilemap, player_right)

            collided : b32
			collision_pos : TilemapPosition
			
			if !is_tilemap_position_empty(tilemap, player_left) {
				collided = true
				collision_pos = player_left
			}
			if !is_tilemap_position_empty(tilemap, player_right) {
				collided = true
				collision_pos = player_right
			}
			if !is_tilemap_position_empty(tilemap, new_player_pos) {
				collided = true
				collision_pos = new_player_pos
			}

            if collided {
				wall_normal: v2
				if collision_pos.tile_x < state.player_pos.tile_x {
					wall_normal = v2{ 1, 0}
				} else if collision_pos.tile_x > state.player_pos.tile_x {
					wall_normal = v2{-1, 0}
				} else if collision_pos.tile_y < state.player_pos.tile_y {
					wall_normal = v2{0, 1}
				} else if collision_pos.tile_y > state.player_pos.tile_y {
					wall_normal = v2{0,-1}

				}
				state.d_player_pos = dont_reflect_just_move_along_axis(state.d_player_pos, wall_normal)
			} else {
                if !are_on_same_tile(state.player_pos, new_player_pos) {
                    new_tile := get_tile_value_checked(tilemap, new_player_pos)
                    if new_tile == 4 {
                        new_player_pos.chunk_tile.z += 1
                    } else if new_tile == 5 {
                        new_player_pos.chunk_tile.z -= 1
                    }
                }
                state.player_pos = new_player_pos
				state.camera_position = state.player_pos
            }
        }
    }

    
    // ---------------------- ---------------------- ----------------------
    // ---------------------- Render
    // ---------------------- ---------------------- ----------------------

    // NOTE: Clear the screen
    draw_rectangle(buffer, {0,0}, vec_cast(f32, buffer.width, buffer.height), {1, 0.09, 0.24})

    draw_bitmap(buffer, state.backdrop, 0)


    Gray   :: GameColor{0.5,0.5,0.5}
    White  :: GameColor{1,1,1}
    Black  :: GameColor{0,0,0}
    Blue   :: GameColor{0.08, 0.49, 0.72}
    Orange :: GameColor{1, 0.71, 0.2}
    Green  :: GameColor{0, 0.59, 0.28}


	tile_size := vec_cast(f32, tile_size_in_pixels, tile_size_in_pixels)
    screen_center := vec_cast(f32, buffer.width, buffer.height) * 0.5
    for row in i32(-10)..=10 {
        for col in i32(-20)..=20 {
            chunk_tile := vec_cast(u32, (vec_cast(i32, state.camera_position.chunk_tile) + {col, row, 0}))
            
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
                if position.chunk_tile == state.player_pos.chunk_tile {
                    // color = Black
                }

                position := screen_center + 
					vec_cast(f32, col,-row) * tile_size + 
					{-1, 1} * state.camera_position.offset * meters_to_pixels +
					{-0.5, 0.5} * tile_size
                
				draw_rectangle(buffer, position, tile_size, color)
            }
        }
    }

	

	chunk_tile_delta := vec_cast(f32, state.player_pos.chunk_tile.xy) - vec_cast(f32, state.camera_position.chunk_tile.xy)
	offset_delta     := state.player_pos.offset - state.camera_position.offset
	total_delta      := (chunk_tile_delta * tile_size + offset_delta * meters_to_pixels)
	
	player_bitmap := state.player[state.player_index]
	center := screen_center + total_delta * {1,-1}
	position := center - {cast(f32) player_bitmap.width * 0.5, 0}
	// TODO bitmap "center/focus" point
	// draw_rectangle(buffer, position, player_size * meters_to_pixels, Green) // player bounding box
    draw_bitmap(buffer, player_bitmap, position)
}

GameState :: struct {
    world_arena: Arena,
    camera_position : TilemapPosition,
    player_pos : TilemapPosition,
	d_player_pos : v2,
    world: World,

    backdrop: LoadedBitmap,
    player: [2]LoadedBitmap,
	player_index: i32
}

World :: struct {
    tilemap: ^Tilemap
}

LoadedBitmap :: struct {
    pixels : []Color,
    width, height: i32,
}

// NOTE: at the moment this has to be a really fast function. It shall not be slower than a
// millisecond or so.
// TODO: reduce the pressure on the performance of this function by measuring
@(export)
game_output_sound_samples :: proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer){
    // TODO: Allow sample offsets here for more robust platform options
}


draw_bitmap :: proc(buffer: GameOffscreenBuffer, bitmap: LoadedBitmap, position: v2) {
    rounded_position := round(position)
    
    left, right := rounded_position.x, rounded_position.x + bitmap.width
    top, bottom := rounded_position.y, rounded_position.y + bitmap.height

	src_left: i32
	src_top : i32
	if left < 0 {
		src_left = -left
		left = 0
	}
	if top < 0 {
		src_top = -top
		top = 0
	}
    bottom = min(bottom, buffer.height)
    right  = min(right,  buffer.width)

    src_row  := bitmap.width * (bitmap.height-1)
	src_row  += -bitmap.width * src_top + src_left
    dest_row := left + top * buffer.width
    for y in top..< bottom  {
        src_index, dest_index := src_row, dest_row
        for x in left..< right  {
			src := vec_cast(f32, bitmap.pixels[src_index])
			dst := &buffer.memory[dest_index]
			a := src.a / 255

			dst.r = cast(u8) lerp(cast(f32) dst.r, src.r, a)
			dst.g = cast(u8) lerp(cast(f32) dst.g, src.g, a)
			dst.b = cast(u8) lerp(cast(f32) dst.b, src.b, a)

            src_index  += 1
            dest_index += 1
        }
        // TODO advance by the pitch instead of assuming its the same as the width
        dest_row += buffer.width
        src_row  -= bitmap.width 
    }
}


draw_rectangle :: proc(buffer: GameOffscreenBuffer, position: v2, size: v2, color: GameColor){
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
    casted := vec_cast(u8, round(c * 255))
    return {r=casted.r, g=casted.g, b=casted.b}
}

Color :: [4]u8

DEBUG_load_bmp :: proc (read_entire_file: proc_DEBUG_read_entire_file, file_name: string) -> LoadedBitmap {
    contents := read_entire_file(file_name)

    BMPHeader :: struct #packed {
        file_type      : [2]u8,
        file_size      : u32,
        reserved_1     : u16,
        reserved_2     : u16,
        bitmap_offset  : u32,
        size           : u32,
        width          : i32,
        height         : i32,
        planes         : u16,
        bits_per_pixel : u16,

        compression      : u32,
        size_of_bitmap   : u32,
        horz_resolution  : i32,
        vert_resolution  : i32,
        colors_used      : u32,
        colors_important : u32,

        red_mask   : u32,
        green_mask : u32,
        blue_mask  : u32,
    }

    // NOTE If you are using this generically for some reason,
    // please remember that BMP files CAN GO IN EITHER DIRECTION and
    // the height will be negative for top-down.
    // (Also, there can be compression, etc., etc ... DON'T think this 
    // a complete implementation)
	// NOTE pixels listed bottom up
    if len(contents) > 0 {
        header := cast(^BMPHeader) &contents[0]

		assert(header.bits_per_pixel == 32)
		assert(header.compression == 3)

		red_mask   := header.red_mask
		green_mask := header.green_mask
		blue_mask  := header.blue_mask
		alpha_mask := ~(red_mask | green_mask | blue_mask)

		red_shift   := intrinsics.count_leading_zeros(red_mask)
        green_shift := intrinsics.count_leading_zeros(green_mask)
        blue_shift  := intrinsics.count_leading_zeros(blue_mask)
        alpha_shift := intrinsics.count_leading_zeros(alpha_mask)
		assert(red_shift   != 32)
		assert(green_shift != 32)
		assert(blue_shift  != 32)
		assert(alpha_shift != 32)

        raw_pixels := ( cast([^]u32) &contents[header.bitmap_offset] )[:header.width * header.height]
        for y in 0..<header.height {
            for x in 0..<header.width {
                raw_pixel := &raw_pixels[y * header.width + x]
				// pixel_be := (cast(u32be) raw_pixel^)
				// start4b := (cast(^[4]u8) raw_pixel)^

				a := (raw_pixel^ >> alpha_shift) & 0xFF
				r := (raw_pixel^ >> red_shift  ) & 0xFF
				g := (raw_pixel^ >> green_shift) & 0xFF
				b := (raw_pixel^ >> blue_shift ) & 0xFF

				// TODO what?
				raw_pixel^ = (b << 24) | (a << 16) | (r << 8) | g
				// middlele := cast(^u32le) raw_pixel
				// middlebe := cast(^u32be) raw_pixel
				// middle4b := cast(^[4]u8) raw_pixel
				// middle4s := cast(^struct {r,g,b,a: u8}) raw_pixel
				
				// pixel := cast(^[4]u8) raw_pixel
				// k := 123
            }
        }

		pixels := ( cast([^]Color) &contents[header.bitmap_offset] )[:header.width * header.height]
        return {pixels, header.width, header.height}
    }
    return {}
}