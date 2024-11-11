package game

import "core:fmt"
import "base:intrinsics"

// TODO: Copypasta from platform
// TODO: Offscreenbuffer color and y-axis being down should not leak into the game layer
OffscreenBufferColor :: struct{
    b, g, r, pad: u8
}

// TODO: COPYPASTA from debug

DEBUG_code :: struct {
    read_entire_file  : proc_DEBUG_read_entire_file,
    write_entire_file : proc_DEBUG_write_entire_file,
    free_file_memory  : proc_DEBUG_free_file_memory,
}

proc_DEBUG_read_entire_file  :: #type proc(filename: string) -> (result: []u8)
proc_DEBUG_write_entire_file :: #type proc(filename: string, memory: []u8) -> b32
proc_DEBUG_free_file_memory  :: #type proc(memory: []u8)

// TODO: Copypasta END

Sample :: [2]i16

// TODO: allow outputing vibration
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
    // NOTE: REQUIRED to be cleared to zero at startup
    permanent_storage: []u8,
    transient_storage: []u8,

    debug: DEBUG_code
}


Arena :: struct {
    storage: []u8,
    used: u64 // TODO: if I use a slice of u8, it can never get more than 4 Gb of memory
}

init_arena :: proc(arena: ^Arena, storage: []u8) {
    arena.storage = storage
}

