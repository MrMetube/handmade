package game

import "base:intrinsics"
import "core:fmt"

INTERNAL :: #config(INTERNAL, false)

/*
    TODO(viktor):
    ARCHITECTURE EXPLORATION
    
    - Audio
        - Sound effects triggers
        - Ambient sounds
        - Music

    - Asset streaming
      - File format
      - Memory management
    
    - Rendering
        - Straighten out all coordinate systems!
            - Screen
            - World
            - Texture
        - Particle systems
        - Lighting
        - Final Optimization    

    - Debug code
        - Fonts
        - Logging
        - Diagramming
        - (a little gui) switches / sliders / etc
        - Draw tile chunks so we can verify that things are aligned / in the chunks we want them to be in / etc
        - Thread visualization 
        
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
    -> Game
      - Entity system
      - World generation
*/

White    :: v4{1,1,1, 1}
Gray     :: v4{0.5,0.5,0.5, 1}
Black    :: v4{0,0,0, 1}
Blue     :: v4{0.08, 0.49, 0.72, 1}
Yellow   :: v4{0.91, 0.81, 0.09, 1}
Orange   :: v4{1, 0.71, 0.2, 1}
Green    :: v4{0, 0.59, 0.28, 1}
Red      :: v4{1, 0.09, 0.24, 1}
DarkGreen:: v4{0, 0.07, 0.0353, 1}

State :: struct {
    is_initialized: b32,

    world_arena: Arena,
    
    mixer: Mixer,
    music: ^PlayingSound,
    
    typical_floor_height: f32,
    // TODO(viktor): should we allow split-screen?
    camera_following_index: StorageIndex,
    camera_p : WorldPosition,
    controlled_heroes: [len(Input{}.controllers)]ControlledHero,

    stored_entity_count: StorageIndex,
    stored_entities: [100_000]StoredEntity,

    world: ^World,
    
    collision_rule_hash: [256]^PairwiseCollsionRule,
    first_free_collision_rule: ^PairwiseCollsionRule,

    null_collision, 
    arrow_collision, 
    stairs_collision, 
    player_collision, 
    monstar_collision, 
    familiar_collision, 
    standart_room_collision,
    wall_collision: ^EntityCollisionVolumeGroup,

    general_entropy: RandomSeries,
    
    time: f32,
    
}

TransientState :: struct {
    is_initialized: b32,
    arena: Arena,
    
    assets: ^Assets,
    
    tasks: [4]TaskWithMemory,

    test_diffuse: Bitmap,
    test_normal:  Bitmap,
    
    ground_buffers: []GroundBuffer,
    
    high_priority_queue: ^PlatformWorkQueue,
    low_priority_queue:  ^PlatformWorkQueue,
    
    env_size: [2]i32,
    using _ : struct #raw_union {
        using _ : struct {
            env_bottom, env_middle, env_top: EnvironmentMap,
        },
        envs: [3]EnvironmentMap,
    },
}

TaskWithMemory :: struct {
    in_use: b32,
    arena: Arena,
    
    memory_flush: TemporaryMemory,
}

GroundBuffer :: struct {
    bitmap: Bitmap,
    // NOTE(viktor): An invalid position tells us that this ground buffer has not been filled
    p: WorldPosition, // NOTE(viktor): this is the center of the bitmap
}

EntityType :: enum u32 {
    Nil, 
    
    Space,
    
    Hero, Wall, Familiar, Monster, Arrow, Stairwell,
}

HitPointPartCount :: 4
HitPoint :: struct {
    flags: u8,
    filled_amount: u8,
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

    // NOTE(viktor): these are the controller requests for simulation
    ddp: v3,
    darrow: v2,
    dz: f32,
}

PairwiseCollsionRuleFlag :: enum {
    ShouldCollide,
    Temporary,
}

PairwiseCollsionRule :: struct {
    can_collide: b32,
    index_a, index_b: StorageIndex,

    next_in_hash: ^PairwiseCollsionRule,
}

// NOTE(viktor): https://graphics.stanford.edu/~seander/bithacks.html#DetermineIfPowerOf2
#assert( len(State{}.collision_rule_hash) & ( len(State{}.collision_rule_hash) - 1 ) == 0)

// NOTE(viktor): Globals
PLATFORM_enqueue_work:      PlatformEnqueueWork
PLATFORM_complete_all_work: PlatformCompleteAllWork
DEBUG_read_entire_file:     DebugReadEntireFile

// NOTE(viktor): declaration of a platform struct, into which we should never need to look
PlatformWorkQueue :: struct {}

