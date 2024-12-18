package game

import "core:fmt"
import "base:runtime"
import "base:intrinsics"

INTERNAL :: #config(INTERNAL, true)

/*
    TODO(viktor):
    ARCHITECTURE EXPLORATION
    
    - Z !
      - debug drawing of Z levels and inclusion of Z to make sure
        that there are no bugs
      - Concept of ground in the collision loop so it can handle 
        collisions coming onto and off of stairs, for example
      - make sure flying things can go over walls
      - how is going "up" and "down" rendered?
    - Collision detection
      - Clean up predicate proliferation! Can we make a nice clean
        set of flags/rules so that it's easy to understand how
        things work in terms of special handling? This may involve
        making the iteration handle everything instead of handling 
        overlap outside and so on.
      - transient collision rules
        - allow non-transient rules to override transient once
        - Entry/Exit
      - Whats the plan for robustness / shape definition ?
      - "Things pushing other things"
    - Implement multiple sim regions per frame
      - per-entity clocking
      - sim region merging?  for multiple players?
      - simple zoomed out view for testing
      
    - Debug code
      - Logging
      - Diagramming
      - (a little gui) switches / sliders / etc
      - Draw tile chunks so we can verify that things are aligned / in the chunks we want them to be in / etc

    - Audio
      - Sound effects triggers
      - Ambient sounds
      - Music
    - Asset streaming

    - Rudimentary worldgen (no quality just "what sorts of things" we do
      - Map displays
      - Placement of background things
      - Connectivity?
      - Non-overlapping?
    - AI
      - Rudimentary monstar behaviour
      * Pathfinding
      - AI "storage"
    - Metagame / save game?
      - how do you enter a "save slot"?
      - persistent unlocks/etc.
      - Do we allow saved games? Probably yes, just only for "pausing"
      * continuous save for crash recovery?

    * Animation should probably lead into rendering
      - Skeletal animation
      - Particle systems

    PRODUCTION
    - Rendering

    -> Game
      - Entity system
      - World generation
*/


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

White    :: GameColor{1,1,1, 1}
Gray     :: GameColor{0.5,0.5,0.5, 1}
Black    :: GameColor{0,0,0, 1}
Blue     :: GameColor{0.08, 0.49, 0.72, 1}
Orange   :: GameColor{1, 0.71, 0.2, 1}
Green    :: GameColor{0, 0.59, 0.28, 1}
Red      :: GameColor{1, 0.09, 0.24, 1}
DarkGreen:: GameColor{0, 0.07, 0.0353, 1}

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

init_arena :: #force_inline proc(arena: ^Arena, storage: []u8) {
    arena.storage = storage
}

// TODO(viktor): zero all pushed data by default and add nonzeroing version for all procs
push :: proc { push_slice, push_struct, push_size }

push_slice :: #force_inline proc(arena: ^Arena, $Element: typeid, len: u64) -> (result: []Element) {
    data := cast([^]Element) push_size(arena, cast(u64) size_of(Element) * len)
    result = data[:len]
    return result
}

push_struct :: #force_inline proc(arena: ^Arena, $T: typeid) -> (result: ^T) {
    result = cast(^T) push_size(arena, cast(u64)size_of(T))
    return result
}

push_size :: #force_inline proc(arena: ^Arena, size: u64) -> (result: [^]u8) {
    assert(arena.used + size < cast(u64)len(arena.storage))
    result = &arena.storage[arena.used]
    arena.used += size
    return result
}

zero :: proc { zero_struct, zero_slice }

zero_struct :: #force_inline proc(s: ^$T) {
    data := cast([^]u8) s
    len  := size_of(T)
    zero_slice(data[:len])
}

