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

GameColor :: [4]f32

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
        state.backdrop   = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/forest_small.bmp")
        state.shadow     = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/shadow.bmp")
        state.player[0]  = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/soldier_left.bmp")
        state.player[1]  = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/soldier_right.bmp")
        state.monster[0] = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/orc_left.bmp")
        state.monster[1] = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/orc_right.bmp")
        state.sword      = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/arrow.bmp")

        state.player[0].focus = {8, 0}
        state.player[1].focus = {-4, 0}

        state.monster[0].focus = {0, -1}
        state.monster[1].focus = {21, -1}
        
        state.shadow.focus = {0, 10}

        state.sword.focus = {16, 16}

        state.world = push_struct(&state.world_arena, World)

        add_low_entity(state, .Nil, nil)
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
        for room_count in u32(0) ..< 200 {
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

        monster_p := new_camera_p.chunk + {10,5,0}
        familiar_p := new_camera_p.chunk + {5,5,0}
        add_monster(state, monster_p.x, monster_p.y, monster_p.z)
        add_familiar(state, familiar_p.x, familiar_p.y, familiar_p.z)

        sim_camera_region(state, new_camera_p)
    }

    // ---------------------- ---------------------- ----------------------
    // ---------------------- Input
    // ---------------------- ---------------------- ----------------------

    world := state.world

    for controller, controller_index in input.controllers {
        storage_index := state.player_index_for_controller[controller_index]
        if storage_index == 0 {
            if controller.start.ended_down {
                entity_index, _ := add_player(state)
                state.player_index_for_controller[controller_index] = entity_index
            }
        } else {
            controlling_entity := force_entity_into_high(state, storage_index)

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
            }

            if controller.start.ended_down {
                controlling_entity.high.dp.z += 2
            }

            d_sword: v2
            if controller.button_up.ended_down {
                d_sword =  {0, 1}
            }
            if controller.button_down.ended_down {
                d_sword = -{0, 1}
            }
            if controller.button_left.ended_down {
                d_sword = -{1, 0}
            }
            if controller.button_right.ended_down {
                d_sword =  {1, 0}
            }
            if d_sword.x != 0 || d_sword.y != 0 {
                sword_low := get_low_entity(state, controlling_entity.low.sword_index)
                if sword_low != nil && !is_valid(sword_low.p) {
                    sword_p := controlling_entity.low.p
                    change_entity_location(&state.world_arena, state.world, controlling_entity.low.sword_index, sword_low, &sword_p)
                    
                    sword_low.distance_remaining = 5

                    sword := force_entity_into_high(state, controlling_entity.low.sword_index)
                    sword.high.dp.xy = 5 * d_sword
                }

            }

            move_spec := default_move_spec()
            move_spec.normalize_accelaration = true
            move_spec.drag = 8
            move_spec.speed = 50

            move_entity(state, controlling_entity, ddp, move_spec, input.delta_time)
        }
    }

    // ---------------------- ---------------------- ----------------------
    // ---------------------- Update
    // ---------------------- ---------------------- ----------------------
    
	// TODO(viktor): these numbers where picked at random
	tilespan := [2]i32{17, 9} * 1
	camera_bounds := rect_center_half_dim(0, state.world.tile_size_in_meters * vec_cast(f32, tilespan))

	camera_sim_region := begin_sim(state.transient_arena, world, state.camera_p, camera_bounds)

    // ---------------------- ---------------------- ----------------------
    // ---------------------- Render
    // ---------------------- ---------------------- ----------------------


    White  :: GameColor{1,1,1, 1}
    Gray   :: GameColor{0.5,0.5,0.5, 1}
    Black  :: GameColor{0,0,0, 1}
    Blue   :: GameColor{0.08, 0.49, 0.72, 1}
    Orange :: GameColor{1, 0.71, 0.2, 1}
    Green  :: GameColor{0, 0.59, 0.28, 1}
    Red    :: GameColor{1, 0.09, 0.24, 1}

    // NOTE: Clear the screen
    draw_rectangle(buffer, 0, vec_cast(f32, buffer.width, buffer.height), Red)

    screen_center := vec_cast(f32, buffer.width, buffer.height) * 0.5
    draw_bitmap(buffer, state.backdrop, screen_center)

    for &entity in camera_sim_region.entities {
		stored := state.stored_entities[entity.storage_index]

        dt := input.delta_time;

		z := entity.p.z
        size := state.meters_to_pixels * stored.size


        // TODO(viktor): this is incorrect, should be computed after update
        shadow_alpha := 1 - 0.5 * entity.p.z;
        if(shadow_alpha < 0) {
            shadow_alpha = 0.0;
        }

        piece_group := EntityVisiblePieceGroup { state = state }

        push_piece :: #force_inline proc(group: ^EntityVisiblePieceGroup, bitmap: ^LoadedBitmap, size, offset: v2, color: GameColor) {
            assert(group.count < len(group.pieces))
            piece := &group.pieces[group.count]
            group.count += 1

            piece.bitmap = bitmap
            piece.offset = {offset.x, -offset.y} * group.state.meters_to_pixels
            piece.size   = size * group.state.meters_to_pixels
            piece.color  = color
        }

        push_bitmap :: #force_inline proc(group: ^EntityVisiblePieceGroup, bitmap: ^LoadedBitmap, offset:v2, alpha: f32 = 1) {
            push_piece(group, bitmap, {}, offset, {1,1,1, alpha})
        }

        push_rectangle :: #force_inline proc(group: ^EntityVisiblePieceGroup, size, offset:v2, color: GameColor) {
            push_piece(group, nil, size, offset, color)
        }

        draw_hitpoints :: proc(group: ^EntityVisiblePieceGroup, stored: ^StoredEntity, offset_y: f32) {
            if stored.hit_point_max > 1 {
                health_size: v2 = 0.1
                spacing_between: f32 = health_size.x * 1.5
                health_x := -0.5 * (cast(f32) stored.hit_point_max - 1) * spacing_between + stored.size.x/2

                for index in 0..<stored.hit_point_max {
                    hit_point := stored.hit_points[index]
                    color := hit_point.filled_amount == 0 ? Gray : Red
                    push_rectangle(group, health_size, {health_x, -offset_y}, color)
                    health_x += spacing_between
                }
            }

        }

        switch stored.type {
        case .Nil: // NOTE(viktor): nothing
        case .Wall:
            position := screen_center + state.meters_to_pixels * (entity.p.xy * {1,-1} - 0.5 * stored.size )
            // TODO(viktor): wall asset
            draw_rectangle(buffer, position, size, White)

        case .Sword:
            update_sword(state, stored, entity, input.delta_time)

            push_bitmap(&piece_group, &state.shadow, 0, shadow_alpha)
            push_bitmap(&piece_group, &state.sword, 0)

        case .Hero:
            push_bitmap(&piece_group, &state.shadow, 0, shadow_alpha)
            push_bitmap(&piece_group, &state.player[stored.facing_index], v2{0,z})
            draw_hitpoints(&piece_group, &stored, 0.5)

        case .Familiar:
            stored.t_bob += dt
            if stored.t_bob > TAU {
                stored.t_bob -= TAU
            }
            hz :: 4
            coeff := sin(stored.t_bob * hz)
            z += (coeff) * 0.3 + 0.3
            // TODO(viktor): shadow is inverted

            update_familiar(state, stored, entity, dt)
            push_bitmap(&piece_group, &state.shadow, 0, 1 - shadow_alpha/2 * (coeff+1))
            push_bitmap(&piece_group, &state.player[stored.facing_index], v2{0,z}, 0.5)

        case .Monster:
            update_monster(state, stored, entity, dt)

            push_bitmap(&piece_group, &state.shadow, 0, shadow_alpha)
            push_bitmap(&piece_group, &state.monster[1], 0)

            draw_hitpoints(&piece_group, &stored, 0.8)
        }

        ddz : f32 = -9.8;
        entity.p.z = 0.5 * ddz * square(dt) + stored.dp.z * dt + entity.p.z;
        stored.dp.z = ddz * dt + stored.dp.z;

        if entity.p.z < 0 {
            entity.p.z = 0;
            stored.dp.z = 0;
        }

        // TODO(viktor): b4aff4a2ed416d607fef8cad47382e2d2e0eebfc between this commit and the next the rendering got offset by one pixel to the right
        for index in 0..<piece_group.count {
            center := screen_center + state.meters_to_pixels * (entity.p.xy * {1,-1} - 0.5 * stored.size)
            piece := piece_group.pieces[index]
            center += piece.offset
            if piece.bitmap != nil {
                center.x -= (cast(f32) piece.bitmap.width/2  - stored.size.x * state.meters_to_pixels)
                center.y -=(cast(f32) piece.bitmap.height/2 -  stored.size.y * state.meters_to_pixels)
                draw_bitmap(buffer, piece.bitmap^, center, piece.color.a)
            } else {
                draw_rectangle(buffer, center, piece.size, piece.color)
            }
        }
    }

	end_sim(camera_sim_region, state)
}