@(export)
update_and_render :: proc(memory: ^GameMemory, buffer: Bitmap, input: Input){
    scoped_timed_block(.update_and_render)

    PLATFORM_enqueue_work      = memory.PLATFORM_enqueue_work
    PLATFORM_complete_all_work = memory.PLATFORM_complete_all_work
    
    when INTERNAL {
        // NOTE(viktor): used by performance counters
        DEBUG_GLOBAL_memory = memory
        DEBUG_read_entire_file = memory.debug.read_entire_file
    }
        
    ground_buffer_size :: 256
    
    // ---------------------- ---------------------- ----------------------
    // ---------------------- Permanent Initialization
    // ---------------------- ---------------------- ----------------------
    assert(size_of(State) <= len(memory.permanent_storage), "The State cannot fit inside the permanent memory")
    state := cast(^State) raw_data(memory.permanent_storage)
    if !state.is_initialized {
        // TODO(viktor): lets start partitioning our memory space
        // TODO(viktor): formalize the world arena and others being after the State in permanent storage
        // initialize the permanent arena first and allocate the state out of it
        // TODO(viktor): use a sub arena here
        init_arena(&state.world_arena, memory.permanent_storage[size_of(State):])
        
        state.general_entropy = seed_random_series(500)
        tiles_per_screen :: [2]i32{15, 7}

        tile_size_in_meters :: 1.5
        state.null_collision          = make_null_collision(state)
        state.wall_collision          = make_simple_grounded_collision(state, {tile_size_in_meters, tile_size_in_meters, state.typical_floor_height})
        state.arrow_collision         = make_simple_grounded_collision(state, {0.5, 1, 0.1})
        state.stairs_collision        = make_simple_grounded_collision(state, {tile_size_in_meters, tile_size_in_meters * 2, state.typical_floor_height + 0.1})
        state.player_collision        = make_simple_grounded_collision(state, {0.75, 0.4, 1})
        state.monstar_collision       = make_simple_grounded_collision(state, {0.75, 0.75, 1.5})
        state.familiar_collision      = make_simple_grounded_collision(state, {0.5, 0.5, 1})
        state.standart_room_collision = make_simple_grounded_collision(state, V3(vec_cast(f32, tiles_per_screen) * tile_size_in_meters, state.typical_floor_height * 0.9))

        //
        // "World Gen"
        //
        
        state.world = push_struct(&state.world_arena, World)
        
        add_stored_entity(state, .Nil, null_position())
        state.typical_floor_height = 3

        world := state.world
        // TODO(viktor): REMOVE THIS
        pixels_to_meters :: 1.0 / 42.0
        chunk_dim_in_meters :f32= pixels_to_meters * ground_buffer_size
        init_world(world, {chunk_dim_in_meters, chunk_dim_in_meters, state.typical_floor_height})
        
        chunk_position_from_tile_positon :: #force_inline proc(world: ^World, tile_x, tile_y, tile_z: i32, additional_offset := v3{}) -> (result: WorldPosition) {
            tile_size_in_meters  :: 1.5
            tile_depth_in_meters :: 3
            offset := v3{tile_size_in_meters, tile_size_in_meters, tile_depth_in_meters} * (vec_cast(f32, tile_x, tile_y, tile_z) + {0.5, 0.5, 0})
            
            result = map_into_worldspace(world, result, offset + additional_offset)
            
            assert(auto_cast is_canonical(world, result.offset))
        
            return result
        }
        
        door_left, door_right: b32
        door_top, door_bottom: b32
        stair_up, stair_down: b32

        series := seed_random_series(0)
        screen_base: [3]i32
        screen_row, screen_col, tile_z := screen_base.x, screen_base.y, screen_base.z
        created_stair: b32
        for room in u32(0) ..< 200 {
            when false {
                choice := random_choice(&series, 3)
            } else {
                choice := 3
            }
            
            created_stair = false
            switch(choice) {
            case 0: door_right  = true
            case 1: door_top    = true
            case 2: stair_down  = true
            case 3: stair_up    = true
            // TODO(viktor): this wont work for now, but whatever
            case 4: door_left   = true
            case 5: door_bottom = true
            }
            
            created_stair = stair_down || stair_up
            need_to_place_stair := created_stair
            
            add_standart_room(state, chunk_position_from_tile_positon(world, 
                screen_col * tiles_per_screen.x + tiles_per_screen.x/2,
                screen_row * tiles_per_screen.y + tiles_per_screen.y/2,
                tile_z,
            )) 

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
                        add_wall(state, chunk_position_from_tile_positon(world, 
                            tile_x + screen_col * tiles_per_screen.x,
                            tile_y + screen_row * tiles_per_screen.y,
                            tile_z,
                        ))
                    } else if need_to_place_stair {
                        add_stairs(state, chunk_position_from_tile_positon(world, 
                            room % 2 == 0 ? 5 : 10 - screen_col * tiles_per_screen.x, 
                            3                      - screen_row * tiles_per_screen.y, 
                            stair_down ? tile_z-1 : tile_z,
                        ))
                        need_to_place_stair = false
                    }

                }
            }
            
            door_left   = door_right
            door_bottom = door_top
            door_right  = false
            door_top    = false

            stair_up   = false
            stair_down = false

            switch(choice) {
            case 0: screen_col += 1
            case 1: screen_row += 1
            case 2: tile_z -= 1
            case 3: tile_z += 1
            case 4: screen_col -= 1
            case 5: screen_row -= 1
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
        add_monster(state,  chunk_position_from_tile_positon(world, monster_p.x, monster_p.y, monster_p.z))
        for _ in 0..< 1 {
            familiar_p := new_camera_p.chunk
            familiar_p.x += random_between_i32(&series, 0, 14)
            familiar_p.y += random_between_i32(&series, 0, 7)
            add_familiar(state, chunk_position_from_tile_positon(world, familiar_p.x, familiar_p.y, familiar_p.z))
        }
         
        // TODO(viktor): do not use the world arena here
        init_mixer(&state.mixer, &state.world_arena)
        
        state.is_initialized = true
    }

    // ---------------------- ---------------------- ----------------------
    // ---------------------- Transient Initialization
    // ---------------------- ---------------------- ----------------------
    assert(size_of(TransientState) <= len(memory.transient_storage), "The Transient State cannot fit inside the permanent memory")
    tran_state := cast(^TransientState) raw_data(memory.transient_storage)
    if !tran_state.is_initialized {
        init_arena(&tran_state.arena, memory.transient_storage[size_of(TransientState):])

        tran_state.high_priority_queue = memory.high_priority_queue
        tran_state.low_priority_queue  = memory.low_priority_queue
        
        for &task in tran_state.tasks {
            task.in_use = false
            sub_arena(&task.arena, &tran_state.arena, megabytes(2))
        }

        tran_state.assets = make_game_assets(&tran_state.arena, megabytes(64), tran_state)
        
        play_sound(&state.mixer, first_sound_from(tran_state.assets, .Music))
        state.music = state.mixer.first_playing_sound
        
        // TODO(viktor): pick a real number here!
        tran_state.ground_buffers = push(&tran_state.arena, GroundBuffer, 64)
        for &ground_buffer in tran_state.ground_buffers {
            ground_buffer.p = null_position()
            ground_buffer.bitmap = make_empty_bitmap(&tran_state.arena, ground_buffer_size, false)
        }
        
        test_size :[2]i32= 256
        tran_state.test_diffuse = make_empty_bitmap(&tran_state.arena, test_size, false)
        // draw_rectangle(tran_state.test_diffuse, vec_cast(f32, test_size/2), vec_cast(f32, test_size), 0.5)
        
        tran_state.test_normal = make_empty_bitmap(&tran_state.arena, test_size, false)
        make_sphere_normal_map(tran_state.test_normal, 0)
        make_sphere_diffuse_map(tran_state.test_diffuse)
        
        tran_state.env_size = {512, 256}
        for &env_map in tran_state.envs {
            size := tran_state.env_size
            for &lod in env_map.LOD {
                lod = make_empty_bitmap(&tran_state.arena, size, false)
                size /= 2
            }
        }
        
        tran_state.is_initialized = true
    }
    
    when false {
        // TODO(viktor): re-enable this? But make sure we dont touch ones in flight?
        if input.reloaded_executable {
            for &ground_buffer in tran_state.ground_buffers {
                ground_buffer.p = null_position()
            }
            
            make_sphere_normal_map(tran_state.test_normal, 0)
            make_sphere_diffuse_map(tran_state.test_diffuse)
        }
    }
    
    // ---------------------- ---------------------- ----------------------
    // ---------------------- Input
    // ---------------------- ---------------------- ----------------------

    world := state.world
    
    when false {
        // NOTE(viktor): test sound panning with the mouse 
        music_volume := vec_cast(f32, input.mouse_position) / vec_cast(f32, buffer.width, buffer.height)
        change_volume(&state.mixer, state.music, 0.01, music_volume)
    }
    
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
            con_hero.darrow = {}

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
            
            when false {
                if controller.start.ended_down {
                    con_hero.dz = 2
                }
            }
            
            con_hero.darrow = {}
            if controller.button_up.ended_down {
                con_hero.darrow =  {0, 1}
                change_volume(&state.mixer, state.music, 4, {1,1})
            }
            if controller.button_down.ended_down {
                con_hero.darrow = -{0, 1}
                change_volume(&state.mixer, state.music, 10, {0,0})
            }
            if controller.button_left.ended_down {
                con_hero.darrow = -{1, 0}
                // change_volume(&state.mixer, state.music, 3, {1,0})
                change_pitch(&state.mixer, state.music, state.music.d_sample - 0.1)
                
            }
            if controller.button_right.ended_down {
                con_hero.darrow =  {1, 0}
                // change_volume(&state.mixer, state.music, 3, {0,1})
                change_pitch(&state.mixer, state.music, state.music.d_sample + 0.1)
            }
            
            if con_hero.darrow != 0 {
                play_sound(&state.mixer, random_sound_from(tran_state.assets, .Hit, &state.general_entropy), 0.2)
            }
        }
    }

    // ---------------------- ---------------------- ----------------------
    // ---------------------- Update and Render
    // ---------------------- ---------------------- ----------------------
    
    when false {
        // NOTE(viktor): enable this to test weird screen sizes
        buffer := buffer
        buffer.width  = 1279
        buffer.height = 719
    }
    
    // TODO(viktor): decide what out push_buffer size is
    render_memory := begin_temporary_memory(&tran_state.arena)
    
    monitor_width_in_meters :: 0.635
    buffer_size := [2]i32{buffer.width, buffer.height}
    meters_to_pixels_for_monitor := cast(f32) buffer_size.x * monitor_width_in_meters
    
    render_group := make_render_group(&tran_state.arena, tran_state.assets, megabytes(4))
    
    focal_length, distance_above_ground : f32 = 0.6, 8
    perspective(render_group, buffer_size, meters_to_pixels_for_monitor, focal_length, distance_above_ground)
    
    clear(render_group, DarkGreen)
    
    for &ground_buffer in tran_state.ground_buffers {
        if is_valid(ground_buffer.p) {
            offset := world_difference(world, ground_buffer.p, state.camera_p)
            
            if abs(offset.z) == 0 {
                bitmap := ground_buffer.bitmap
                bitmap.align_percentage = 0.5
                
                ground_chunk_size := world.chunk_dim_meters.x
                push_bitmap_raw(render_group, bitmap, ground_chunk_size, offset)
                
                when false {
                    push_rectangle_outline(render_group, offset, ground_chunk_size, Yellow)
                }
            }
        }
    }
    
    
    screen_bounds := get_camera_rectangle_at_target(render_group)
    camera_bounds := Rectangle3{
        V3(screen_bounds.min, -0.5 * state.typical_floor_height), 
        V3(screen_bounds.max, 4 * state.typical_floor_height),
    }

    when false {
        min_p := map_into_worldspace(world, state.camera_p, camera_bounds.min)
        max_p := map_into_worldspace(world, state.camera_p, camera_bounds.max)

        for z in min_p.chunk.z ..= max_p.chunk.z {
            for y in min_p.chunk.y ..= max_p.chunk.y {
                for x in min_p.chunk.x ..= max_p.chunk.x {
                    chunk_center := WorldPosition{ chunk = { x, y, z } }
                    
                    furthest_distance: f32 = -1
                    furthest: ^GroundBuffer
                    // TODO(viktor): @Speed this is super inefficient. Fix it!
                    for &ground_buffer in tran_state.ground_buffers {
                        buffer_delta := world_difference(world, ground_buffer.p, state.camera_p)
                        if are_in_same_chunk(world, ground_buffer.p, chunk_center) {
                            furthest = nil
                            break
                        } else if is_valid(ground_buffer.p) {
                            if abs(buffer_delta.z) <= 4 {
                                distance_from_camera := length_squared(buffer_delta.xy)
                                if distance_from_camera > furthest_distance {
                                    furthest_distance = distance_from_camera
                                    furthest = &ground_buffer
                                }
                            }
                        } else {
                            furthest_distance = max(f32)
                            furthest = &ground_buffer
                        }
                    }
                    
                    if furthest != nil {
                        fill_ground_chunk(tran_state, state, furthest, chunk_center)
                    }
                }
            }
        }
    }
    
    sim_memory := begin_temporary_memory(&tran_state.arena)
    // TODO(viktor): by how much should we expand the sim region?
    // TODO(viktor): do we want to simulate upper floors, etc?
    sim_bounds := rectangle_add_radius(camera_bounds, v3{15, 15, 0})
    sim_origin := state.camera_p
    camera_sim_region := begin_sim(&tran_state.arena, state, world, sim_origin, sim_bounds, input.delta_time)
    
    push_rectangle_outline(render_group, 0, rectangle_get_diameter(screen_bounds),                         Yellow,0.1)
    push_rectangle_outline(render_group, 0, rectangle_get_diameter(camera_sim_region.bounds).xy,           Blue,  0.2)
    push_rectangle_outline(render_group, 0, rectangle_get_diameter(camera_sim_region.updatable_bounds).xy, Green, 0.2)
    
    camera_p := world_difference(world, state.camera_p, sim_origin)
        
    for &entity in camera_sim_region.entities[:camera_sim_region.entity_count] {
        if entity.updatable { // TODO(viktor):  move this out into entity.odin
            dt := input.delta_time;

            // TODO(viktor): Probably indicates we want to separate update adn rednder for entities sometime soon?
            camera_relative_ground := get_entity_ground_point(&entity) - camera_p
            fade_top_end      :=  0.75 * state.typical_floor_height
            fade_top_start    :=  0.5  * state.typical_floor_height
            fade_bottom_start := -1    * state.typical_floor_height
            fade_bottom_end   := -1.5  * state.typical_floor_height 
            
            render_group.global_alpha = 1
            if camera_relative_ground.z > fade_top_start {
                render_group.global_alpha = clamp_01_to_range(fade_top_end, camera_relative_ground.z, fade_top_start)
            } else if camera_relative_ground.z < fade_bottom_start {
                render_group.global_alpha = clamp_01_to_range(fade_bottom_end, camera_relative_ground.z, fade_bottom_start)
            }
            

            // TODO(viktor): this is incorrect, should be computed after update
            shadow_alpha := 1 - 0.5 * entity.p.z;
            if shadow_alpha < 0 {
                shadow_alpha = 0.0;
            }
            
            ddp: v3
            move_spec := default_move_spec()
            
            // 
            // Pre-physics entity work
            // 
            switch entity.type {
            case .Nil: // NOTE(viktor): nothing
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

                        if con_hero.darrow.x != 0 || con_hero.darrow.y != 0 {
                            arrow := entity.arrow.ptr
                            if arrow != nil && .Nonspatial in arrow.flags {
                                dp: v3
                                dp.xy = 5 * con_hero.darrow
                                arrow.distance_limit = 5
                                add_collision_rule(state, entity.storage_index, arrow.storage_index, false)
                                make_entity_spatial(arrow, entity.p, dp)
                            }

                        }

                        break
                    }
                }

            case .Arrow:
                move_spec.normalize_accelaration = false
                move_spec.drag = 0
                move_spec.speed = 0

                if entity.distance_limit == 0 {
                    clear_collision_rules(state, entity.storage_index)
                    make_entity_nonspatial(&entity)
                }
                
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
                
            // NOTE(viktor): nothing
            case .Monster:
            case .Wall:
            case .Stairwell: 
            case .Space: 
            }

            if entity.flags & {.Nonspatial, .Moveable} == {.Moveable} {
                move_entity(state, camera_sim_region, &entity, ddp, move_spec, input.delta_time)
            }

            render_group.transform.offset = get_entity_ground_point(&entity)

            // 
            // Post-physics entity work
            // 
            match_vector  := AssetVector {
                .FacingDirection = entity.facing_direction
            }
            weight_vector := AssetVector {
                .FacingDirection = 1
            }
            
            head_id  := best_match_bitmap_from(tran_state.assets, .Head, match_vector, weight_vector)
            body_id  := best_match_bitmap_from(tran_state.assets, .Body, match_vector, weight_vector)
            cape_id  := best_match_bitmap_from(tran_state.assets, .Cape, match_vector, weight_vector)
            sword_id := best_match_bitmap_from(tran_state.assets, .Sword, match_vector, weight_vector)
            switch entity.type {
            case .Nil: // NOTE(viktor): nothing
            case .Hero:
                push_bitmap(render_group, first_bitmap_from(tran_state.assets, AssetTypeId.Shadow), 0.5, color = {1, 1, 1, shadow_alpha})
                push_bitmap(render_group, cape_id,  1.6)
                push_bitmap(render_group, body_id,  1.6)
                push_bitmap(render_group, head_id,  1.6)
                push_bitmap(render_group, sword_id, 1.6)
                push_hitpoints(render_group, &entity, 1)

            case .Arrow:
                push_bitmap(render_group, first_bitmap_from(tran_state.assets, AssetTypeId.Shadow), 0.5, color = {1, 1, 1, shadow_alpha})
                push_bitmap(render_group, first_bitmap_from(tran_state.assets, AssetTypeId.Arrow), 0.1)

            case .Familiar: 
                entity.t_bob += dt
                if entity.t_bob > Tau {
                    entity.t_bob -= Tau
                }
                hz :: 4
                coeff := sin(entity.t_bob * hz)
                z := (coeff) * 0.3 + 0.3

                push_bitmap(render_group, first_bitmap_from(tran_state.assets, AssetTypeId.Shadow), 0.3, color = {1, 1, 1, 1 - shadow_alpha/2 * (coeff+1)})
                push_bitmap(render_group, head_id, 1, offset = {0, 1+z, 0}, color = {1, 1, 1, 0.5})

            case .Monster:
                monster_id := best_match_bitmap_from(tran_state.assets, .Monster, match_vector, weight_vector)

                push_bitmap(render_group, first_bitmap_from(tran_state.assets, AssetTypeId.Shadow), 0.75, color = {1, 1, 1, shadow_alpha})
                push_bitmap(render_group, monster_id, 1.5)
                push_hitpoints(render_group, &entity, 1.6)
            
            case .Wall:
                push_bitmap(render_group, first_bitmap_from(tran_state.assets, AssetTypeId.Rock), 1.5)
    
            case .Stairwell: 
                push_rectangle(render_group, 0,                              entity.walkable_dim, color = Blue)
                push_rectangle(render_group, {0, 0, entity.walkable_height}, entity.walkable_dim, color = Orange * {1, 1, 1, 0.5})
            
            case .Space: 
                when false {
                    for volume in entity.collision.volumes {
                        push_rectangle_outline(render_group, volume.dim.xy, volume.offset, Blue)
                    }
                }
            }
        }
    }
    render_group.transform.offset = 0
    
    when false {
        map_color := [?]v4{Red, Green, Blue}
    
        for it, it_index in tran_state.envs {
            lod := it.LOD[0]
            checker_dim: [2]i32 = 32
            
            row_on: b32
            for y: i32; y < lod.height; y += checker_dim.y {
                on := row_on
                for x: i32; x < lod.width; x += checker_dim.x {
                    color := map_color[it_index]
                    size := vec_cast(f32, checker_dim)
                    draw_rectangle(lod, vec_cast(f32, x, y) + size*0.5, size, on ? color : Black)
                    on = !on
                }
                row_on = !row_on
            }
        }
        tran_state.env_bottom.pz = -4
        tran_state.env_middle.pz =  0
        tran_state.env_top.pz    =  4
        
        state.time += input.delta_time
        
        angle :f32= state.time
        when !true {
            disp :f32= 0
        } else {
            disp := v2{cos(angle*2) * 100, cos(angle*4.1) * 50}
        }
        origin := screen_center
        scale :: 100
        x_axis := scale * v2{cos(angle), sin(angle)}
        y_axis := perpendicular(x_axis)
        
        if entry := coordinate_system(render_group); entry != nil {
            entry.origin = origin - x_axis*0.5 - y_axis*0.5 + disp
            entry.x_axis = x_axis
            entry.y_axis = y_axis
            
            assert(tran_state.test_diffuse.memory != nil)
            entry.texture = tran_state.test_diffuse
            entry.normal  = tran_state.test_normal
            
            entry.top    = tran_state.env_top
            entry.middle = tran_state.env_middle
            entry.bottom = tran_state.env_bottom
        }

        for it, it_index in tran_state.envs {
            size := vec_cast(f32, it.LOD[0].width, it.LOD[0].height) / 2
            
            if entry := coordinate_system(render_group); entry != nil {
                entry.x_axis = {size.x, 0}
                entry.y_axis = {0, size.y}
                entry.origin = 20 + (entry.x_axis + {20, 0}) * auto_cast it_index
                
                entry.texture = it.LOD[0]
                assert(it.LOD[0].memory != nil)
            }
        }

    }
    
    tiled_render_group_to_output(tran_state.high_priority_queue, render_group, buffer)
    
    // TODO(viktor): Make sure we hoist the camera update out to a place where the renderer
    // can know about the location of the camera at the end of the frame so there isn't
    // a frame of lag in camera updating compared to the hero.       
    end_sim(camera_sim_region, state)
    
    end_temporary_memory(sim_memory)
    end_temporary_memory(render_memory)
    
    check_arena(&state.world_arena)
    check_arena(&tran_state.arena)
}

