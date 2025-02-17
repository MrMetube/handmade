package game

@common 
INTERNAL :: #config(INTERNAL, false)

/* TODO(viktor):
    - Is this still relevant? Dead Lock on Load when a lot of assets are loaded at once
    - Font Rendering Robustness
        - Kerning
    
    - :PointerArithmetic
        - change the types to a less c-mindset
        - or if necessary make utilities to these operations
    
    - Debug code
        - Diagramming
        - (a little gui) switches / sliders / etc
        - Draw tile chunks so we can verify that things are aligned / in the chunks we want them to be in / etc
        - Thread visualization 
    
    - Audio
        - Fix clicking Bug at the end of samples
    
    - Rendering
        - Check why the view frustum is not working quite right(too small) since <b7a4b31>
        - Get rid of "even" scan line notion?
        - Real projections with solid concept of project/unproject
        - Straighten out all coordinate systems!
            - Screen
            - World
            - Texture
        - Lighting
        - Final Optimization    
        
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

    - Animation
        - Skeletal animation

    - Implement multiple sim regions per frame
        - per-entity clocking
        - sim region merging?  for multiple players?
        - simple zoomed out view for testing

    PRODUCTION
    -> Game
        - Entity system
        
        - Rudimentary worldgen (no quality just "what sorts of things" we do
            - Map displays
            - Placement of background things
            - Connectivity?
            - Non-overlapping?

        - AI
            - Rudimentary monstar behaviour
            - Pathfinding
            - AI "storage"

      
    - Metagame / save game?
        - how do you enter a "save slot"?
        - persistent unlocks/etc.
        - Do we allow saved games? Probably yes, just only for "pausing"
        - continuous save for crash recovery?

*/

@common 
InputButton :: struct {
    half_transition_count: u32,
    ended_down:            b32,
}

@common 
InputController :: struct {
    // TODO: allow outputing vibration
    is_connected: b32,
    is_analog:    b32,

    stick_average: [2]f32,

    using _buttons_array_and_enum : struct #raw_union {
        buttons: [18]InputButton,
        using _buttons_enum : struct {
            stick_up , stick_down , stick_left , stick_right ,
            button_up, button_down, button_left, button_right,
            dpad_up  , dpad_down  , dpad_left  , dpad_right  ,

            start, back,
            shoulder_left, shoulder_right,
            thumb_left   , thumb_right:    InputButton,
        },
    },
}
#assert(size_of(InputController{}._buttons_array_and_enum.buttons) == size_of(InputController{}._buttons_array_and_enum._buttons_enum))

@common 
Input :: struct {
    delta_time: f32,

    mouse: struct {
        using _buttons_array_and_enum : struct #raw_union {
            buttons: [5]InputButton,
            using _buttons_enum : struct {
                left, 
                right, 
                middle,
                extra1, 
                extra2: InputButton,
            },
        },
        p:     v2,
        wheel: f32,
    },

    controllers: [5]InputController,
}
#assert(size_of(Input{}.mouse._buttons_array_and_enum.buttons) == size_of(Input{}.mouse._buttons_array_and_enum._buttons_enum))

@common 
GameMemory :: struct {
    reloaded_executable: b32,
    // NOTE: REQUIRED to be cleared to zero at startup
    permanent_storage: []u8,
    transient_storage: []u8,
    debug_storage:     []u8,

    high_priority_queue: ^PlatformWorkQueue,
    low_priority_queue:  ^PlatformWorkQueue,
    
    Platform_api: PlatformAPI,
}

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
    
    collision_rule_hash:       [256]^PairwiseCollsionRule,
    first_free_collision_rule: ^PairwiseCollsionRule,

    null_collision, 
    arrow_collision, 
    stairs_collision, 
    player_collision, 
    monstar_collision, 
    familiar_collision, 
    standart_room_collision,
    wall_collision: ^EntityCollisionVolumeGroup,

    effects_entropy: RandomSeries, // NOTE(viktor): this is randomness that does NOT effect the gameplay
    
    time: f32,
    
    next_particle: u32,
    particles:     [256]Particle,
    cells:         [ParticleCellSize][ParticleCellSize]ParticleCell,
}
// NOTE(viktor): https://graphics.stanford.edu/~seander/bithacks.html#DetermineIfPowerOf2
#assert( len(State{}.collision_rule_hash) & ( len(State{}.collision_rule_hash) - 1 ) == 0)

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
    envs: [3]EnvironmentMap,
}