// TODO(viktor): This is dumb, this should just be part of
// the renderer pushbuffer - add correction of coordinates
// in there and be done with it.

EntityVisiblePieceGroup :: struct {
    state: ^GameState,
    count: u32,
    pieces: [8]EntityVisiblePiece,
}

EntityVisiblePiece :: struct {
    bitmap: ^LoadedBitmap,
    offset: v2,

    color: GameColor,
    size: v2,
}

HIT_POINT_PART_COUNT :: 4
HitPoint :: struct {
    flags: u8,
    filled_amount: u8,
}

EntityType :: enum u32 {
    Nil, Hero, Wall, Familiar, Monster, Sword
}

EntityIndex :: u32
StorageIndex :: distinct EntityIndex

StoredEntity :: struct {
    type: EntityType,

    p: WorldPosition,
	dp: v3,

    size: v2,

    // NOTE(viktor): This is for "stairs"
    d_tile_z: i32,
    collides: b32,

    hit_point_max: u32,
    hit_points: [16]HitPoint,

    sword_index: StorageIndex,
    distance_remaining: f32,

	facing_index: i32,
	t_bob:f32,
}

GameState :: struct {
    world_arena: Arena,
    // TODO(viktor): should we allow split-screen?
    camera_following_index: StorageIndex,
    camera_p : WorldPosition,
    player_index_for_controller: [len(GameInput{}.controllers)]StorageIndex,

    stored_entity_count: StorageIndex,
    stored_entities: [100_000]StoredEntity,

    world: ^World,

    backdrop: LoadedBitmap,
    shadow: LoadedBitmap,
    player: [2]LoadedBitmap,
    monster: [2]LoadedBitmap,
    sword: LoadedBitmap,

    tile_size_in_pixels :u32,
    meters_to_pixels: f32,
}