push_slice :: proc(arena: ^Arena, $Element: typeid, len: u64) -> []Element {
    data := cast([^]Element) push_size(arena, cast(u64) size_of(Element) * len)
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

// timing
@(export)
game_update_and_render :: proc(memory: ^GameMemory, buffer: GameOffscreenBuffer, input: GameInput){
    assert(size_of(GameState) <= len(memory.permanent_storage), "The GameState cannot fit inside the permanent memory")

    state := cast(^GameState) raw_data(memory.permanent_storage)

    // ---------------------- ---------------------- ----------------------
    // ---------------------- Initialization
    // ---------------------- ---------------------- ----------------------
    if !memory.is_initialized {
		defer memory.is_initialized = true

        init_arena(&state.world_arena, memory.permanent_storage[size_of(GameState):])

        // DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/structuredArt.bmp")
        state.backdrop  = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/forest_small.bmp")
        state.player[1] = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/SoldierRight.bmp")
        state.player[0] = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/SoldierLeft.bmp")
		
        state.world = push_struct(&state.world_arena, World)

		nil_entity := add_low_entity(state, .Nil, nil)
		state.high_entity_count = 1

        world := state.world

        init_world(world, 1)

		state.tile_size_in_pixels = 60
		state.meters_to_pixels = f32(state.tile_size_in_pixels) / world.tile_size_in_meters

        door_left, door_right: b32
        door_top, door_bottom: b32
        stair_up, stair_down: b32

        tiles_per_screen := [2]i32{17, 9}

		screen_base: [3]i32
        screen_row, screen_col, tile_z := screen_base.x, screen_base.y, screen_base.z
        for room_count in u32(0) ..< 1 {
            // TODO: random number generator
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
                if tile_z == 1 {
                    stair_down = true
                } else {
                    stair_up = true
                }
            }

            for tile_y in 0..< tiles_per_screen.y {
                for tile_x in 0 ..< tiles_per_screen.x {
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
					
					if value == 2 do add_wall(state, 
						tile_x + screen_col * tiles_per_screen.x,
						tile_y + screen_row * tiles_per_screen.y,
						tile_z,
					)
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
                tile_z = tile_z == screen_base.z+1 ? screen_base.z : screen_base.z+1
            }
        }

		
		new_camera_p := chunk_position_from_tile_positon(
			world,
			screen_base.x * tiles_per_screen.x + tiles_per_screen.x/2,
			screen_base.y * tiles_per_screen.y + tiles_per_screen.y/2,
			screen_base.z,
		)
		set_camera(state, new_camera_p)
    }
    
    // ---------------------- ---------------------- ----------------------
    // ---------------------- Input
    // ---------------------- ---------------------- ----------------------
	
	world := state.world

    for controller, controller_index in input.controllers {
		low_index := state.player_index_for_controller[controller_index]
		if low_index == 0 {
			if controller.start.ended_down {
				entity_index := add_player(state)
				state.player_index_for_controller[controller_index] = entity_index
			}
		} else {
			controlling_entity := get_high_entity(state, low_index)

			ddp: v2
			if controller.is_analog {
				// NOTE(viktor): Use analog movement tuning
				ddp = controller.stick_average
			} else {
				// NOTE(viktor): Use digital movement tuning
				if controller.stick_left.ended_down {
					ddp.x -= 1
				}
				if controller.stick_right.ended_down {
					ddp.x += 1
				}
				if controller.stick_up.ended_down {
					ddp.y += 1
				}
				if controller.stick_down.ended_down {
					ddp.y -= 1
				}

				if controller.button_up.ended_down {
					controlling_entity.high.dp.z += 2
				}
			}

			move_player(state, controlling_entity, ddp, input.delta_time)
		}
    }
    
    // ---------------------- ---------------------- ----------------------
    // ---------------------- Update
    // ---------------------- ---------------------- ----------------------

	if entity := get_high_entity(state, state.camera_following_index); entity.high != nil {
		new_camera_p := state.camera_p
	when !true {
		new_camera_p.chunk.z = entity.low.p.chunk.z
		offset := entity.high.p

		if offset.x < -9 * world.tile_size_in_meters {
			new_camera_p.offset_.x -= 17
		}
		if offset.x > 9 * world.tile_size_in_meters {
			new_camera_p.offset_.x += 17
		}
		if offset.y < -5 * world.tile_size_in_meters {
			new_camera_p.offset_.y -= 9
		}
		if offset.y > 5 * world.tile_size_in_meters {
			new_camera_p.offset_.y += 9
		}
	} else {
		new_camera_p = entity.low.p
	}
		set_camera(state, new_camera_p)
	}
    
    // ---------------------- ---------------------- ----------------------
    // ---------------------- Render
    // ---------------------- ---------------------- ----------------------

    // NOTE: Clear the screen
    draw_rectangle(buffer, {0,0}, vec_cast(f32, buffer.width, buffer.height), {1, 0.09, 0.24})

    draw_bitmap(buffer, state.backdrop, 0)

    White  :: GameColor{1,1,1}
    Gray   :: GameColor{0.5,0.5,0.5}
    Black  :: GameColor{0,0,0}
    Blue   :: GameColor{0.08, 0.49, 0.72}
    Orange :: GameColor{1, 0.71, 0.2}
    Green  :: GameColor{0, 0.59, 0.28}


    screen_center := vec_cast(f32, buffer.width, buffer.height) * 0.5
	for entity_index in 1..<state.high_entity_count {
		high_entity := &state.high_entities_[entity_index]
		low_entity  := &state.low_entities[high_entity.low_index]

		position := screen_center + state.meters_to_pixels * (high_entity.p.xy * {1,-1} - 0.5 * low_entity.size )
		z :=  -state.meters_to_pixels * high_entity.p.z
		size := state.meters_to_pixels * low_entity.size

		switch low_entity.type {
		case .Nil:
		case .Hero:
			player_bitmap := state.player[high_entity.facing_index]

			dt := input.delta_time;
			ddz : f32 = -9.8;
			high_entity.p.z = 0.5 * ddz * square(dt) + high_entity.dp.z * dt + high_entity.p.z;
			high_entity.dp.z = ddz * dt + high_entity.dp.z;

			if(high_entity.p.z < 0) {
				high_entity.p.z = 0;
				high_entity.dp.z = 0;
			}

			c_alpha := 1 - 0.5 * high_entity.p.z;
			if(c_alpha < 0) {
				c_alpha = 0.0;
			}


			// TODO: bitmap "center/focus" point
			draw_rectangle(buffer, position, size, Black, c_alpha) // Shadow

			draw_rectangle(buffer, position + {0,z}, size, Green) // Bounds
			bitmap_position := position + v2{-0.5, -1} * ({cast(f32) player_bitmap.width, cast(f32) player_bitmap.height} - low_entity.size * state.meters_to_pixels)
			draw_bitmap(buffer, player_bitmap, bitmap_position + {0,z})
		case .Wall:
			draw_rectangle(buffer, position, size, White)
		}
	}
}

EntityType :: enum u32 {
	Nil, Hero, Wall
}

EntityIndex :: u32
LowIndex :: distinct EntityIndex

Entity :: struct {
	low_index: LowIndex,
	low: ^LowEntity,
	high: ^HighEntity,
}

LowEntity :: struct {
	type: EntityType,

	p: WorldPosition,
	size: v2,
		
	// NOTE(viktor): This is for "stairs"
	d_tile_z: i32,
	collides: b32,

	high_entity_index: EntityIndex,
}

LowEntityReference :: struct {
	chunk: ^Chunk,
	index_in_chunk: u32,
}

HighEntity :: struct {
	// NOTE(viktor): this already relative to the camera
	p, dp: v3, 

	facing_index: i32,

	low_index: LowIndex,
}

GameState :: struct {
    world_arena: Arena,
	// TODO(viktor): should we allow split-screen?
	camera_following_index: LowIndex,
    camera_p : WorldPosition,
	player_index_for_controller: [len(GameInput{}.controllers)]LowIndex,
	
	low_entity_count: LowIndex,
	low_entities: [100_000]LowEntity,

	high_entity_count: EntityIndex,
	high_entities_: [256]HighEntity,
    
	world: ^World,

    backdrop: LoadedBitmap,
    player: [2]LoadedBitmap,

	tile_size_in_pixels :u32,
	meters_to_pixels: f32,
}

LoadedBitmap :: struct {
    pixels : []Color,
    width, height: i32,
}

Color :: [4]u8

get_low_entity :: #force_inline proc(state: ^GameState, low_index: LowIndex) -> (entity: ^LowEntity) #no_bounds_check {
	assert(low_index > 0 && low_index <= state.low_entity_count)
	entity = &state.low_entities[low_index]
	
	return entity
}