ParticleCellSize :: 16

ParticleCell :: struct {
    density: f32,
    velocity_times_density: v3,
}

Particle :: struct {
    p:      v3,
    dp:     v3,
    ddp:    v3,
    color:  v4,
    dcolor: v4,
    
    bitmap_id: BitmapId,
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

ControlledHero :: struct {
    storage_index: StorageIndex,

    // NOTE(viktor): these are the controller requests for simulation
    ddp: v3,
    darrow: v2,
    dz: f32,
}

// NOTE(viktor): Platform specific structs
PlatformWorkQueue  :: struct{}
Platform: PlatformAPI

debug_get_game_assets_and_work_queue :: proc(memory: ^GameMemory) -> (assets: ^Assets, work_queue: ^PlatformWorkQueue) {
    tran_state := cast(^TransientState) raw_data(memory.transient_storage)
    if tran_state.is_initialized {
        assets = tran_state.assets
        work_queue = tran_state.high_priority_queue
    }
    
    return assets, work_queue
}

@export
update_and_render :: proc(memory: ^GameMemory, buffer: Bitmap, input: Input) {
    Platform = memory.Platform_api
    
    when INTERNAL {
        if memory.debug_storage == nil do return
        assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
        GlobalDebugMemory = memory
    }
        
    ground_buffer_size :: 512
    
    ////////////////////////////////////////////////
    // Permanent Initialization
    // 
    assert(size_of(State) <= len(memory.permanent_storage), "The State cannot fit inside the permanent memory")
    state := cast(^State) raw_data(memory.permanent_storage)
    if !state.is_initialized {
        // TODO(viktor): lets start partitioning our memory space
        // TODO(viktor): formalize the world arena and others being after the State in permanent storage
        // initialize the permanent arena first and allocate the state out of it
        // TODO(viktor): use a sub arena here
        init_arena(&state.world_arena, memory.permanent_storage[size_of(State):])
        
        state.world = push_struct(&state.world_arena, World)
        
        add_stored_entity(state, .Nil, null_position())
        state.typical_floor_height = 3

        world := state.world
        // TODO(viktor): REMOVE THIS
        pixels_to_meters :: 1.0 / 42.0
        chunk_dim_in_meters :f32= pixels_to_meters * ground_buffer_size
        init_world(world, {chunk_dim_in_meters, chunk_dim_in_meters, state.typical_floor_height})
        
        state.effects_entropy = seed_random_series(500)
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

        ////////////////////////////////////////////////
        // "World Gen"
        //
        
        chunk_position_from_tile_positon :: #force_inline proc(world: ^World, tile_x, tile_y, tile_z: i32, additional_offset := v3{}) -> (result: WorldPosition) {
            tile_size_in_meters  :: 1.5
            tile_depth_in_meters :: 3
            offset := v3{tile_size_in_meters, tile_size_in_meters, tile_depth_in_meters} * (vec_cast(f32, tile_x, tile_y, tile_z) + {0.5, 0.5, 0})
            
            result = map_into_worldspace(world, result, offset + additional_offset)
            
            assert(is_canonical(world, result.offset))
        
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
            familiar_p.y += random_between_i32(&series, 0, 1)
            add_familiar(state, chunk_position_from_tile_positon(world, familiar_p.x, familiar_p.y, familiar_p.z))
        }
         
        // TODO(viktor): do not use the world arena here
        init_mixer(&state.mixer, &state.world_arena)
        
        state.is_initialized = true
    }

    ////////////////////////////////////////////////
    // Transient Initialization
    //
    assert(size_of(TransientState) <= len(memory.transient_storage), "The Transient State cannot fit inside the permanent memory")
    tran_state := cast(^TransientState) raw_data(memory.transient_storage)
    if !tran_state.is_initialized {
        init_arena(&tran_state.arena, memory.transient_storage[size_of(TransientState):])

        tran_state.high_priority_queue = memory.high_priority_queue
        tran_state.low_priority_queue  = memory.low_priority_queue
        
        for &task in tran_state.tasks {
            task.in_use = false
            sub_arena(&task.arena, &tran_state.arena, 2 * Megabyte)
        }

        tran_state.assets = make_assets(&tran_state.arena, 64 * Megabyte, tran_state)
        
        state.mixer.master_volume = 0.1
        
        // TODO(viktor): pick a real number here!
        tran_state.ground_buffers = push(&state.world_arena, GroundBuffer, 256)
        for &ground_buffer in tran_state.ground_buffers {
            ground_buffer.p = null_position()
            ground_buffer.bitmap = make_empty_bitmap(&tran_state.arena, ground_buffer_size, false)
        }
        
        test_size: [2]i32= 256
        tran_state.test_diffuse = make_empty_bitmap(&tran_state.arena, test_size, false)
        tran_state.test_normal  = make_empty_bitmap(&tran_state.arena, test_size, false)
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
    
    if memory.reloaded_executable {
        for &ground_buffer in tran_state.ground_buffers {
            ground_buffer.p = null_position()
        }
        
        make_sphere_normal_map(tran_state.test_normal, 0)
        make_sphere_diffuse_map(tran_state.test_diffuse)
    }
    
    ////////////////////////////////////////////////
    // Input
    // 

    world := state.world
    
    when DEBUG_SoundPanningWithMouse {
        // NOTE(viktor): test sound panning with the mouse 
        music_volume := input.mouse.p - vec_cast(f32, buffer.width, buffer.height) * 0.5
        if state.music == nil {
            if state.mixer.first_playing_sound == nil {
                play_sound(&state.mixer, first_sound_from(tran_state.assets, .Music))
            }
            state.music = state.mixer.first_playing_sound
        }
        change_volume(&state.mixer, state.music, 0.01, music_volume)
    }
    
    when DEBUG_SoundPitchingWithMouse {
        // NOTE(viktor): test sound panning with the mouse 
        if state.music == nil {
            if state.mixer.first_playing_sound == nil {
                play_sound(&state.mixer, first_sound_from(tran_state.assets, .Music))
            }
            state.music = state.mixer.first_playing_sound
        }
        
        delta: f32
        if was_pressed(input.mouse_middle) {
            if input.mouse_position.x > 10  do delta = 0.1
            if input.mouse_position.x < -10 do delta = -0.1
            change_pitch(&state.mixer, state.music, state.music.d_sample + delta)
        }
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
            
            when DEBUG_HeroJumping {
                if controller.start.ended_down {
                    con_hero.dz = 2
                }
            }
            
            con_hero.darrow = {}
            if controller.button_up.ended_down {
                con_hero.darrow =  {0, 1}
            }
            if controller.button_down.ended_down {
                con_hero.darrow = -{0, 1}
            }
            if controller.button_left.ended_down {
                con_hero.darrow = -{1, 0}
            }
            if controller.button_right.ended_down {
                con_hero.darrow =  {1, 0}
            }
            
            if con_hero.darrow != 0 {
                play_sound(&state.mixer, random_sound_from(tran_state.assets, .Hit, &state.effects_entropy), 0.2)
            }
        }
    }

    ////////////////////////////////////////////////
    // Update and Render
    // 
    
    when DEBUG_TestWeirdScreenSizes {
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
    
    render_group := make_render_group(&tran_state.arena, tran_state.assets, 4 * Megabyte, false)
    begin_render(render_group)

    // orthographic(render_group, buffer_size, 1)
    // clear(render_group, Red)
    // push_rectangle(render_group, rectangle_center_diameter(input.mouse.p, 6), Blue)
    
    focal_length, distance_above_ground : f32 = 0.6, 8
    perspective(render_group, buffer_size, meters_to_pixels_for_monitor, focal_length, distance_above_ground)
    
    clear(render_group, Red)
    
    
    for &ground_buffer in tran_state.ground_buffers {
        if is_valid(ground_buffer.p) {
            offset := world_difference(world, ground_buffer.p, state.camera_p)
            
            if abs(offset.z) == 0 {
                bitmap := ground_buffer.bitmap
                bitmap.align_percentage = 0
                
                ground_chunk_size := world.chunk_dim_meters.x
                push_bitmap_raw(render_group, bitmap, ground_chunk_size, offset)
                
                when DEBUG_ShowGroundChunkBounds {
                    push_rectangle_outline(render_group, offset.xy, ground_chunk_size, Yellow)
                }
            }
        }
    }
    
    
    screen_bounds := get_camera_rectangle_at_target(render_group)
    camera_bounds := Rectangle3{
        V3(screen_bounds.min, -0.5 * state.typical_floor_height), 
        V3(screen_bounds.max, 4 * state.typical_floor_height),
    }

    {
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
    
    when DEBUG_UseDebugCamera {
        push_rectangle_outline(render_group, rectangle_center_diameter(v2{}, rectangle_get_diameter(screen_bounds)),                         Yellow,0.1)
        push_rectangle_outline(render_group, rectangle_center_diameter(v2{}, rectangle_get_diameter(camera_sim_region.bounds).xy),           Blue,  0.2)
        push_rectangle_outline(render_group, rectangle_center_diameter(v2{}, rectangle_get_diameter(camera_sim_region.updatable_bounds).xy), Green, 0.2)
    }
    
    camera_p := world_difference(world, state.camera_p, sim_origin)
        
    for &entity in camera_sim_region.entities[:camera_sim_region.entity_count] {
        if entity.updatable { // TODO(viktor):  move this out into entity.odin
            dt := input.delta_time;

            // TODO(viktor): Probably indicates we want to separate update ann render for entities sometime soon?
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
            
            ////////////////////////////////////////////////
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
                closest_hero_dsq := square(f32(10))

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
                
                when DEBUG_FamiliarFollowsHero {
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
                if random_unilateral(&state.effects_entropy, f32) > 0.98 {
                    entity.facing_direction += Pi
                    entity.facing_direction = mod(entity.facing_direction, Tau)
                } 
            case .Wall:
            case .Stairwell: 
            case .Space: 
            }

            if entity.flags & {.Nonspatial, .Moveable} == {.Moveable} {
                move_entity(state, camera_sim_region, &entity, ddp, move_spec, input.delta_time)
            }

            render_group.transform.offset = get_entity_ground_point(&entity)

            ////////////////////////////////////////////////
            // Post-physics entity work
            facing_match   := #partial AssetVector{ .FacingDirection = entity.facing_direction }
            facing_weights := #partial AssetVector{.FacingDirection = 1 }
            
            head_id  := best_match_bitmap_from(tran_state.assets, .Head, facing_match, facing_weights)
            switch entity.type {
            case .Nil: // NOTE(viktor): nothing
            case .Hero:
                cape_id  := best_match_bitmap_from(tran_state.assets, .Cape, facing_match, facing_weights)
                sword_id := best_match_bitmap_from(tran_state.assets, .Sword, facing_match, facing_weights)
                body_id  := best_match_bitmap_from(tran_state.assets, .Body, facing_match, facing_weights)
                push_bitmap(render_group, first_bitmap_from(tran_state.assets, AssetTypeId.Shadow), 0.5, color = {1, 1, 1, shadow_alpha})
                push_bitmap(render_group, cape_id,  1.6)
                push_bitmap(render_group, body_id,  1.6)
                push_bitmap(render_group, head_id,  1.6)
                push_bitmap(render_group, sword_id, 1.6)
                push_hitpoints(render_group, &entity, 1)
                
                when DEBUG_ParticleSystemTest { 
                    ////////////////////////////////////////////////
                    // NOTE(viktor): Particle system test
                    font_id := first_font_from(tran_state.assets, .Font)
                    font := get_font(tran_state.assets, font_id, render_group.generation_id)
                    if font == nil {
                        load_font(tran_state.assets, font_id, false)
                    } else {
                        font_info := get_font_info(tran_state.assets, font_id)
                        for _ in 0..<4 {
                            particle := &state.particles[state.next_particle]
                            state.next_particle += 1
                            if state.next_particle >= len(state.particles) {
                                state.next_particle = 0
                            }
                            particle.p = {random_bilateral(&state.effects_entropy, f32)*0.1, 0, 0}
                            particle.dp = {random_bilateral(&state.effects_entropy, f32)*0, (random_unilateral(&state.effects_entropy, f32)*0.4)+7, 0}
                            particle.ddp = {0, -9.8, 0}
                            particle.color = V4(random_unilateral_3(&state.effects_entropy, f32), 1)
                            particle.dcolor = {0,0,0,-0.2}
                            
                            nothings := "NOTHINGS"
                            
                            r := random_choice_data(&state.effects_entropy, transmute([]u8) nothings)^
                            
                            particle.bitmap_id = get_bitmap_for_glyph(font, font_info, cast(rune) r)
                        }
                        
                        for &row in state.cells {
                            zero(row[:])
                        }
                        
                        grid_scale :f32= 0.3
                        grid_origin:= v3{-0.5 * grid_scale * ParticleCellSize, 0, 0}
                        for particle in state.particles {
                            p := ( particle.p - grid_origin ) / grid_scale
                            x := truncate(p.x)
                            y := truncate(p.y)
                            
                            x = clamp(x, 1, ParticleCellSize-2)
                            y = clamp(y, 1, ParticleCellSize-2)
                            
                            cell := &state.cells[y][x]
                            
                            density: f32 = particle.color.a
                            cell.density                += density
                            cell.velocity_times_density += density * particle.dp
                        }
                        
                        when DEBUG_ParticleGrid {
                            for row, y in state.cells {
                                for cell, x in row {
                                    alpha := clamp_01(0.1 * cell.density)
                                    color := v4{1,1,1, alpha}
                                    position := (vec_cast(f32, x, y, 0) + {0.5,0.5,0})*grid_scale + grid_origin
                                    push_rectangle(render_group, rectangle_center_diameter(position.xy, grid_scale), color)
                                }
                            }
                        }
                        
                        for &particle in state.particles {
                            p := ( particle.p - grid_origin ) / grid_scale
                            x := truncate(p.x)
                            y := truncate(p.y)
                            
                            x = clamp(x, 1, ParticleCellSize-2)
                            y = clamp(y, 1, ParticleCellSize-2)
                            
                            cell := &state.cells[y][x]
                            cell_l := &state.cells[y][x-1]
                            cell_r := &state.cells[y][x+1]
                            cell_u := &state.cells[y+1][x]
                            cell_d := &state.cells[y-1][x]
                            
                            dispersion: v3
                            dc : f32 = 0.3
                            dispersion += dc * (cell.density - cell_l.density) * v3{-1, 0, 0}
                            dispersion += dc * (cell.density - cell_r.density) * v3{ 1, 0, 0}
                            dispersion += dc * (cell.density - cell_d.density) * v3{ 0,-1, 0}
                            dispersion += dc * (cell.density - cell_u.density) * v3{ 0, 1, 0}
                            
                            particle_ddp := particle.ddp + dispersion
                            // NOTE(viktor): simulate particle forward in time
                            particle.p     += particle_ddp * 0.5 * square(input.delta_time) + particle.dp * input.delta_time
                            particle.dp    += particle_ddp * input.delta_time
                            particle.color += particle.dcolor * input.delta_time
                            // TODO(viktor): should we just clamp colors in the renderer?
                            color := clamp_01(particle.color)
                            if color.a > 0.9 {
                                color.a = 0.9 * clamp_01_to_range(1, color.a, 0.9)
                            }

                            if particle.p.y < 0 {
                                coefficient_of_restitution :f32= 0.3
                                coefficient_of_friction :f32= 0.7
                                particle.p.y *= -1
                                particle.dp.y *= -coefficient_of_restitution
                                particle.dp.x *= coefficient_of_friction
                            }
                            // NOTE(viktor): render the particle
                            push_bitmap(render_group, particle.bitmap_id, 0.4, particle.p, color)
                        }
                    }             
                }

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
                monster_id := best_match_bitmap_from(tran_state.assets, .Monster, facing_match, facing_weights)

                push_bitmap(render_group, first_bitmap_from(tran_state.assets, AssetTypeId.Shadow), 0.75, color = {1, 1, 1, shadow_alpha})
                push_bitmap(render_group, monster_id, 1.5)
                push_hitpoints(render_group, &entity, 1.6)
            
            case .Wall:
                push_bitmap(render_group, first_bitmap_from(tran_state.assets, AssetTypeId.Rock), 1.5)
    
            case .Stairwell: 
                push_rectangle(render_group, rectangle_center_diameter(v2{0, 0}, entity.walkable_dim), Blue)
            
            case .Space: 
                when DEBUG_ShowSpaceBounds {
                    for volume in entity.collision.volumes {
                        push_rectangle_outline(render_group, volume.offset.xy, volume.size.xy, Blue)
                    }
                }
            }
        }
        
        when DEBUG_ShowEntityBounds {
            for volume in entity.collision.volumes {
                local_mouse_p := unproject_with_transform(render_group.transform, input.mouse.p)
                
                if local_mouse_p.x >= volume.min.x && local_mouse_p.x < volume.max.x && local_mouse_p.y >= volume.min.y && local_mouse_p.y < volume.max.y  {
                    color := Yellow
                    push_rectangle_outline(render_group, volume, color, 0.05)
                    
                    stored_entity := &state.stored_entities[entity.storage_index]
                    begin_data_block(stored_entity)
                        record_debug_event_value(entity.updatable)
                        record_debug_event_value(entity.p)
                        record_debug_event_value(entity.dp)
                        record_debug_event_value(first_bitmap_from(tran_state.assets, .Body))
                        record_debug_event_value(entity.distance_limit)
                    end_data_block()
                }
            }
        }
    }
    render_group.transform.offset = 0
    
    when DEBUG_CoordinateSystemTest { 
        ////////////////////////////////////////////////
        // NOTE(viktor): Coordinate System and Environment Map Test
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
                    draw_rectangle(lod, rectangle_min_diameter(vec_cast(f32, x, y), size), on ? color : Black, {min(i32), max(i32)}, true)
                    draw_rectangle(lod, rectangle_min_diameter(vec_cast(f32, x, y), size), on ? color : Black, {min(i32), max(i32)}, false)
                    on = !on
                }
                row_on = !row_on
            }
        }
        tran_state.envs[0].pz = -4
        tran_state.envs[1].pz =  0
        tran_state.envs[2].pz    =  4
        
        state.time += input.delta_time
        
        angle :f32= state.time
        when !true {
            disp :f32= 0
        } else {
            disp := v2{cos(angle*2) * 100, cos(angle*4.1) * 50}
        }
        origin := vec_cast(f32, buffer_size) * 0.5
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
            
            entry.top    = tran_state.envs[2]
            entry.middle = tran_state.envs[1]
            entry.bottom = tran_state.envs[0]
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
    end_render(render_group)
    
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
@export 
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
            
            dst := &bitmap.memory[y * bitmap.width + x]
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
            
            dst := &buffer.memory[y * buffer.width + x]
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
            
            dst := &buffer.memory[y * buffer.width + x]
            dst^ = vec_cast(u8, color)
        }
    }
}