zero_slice :: #force_inline proc(memory: []$u8){
    // TODO(viktor): check this guy for performance
    for &Byte in memory {
        Byte = 0
    }
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
        state.wall       = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/wall.bmp")
        state.stair      = DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/stair.bmp")

        state.player[0].focus = {8, 0}
        state.player[1].focus = {-4, 0}

        state.monster[0].focus = {0, -1}
        state.monster[1].focus = {21, -1}

        state.shadow.focus = {0, 10}

        state.sword.focus = {16, 16}

        state.world = push_struct(&state.world_arena, World)

        add_stored_entity(state, .Nil, null_position())

        world := state.world
        init_world(world, 1, 3)

        state.tile_size_in_pixels = 60
        state.meters_to_pixels = f32(state.tile_size_in_pixels) / world.tile_size_in_meters

        door_left, door_right: b32
        door_top, door_bottom: b32
        stair_up, stair_down: b32

        tiles_per_screen := [2]i32{17, 9}

        screen_base: [3]i32
        screen_row, screen_col, tile_z := screen_base.x, screen_base.y, screen_base.z + 1
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
            need_to_place_stair := created_stair

            for tile_y in 0..< tiles_per_screen.y {
                for tile_x in 0 ..< tiles_per_screen.x {
                    should_be_door: b32
                    if tile_x == 0                    && (!door_left  || tile_y != tiles_per_screen.y / 2) {
                        should_be_door = true
                    }
                    if tile_x == tiles_per_screen.x-1 && (!door_right || tile_y != tiles_per_screen.y / 2) {
                        should_be_door = true
                    }

                    if tile_y == 0                    && (!door_bottom || tile_x != tiles_per_screen.x / 2) {
                        should_be_door = true
                    }
                    if tile_y == tiles_per_screen.y-1 && (!door_top    || tile_x != tiles_per_screen.x / 2) {
                        should_be_door = true
                    }

                    if should_be_door {
                        add_wall(state,
                            tile_x + screen_col * tiles_per_screen.x,
                            tile_y + screen_row * tiles_per_screen.y,
                            tile_z,
                        ) 
                    } else if need_to_place_stair {
                        add_stairs(state, 
                            5 + screen_col * tiles_per_screen.x,
                            3 + screen_row * tiles_per_screen.y,
                            stair_down ? tile_z-1 : tile_z
                        )
                        need_to_place_stair = false
                    }

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

        state.camera_p = new_camera_p

        monster_p  := new_camera_p.chunk + {10,5,0}
        familiar_p := new_camera_p.chunk + {10,1,0}
        add_monster(state,  monster_p.x, monster_p.y, monster_p.z)
        add_familiar(state, familiar_p.x, familiar_p.y, familiar_p.z)
    }

    // ---------------------- ---------------------- ----------------------
    // ---------------------- Input
    // ---------------------- ---------------------- ----------------------

    world := state.world

    for controller, controller_index in input.controllers {
        con_hero := &state.controlled_heroes[controller_index]
        if con_hero.storage_index == 0 {
            if controller.start.ended_down {
                player_index, _ := add_player(state)
                con_hero^ = { storage_index = player_index }
            }
        } else {
            con_hero.dz     = {}
            con_hero.ddp    = {}
            con_hero.dsword = {}

            if controller.is_analog {
                // NOTE(viktor): Use analog movement tuning
                con_hero.ddp.xy = controller.stick_average
            } else {
                // NOTE(viktor): Use digital movement tuning
                if controller.stick_left.ended_down {
                    con_hero.ddp.x -= 1
                }
                if controller.stick_right.ended_down {
                    con_hero.ddp.x += 1
                }
                if controller.stick_up.ended_down {
                    con_hero.ddp.y += 1
                }
                if controller.stick_down.ended_down {
                    con_hero.ddp.y -= 1
                }
            }

            if controller.start.ended_down {
                con_hero.dz = 2
            }

            con_hero.dsword = {}
            if controller.button_up.ended_down {
                con_hero.dsword =  {0, 1}
            }
            if controller.button_down.ended_down {
                con_hero.dsword = -{0, 1}
            }
            if controller.button_left.ended_down {
                con_hero.dsword = -{1, 0}
            }
            if controller.button_right.ended_down {
                con_hero.dsword =  {1, 0}
            }
        }
    }

    // ---------------------- ---------------------- ----------------------
    // ---------------------- Update and Render
    // ---------------------- ---------------------- ----------------------

    // NOTE: Clear the screen
    draw_rectangle(buffer, 0, vec_cast(f32, buffer.width, buffer.height), DarkGreen) 

    // TODO(viktor): these numbers where picked at random
    tilespan := [3]f32{17, 9, 1} * 2
    camera_bounds := rectangle_center_half_diameter(0, tilespan * {world.tile_size_in_meters, world.tile_size_in_meters, state.world.tile_depth_in_meters })

    sim_arena: Arena
    init_arena(&sim_arena, memory.transient_storage)

    camera_sim_region := begin_sim(&sim_arena, state, world, state.camera_p, camera_bounds, input.delta_time)

    screen_center := vec_cast(f32, buffer.width, buffer.height) * 0.5
    draw_bitmap(buffer, state.backdrop, screen_center)

    for &entity in camera_sim_region.entities {
        if entity.updatable {
            // TODO(viktor):  move this out into entity.odin
            dt := input.delta_time;

            size := state.meters_to_pixels * entity.size

            // TODO(viktor): this is incorrect, should be computed after update
            shadow_alpha := 1 - 0.5 * entity.p.z;
            if(shadow_alpha < 0) {
                shadow_alpha = 0.0;
            }

            piece_group := EntityVisiblePieceGroup { state = state }

            ddp: v3
            move_spec := default_move_spec()

            switch entity.type {
            case .Nil: // NOTE(viktor): nothing
            case .Wall:
                push_bitmap(&piece_group, &state.wall, 0)

            case .Stairwell: 
                position := screen_center + state.meters_to_pixels * (entity.p.xy * {1,-1} - 0.5 * entity.size.xy )
                push_rectangle(&piece_group, entity.size.xy, 0,             Blue * {1,1,1,0.5})
                push_rectangle(&piece_group, entity.size.xy, {0, 0, entity.size.z}, Blue * {1,1,0.6,0.5})
    
            case .Hero:
                for &con_hero in state.controlled_heroes {
                    if con_hero.storage_index == entity.storage_index {
                        if con_hero.dz != 0 {
                            entity.dp.z = con_hero.dz
                        }

                        move_spec.normalize_accelaration = true
                        move_spec.drag = 8
                        move_spec.speed = 50
                        ddp = con_hero.ddp


                        push_bitmap(&piece_group, &state.shadow, 0, shadow_alpha)
                        push_bitmap(&piece_group, &state.player[entity.facing_index], 0)
                        draw_hitpoints(&piece_group, &entity, 1)

                        if con_hero.dsword.x != 0 || con_hero.dsword.y != 0 {
                            sword := entity.sword.ptr
                            if sword != nil && .Nonspatial in sword.flags {
                                dp: v3
                                dp.xy = 5 * con_hero.dsword
                                sword.distance_limit = 5
                                add_collision_rule(state, entity.storage_index, sword.storage_index, false)
                                make_entity_spatial(sword, entity.p, dp)
                            }

                        }

                        break
                    }
                }

            case .Sword:
                move_spec.normalize_accelaration = false
                move_spec.drag = 0
                move_spec.speed = 0

                if entity.distance_limit == 0 {
                    clear_collision_rules(state, entity.storage_index)
                    make_entity_nonspatial(&entity)
                }

                push_bitmap(&piece_group, &state.shadow, 0, shadow_alpha)
                push_bitmap(&piece_group, &state.sword, 0)

            case .Familiar:
                closest_hero: ^Entity
                closest_hero_dsq := square(10)

                // TODO(viktor): make spatial queries easy for things
                for &test in camera_sim_region.entities[:camera_sim_region.entity_count] {
                    if test.type == .Hero {
                        dsq := length_squared(test.p.xy - entity.p.xy)
                        if dsq < closest_hero_dsq {
                            closest_hero_dsq = dsq
                            closest_hero = &test
                        }
                    }
                }
when false {
                if closest_hero != nil && closest_hero_dsq > 1 {
                    mpss: f32 = 0.5
                    ddp = mpss / square_root(closest_hero_dsq) * (closest_hero.p - entity.p)
                }
}

                move_spec.normalize_accelaration = true
                move_spec.drag = 8
                move_spec.speed = 50

                entity.t_bob += dt
                if entity.t_bob > TAU {
                    entity.t_bob -= TAU
                }
                hz :: 4
                coeff := sin(entity.t_bob * hz)
                z := (coeff) * 0.3 + 0.3

                push_bitmap(&piece_group, &state.shadow, 0, 1 - shadow_alpha/2 * (coeff+1))
                push_bitmap(&piece_group, &state.player[entity.facing_index], {0, z, 0}, 0.5)

            case .Monster:
                push_bitmap(&piece_group, &state.shadow, 0, shadow_alpha)
                push_bitmap(&piece_group, &state.monster[1], 0)

                draw_hitpoints(&piece_group, &entity, 1.6)
            }

            if entity.flags & {.Nonspatial, .Moveable} == {.Moveable} {
                move_entity(state, camera_sim_region, &entity, ddp, move_spec, input.delta_time)
            }

            base_p := get_entity_ground_point(&entity)

            for piece in piece_group.pieces[:piece_group.count] {
                z_fudge := 1 + 0.05 * (base_p.z + piece.offset.z)

                center := screen_center 
                center.x += state.meters_to_pixels * z_fudge * (base_p.x - 0.5 * entity.size.x) 
                center.y -= state.meters_to_pixels * z_fudge * (base_p.y - 0.5 * entity.size.y) 
                center.y -= state.meters_to_pixels / state.world.tile_depth_in_meters * base_p.z 

                center += piece.offset.xy

                if piece.bitmap != nil {
                    center.x -= (cast(f32) piece.bitmap.width/2  - entity.size.x * state.meters_to_pixels)
                    center.y -=(cast(f32) piece.bitmap.height/2 -  entity.size.y * state.meters_to_pixels)
                    draw_bitmap(buffer, piece.bitmap^, center, clamp_01(piece.color.a))
                } else {
                    center.y -= entity.size.y * state.meters_to_pixels
                    draw_rectangle(buffer, center, piece.size, piece.color)
                }
            }
        }
    }

    end_sim(camera_sim_region, state)
}