// NOTE: at the moment this has to be a really fast function. It shall not be slower than a
// millisecond or so.
// TODO: reduce the pressure on the performance of this function by measuring
// TODO: Allow sample offsets here for more robust platform options
@(export)
output_sound_samples :: proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer){
    state      := cast(^State)          raw_data(memory.permanent_storage)
    tran_state := cast(^TransientState) raw_data(memory.transient_storage)
    
    output_playing_sounds(&state.mixer, &tran_state.arena, tran_state.assets, sound_buffer)
}

begin_task_with_memory :: proc(tran_state: ^TransientState) -> (result: ^TaskWithMemory) {
    for &task in tran_state.tasks {
        if !task.in_use {
            result = &task
            
            task.memory_flush = begin_temporary_memory(&task.arena)
            result.in_use = true
            
            break
        }
    }
    
    return result
}

end_task_with_memory :: #force_inline proc (task: ^TaskWithMemory) {
    end_temporary_memory(task.memory_flush)
    
    complete_previous_writes_before_future_writes()
    
    task.in_use = false
}

make_pyramid_normal_map :: proc(bitmap: Bitmap, roughness: f32) {
    for y in 0..<bitmap.height {
        for x in 0..<bitmap.width {
            inv_x := bitmap.width - x
            InvSqrtTwo :: 1.0 / SqrtTwo
            normal: v3 = { 0, 0, InvSqrtTwo }
            if x < y {
                if inv_x < y {
                    normal.y = InvSqrtTwo
                } else {
                    normal.x = -InvSqrtTwo
                }
            } else {
                if inv_x < y {
                    normal.x = InvSqrtTwo
                } else {
                    normal.y = -InvSqrtTwo
                }
            }
            
            color := 255 * V4((normal + 1) * 0.5, roughness)
            
            dst := &bitmap.memory[y*bitmap.pitch + x]
            dst^ = vec_cast(u8, color)
        }
    }
}