make_empty_bitmap :: proc(arena: ^Arena, dim: [2]i32, clear_to_zero: b32 = true) -> (result: Bitmap) {
    result = {
        memory = push(arena, ByteColor, (dim.x * dim.y), clear_to_zero = clear_to_zero, alignment = 32),
        width  = dim.x,
        height = dim.y,
        width_over_height = safe_ratio_1(cast(f32) dim.x,  cast(f32) dim.y),
    }
    
    return result
}

FillGroundChunkWork :: struct {
    task: ^TaskWithMemory,
    
    tran_state: ^TransientState, 
    state: ^State, 
    ground_buffer: ^GroundBuffer, 
    p: WorldPosition,
}

do_fill_ground_chunk_work : PlatformWorkQueueCallback : proc(data: rawpointer) {
    timed_function()
    work := cast(^FillGroundChunkWork) data

    
    bitmap := &work.ground_buffer.bitmap
    bitmap.align_percentage = 0.5
    bitmap.width_over_height = 1
    
    buffer_size := work.state.world.chunk_dim_meters.xy
    assert(buffer_size.x == buffer_size.y)
    half_dim := buffer_size * 0.5

    render_group := make_render_group(&work.task.arena, work.tran_state.assets, 0, true)
    begin_render(render_group)
    
    orthographic(render_group, {bitmap.width, bitmap.height}, cast(f32) (bitmap.width-2) / buffer_size.x)

    clear(render_group, Red)
        
    chunk_z := work.p.chunk.z
    for offset_y in i32(-1) ..= 1 {
        for offset_x in i32(-1) ..= 1 {
            chunk_x := work.p.chunk.x + offset_x
            chunk_y := work.p.chunk.y + offset_y
            
            center := vec_cast(f32, offset_x, offset_y) * buffer_size
            // TODO(viktor): look into wang hashing here or some other spatial seed generation "thing"
            series := seed_random_series(cast(u32) (463 * chunk_x + 311 * chunk_y + 185 * chunk_z) + 99)
            
            for _ in 0..<120 {
                stamp := random_bitmap_from(work.tran_state.assets, .Grass, &series)
                p := center + random_bilateral_2(&series, f32) * half_dim 
                push_bitmap(render_group, stamp, 5, offset = V3(p, 0))
            }
        }
    }
    
    assert(all_assets_valid(render_group))
    
    render_group_to_output(render_group, bitmap^)
    
    end_render(render_group)
    
    end_task_with_memory(work.task)
}

