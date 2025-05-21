package game

World :: struct {
    arena: Arena,
    
    ////////////////////////////////////////////////
    // World specific    
    chunk_dim_meters: v3,
    
    // @todo(viktor): chunk_hash should probably switch to pointers IF
    // tile_entity_blocks continue to be stored en masse in the tile chunk!
    chunk_hash: [4096]^Chunk,
    first_free: ^WorldEntityBlock,
    
    ////////////////////////////////////////////////
    // General
    typical_floor_height: f32,
    
    // @todo(viktor): Should we allow split-screen?
    camera_following_id: EntityId,
    camera_p :           WorldPosition,
    camera_offset:       v3,
    // @todo(viktor): Should which players joined be part of the general state?
    controlled_heroes: [len(Input{}.controllers)]ControlledHero,
    
    collision_rule_hash:       [256]^PairwiseCollsionRule,
    first_free_collision_rule: ^PairwiseCollsionRule,
    
    null_collision, 
    wall_collision,    
    floor_collision,
    stairs_collision, 
    hero_body_collision, 
    hero_head_collision, 
    monstar_collision, 
    familiar_collision: ^EntityCollisionVolumeGroup, 
    
    // @note(viktor): Only for testing, use Input.delta_time and your own t-values.
    time: f32,
    
    // @todo(viktor): This could just be done in temporary memory.
    // @todo(viktor): This should catch bugs, remove once satisfied.
    creation_buffer_index: u32,
    creation_buffer:       [4]Entity,
    last_used_entity_id:   EntityId, // @todo(viktor): Worry about wrapping - Free list of ids?
    
    general_entropy: RandomSeries,
    
    first_free_chunk: ^Chunk,
    first_free_block: ^WorldEntityBlock,
}

// @note(viktor): https://graphics.stanford.edu/~seander/bithacks.html#DetermineIfPowerOf2
#assert( len(World{}.collision_rule_hash) & ( len(World{}.collision_rule_hash) - 1 ) == 0)

Chunk :: #type SingleLinkedList(ChunkData)
ChunkData :: struct {
    chunk: [3]i32,
    
    first_block: ^WorldEntityBlock,
}

// @todo(viktor): Could make this just Chunk and then allow multiple tile chunks per X/Y/Z
WorldEntityBlock :: #type SingleLinkedList(WorldEntityBlockData)
WorldEntityBlockData :: struct {
    entity_count: u32,
    // @note(viktor): entity_data'count =^= size_of(Entity) * entity_count  for now, because there is no compression
    entity_data: FixedArray(1 << 14, u8), // :DisjointArray of Entity Data and inlined member arrays or specialized :Arena
}

WorldPosition :: struct {
    // @todo(viktor): It seems like we have to store ChunkX/Y/Z with each
    // entity because even though the sim region gather doesn't need it
    // at first, and we could get by without it, but entity references pull
    // in entities WITHOUT going through their world_chunk, and thus
    // still need to know the ChunkX/Y/Z
    chunk:  [3]i32,
    offset: v3,
}

chunk_position_from_tile_positon :: proc(world: ^World, tile_x, tile_y, tile_z: i32, additional_offset := v3{}) -> (result: WorldPosition) {
    // @volatile
    tile_size_in_meters  :: 1.5
    tile_depth_in_meters := world.typical_floor_height
    
    offset := v3{tile_size_in_meters, tile_size_in_meters, tile_depth_in_meters} * (vec_cast(f32, tile_x, tile_y, tile_z) + {0.5, 0.5, 0})
    
    result = map_into_worldspace(world, result, offset + additional_offset)
    
    assert(is_canonical(world, result.offset))

    return result
}