make_sphere_normal_map :: proc(buffer: Bitmap, roughness: f32, c:= v2{1,1}) {
    inv_size: v2 = 1 / (vec_cast(f32, buffer.width, buffer.height) - 1)
    
    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            bitmap_uv := inv_size * vec_cast(f32, x, y)
            nxy := c * ((2 * bitmap_uv) - 1)
            
            root_term := 1 - square(nxy.x) - square(nxy.y)

            InvSqrtTwo :: 1.0 / SqrtTwo
            normal := v3{0, InvSqrtTwo, InvSqrtTwo}
            if root_term >= 0 {
                nz := square_root(root_term)
                normal = V3(nxy, nz)
            }
            
            color := 255 * V4((normal + 1) * 0.5, roughness)
            
            dst := &buffer.memory[y*buffer.pitch + x]
            dst^ = vec_cast(u8, color)
        }
    }
}

make_sphere_diffuse_map :: proc(buffer: Bitmap, c := v2{1,1}) {
    inv_size: v2 = 1 / (vec_cast(f32, buffer.width, buffer.height) - 1)
    
    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            bitmap_uv := inv_size * vec_cast(f32, x, y)
            nxy := c * ((2 * bitmap_uv) - 1)
            
            root_term := 1 - square(nxy.x) - square(nxy.y)

            alpha: f32
            if root_term > 0 {
                alpha = 1
            }
            alpha *= 255
            base_color: v3 = 0
            color := V4(alpha * base_color, alpha)
            
            dst := &buffer.memory[y*buffer.pitch + x]
            dst^ = vec_cast(u8, color)
        }
    }
}