LoadedBitmap :: struct {
    pixels : []Color,
    width, height: i32,
    focus: [2]i32,
}

Color :: [4]u8

add_stored_entity :: proc(state: ^GameState, type: EntityType, p: ^WorldPosition) -> (index: StorageIndex, stored: ^StoredEntity) #no_bounds_check {
    index = state.stored_entity_count
    state.stored_entity_count += 1
    assert(state.stored_entity_count < len(state.stored_entities))
    stored = &state.stored_entities[index]
    stored^ = { type = type }

    change_entity_location(&state.world_arena, state.world, index, stored, p)

    return index, stored
}

init_hitpoints :: proc(entity: ^StoredEntity, count: u32) {
    assert(count < len(entity.hit_points))

    entity.hit_point_max = count
    for i in 0..<count {
        entity.hit_points[i] = { filled_amount = HIT_POINT_PART_COUNT }
    }
}

add_sword :: proc(state: ^GameState) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_stored_entity(state, .Sword, nil)

    entity.size = {0.5, 1}
    entity.collides = false

    return index, entity
}

add_monster :: proc(state: ^GameState, tile_x, tile_y, tile_z: i32) -> (index: StorageIndex, entity: ^StoredEntity) {
    p := chunk_position_from_tile_positon(state.world, tile_x, tile_y, tile_z)
    index, entity = add_stored_entity(state, .Monster, &p)

    entity.size = 0.75
    entity.collides = true

    init_hitpoints(entity, 3)

    return index, entity
}

add_familiar :: proc(state: ^GameState, tile_x, tile_y, tile_z: i32) -> (index: StorageIndex, entity: ^StoredEntity) {
    p := chunk_position_from_tile_positon(state.world, tile_x, tile_y, tile_z)
    index, entity = add_stored_entity(state, .Familiar, &p)

    entity.size = 0.5

    return index, entity
}