EntityType :: enum u32 {
    Nil, Hero, Wall, Familiar, Monster, Sword, Stairwell
}

HIT_POINT_PART_COUNT :: 4
HitPoint :: struct {
    flags: u8,
    filled_amount: u8,
}

EntityVisiblePieceGroup :: struct {
    // TODO(viktor): This is dumb, this should just be part of
    // the renderer pushbuffer - add correction of coordinates
    // in there and be done with it.

    state: ^GameState,
    count: u32,
    pieces: [8]EntityVisiblePiece,
}

EntityVisiblePiece :: struct {
    bitmap: ^LoadedBitmap,
    offset: v3,

    color: GameColor,
    size: v2,
}

EntityIndex :: u32
StorageIndex :: distinct EntityIndex

StoredEntity :: struct {
    // TODO(viktor): its kind of busted that ps can be invalid  here
    // AND we stored whether they would be invalid in the flags field...
    // Can we do something better here?
    sim: Entity,
    p: WorldPosition,
}

ControlledHero :: struct {
    storage_index: StorageIndex,

    // NOTE(viktor): these are the controller request for simulation
    ddp: v3,
    dsword: v2,
    dz: f32,
}

PairwiseCollsionRuleFlag :: enum {
    ShouldCollide,
    Temporary,
}