get_high_entity :: #force_inline proc(state: ^GameState, low_index: LowIndex) -> (entity: Entity) #no_bounds_check {
	if low_index > 0 && low_index <= state.low_entity_count {
		entity.high = make_entity_high_frequency(state, low_index)
		entity.low_index = low_index
		entity.low = &state.low_entities[entity.low_index]
	}

	return entity
}

get_camera_space_p :: #force_inline proc(state: ^GameState, low: ^LowEntity) -> v3 {
	diff := world_difference(state.world, low.p, state.camera_p)
	return diff
}

make_entity_high_frequency :: proc { make_entity_high_frequency_set_p, make_entity_high_frequency_calc_p }

make_entity_high_frequency_set_p :: #force_inline proc(state: ^GameState, low: ^LowEntity, low_index: LowIndex, camera_space_p: v3) -> (high: ^HighEntity) {
	assert(low.high_entity_index == 0)
	
	if state.high_entity_count < len(state.high_entities_) {
		high_index := state.high_entity_count
		state.high_entity_count += 1

		high = &state.high_entities_[high_index]
		high^ = {}

		high.p = camera_space_p
		high.low_index = low_index
		low.high_entity_index = high_index
	} else {
		unreachable()
	}
	
	return high
}
make_entity_high_frequency_calc_p :: #force_inline proc(state: ^GameState, low_index: LowIndex) -> (high: ^HighEntity) {
	low_entity  := &state.low_entities[low_index]
	if low_entity.high_entity_index == 0 {
		camera_space_p := get_camera_space_p(state, low_entity)
		high = make_entity_high_frequency_set_p(state, low_entity, low_index, camera_space_p)
	} else {
		high = &state.high_entities_[low_entity.high_entity_index]
	}
	return high
}

make_entity_low_frequency :: #force_inline proc(state: ^GameState, low_index: LowIndex) {
	low  := &state.low_entities[low_index]
	high_index := low.high_entity_index
	if high_index != 0 {
		last_index := state.high_entity_count-1
		if high_index != last_index {
			last := &state.high_entities_[last_index]
			del  := &state.high_entities_[high_index]
			del^ = last^
			low_of_last := &state.low_entities[last.low_index]
			low_of_last.high_entity_index = high_index
		}
		state.high_entity_count -= 1
		low.high_entity_index = 0
	}
}