init_world :: proc(world: ^World, parent_arena: ^Arena) {
    sub_arena(&world.arena, parent_arena, arena_remaining_size(parent_arena))

    world.last_used_entity_id = cast(EntityId) ReservedBrainId.FirstFree
    
    world.general_entropy = seed_random_series(123)
    
    pixels_to_meters :: 1.0 / 42.0
    chunk_dim_in_meters :f32= pixels_to_meters * 256
    world.typical_floor_height = 3
    
    world.chunk_dim_meters = v3{chunk_dim_in_meters, chunk_dim_in_meters, world.typical_floor_height}
    
    world.first_free = nil
    
    ////////////////////////////////////////////////
    
    tiles_per_screen :: [2]i32{17,9}
    
    tile_size_in_meters :: 1.5
    world.null_collision     = make_null_collision(world)
    
    world.wall_collision      = make_simple_grounded_collision(world, {tile_size_in_meters, tile_size_in_meters, world.typical_floor_height})
    world.stairs_collision    = make_simple_grounded_collision(world, {tile_size_in_meters, tile_size_in_meters * 2, world.typical_floor_height + 0.1})
    world.hero_body_collision = make_simple_grounded_collision(world, {0.75, 0.4, 0.6})
    world.hero_head_collision = make_simple_grounded_collision(world, {0.75, 0.4, 0.5}, .7)
    world.monstar_collision   = make_simple_grounded_collision(world, {0.75, 0.75, 1.5})
    world.familiar_collision  = make_simple_grounded_collision(world, {0.5, 0.5, 1})
    
    world.floor_collision    = make_simple_floor_collision(world, v3{tile_size_in_meters, tile_size_in_meters, world.typical_floor_height})
    
    ////////////////////////////////////////////////
    // "World Gen"
    
    screen_base: [3]i32
    
    new_camera_p := chunk_position_from_tile_positon(
        world,
        screen_base.x * tiles_per_screen.x + tiles_per_screen.x/2,
        screen_base.y * tiles_per_screen.y + tiles_per_screen.y/2,
        screen_base.z,
    )
    
    world.camera_p = new_camera_p
    
    series := seed_random_series(0)
    monster_p  := new_camera_p.chunk + {10,5,0}
    add_monster(world,  chunk_position_from_tile_positon(world, monster_p.x, monster_p.y, monster_p.z))
    for _ in 0..< 1 {
        familiar_p := new_camera_p.chunk
        familiar_p.x += random_between_i32(&series, 0, 14)
        familiar_p.y += random_between_i32(&series, 0, 1)
        add_familiar(world, chunk_position_from_tile_positon(world, familiar_p.x, familiar_p.y, familiar_p.z))
    }
    
    screen_row, screen_col, tile_z := screen_base.x, screen_base.y, screen_base.z
    created_stair: b32
    door_left, door_right: b32
    door_top, door_bottom: b32
    stair_up, stair_down:  b32
    for room in u32(0) ..< 8 {
        when !true {
            choice := random_choice(&series, 2)
        } else {
            choice := 1
        }
        
        created_stair = false
        switch(choice) {
        case 0: door_right  = true
        case 1: door_top    = true
        // case 2: stair_down  = true
        // case 3: stair_up    = true
        // case 4: door_left   = true
        // case 5: door_bottom = true
        }
        
        created_stair = stair_down || stair_up
        need_to_place_stair := created_stair
        
        room_x := screen_col * tiles_per_screen.x
        room_y := screen_row * tiles_per_screen.y
        
        for tile_y in 0..< tiles_per_screen.y {
            for tile_x in 0 ..< tiles_per_screen.x {
                col := tile_x + room_x
                row := tile_y + room_y
                
                should_be_wall: b32
                if tile_x == 0                    && (!door_left  || tile_y != tiles_per_screen.y / 2) {
                    should_be_wall = true
                }
                if tile_x == tiles_per_screen.x-1 && (!door_right || tile_y != tiles_per_screen.y / 2) {
                    should_be_wall = true
                }

                if tile_y == 0                    && (!door_bottom || tile_x != tiles_per_screen.x / 2) {
                    should_be_wall = true
                }
                if tile_y == tiles_per_screen.y-1 && (!door_top    || tile_x != tiles_per_screen.x / 2) {
                    should_be_wall = true
                }
                
                if should_be_wall {
                    add_wall(world, chunk_position_from_tile_positon(world, col, row, tile_z))
                } else if need_to_place_stair {
                    add_stairs(world, chunk_position_from_tile_positon(world, 
                        room % 2 == 0 ? 5 : 10 - room_x, 
                        3                      - room_y, 
                        stair_down ? tile_z-1 : tile_z,
                    ))
                    need_to_place_stair = false
                }
                
            }
        }
        
        p := chunk_position_from_tile_positon(world, room_x + tiles_per_screen.x/2, room_y + tiles_per_screen.y/2, tile_z)
        add_standart_room(world, p) 
        
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
}

update_and_render_world :: proc(world: ^World, tran_state: ^TransientState, render_group: ^RenderGroup, input: Input) {
    dt := input.delta_time * TimestepPercentage/100.0
    timed_function()
    
    monitor_width_in_meters :: 0.635
    buffer_size := [2]i32{render_group.commands.width, render_group.commands.height}
    meters_to_pixels_for_monitor := cast(f32) buffer_size.x * monitor_width_in_meters
    
    focal_length, distance_above_ground : f32 = 0.6, 10
    perspective(render_group, buffer_size, meters_to_pixels_for_monitor, focal_length, distance_above_ground)
    
    clear(render_group, DarkBlue)
    
    screen_bounds := get_camera_rectangle_at_target(render_group)
    camera_bounds := rectangle_min_max(
        V3(screen_bounds.min, -0.5 * world.typical_floor_height), 
        V3(screen_bounds.max, 4 * world.typical_floor_height),
    )
    
    sim_memory := begin_temporary_memory(&tran_state.arena)
    // @todo(viktor): by how much should we expand the sim region?
    // @todo(viktor): do we want to simulate upper floors, etc?
    sim_bounds := rectangle_add_radius(camera_bounds, v3{15, 15, 15})
    sim_origin := world.camera_p
    sim_region := begin_sim(&tran_state.arena, world, sim_origin, sim_bounds, dt)
    
    camera_p := world.camera_offset + world_distance(world, world.camera_p, sim_origin)
    
    if ShowRenderAndSimulationBounds {
        transform := default_flat_transform()
        transform.offset -= camera_p
        transform.sort_bias = 10000
        push_rectangle_outline(render_group, rectangle_center_dimension(v2{}, rectangle_get_dimension(screen_bounds)),                         transform, Orange,0.1)
        push_rectangle_outline(render_group, rectangle_center_dimension(v2{}, rectangle_get_dimension(sim_region.bounds).xy),           transform, Blue,  0.2)
        push_rectangle_outline(render_group, rectangle_center_dimension(v2{}, rectangle_get_dimension(sim_region.updatable_bounds).xy), transform, Green, 0.2)
    }
    
    ////////////////////////////////////////////////
    // Look to see if any players are trying to join
    
    for controller, controller_index in input.controllers {
        con_hero := &world.controlled_heroes[controller_index]
        if con_hero.brain_id == 0 {
            if was_pressed(controller.start) {
                standing_on, ok := get_closest_traversable(sim_region, camera_p, {.Unoccupied} )
                assert(ok) // @todo(viktor): GameUI that tells you there is no safe space...
                // maybe keep trying on subsequent frames?
                
                brain_id := cast(BrainId) controller_index + cast(BrainId) ReservedBrainId.FirstHero
                con_hero^ = { brain_id = brain_id }
                add_hero(world, sim_region, standing_on, brain_id)
            }
        }
    }

    ////////////////////////////////////////////////
    // Run all brains
    
    for &brain in slice(sim_region.brains) {
        execute_brain(input, sim_region, &brain)
    }
    
    ////////////////////////////////////////////////
    // Simulate all entities
    
    for &entity in slice(sim_region.entities) {
        // @todo(viktor): we dont really have a way to unique-ify these :(
        debug_id := debug_pointer_id(cast(pmm) cast(umm) entity.id)
        if debug_requested(debug_id) { 
            debug_begin_data_block("Game/Entity")
        }
        defer if debug_requested(debug_id) {
            debug_end_data_block()
        }
        
        // @todo(viktor): set this at contruction
        entity.x_axis = {1,0}
        entity.y_axis = {0,1}
        
        if entity.updatable { // @todo(viktor):  move this out into entity.odin
            ////////////////////////////////////////////////
            // Movement
            
            if entity.movement_mode == .Planted {
                if entity.occupying.entity.pointer != nil {
                    entity.p = get_sim_space_traversable(entity.occupying).p
                }
            }
            
            switch entity.movement_mode {
              case .Planted: // Nothing
              case .Hopping:
                t_jump :: 0.1
                t_thrust :: 0.8
                if entity.t_movement < t_thrust {
                    entity.ddt_bob -= 60
                }
                
                occupying := get_sim_space_traversable(entity.occupying).p
                came_from := get_sim_space_traversable(entity.came_from).p
                pt := occupying
                
                if t_jump <= entity.t_movement {
                    
                    t := clamp_01_to_range(t_jump, entity.t_movement, 1)
                    entity.t_bob = sin(t * Pi) * 0.1
                    entity.p = lerp(came_from, occupying, entity.t_movement)
                    entity.dp = 0
                    
                    pf := came_from
                    
                    // :ZHandling
                    height := v3{0, 0.3, 0.3}
                    
                    c := pf
                    a := -4 * height
                    b := pt - pf - a
                    entity.p = a * square(t) + b * t + c
                }
                
                if entity.t_movement >= 1 {
                    entity.movement_mode = .Planted
                    entity.dt_bob = -3
                    entity.p = pt
                    entity.came_from = entity.occupying
                }
                
                hop_duration :f32: 0.2
                entity.t_movement += dt * (1 / hop_duration)
                
                if entity.t_movement >= 1 {
                    entity.t_movement = 1
                }
            }
            
            entity.ddt_bob += 100 * (0-entity.t_bob) + 12 * (0-entity.dt_bob)
            entity.t_bob += entity.ddt_bob*square(dt) + entity.dt_bob*dt
            entity.dt_bob += 0.5*entity.ddt_bob*dt
            
            if .Moveable in entity.flags {
                move_entity(sim_region, &entity, entity.ddp, entity.move_spec, dt)
            }
            
            ////////////////////////////////////////////////
            // Rendering
            
            camera_relative_ground := get_entity_ground_point(&entity) - camera_p
            fade_top_end      :=  0.75 * world.typical_floor_height
            fade_top_start    :=  0.5  * world.typical_floor_height
            fade_bottom_start := -1    * world.typical_floor_height
            fade_bottom_end   := -1.5  * world.typical_floor_height 
            
            render_group.global_alpha = 1
            if camera_relative_ground.z > fade_top_start {
                render_group.global_alpha = clamp_01_to_range(fade_top_end, camera_relative_ground.z, fade_top_start)
            } else if camera_relative_ground.z < fade_bottom_start {
                render_group.global_alpha = clamp_01_to_range(fade_bottom_end, camera_relative_ground.z, fade_bottom_start)
            }
            
            // @todo(viktor): this is incorrect, should be computed after update
            shadow_alpha := 1 - 0.5 * entity.p.z
            if shadow_alpha < 0 {
                shadow_alpha = 0.0
            }
            
            facing_match   := #partial AssetVector{ .FacingDirection = entity.facing_direction }
            facing_weights := #partial AssetVector{ .FacingDirection = 1 }
            head_id   := best_match_bitmap_from(tran_state.assets, .Head,  facing_match, facing_weights)
            
            shadow_id := first_bitmap_from(tran_state.assets, AssetTypeId.Shadow)
            
            transform := default_upright_transform()
            transform.offset = get_entity_ground_point(&entity) - camera_p
            
            shadow_transform := default_flat_transform()
            shadow_transform.offset = get_entity_ground_point(&entity) - camera_p
            shadow_transform.offset.y -= 0.5
            
            hero_height :f32= 3.5
            switch entity.type {
              case .Nil, .Floor, .FloatyThingForNow,
                   .Stairwell, .Monster, .Wall:
                // @note(viktor): nothing
                
              case .HeroHead:
                before := transform
                defer transform = before
                transform.sort_bias += 10000
                transform.offset.y -= 0.9 * hero_height
                push_bitmap(render_group, head_id,  transform, hero_height * 1.4)
                if debug_requested(debug_id) { 
                    debug_record_value(&head_id)
                }
                
              case .HeroBody:
                cape_id  := best_match_bitmap_from(tran_state.assets, .Cape,  facing_match, facing_weights)
                body_id  := best_match_bitmap_from(tran_state.assets, .Body,  facing_match, facing_weights)
                
                push_bitmap(render_group, shadow_id, shadow_transform, 0.5, color = {1, 1, 1, shadow_alpha})
                
                x_axis, y_axis := entity.x_axis, entity.y_axis * 0.4
                before := transform
                    transform.sort_bias += 10
                    push_bitmap(render_group, body_id,  transform, hero_height, x_axis = x_axis, y_axis = y_axis)
                transform = before
                    transform.offset.y += entity.t_bob
                    transform.sort_bias -= 10
                    transform.offset.y += -0.3
                    push_bitmap(render_group, cape_id,  transform, hero_height*1.3, x_axis = x_axis, y_axis = y_axis)
                transform = before
                
                if debug_requested(debug_id) { 
                    debug_record_value(&shadow_id)
                    debug_record_value(&cape_id)
                    debug_record_value(&body_id)
                }
                
              case .Familiar: 
                entity.t_bob += dt
                if entity.t_bob > Tau {
                    entity.t_bob -= Tau
                }
                hz :: 4
                coeff := sin(entity.t_bob * hz)
                z := (coeff) * 0.3 + 0.3
                
                push_bitmap(render_group, shadow_id, shadow_transform, 0.3, color = {1, 1, 1, 1 - shadow_alpha/2 * (coeff+1)})
                push_bitmap(render_group, head_id, transform, 1, offset = {0, 1+z, 0}, color = {1, 1, 1, 0.5})
                
                if debug_requested(debug_id) { 
                    debug_record_value(&shadow_id)
                    debug_record_value(&head_id)
                }
                
            }
            
            for piece in slice(&entity.pieces) {
                bitmap_id := best_match_bitmap_from(tran_state.assets, piece.asset, facing_match, facing_weights)
                push_bitmap(render_group, bitmap_id, transform, piece.height, color = piece.color, x_axis = entity.x_axis, y_axis = entity.y_axis)
                
                if debug_requested(debug_id) { 
                    debug_record_value(&bitmap_id)
                }
            }
            
            draw_hitpoints(render_group, &entity, 0.5, transform)
            
            if RenderCollisionOutlineAndTraversablePoints {
                transform.upright = false
                color := Green
                color.rgb *= 0.4
                push_rectangle_outline(render_group, entity.collision.total_volume, transform, color)
                
                for traversable in slice(entity.traversables) {
                    rect := rectangle_center_dimension(traversable.p, 0.1)
                    push_rectangle(render_group, rect, transform, traversable.occupant != nil ? Red : Blue)
                }
            }
            
            when DebugEnabled {
                for volume in entity.collision.volumes {
                    local_mouse_p := unproject_with_transform(render_group.camera, transform, input.mouse.p)
                    
                    if local_mouse_p.x >= volume.min.x && local_mouse_p.x < volume.max.x && local_mouse_p.y >= volume.min.y && local_mouse_p.y < volume.max.y  {
                        debug_hit(debug_id, local_mouse_p.z)
                    }
                    
                    highlighted, color := debug_highlighted(debug_id)
                    if highlighted {
                        push_rectangle_outline(render_group, volume, transform, color, 0.05)
                    }
                }
                
                if debug_requested(debug_id) { 
                    debug_record_value(cast(^u32) &entity.id, name = "entity_id")
                    debug_record_value(&entity.p.x)
                    debug_record_value(&entity.p.y)
                    debug_record_value(&entity.p.y)
                    debug_record_value(&entity.dp)
                }
            }
        }
    }
    
    when false do if EnvironmentTest { 
        ////////////////////////////////////////////////
        // @note(viktor): Coordinate System and Environment Map Test
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
                    draw_rectangle(lod, rectangle_min_dimension(vec_cast(f32, x, y), size), on ? color : Black, {min(i32), max(i32)})
                    on = !on
                }
                row_on = !row_on
            }
        }
        tran_state.envs[0].pz = -4
        tran_state.envs[1].pz =  0
        tran_state.envs[2].pz    =  4
        
        world.time += input.delta_time
        
        angle :f32= world.time
        when !true {
            disp :f32= 0
        } else {
            disp := v2{cos(angle*2) * 100, cos(angle*4.1) * 50}
        }
        origin := vec_cast(f32, buffer_size) * 0.5
        scale :: 100
        x_axis := scale * v2{cos(angle), sin(angle)}
        y_axis := perpendicular(x_axis)
        transform := default_flat_transform()
        if entry := coordinate_system(render_group, transform); entry != nil {
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
            
            if entry := coordinate_system(render_group, transform); entry != nil {
                entry.x_axis = {size.x, 0}
                entry.y_axis = {0, size.y}
                entry.origin = 20 + (entry.x_axis + {20, 0}) * auto_cast it_index
                
                entry.texture = it.LOD[0]
                assert(it.LOD[0].memory != nil)
            }
        }
    }
    
    // @todo(viktor): Make sure we hoist the camera update out to a place where the renderer
    // can know about the location of the camera at the end of the frame so there isn't
    // a frame of lag in camera updating compared to the hero.       
    end_sim(sim_region)
    end_temporary_memory(sim_memory)
    
    check_arena(&world.arena)
    
    // @todo(viktor): Should switch mode. Implemented in :CutsceneEpisodes
    heroes_exist: b32
    for con_hero in world.controlled_heroes {
        if con_hero.brain_id != 0 {
            heroes_exist = true
            break
        }
    }
}