make_empty_bitmap :: proc(arena: ^Arena, dim: [2]i32, clear_to_zero: b32 = true) -> (result: Bitmap) {
    result = {
        memory = push(arena, ByteColor, cast(u64) (dim.x * dim.y), clear_to_zero = clear_to_zero, alignment = 16),
        width  = dim.x,
        height = dim.y,
        pitch  = dim.x,
    }
    
    return result
}

FillGroundChunkWork :: struct {
    task: ^TaskWithMemory,
    group: ^RenderGroup,
    buffer: Bitmap,
}

do_fill_ground_chunk_work : PlatformWorkQueueCallback : proc(data: rawpointer) {
    data := cast(^FillGroundChunkWork) data

    render_group_to_output(data.group, data.buffer)
    
    end_task_with_memory(data.task)
}

fill_ground_chunk :: proc(tran_state: ^TransientState, state: ^State, ground_buffer: ^GroundBuffer, p: WorldPosition){
    if task := begin_task_with_memory(tran_state); task != nil {
        work := push(&task.arena, FillGroundChunkWork)
        
        bitmap := &ground_buffer.bitmap
        bitmap.align_percentage = 0.5
        bitmap.width_over_height = 1
        
        buffer_size := state.world.chunk_dim_meters.xy
        assert(buffer_size.x == buffer_size.y)
        half_dim := buffer_size * 0.5

        render_group := make_render_group(&task.arena, tran_state.assets, 0)
        orthographic(render_group, {bitmap.width, bitmap.height}, cast(f32) (bitmap.width-2) / buffer_size.x)

        clear(render_group, Red)
            
        chunk_z := p.chunk.z
        for offset_y in i32(-1) ..= 1 {
            for offset_x in i32(-1) ..= 1 {
                chunk_x := p.chunk.x + offset_x
                chunk_y := p.chunk.y + offset_y
                
                center := vec_cast(f32, offset_x, offset_y) * buffer_size
                // TODO(viktor): look into wang hashing here or some other spatial seed generation "thing"
                series := seed_random_series(cast(u32) (133 * chunk_x + 593 * chunk_y + 329 * chunk_z))
                
                for _ in 0..<4 {
                    stamp := random_bitmap_from(tran_state.assets, .Grass, &series)
                    p := center + random_bilateral_2(&series, f32) * half_dim 
                    push_bitmap(render_group, stamp, 5, offset = V3(p, 0))
                }
            }
        }
        
        if all_assets_valid(render_group) {
            work.buffer = bitmap^
            work.group  = render_group
            work.task   = task
            ground_buffer.p = p
            
            PLATFORM_enqueue_work(tran_state.low_priority_queue, do_fill_ground_chunk_work, work)
        } else {
            end_task_with_memory(task)
        }
    }
}