add_wall :: proc(state: ^GameState, tile_x, tile_y, tile_z: i32) -> (index: StorageIndex, entity: ^StoredEntity) {
    p := chunk_position_from_tile_positon(state.world, tile_x, tile_y, tile_z)
    index, entity = add_stored_entity(state, .Wall, &p)

    entity.size = state.world.tile_size_in_meters
    entity.collides = true

    return index, entity
}

add_player :: proc(state: ^GameState) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_stored_entity(state, .Hero, &state.camera_p)

    entity.size = {0.75, 0.4}
    entity.collides = true

    init_hitpoints(entity, 3)

    sword_index, sword := add_sword(state)
    entity.sword_index = sword_index

    make_entity_high_frequency(state, index)

    if state.camera_following_index == 0 {
        state.camera_following_index = index
    }

    return index, entity
}

sim_camera_region :: proc(state: ^GameState) {
    
}

entity_from_high_index :: #force_inline proc(state:^GameState, index: EntityIndex) -> (result: Entity) {
    if index != 0 {
        assert(index < state.high_entity_count)

        result.high = &state.high_entities_[index]
        result.storage_index = result.high.storage_index
        result.stored = &state.stored_entities[result.storage_index]
    }

    return result
}

update_monster :: #force_inline proc(state:^GameState, stored: StoredEntity, entity: SimEntity, dt:f32) {

}

update_sword :: #force_inline proc(state:^GameState, stored: StoredEntity, entity: SimEntity, dt:f32) {
    move_spec := default_move_spec()
    move_spec.normalize_accelaration = false
    move_spec.drag = 0
    move_spec.speed = 0

    old_p := entity.high.p
    move_entity(state, entity, 0, move_spec, dt)
    distance_traveled := length(entity.high.p - old_p)
    
    entity.stored.distance_remaining -= distance_traveled
    if entity.stored.distance_remaining < 0 {
        change_entity_location(&state.world_arena, state.world, entity.storage_index, entity.stored, nil, &entity.stored.p)
    }
}

update_familiar :: #force_inline proc(state:^GameState, stored: StoredEntity, entity: SimEntity, dt:f32) {
    closest_hero: Entity
    closest_hero_dsq := square(6) // NOTE(viktor): 10m maximum search
    for entity_index in 1..<state.high_entity_count {
        test := entity_from_high_index(state, entity_index)
        if test.stored.type == .Hero {
            dsq := length_squared(test.high.p.xy - entity.high.p.xy)
            if dsq < closest_hero_dsq {
                closest_hero_dsq = dsq
                closest_hero = test
            }
        }
    }

    ddp: v2
    if closest_hero.high != nil && closest_hero_dsq > 1 {
        mpss: f32 = 0.5
        ddp = mpss / square_root(closest_hero_dsq) * (closest_hero.high.p.xy - entity.high.p.xy)
    }

    move_spec := default_move_spec()
    move_spec.normalize_accelaration = true
    move_spec.drag = 8
    move_spec.speed = 50
    move_entity(state, entity, ddp, move_spec, dt)
}

MoveSpec :: struct {
    normalize_accelaration: b32,
    drag: f32,
    speed: f32,
}

default_move_spec :: #force_inline proc() -> MoveSpec {
    return { false, 1, 0}
}