add_low_entity :: proc(state: ^GameState, type: EntityType, p: ^WorldPosition) -> LowIndex #no_bounds_check {
	low_index := state.low_entity_count
	state.low_entity_count += 1
	assert(state.low_entity_count < len(state.low_entities))
	
	state.low_entities[low_index]  = { type = type }

	if p != nil {
		state.low_entities[low_index].p =  p^
		change_entity_location(&state.world_arena, state.world, low_index, p^)
	}
	
	return low_index
}

add_wall :: proc(state: ^GameState, tile_x, tile_y, tile_z: i32) -> LowIndex {
	p := chunk_position_from_tile_positon(state.world, tile_x, tile_y, tile_z)

	index := add_low_entity(state, .Wall, &p)
	wall  := get_low_entity(state, index)

	wall.size = state.world.tile_size_in_meters
	wall.collides = true

	return index
}

add_player :: proc(state: ^GameState) -> LowIndex {
	index := add_low_entity(state, .Hero, &state.camera_p)
	player := get_low_entity(state, index)

	player.size = {0.6, 0.4}
	player.collides = true

	make_entity_high_frequency(state, index)

	if state.camera_following_index == 0 {
		state.camera_following_index = index
	}
	return index
}

validate_entity_pairs :: #force_inline proc(state: ^GameState) -> bool {
	valid := true
	for high_index in 1..<state.high_entity_count {
		high := &state.high_entities_[high_index]
		valid &= state.low_entities[high.low_index].high_entity_index == high_index
	}
	return valid
}

offset_and_check_frequency_by_area :: #force_inline proc(state: ^GameState, offset: v2, camera_bounds: Rectangle) {
	for entity_index: EntityIndex = 1; entity_index < state.high_entity_count; {
		high := &state.high_entities_[entity_index]

		high.p.xy += offset
		if !is_in_rectangle(camera_bounds, high.p.xy) {
			make_entity_low_frequency(state, high.low_index)
		} else {
			entity_index += 1
		}
	}
}
 
set_camera :: proc(state: ^GameState, new_camera_p: WorldPosition) {
	world := state.world

	assert(validate_entity_pairs(state))

	d_camera_p := world_difference(world, new_camera_p, state.camera_p)
	state.camera_p = map_into_worldspace(world, new_camera_p)
	
	// TODO(viktor): these numbers where picked at random
	tilespan := [2]i32{17, 9} * 1
	camera_bounds := rect_center_half_dim(0, state.world.tile_size_in_meters * vec_cast(f32, tilespan))

	entity_offset_for_frame := -d_camera_p.xy
	offset_and_check_frequency_by_area(state, entity_offset_for_frame, camera_bounds)

	assert(validate_entity_pairs(state))

	map_into_worldspace(world, new_camera_p, camera_bounds.min)

	min_chunk := state.camera_p.chunk.xy-tilespan/2 
	max_chunk := state.camera_p.chunk.xy+tilespan/2
	// TODO(viktor): this needs to be accelarated, but man, this CPU is crazy fast
	for chunk_y in min_chunk.y ..= max_chunk.y {
		for chunk_x in min_chunk.x ..= max_chunk.x {
			chunk := get_chunk(nil, world, chunk_x, chunk_y, new_camera_p.chunk.z)
			if chunk != nil {
				for block := &chunk.first_block; block != nil; block = block.next {
					for entity_index in 0..< block.entity_count {
						low_index := block.indices[entity_index]
						low := &state.low_entities[low_index]
						if low.high_entity_index == 0 {
							camera_space_p := get_camera_space_p(state, low)
							if is_in_rectangle(camera_bounds, camera_space_p.xy) {
								make_entity_high_frequency(state, low, low_index, camera_space_p)
							}
						}
					}
				}
			}
		}
	}
	assert(validate_entity_pairs(state))
}