make_null_collision :: proc(state: ^State) -> (result: ^EntityCollisionVolumeGroup) {
    result = push(&state.world_arena, EntityCollisionVolumeGroup)

    result^ = {}
    
    return result
}

make_simple_grounded_collision :: proc(state: ^State, dim: v3) -> (result: ^EntityCollisionVolumeGroup) {
    // TODO(viktor): NOT WORLD ARENA!!! change to using the fundamental types arena
    result = push(&state.world_arena, EntityCollisionVolumeGroup)
    result.volumes = push(&state.world_arena, EntityCollisionVolume, 1)
    
    result.total_volume = {
        dim = dim, 
        offset = {0, 0, 0.5*dim.z},
    }
    result.volumes[0] = result.total_volume

    return result
}

get_low_entity :: #force_inline proc(state: ^State, storage_index: StorageIndex) -> (entity: ^StoredEntity) #no_bounds_check {
    if storage_index > 0 && storage_index <= state.stored_entity_count {
        entity = &state.stored_entities[storage_index]
    }

    return entity
}

add_stored_entity :: proc(state: ^State, type: EntityType, p: WorldPosition) -> (index: StorageIndex, stored: ^StoredEntity) #no_bounds_check {
    assert(state.world != nil)
    
    index = state.stored_entity_count
    state.stored_entity_count += 1
    assert(state.stored_entity_count < len(state.stored_entities))
    stored = &state.stored_entities[index]
    stored.sim = { type = type }

    stored.sim.collision = state.null_collision
    stored.p = null_position()

    change_entity_location(&state.world_arena, state.world, index, stored, p)

    return index, stored
}