fill_ground_chunk :: proc(tran_state: ^TransientState, state: ^State, ground_buffer: ^GroundBuffer, p: WorldPosition){
    if task := begin_task_with_memory(tran_state); task != nil {
        work := push(&task.arena, FillGroundChunkWork)
            
        work^ = {
            task = task,
    
            tran_state = tran_state, 
            state = state,
            ground_buffer = ground_buffer, 
            p = p,
        }
        
        ground_buffer.p = p
        
        Platform.enqueue_work(tran_state.low_priority_queue, do_fill_ground_chunk_work, work)
    }
}

make_null_collision :: proc(state: ^State) -> (result: ^EntityCollisionVolumeGroup) {
    result = push(&state.world_arena, EntityCollisionVolumeGroup)

    result^ = {}
    
    return result
}

make_simple_grounded_collision :: proc(state: ^State, size: v3) -> (result: ^EntityCollisionVolumeGroup) {
    // TODO(viktor): NOT WORLD ARENA!!! change to using the fundamental types arena
    result = push(&state.world_arena, EntityCollisionVolumeGroup)
    result.volumes = push(&state.world_arena, Rectangle3, 1)
    
    result.total_volume = rectangle_center_diameter(v3{0, 0, 0.5*size.z}, size)
    result.volumes[0] = result.total_volume

    return result
}