move_player :: proc(state: ^GameState, player: Entity, ddp: v2, dt: f32) {
	ddp := ddp
	ddp_length_squared := length_squared(ddp)

	if ddp_length_squared > 1 {
		ddp *= 1 / square_root(ddp_length_squared)
	}

	player_speed_in_mpss: f32 : 50
	speed := player_speed_in_mpss
	ddp *= speed

	// TODO(viktor): ODE here
	ddp += -8 * player.high.dp.xy

	player_delta := 0.5*ddp * square(dt) + player.high.dp.xy * dt
	player.high.dp.xy = ddp * dt + player.high.dp.xy
	
	for iteration in 0..<4 {
		desired_p := player.high.p.xy + player_delta

		t_min: f32 = 1
		wall_normal: v2
		hit_high_entity_index: EntityIndex

		for test_high_entity_index in 1..<state.high_entity_count {
			if test_high_entity_index != player.low.high_entity_index {

				test_entity: Entity
				test_entity.high = &state.high_entities_[test_high_entity_index]
				test_entity.low_index = test_entity.high.low_index
				test_entity.low = &state.low_entities[test_entity.low_index]

				if test_entity.low.collides {
					diameter := player.low.size + test_entity.low.size
					min_corner := -0.5 * diameter
					max_corner :=  0.5 * diameter

					rel := player.high.p - test_entity.high.p
					
					test_wall :: proc(wall_x, player_delta_x, player_delta_y, rel_x, rel_y, min_y, max_y: f32, t_min: ^f32) -> (collided: b32) {
						EPSILON :: 0.01
						if player_delta_x != 0 {
							t_result := (wall_x - rel_x) / player_delta_x
							y := rel_y + t_result * player_delta_y
							if 0 <= t_result && t_result < t_min^ {
								if y >= min_y && y <= max_y {
									t_min^ = max(0, t_result-EPSILON)
									collided = true
								}
							}
						}
						return collided
					}

					if test_wall(min_corner.x, player_delta.x, player_delta.y, rel.x, rel.y, min_corner.y, max_corner.y, &t_min) {
						wall_normal = {-1,  0}
						hit_high_entity_index = test_high_entity_index
					}
					if test_wall(max_corner.x, player_delta.x, player_delta.y, rel.x, rel.y, min_corner.y, max_corner.y, &t_min) {
						wall_normal = { 1,  0}
						hit_high_entity_index = test_high_entity_index
					}
					if test_wall(min_corner.y, player_delta.y, player_delta.x, rel.y, rel.x, min_corner.x, max_corner.x, &t_min) {
						wall_normal = { 0, -1}
						hit_high_entity_index = test_high_entity_index
					}
					if test_wall(max_corner.y, player_delta.y, player_delta.x, rel.y, rel.x, min_corner.x, max_corner.x, &t_min) {
						wall_normal = { 0,  1}
						hit_high_entity_index = test_high_entity_index
					}
				}
			}
		}

		player.high.p.xy += t_min * player_delta

		if hit_high_entity_index != 0 {
			player.high.dp.xy = project(player.high.dp.xy, wall_normal)
			player_delta = desired_p - player.high.p.xy
			player_delta = project(player_delta, wall_normal)

			hit_high_entity := state.high_entities_[hit_high_entity_index]
			hit_low_entity := state.low_entities[hit_high_entity.low_index]
			player.low.p.chunk.z += hit_low_entity.d_tile_z
		} else {
			break
		}
	}

	if player.high.dp.x < 0  {
		player.high.facing_index = 0
	} else {
		player.high.facing_index = 1
	}
	
	new_p := map_into_worldspace(state.world, state.camera_p, player.high.p.xy)
	// TODO(viktor): bundle these together as the location update
	change_entity_location(&state.world_arena, state.world, player.low_index, new_p, &player.low.p)
	player.low.p = new_p
}



// NOTE: at the moment this has to be a really fast function. It shall not be slower than a
// millisecond or so.
// TODO: reduce the pressure on the performance of this function by measuring
@(export)
game_output_sound_samples :: proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer){
    // TODO: Allow sample offsets here for more robust platform options
}