PairwiseCollsionRule :: struct {
    can_collide: b32,
    index_a, index_b: StorageIndex,

    next_in_hash: ^PairwiseCollsionRule
}

GameState :: struct {
    world_arena: Arena,
    // TODO(viktor): should we allow split-screen?
    camera_following_index: StorageIndex,
    camera_p : WorldPosition,
    controlled_heroes: [len(GameInput{}.controllers)]ControlledHero,

    stored_entity_count: StorageIndex,
    stored_entities: [100_000]StoredEntity,

    world: ^World,

    backdrop, wall, shadow, sword, stair: LoadedBitmap,
    player, monster: [2]LoadedBitmap,

    tile_size_in_pixels: u32,
    meters_to_pixels: f32,

    // NOTE(viktor): must be a power of 2!
    collision_rule_hash: [256]^PairwiseCollsionRule,
    first_free_collision_rule: ^PairwiseCollsionRule,
}

LoadedBitmap :: struct {
    pixels : []Color,
    width, height: i32,
    focus: [2]i32,
}

Color :: [4]u8

get_low_entity :: #force_inline proc(state: ^GameState, storage_index: StorageIndex) -> (entity: ^StoredEntity) #no_bounds_check {
    if storage_index > 0 && storage_index <= state.stored_entity_count {
        entity = &state.stored_entities[storage_index]
    }

    return entity
}