move_entity :: proc(state: ^GameState, entity: Entity, ddp: v2, move_spec: MoveSpec, dt: f32) {
    ddp := ddp
    
    if move_spec.normalize_accelaration {
        ddp_length_squared := length_squared(ddp)

        if ddp_length_squared > 1 {
            ddp *= 1 / square_root(ddp_length_squared)
        }
    }

    ddp *= move_spec.speed

    // TODO(viktor): ODE here
    ddp += -move_spec.drag * entity.high.dp.xy

    entity_delta := 0.5*ddp * square(dt) + entity.high.dp.xy * dt
    entity.high.dp.xy = ddp * dt + entity.high.dp.xy

    for iteration in 0..<4 {
        desired_p := entity.high.p.xy + entity_delta

        t_min: f32 = 1
        wall_normal: v2
        hit_high_entity_index: EntityIndex
        
        if entity.stored.collides {
            for test_high_entity_index in 1..<state.high_entity_count {
                if test_high_entity_index != entity.stored.high_entity_index {

                    test_entity: Entity
                    test_entity.high = &state.high_entities_[test_high_entity_index]
                    test_entity.storage_index = test_entity.high.storage_index
                    test_entity.stored = &state.stored_entities[test_entity.storage_index]

                    if test_entity.stored.collides {
                        diameter := entity.stored.size + test_entity.stored.size
                        min_corner := -0.5 * diameter
                        max_corner :=  0.5 * diameter

                        rel := entity.high.p - test_entity.high.p

                        test_wall :: proc(wall_x, entity_delta_x, entity_delta_y, rel_x, rel_y, min_y, max_y: f32, t_min: ^f32) -> (collided: b32) {
                            EPSILON :: 0.01
                            if entity_delta_x != 0 {
                                t_result := (wall_x - rel_x) / entity_delta_x
                                y := rel_y + t_result * entity_delta_y
                                if 0 <= t_result && t_result < t_min^ {
                                    if y >= min_y && y <= max_y {
                                        t_min^ = max(0, t_result-EPSILON)
                                        collided = true
                                    }
                                }
                            }
                            return collided
                        }

                        if test_wall(min_corner.x, entity_delta.x, entity_delta.y, rel.x, rel.y, min_corner.y, max_corner.y, &t_min) {
                            wall_normal = {-1,  0}
                            hit_high_entity_index = test_high_entity_index
                        }
                        if test_wall(max_corner.x, entity_delta.x, entity_delta.y, rel.x, rel.y, min_corner.y, max_corner.y, &t_min) {
                            wall_normal = { 1,  0}
                            hit_high_entity_index = test_high_entity_index
                        }
                        if test_wall(min_corner.y, entity_delta.y, entity_delta.x, rel.y, rel.x, min_corner.x, max_corner.x, &t_min) {
                            wall_normal = { 0, -1}
                            hit_high_entity_index = test_high_entity_index
                        }
                        if test_wall(max_corner.y, entity_delta.y, entity_delta.x, rel.y, rel.x, min_corner.x, max_corner.x, &t_min) {
                            wall_normal = { 0,  1}
                            hit_high_entity_index = test_high_entity_index
                        }
                    }
                }
            }
        }

        entity.high.p.xy += t_min * entity_delta

        if hit_high_entity_index != 0 {
            entity.high.dp.xy = project(entity.high.dp.xy, wall_normal)
            entity_delta = desired_p - entity.high.p.xy
            entity_delta = project(entity_delta, wall_normal)

            hit_high_entity := state.high_entities_[hit_high_entity_index]
            hit_stored_entity := state.stored_entities[hit_high_entity.storage_index]
            entity.stored.p.chunk.z += hit_stored_entity.d_tile_z
        } else {
            break
        }
    }

    if entity.high.dp.x < 0  {
        entity.high.facing_index = 0
    } else {
        entity.high.facing_index = 1
    }

    new_p := map_into_worldspace(state.world, state.camera_p, entity.high.p.xy)
    // TODO(viktor): bundle these together as the location update
    change_entity_location(&state.world_arena, state.world, entity.storage_index, entity.stored, &new_p, &entity.stored.p)
}



// NOTE: at the moment this has to be a really fast function. It shall not be slower than a
// millisecond or so.
// TODO: reduce the pressure on the performance of this function by measuring
@(export)
game_output_sound_samples :: proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer){
    // TODO: Allow sample offsets here for more robust platform options
}


draw_bitmap :: proc(buffer: GameOffscreenBuffer, bitmap: LoadedBitmap, center: v2, c_alpha: f32 = 1) {
    rounded_center := round(center) + bitmap.focus

    left   := rounded_center.x - bitmap.width / 2
    top	   := rounded_center.y - bitmap.height / 2
    right  := left + bitmap.width
    bottom := top  + bitmap.height

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


draw_rectangle :: proc(buffer: GameOffscreenBuffer, position: v2, size: v2, color: GameColor){
    rounded_position := floor(position)
    rounded_size     := floor(size)

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

            dst.r = cast(u8) lerp(cast(f32) dst.r, src.r, color.a)
            dst.g = cast(u8) lerp(cast(f32) dst.g, src.g, color.a)
            dst.b = cast(u8) lerp(cast(f32) dst.b, src.b, color.a)
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
        return {pixels, header.width, header.height, {}}
    }
    return {}
}