draw_bitmap :: proc(buffer: GameOffscreenBuffer, bitmap: LoadedBitmap, position: v2, c_alpha: f32 = 1) {
    rounded_position := round(position)
    
    left   := rounded_position.x
    top	   := rounded_position.y
	right  := left + bitmap.width
	bottom := top + bitmap.height

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
			a *= c_alpha

			dst.r = cast(u8) lerp(cast(f32) dst.r, src.r, a)
			dst.g = cast(u8) lerp(cast(f32) dst.g, src.g, a)
			dst.b = cast(u8) lerp(cast(f32) dst.b, src.b, a)

            src_index  += 1
            dest_index += 1
        }
        // TODO: advance by the pitch instead of assuming its the same as the width
        dest_row += buffer.width
        src_row  -= bitmap.width 
    }
}


draw_rectangle :: proc(buffer: GameOffscreenBuffer, position: v2, size: v2, color: GameColor, c_alpha: f32 = 1){
    rounded_position := round(position)
    rounded_size     := round(size)

    left, right := rounded_position.x, rounded_position.x + rounded_size.x
    top, bottom := rounded_position.y, rounded_position.y + rounded_size.y

    if left < 0 do left = 0
    if top  < 0 do top  = 0
    if right  > buffer.width  do right  = buffer.width
    if bottom > buffer.height do bottom = buffer.height

    for y in top..<bottom {
        for x in left..<right {
            dst := &buffer.memory[y*buffer.width + x]
			src := color * 255
			a := c_alpha

			dst.r = cast(u8) lerp(cast(f32) dst.r, src.r, a)
			dst.g = cast(u8) lerp(cast(f32) dst.g, src.g, a)
			dst.b = cast(u8) lerp(cast(f32) dst.b, src.b, a)
        }
    }
}

game_color_to_buffer_color :: #force_inline proc(c: GameColor) -> OffscreenBufferColor {
    casted := vec_cast(u8, round(c * 255))
    return {r=casted.r, g=casted.g, b=casted.b}
}

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

    // NOTE: If you are using this generically for some reason,
    // please remember that BMP files CAN GO IN EITHER DIRECTION and
    // the height will be negative for top-down.
    // (Also, there can be compression, etc., etc ... DON'T think this 
    // a complete implementation)
	// NOTE: pixels listed bottom up
    if len(contents) > 0 {
        header := cast(^BMPHeader) &contents[0]

		assert(header.bits_per_pixel == 32)
		assert(header.compression == 3)

		red_mask   := header.red_mask
		green_mask := header.green_mask
		blue_mask  := header.blue_mask
		alpha_mask := ~(red_mask | green_mask | blue_mask)

		red_scan   := intrinsics.count_leading_zeros(red_mask)
        green_scan := intrinsics.count_leading_zeros(green_mask)
        blue_scan  := intrinsics.count_leading_zeros(blue_mask)
        alpha_scan := intrinsics.count_leading_zeros(alpha_mask)
		assert(red_scan   != 32)
		assert(green_scan != 32)
		assert(blue_scan  != 32)
		assert(alpha_scan != 32)

        raw_pixels := ( cast([^]u32) &contents[header.bitmap_offset] )[:header.width * header.height]
        for y in 0..<header.height {
            for x in 0..<header.width {
                raw_pixel := &raw_pixels[y * header.width + x]
				/* TODO: check what the shifts and "C" where actually 
				raw_pixel^ = (rotate_left(raw_pixel^ & red_mask, red_shift) |
				              rotate_left(raw_pixel^ & green_mask, green_shift) |
				              rotate_left(raw_pixel^ & blue_mask, blue_shift) |
				              rotate_left(raw_pixel^ & alpha_mask, alpha_shift))
				 */
				a := (raw_pixel^ >> alpha_scan) & 0xFF
				r := (raw_pixel^ >> red_scan  ) & 0xFF
				g := (raw_pixel^ >> green_scan) & 0xFF
				b := (raw_pixel^ >> blue_scan ) & 0xFF

				// // TODO: what?
				raw_pixel^ = (b << 24) | (a << 16) | (r << 8) | g
            }
        }

		pixels := ( cast([^]Color) &contents[header.bitmap_offset] )[:header.width * header.height]
        return {pixels, header.width, header.height}
    }
    return {}
}