add_stored_entity :: proc(state: ^GameState, type: EntityType, p: WorldPosition) -> (index: StorageIndex, stored: ^StoredEntity) #no_bounds_check {
    index = state.stored_entity_count
    state.stored_entity_count += 1
    assert(state.stored_entity_count < len(state.stored_entities))
    stored = &state.stored_entities[index]
    stored.sim = { type = type }
    stored.p = null_position()

    change_entity_location(&state.world_arena, state.world, index, stored, p)

    return index, stored
}

add_grounded_entity :: proc(state: ^GameState, type: EntityType, p: WorldPosition, size: v3) -> (index: StorageIndex, stored: ^StoredEntity) #no_bounds_check {
    offset_p := map_into_worldspace(state.world, p, {0, 0, 0.5 * size.z})
    index, stored = add_stored_entity(state, type, offset_p)
    stored.sim.size = size

    return index, stored
}

init_hitpoints :: proc(entity: ^StoredEntity, count: u32) {
    assert(count < len(entity.sim.hit_points))

    entity.sim.hit_point_max = count
    for &hit_point in entity.sim.hit_points[:count] {
        hit_point = { filled_amount = HIT_POINT_PART_COUNT }
    }
}

add_sword :: proc(state: ^GameState) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_stored_entity(state, .Sword, null_position())

    entity.sim.size = {0.5, 1, 0.1}
    entity.sim.flags += {.Moveable}

    return index, entity
}

add_monster :: proc(state: ^GameState, tile_x, tile_y, tile_z: i32) -> (index: StorageIndex, entity: ^StoredEntity) {
    p := chunk_position_from_tile_positon(state.world, tile_x, tile_y, tile_z)
    index, entity = add_grounded_entity(state, .Monster, p, {0.75, 0.75, 1.5})

    entity.sim.flags += {.Collides, .Moveable}

    init_hitpoints(entity, 3)

    return index, entity
}

add_familiar :: proc(state: ^GameState, tile_x, tile_y, tile_z: i32) -> (index: StorageIndex, entity: ^StoredEntity) {
    p := chunk_position_from_tile_positon(state.world, tile_x, tile_y, tile_z)
    index, entity = add_stored_entity(state, .Familiar, p)

    entity.sim.size = 0.5
    entity.sim.flags += {.Moveable}

    return index, entity
}

add_wall :: proc(state: ^GameState, tile_x, tile_y, tile_z: i32) -> (index: StorageIndex, entity: ^StoredEntity) {
    p := chunk_position_from_tile_positon(state.world, tile_x, tile_y, tile_z)
    index, entity = add_grounded_entity(state, .Wall, p, {state.world.tile_size_in_meters, state.world.tile_size_in_meters, state.world.tile_depth_in_meters})

    entity.sim.flags += {.Collides}

    return index, entity
}

add_stairs :: proc(state: ^GameState, tile_x, tile_y, tile_z: i32) -> (index: StorageIndex, entity: ^StoredEntity) {
    p := chunk_position_from_tile_positon(state.world, tile_x, tile_y, tile_z)
    index, entity = add_grounded_entity(state, .Stairwell, p, {
        state.world.tile_size_in_meters,
        state.world.tile_size_in_meters * 2,
        state.world.tile_depth_in_meters + 0.1
    })

    entity.sim.flags += {.Collides}
    entity.sim.walkable_height = state.world.tile_depth_in_meters

    return index, entity
}

add_player :: proc(state: ^GameState) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Hero, state.camera_p, {0.75, 0.4, 1.2})

    entity.sim.flags += {.Collides, .Moveable}

    init_hitpoints(entity, 3)

    sword_index, sword := add_sword(state)
    entity.sim.sword.index = sword_index

    if state.camera_following_index == 0 {
        state.camera_following_index = index
    }

    return index, entity
}