////////////////////////////////////////////////

make_null_collision :: proc(world: ^World) -> (result: ^EntityCollisionVolumeGroup) {
    result = push(&world.arena, EntityCollisionVolumeGroup, no_clear())
    result^ = {}
    
    return result
}

make_simple_grounded_collision :: proc(world: ^World, size: v3, offset_z:f32=0) -> (result: ^EntityCollisionVolumeGroup) {
    // @todo(viktor): NOT WORLD ARENA!!! change to using the fundamental types arena
    result = push(&world.arena, EntityCollisionVolumeGroup, no_clear())
    result^ = {
        total_volume = rectangle_center_dimension(v3{0, 0, 0.5 * size.z + offset_z}, size),
        volumes = push(&world.arena, Rectangle3, 1),
    }
    result.volumes[0] = result.total_volume
    
    return result
}

make_simple_floor_collision :: proc(world: ^World, size: v3) -> (result: ^EntityCollisionVolumeGroup) {
    // @todo(viktor): NOT WORLD ARENA!!! change to using the fundamental types arena
    result = push(&world.arena, EntityCollisionVolumeGroup, no_clear())
    result^ = {
        total_volume = rectangle_center_dimension(v3{0, 0, -0.5 * size.z}, size),
        volumes = {},
    }
    
    return result
}