add_grounded_entity :: proc(state: ^State, type: EntityType, p: WorldPosition, collision: ^EntityCollisionVolumeGroup) -> (index: StorageIndex, stored: ^StoredEntity) #no_bounds_check {
    index, stored = add_stored_entity(state, type, p)
    stored.sim.collision = collision

    return index, stored
}

add_arrow :: proc(state: ^State) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_stored_entity(state, .Arrow, null_position())
    
    entity.sim.collision = state.arrow_collision
    entity.sim.flags += {.Moveable}

    return index, entity
}

add_wall :: proc(state: ^State, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Wall, p, state.wall_collision)

    entity.sim.flags += {.Collides}

    return index, entity
}

add_stairs :: proc(state: ^State, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Stairwell, p, state.stairs_collision)

    entity.sim.flags += {.Collides}
    entity.sim.walkable_height = state.typical_floor_height
    entity.sim.walkable_dim    = entity.sim.collision.total_volume.dim.xy

    return index, entity
}

add_player :: proc(state: ^State) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Hero, state.camera_p, state.player_collision)

    entity.sim.flags += {.Collides, .Moveable}

    init_hitpoints(entity, 3)

    arrow_index, _ := add_arrow(state)
    entity.sim.arrow.index = arrow_index

    if state.camera_following_index == 0 {
        state.camera_following_index = index
    }

    return index, entity
}

add_monster :: proc(state: ^State, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Monster, p, state.monstar_collision)

    entity.sim.flags += {.Collides, .Moveable}

    init_hitpoints(entity, 3)

    return index, entity
}

add_familiar :: proc(state: ^State, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Familiar, p, state.familiar_collision)

    entity.sim.flags += {.Moveable}

    return index, entity
}

add_standart_room :: proc(state: ^State, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Space, p, state.standart_room_collision)

    entity.sim.flags += { .Traversable }

    return index, entity
}

init_hitpoints :: proc(entity: ^StoredEntity, count: u32) {
    assert(count < len(entity.sim.hit_points))

    entity.sim.hit_point_max = count
    for &hit_point in entity.sim.hit_points[:count] {
        hit_point = { filled_amount = HitPointPartCount }
    }
}

add_collision_rule :: proc(state:^State, a, b: StorageIndex, should_collide: b32) {
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

clear_collision_rules :: proc(state:^State, storage_index: StorageIndex) {
    // TODO(viktor): need to make a better data structute that allows for
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