add_collision_rule :: proc(state:^GameState, a, b: StorageIndex, should_collide: b32) {
    // TODO(viktor): collapse this with should_collide
    a, b := a, b
    if a > b do swap(&a, &b)
    // TODO(viktor): BETTER HASH FUNCTION!!!
    found: ^PairwiseCollsionRule
    hash_bucket := a & (len(state.collision_rule_hash) - 1)
    for rule := state.collision_rule_hash[hash_bucket]; rule != nil; rule = rule.next_in_hash {
        if rule.index_a == a && rule.index_b == b {
            found = rule
            break
        }
    }

    if found == nil {
        found = state.first_free_collision_rule
        if found != nil {
            state.first_free_collision_rule = found.next_in_hash
        } else {
            found = push(&state.world_arena, PairwiseCollsionRule)
        }
        found.next_in_hash = state.collision_rule_hash[hash_bucket]
        state.collision_rule_hash[hash_bucket] = found
    }

    if found != nil {
        found.index_a = a
        found.index_b = b
        found.can_collide = should_collide
    }
}

clear_collision_rules :: proc(state:^GameState, storage_index: StorageIndex) {
    // TODO(viktor): need to make a better datastructute that allows for
    // the removal of collision rules without searching the entire table
    // NOTE(viktor): One way to make removal easy would be to always
    // add _both_ orders of the pairs of storage indices to the
    // hash table, so no matter which position the entity is in,
    // you can always find it. Then, when you do your first pass
    // through for removal, you just remember the original top
    // of the free list, and when you're done, do a pass through all
    // the new things on the free list, and remove the reverse of
    // those pairs.
    for hash_bucket in 0..<len(state.collision_rule_hash) {
        for rule := &state.collision_rule_hash[hash_bucket]; rule^ != nil;  {
            if rule^.index_a == storage_index || rule^.index_b == storage_index {
                removed_rule := rule^

                rule^ = (rule^).next_in_hash

                removed_rule.next_in_hash = state.first_free_collision_rule
                state.first_free_collision_rule = removed_rule
            } else {
                rule = &(rule^.next_in_hash)
            }
        }
    }
}

push_piece :: #force_inline proc(group: ^EntityVisiblePieceGroup, bitmap: ^LoadedBitmap, size: v2, offset: v3, color: GameColor) {
    assert(group.count < len(group.pieces))
    piece := &group.pieces[group.count]
    group.count += 1

    piece.bitmap = bitmap
    piece.offset.xy = {offset.x, -offset.y} * group.state.meters_to_pixels
    piece.offset.z = offset.z
    piece.size   = size * group.state.meters_to_pixels
    piece.color  = color
}

push_bitmap :: #force_inline proc(group: ^EntityVisiblePieceGroup, bitmap: ^LoadedBitmap, offset:v3, alpha: f32 = 1) {
    push_piece(group, bitmap, {}, offset, {1,1,1, alpha})
}

push_rectangle :: #force_inline proc(group: ^EntityVisiblePieceGroup, size: v2, offset:v3, color: GameColor) {
    push_piece(group, nil, size, offset, color)
}

draw_hitpoints :: proc(group: ^EntityVisiblePieceGroup, entity: ^Entity, offset_y: f32) {
    if entity.hit_point_max > 1 {
        health_size: v2 = 0.1
        spacing_between: f32 = health_size.x * 1.5
        health_x := -0.5 * (cast(f32) entity.hit_point_max - 1) * spacing_between + entity.size.x/2

        for index in 0..<entity.hit_point_max {
            hit_point := entity.hit_points[index]
            color := hit_point.filled_amount == 0 ? Gray : Red
            push_rectangle(group, health_size, {health_x, -offset_y, 0}, color)
            health_x += spacing_between
        }
    }

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

            dst.r = cast(u8) lerp(cast(f32) dst.r, src.r, clamp_01(color.a))
            dst.g = cast(u8) lerp(cast(f32) dst.g, src.g, clamp_01(color.a))
            dst.b = cast(u8) lerp(cast(f32) dst.b, src.b, clamp_01(color.a))
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