map_into_worldspace :: proc(world: ^World, center: WorldPosition, offset: v3 = {0,0,0}) -> WorldPosition {
    result := center
    result.offset += offset
    
    rounded_offset := round(result.offset / world.chunk_dim_meters, i32)
    result.chunk   =  result.chunk + rounded_offset
    result.offset  -= vec_cast(f32, rounded_offset) * world.chunk_dim_meters
    
    assert(is_canonical(world, result.offset))
    
    return result
}

world_distance :: proc(world: ^World, a, b: WorldPosition) -> (result: v3) {
    chunk_delta  := vec_cast(f32, a.chunk) - vec_cast(f32, b.chunk)
    offset_delta := a.offset - b.offset
    result = chunk_delta * world.chunk_dim_meters
    result += offset_delta
    return result
}

is_canonical :: proc(world: ^World, offset: v3) -> b32 {
    epsilon: f32 = 0.0001
    half_size := 0.5 * world.chunk_dim_meters + epsilon
    return -half_size.x <= offset.x && offset.x <= half_size.x &&
           -half_size.y <= offset.y && offset.y <= half_size.y &&
           -half_size.z <= offset.z && offset.z <= half_size.z
}

get_chunk :: proc (arena: ^Arena = nil, world: ^World, point: WorldPosition) -> ^Chunk {
    return get_chunk_3(arena, world, point.chunk)
}
get_chunk_3_internal :: proc(world: ^World, chunk_p: [3]i32) -> (result: ^^Chunk) {
    timed_function()
    ChunkSafeMargin :: 256
    
    assert(chunk_p.x > min(i32) + ChunkSafeMargin)
    assert(chunk_p.x < max(i32) - ChunkSafeMargin)
    assert(chunk_p.y > min(i32) + ChunkSafeMargin)
    assert(chunk_p.y < max(i32) - ChunkSafeMargin)
    assert(chunk_p.z > min(i32) + ChunkSafeMargin)
    assert(chunk_p.z < max(i32) - ChunkSafeMargin)
    
    // @todo(viktor): BETTER HASH FUNCTION !!
    hash_value := 19*chunk_p.x + 7*chunk_p.y + 3*chunk_p.z
    hash_slot := hash_value & (len(world.chunk_hash)-1)
    
    assert(hash_slot < len(world.chunk_hash))
    
    result = &world.chunk_hash[hash_slot]
    for result^ != nil && chunk_p != (result^).chunk {
        result = &(result^).next
    }
    
    return result
}
get_chunk_3 :: proc(arena: ^Arena = nil, world: ^World, chunk_p: [3]i32) -> (result: ^Chunk) {
    next_pointer_of_the_chunks_previous_chunk := get_chunk_3_internal(world, chunk_p)
    result = next_pointer_of_the_chunks_previous_chunk^
        
    if arena != nil && result == nil {
        result = push(arena, Chunk)
        result.chunk = chunk_p
        
        result.next = next_pointer_of_the_chunks_previous_chunk^
        next_pointer_of_the_chunks_previous_chunk^ = result
    }
    
    return result
}

////////////////////////////////////////////////

extract_chunk :: proc(world: ^World, chunk_p: [3]i32) -> (result: ^Chunk) {
    next_pointer_of_the_chunks_previous_chunk := get_chunk_3_internal(world, chunk_p)
    result = next_pointer_of_the_chunks_previous_chunk^
    
    if result != nil {
        next_pointer_of_the_chunks_previous_chunk ^= result.next
    }
    
    return result
}

pack_entity_into_world :: proc(region: ^SimRegion, world: ^World, source: ^Entity, p: WorldPosition) {
    chunk := get_chunk(&world.arena, world, p)
    assert(chunk != nil)
    
    source.p = p.offset

    pack_entity_into_chunk(region, world, source, chunk)
}

pack_entity_into_chunk :: proc(region: ^SimRegion, world: ^World, source: ^Entity, chunk: ^Chunk) {
    assert(chunk != nil)
    
    // :PointerArithmetic
    pack_size := cast(i64) size_of(Entity)
    
    if chunk.first_block == nil || !block_has_room(chunk.first_block, pack_size) {
        new_block := list_pop(&world.first_free_block) or_else push(&world.arena, WorldEntityBlock, no_clear())
        clear_world_entity_block(new_block)
        
        list_push(&chunk.first_block, new_block)
    }
    assert(block_has_room(chunk.first_block, pack_size))
    
    block := chunk.first_block
    
    // :PointerArithmetic
    dest := &block.entity_data.data[block.entity_data.count]
    block.entity_data.count += pack_size
    
    block.entity_count += 1
    
    entity := (cast(^Entity) dest)
    entity ^= source^
    
    // @volatile see Entity definition @metaprogram
    entity.ddp = 0
    entity.ddt_bob = 0
    
    // pack_entity_reference(region, &entity.head)
    pack_traversable_reference(region, &entity.came_from)
    pack_traversable_reference(region, &entity.occupying)
}

pack_entity_reference :: proc(region: ^SimRegion, ref: ^EntityReference) {
    if ref.pointer != nil {
        if .Deleted in ref.pointer.flags {
            ref.id = 0
        } else {
            ref.id = ref.pointer.id
        }
    } else if ref.id != 0 {
        if region == nil || get_entity_hash_from_id(region, ref.id) != nil {
            ref.id = 0
        }
    }
}

pack_traversable_reference :: proc(region: ^SimRegion, ref: ^TraversableReference) {
    pack_entity_reference(region, &ref.entity)
}

clear_world_entity_block :: proc(block: ^WorldEntityBlock) {
    block.entity_count = 0
    block.entity_data.count = 0
    block.next = nil
}

block_has_room :: proc(block: ^WorldEntityBlock, size: i64) -> b32 {
    return block.entity_data.count + size < len(block.entity_data.data)
}