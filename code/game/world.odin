package game

World :: struct {
    arena: Arena,
    
    ////////////////////////////////////////////////
    // World specific    
    chunk_dim_meters: v3,

    // TODO(viktor): chunk_hash should probably switch to pointers IF
    // tile_entity_blocks continue to be stored en masse in the tile chunk!
    chunk_hash: [4096]Chunk,
    first_free: ^WorldEntityBlock,
    
    ////////////////////////////////////////////////
    // General
    typical_floor_height: f32,
    
    // TODO(viktor): Should we allow split-screen?
    camera_following_index: StorageIndex,
    camera_p : WorldPosition,
    // TODO(viktor): Should which players joined be part of the general state?
    controlled_heroes: [len(Input{}.controllers)]ControlledHero,
    
    stored_entity_count: StorageIndex,
    stored_entities: [100_000]StoredEntity,

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
    
    
    // NOTE(viktor): Only for testing, use Input.delta_time and your own t-values.
    time: f32,
}

// NOTE(viktor): https://graphics.stanford.edu/~seander/bithacks.html#DetermineIfPowerOf2
#assert( len(World{}.collision_rule_hash) & ( len(World{}.collision_rule_hash) - 1 ) == 0)

Chunk :: #type SingleLinkedList(ChunkData)
ChunkData :: struct {
    chunk: [3]i32,

    first_block: WorldEntityBlock,
}

// TODO(viktor): Could make this just Chunk and then allow multiple tile chunks per X/Y/Z
WorldEntityBlock :: #type SingleLinkedList(WorldEntityBlockData)
WorldEntityBlockData :: struct {
    entity_count: StorageIndex,
    indices:      [16]StorageIndex,
}

WorldPosition :: struct {
    // TODO(viktor): It seems like we have to store ChunkX/Y/Z with each
    // entity because even though the sim region gather doesn't need it
    // at first, and we could get by without it, but entity references pull
    // in entities WITHOUT going through their world_chunk, and thus
    // still need to know the ChunkX/Y/Z
    chunk: [3]i32,
    offset: v3,
}

GroundBuffer :: struct {
    bitmap: Bitmap,
    // NOTE(viktor): An invalid position tells us that this ground buffer has not been filled
    p: WorldPosition, // NOTE(viktor): this is the center of the bitmap
}

init_world :: proc(world: ^World, parent_arena: ^Arena, ground_buffer_size: f32) {
    sub_arena(&world.arena, parent_arena, arena_remaining_size(parent_arena))


    // TODO(viktor): REMOVE THIS
    pixels_to_meters :: 1.0 / 42.0
    chunk_dim_in_meters :f32= pixels_to_meters * ground_buffer_size
    world.typical_floor_height = 3
    
    world.chunk_dim_meters = v3{chunk_dim_in_meters, chunk_dim_in_meters, world.typical_floor_height}

    world.first_free = nil
    for &chunk_block in world.chunk_hash {
        chunk_block.chunk.x = UninitializedChunk
        chunk_block.first_block.entity_count = 0
    }
    
    ////////////////////////////////////////////////
    
    add_stored_entity(world, .Nil, null_position())
    
    
    
    tiles_per_screen :: [2]i32{15, 7}

    tile_size_in_meters :: 1.5
    world.null_collision          = make_null_collision(world)
    world.wall_collision          = make_simple_grounded_collision(world, {tile_size_in_meters, tile_size_in_meters, world.typical_floor_height})
    world.arrow_collision         = make_simple_grounded_collision(world, {0.5, 1, 0.1})
    world.stairs_collision        = make_simple_grounded_collision(world, {tile_size_in_meters, tile_size_in_meters * 2, world.typical_floor_height + 0.1})
    world.player_collision        = make_simple_grounded_collision(world, {0.75, 0.4, 1})
    world.monstar_collision       = make_simple_grounded_collision(world, {0.75, 0.75, 1.5})
    world.familiar_collision      = make_simple_grounded_collision(world, {0.5, 0.5, 1})
    world.standart_room_collision = make_simple_grounded_collision(world, V3(vec_cast(f32, tiles_per_screen) * tile_size_in_meters, world.typical_floor_height * 0.9))

    ////////////////////////////////////////////////
    // "World Gen"
    
    chunk_position_from_tile_positon :: proc(world: ^World, tile_x, tile_y, tile_z: i32, additional_offset := v3{}) -> (result: WorldPosition) {
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
        
        add_standart_room(world, chunk_position_from_tile_positon(world, 
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
                    add_wall(world, chunk_position_from_tile_positon(world, 
                        tile_x + screen_col * tiles_per_screen.x,
                        tile_y + screen_row * tiles_per_screen.y,
                        tile_z,
                    ))
                } else if need_to_place_stair {
                    add_stairs(world, chunk_position_from_tile_positon(world, 
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

    world.camera_p = new_camera_p

    monster_p  := new_camera_p.chunk + {10,5,0}
    add_monster(world,  chunk_position_from_tile_positon(world, monster_p.x, monster_p.y, monster_p.z))
    for _ in 0..< 1 {
        familiar_p := new_camera_p.chunk
        familiar_p.x += random_between_i32(&series, 0, 14)
        familiar_p.y += random_between_i32(&series, 0, 1)
        add_familiar(world, chunk_position_from_tile_positon(world, familiar_p.x, familiar_p.y, familiar_p.z))
    }
}

update_and_render_world :: proc(world: ^World, tran_state: ^TransientState, render_group: ^RenderGroup, input: Input) {
    timed_function()
    
    for controller, controller_index in input.controllers {
        con_hero := &world.controlled_heroes[controller_index]

        if con_hero.storage_index == 0 {
            if controller.start.ended_down {
                player_index, _ := add_player(world)
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
            
            if HeroJumping {
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
                // TODO(viktor): How do we want to handle this?
                // play_sound(&state.mixer, random_sound_from(tran_state.assets, .Hit, &state.effects_entropy), 0.2)
            }
        }
    }

    
    monitor_width_in_meters :: 0.635
    buffer_size := [2]i32{render_group.commands.width, render_group.commands.height}
    meters_to_pixels_for_monitor := cast(f32) buffer_size.x * monitor_width_in_meters
    
    focal_length, distance_above_ground : f32 = 0.6, 8
    perspective(render_group, buffer_size, meters_to_pixels_for_monitor, focal_length, distance_above_ground)
    
    clear(render_group, Red)
    
    if RenderGroundChunks {
        for &ground_buffer in tran_state.ground_buffers {
            if is_valid(ground_buffer.p) {
                offset := world_difference(world, ground_buffer.p, world.camera_p)
                transform := default_flat_transform()
                
                transform.offset = offset
                
                // @Cleanup @CopyPasta from entity loop
                camera_relative_ground := offset
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
                
                
                bitmap := ground_buffer.bitmap
                bitmap.align_percentage = 0
                
                ground_chunk_size := world.chunk_dim_meters.x
                
                // TODO(viktor): Disables for now as we dynamically change and reuse 
                // these textures so its dificult to know when to upload to the gpu.
                // push_bitmap_raw(render_group, &bitmap, transform, ground_chunk_size)
                
                if ShowGroundChunkBounds {
                    push_rectangle_outline(render_group, rectangle_center_dimension(offset.xy, ground_chunk_size), transform, Orange)
                }
            }
        }
    }
    
    screen_bounds := get_camera_rectangle_at_target(render_group)
    camera_bounds := Rectangle3{
        V3(screen_bounds.min, -0.5 * world.typical_floor_height), 
        V3(screen_bounds.max, 4 * world.typical_floor_height),
    }

    if RenderGroundChunks {
        min_p := map_into_worldspace(world, world.camera_p, camera_bounds.min)
        max_p := map_into_worldspace(world, world.camera_p, camera_bounds.max)

        for z in min_p.chunk.z ..= max_p.chunk.z {
            for y in min_p.chunk.y ..= max_p.chunk.y {
                for x in min_p.chunk.x ..= max_p.chunk.x {
                    chunk_center := WorldPosition{ chunk = { x, y, z } }
                    
                    furthest_distance: f32 = -1
                    furthest: ^GroundBuffer
                    // @Speed this is super inefficient. Fix it!
                    for &ground_buffer in tran_state.ground_buffers {
                        buffer_delta := world_difference(world, ground_buffer.p, world.camera_p)
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
                            furthest_distance = PositiveInfinity
                            furthest = &ground_buffer
                        }
                    }
                    
                    if furthest != nil {
                        fill_ground_chunk(tran_state, world, furthest, chunk_center)
                    }
                }
            }
        }
    }
    
    sim_memory := begin_temporary_memory(&tran_state.arena)
    // TODO(viktor): by how much should we expand the sim region?
    // TODO(viktor): do we want to simulate upper floors, etc?
    sim_bounds := rectangle_add_radius(camera_bounds, v3{15, 15, 0})
    sim_origin := world.camera_p
    camera_sim_region := begin_sim(&tran_state.arena, world, sim_origin, sim_bounds, input.delta_time)
    
    
    if ShowRenderAndSimulationBounds {
        transform := default_flat_transform()
        push_rectangle_outline(render_group, rectangle_center_dimension(v2{}, rectangle_get_dimension(screen_bounds)),                         transform, Orange,0.1)
        push_rectangle_outline(render_group, rectangle_center_dimension(v2{}, rectangle_get_dimension(camera_sim_region.bounds).xy),           transform, Blue,  0.2)
        push_rectangle_outline(render_group, rectangle_center_dimension(v2{}, rectangle_get_dimension(camera_sim_region.updatable_bounds).xy), transform, Green, 0.2)
    }
    
    camera_p := world_difference(world, world.camera_p, sim_origin)
    
    update_block := begin_timed_block("update and render entity")
    for &entity in camera_sim_region.entities[:camera_sim_region.entity_count] {
        if entity.updatable { // TODO(viktor):  move this out into entity.odin
            dt := input.delta_time;

            // TODO(viktor): Probably indicates we want to separate update ann render for entities sometime soon?
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
            

            // TODO(viktor): this is incorrect, should be computed after update
            shadow_alpha := 1 - 0.5 * entity.p.z;
            if shadow_alpha < 0 {
                shadow_alpha = 0.0;
            }
            
            ddp: v3
            move_spec := default_move_spec()
            
            ////////////////////////////////////////////////
            // Pre-physics entity work

            switch entity.type {
              case .Nil, .Monster, .Wall, .Stairwell, .Space:
              case .Hero:
                for &con_hero in world.controlled_heroes {
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
                                add_collision_rule(world, entity.storage_index, arrow.storage_index, false)
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
                    clear_collision_rules(world, entity.storage_index)
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
                
                if FamiliarFollowsHero {
                    if closest_hero != nil && closest_hero_dsq > 1 {
                        mpss: f32 = 0.5
                        ddp = mpss / square_root(closest_hero_dsq) * (closest_hero.p - entity.p)
                    }
                }

                move_spec.normalize_accelaration = true
                move_spec.drag = 8
                move_spec.speed = 50
            }

            if entity.flags & {.Nonspatial, .Moveable} == {.Moveable} {
                move_entity(camera_sim_region, &entity, ddp, move_spec, input.delta_time)
            }

            ////////////////////////////////////////////////
            // Post-physics entity work

            facing_match   := #partial AssetVector{ .FacingDirection = entity.facing_direction }
            facing_weights := #partial AssetVector{.FacingDirection = 1 }
            head_id   := best_match_bitmap_from(tran_state.assets, .Head,  facing_match, facing_weights)
            
            shadow_id := first_bitmap_from(tran_state.assets, AssetTypeId.Shadow)
            
            transform := default_upright_transform()
            shadow_transform := default_flat_transform()
            
            transform.offset = get_entity_ground_point(&entity)
            shadow_transform.offset = get_entity_ground_point(&entity)
            
            switch entity.type {
              case .Nil: // NOTE(viktor): nothing
              case .Hero:
                { debug_data_block("Game/Entity")
                    debug_record_value(&entity.facing_direction, "Hero Direction")
                }
                
                cape_id  := best_match_bitmap_from(tran_state.assets, .Cape,  facing_match, facing_weights)
                sword_id := best_match_bitmap_from(tran_state.assets, .Sword, facing_match, facing_weights)
                body_id  := best_match_bitmap_from(tran_state.assets, .Body,  facing_match, facing_weights)
                push_bitmap(render_group, shadow_id, shadow_transform, 0.5, color = {1, 1, 1, shadow_alpha})

                hero_height :f32= 1.6
                push_bitmap(render_group, cape_id,  transform, hero_height)
                push_bitmap(render_group, body_id,  transform, hero_height)
                push_bitmap(render_group, head_id,  transform, hero_height)
                push_bitmap(render_group, sword_id, transform, hero_height)
                push_hitpoints(render_group, &entity, 1, transform)

              case .Arrow:
                push_bitmap(render_group, shadow_id, shadow_transform, 0.5, color = {1, 1, 1, shadow_alpha})
                push_bitmap(render_group, first_bitmap_from(tran_state.assets, AssetTypeId.Arrow), transform, 0.1)

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

              case .Monster:
                monster_id := best_match_bitmap_from(tran_state.assets, .Monster, facing_match, facing_weights)

                push_bitmap(render_group, shadow_id, shadow_transform, 0.75, color = {1, 1, 1, shadow_alpha})
                push_bitmap(render_group, monster_id, transform, 1.5)
                push_hitpoints(render_group, &entity, 1.6, transform)
            
              case .Wall:
                rock_id := first_bitmap_from(tran_state.assets, AssetTypeId.Rock)
                
                push_bitmap(render_group, rock_id, transform, 1.5)
    
              case .Stairwell: 
                transform.upright = false
                push_rectangle(render_group, rectangle_center_dimension(v2{0, 0}, entity.walkable_dim), transform, Blue)
                transform.offset.z += world.typical_floor_height
                push_rectangle(render_group, rectangle_center_dimension(v2{0, 0}, entity.walkable_dim), transform, Blue * {1,1,1,0.5})
              
              case .Space: 
                if ShowSpaceBounds {
                    transform.upright = false
                    for volume in entity.collision.volumes {
                        push_rectangle_outline(render_group, volume, transform, Blue)
                    }
                }
            }
        
            when DebugEnabled {
                if entity.type != .Space {
                    debug_id := debug_pointer_id(&world.stored_entities[entity.storage_index])
                    
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
                        debug_data_block("Entity/HotEntity/")
                        debug_record_value(cast(^u32) &entity.storage_index, name = "storage_index")
                        debug_record_value(&entity.updatable)
                        debug_record_value(&entity.p)
                        debug_record_value(&entity.dp)
                        id := first_bitmap_from(tran_state.assets, .Body)
                        debug_record_value(&id, name = "bitmap")
                        debug_record_value(&entity.distance_limit)
                    }
                }
            }
        }
    }
    end_timed_block(update_block)
    
    when false do if EnvironmentTest { 
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
    
    // TODO(viktor): Make sure we hoist the camera update out to a place where the renderer
    // can know about the location of the camera at the end of the frame so there isn't
    // a frame of lag in camera updating compared to the hero.       
    end_sim(camera_sim_region)
    end_temporary_memory(sim_memory)
    
    check_arena(&world.arena)
}

////////////////////////////////////////////////

null_position :: proc() -> (result:WorldPosition) {
    result.chunk.x = UninitializedChunk
    return result
}

is_valid :: proc(p: WorldPosition) -> b32 {
    return p.chunk.x != UninitializedChunk
}

make_null_collision :: proc(world: ^World) -> (result: ^EntityCollisionVolumeGroup) {
    result = push(&world.arena, EntityCollisionVolumeGroup, no_clear())
    result^ = {}
    
    return result
}

make_simple_grounded_collision :: proc(world: ^World, size: v3) -> (result: ^EntityCollisionVolumeGroup) {
    // TODO(viktor): NOT WORLD ARENA!!! change to using the fundamental types arena
    result = push(&world.arena, EntityCollisionVolumeGroup, no_clear())
    result^ = {
        total_volume = rectangle_center_dimension(v3{0, 0, 0.5*size.z}, size),
        volumes = push(&world.arena, Rectangle3, 1),
    }
    
    result.volumes[0] = result.total_volume

    return result
}

change_entity_location :: proc(arena: ^Arena = nil, world: ^World, index: StorageIndex, stored: ^StoredEntity, new_p_init: WorldPosition) {
    new_p, old_p : ^WorldPosition
    if is_valid(new_p_init) {
        new_p_init := new_p_init
        new_p = &new_p_init
    }
    if .Nonspatial not_in stored.sim.flags && is_valid(stored.p) {
        old_p = &stored.p
    }

    change_entity_location_raw(arena, world, index, new_p, old_p)

    if new_p != nil && is_valid(new_p^) {
        stored.p = new_p^
        stored.sim.flags -= { .Nonspatial }
    } else {
        stored.p = null_position()
        stored.sim.flags += { .Nonspatial }
    }
}

change_entity_location_raw :: proc(arena: ^Arena = nil, world: ^World, storage_index: StorageIndex, new_p: ^WorldPosition, old_p: ^WorldPosition = nil) {
    timed_function()
    // TODO(viktor): if the entity moves  into the camera bounds, shoulds this force the entity into the high set immediatly?
    assert((old_p == nil || is_valid(old_p^)))
    assert((new_p == nil || is_valid(new_p^)))

    if old_p != nil && new_p != nil && are_in_same_chunk(world, old_p^, new_p^) {
        // NOTE(viktor): leave entity where it is
    } else {
        if old_p != nil {
            // NOTE(viktor): Pull the entity out of its old block
            chunk := get_chunk(nil, world, old_p^)
            assert(chunk != nil)
            if chunk != nil {
                first_block := &chunk.first_block
                outer: for block := first_block; block != nil; block = block.next {
                    for &block_index in block.indices[:block.entity_count] {
                        if block_index == storage_index {
                            first_block.entity_count -= 1
                            block_index = first_block.indices[first_block.entity_count]

                            if first_block.entity_count == 0 {
                                if first_block.next != nil {
                                    free_block := list_pop(&first_block)
                                    list_push(&world.first_free, free_block)
                                }
                            }
                            break outer
                        }

                    }
                }
            }
        }

        if new_p != nil {
            // NOTE(viktor): Insert the entity into its new block
            chunk := get_chunk(arena, world, new_p^)
            assert(chunk != nil)

            block := &chunk.first_block
            if block.entity_count == len(block.indices) {
                // NOTE(viktor): We're out of room, get a new block!
                new_block := list_pop(&world.first_free) or_else push(arena, WorldEntityBlock)
                
                list_push_after_head(block, new_block)
                block^ = {}
            }
            assert(block.entity_count < len(block.indices))

            block.indices[block.entity_count] = storage_index
            block.entity_count += 1
        }
    }
}

map_into_worldspace :: proc(world: ^World, center: WorldPosition, offset: v3 = {0,0,0}) -> WorldPosition {
    result := center
    result.offset += offset

    rounded_offset  := round(result.offset / world.chunk_dim_meters, i32)
    result.chunk  = result.chunk + rounded_offset
    result.offset -= vec_cast(f32, rounded_offset) * world.chunk_dim_meters

    assert(is_canonical(world, result.offset))

    return result
}

world_difference :: proc(world: ^World, a, b: WorldPosition) -> (result: v3) {
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

are_in_same_chunk :: proc(world: ^World, a, b: WorldPosition) -> b32 {
    assert(is_canonical(world, a.offset))
    assert(is_canonical(world, b.offset))

    return a.chunk == b.chunk
}

get_chunk :: proc {
    get_chunk_pos,
    get_chunk_3,
}

get_chunk_pos :: proc(arena: ^Arena = nil, world: ^World, point: WorldPosition) -> ^Chunk {
    return get_chunk_3(arena, world, point.chunk)
}
get_chunk_3 :: proc(arena: ^Arena = nil, world: ^World, chunk_p: [3]i32) -> ^Chunk {
    timed_function()
    ChunkSafeMargin :: 256

    assert(chunk_p.x > min(i32) + ChunkSafeMargin)
    assert(chunk_p.x < max(i32) - ChunkSafeMargin)
    assert(chunk_p.y > min(i32) + ChunkSafeMargin)
    assert(chunk_p.y < max(i32) - ChunkSafeMargin)
    assert(chunk_p.z > min(i32) + ChunkSafeMargin)
    assert(chunk_p.z < max(i32) - ChunkSafeMargin)

    // TODO(viktor): BETTER HASH FUNCTION !!
    hash_value := 19*chunk_p.x + 7*chunk_p.y + 3*chunk_p.z
    hash_slot := hash_value & (len(world.chunk_hash)-1)

    assert(hash_slot < len(world.chunk_hash))

    world_chunk := &world.chunk_hash[hash_slot]
    for {
        if chunk_p == world_chunk.chunk {
            break
        }

        if arena != nil && world_chunk.chunk.x != UninitializedChunk && world_chunk.next == nil {
            world_chunk.next = push(arena, Chunk)
            
            world_chunk = world_chunk.next
            world_chunk.chunk.x = UninitializedChunk
        }

        if arena != nil && world_chunk.chunk.x == UninitializedChunk {
            world_chunk.chunk = chunk_p
            world_chunk.next = nil

            break
        }

        world_chunk = world_chunk.next
        if world_chunk == nil do break
    }

    return world_chunk
}


FillGroundChunkWork :: struct {
    task: ^TaskWithMemory,
    
    ground_buffer: ^GroundBuffer, 
    
    tran_state:    ^TransientState, 
    world:         ^World,
    p:             WorldPosition,
}

do_fill_ground_chunk_work : PlatformWorkQueueCallback : proc(data: pmm) {
    timed_function()
    using work := cast(^FillGroundChunkWork) data
    
    bitmap := &ground_buffer.bitmap
    bitmap.align_percentage = 0.5
    bitmap.width_over_height = 1
    
    
    when false {
        buffer_size := world.chunk_dim_meters.xy
        assert(buffer_size.x == buffer_size.y)
        half_dim := buffer_size * 0.5
        render_group := init_render_group(&task.arena, tran_state.assets, 32 * Megabyte, true)
        begin_render(render_group)
        
        orthographic(render_group, {bitmap.width, bitmap.height}, cast(f32) (bitmap.width-2) / buffer_size.x)
        
        clear(render_group, Red)

        transform := default_flat_transform()
        
        chunk_z := p.chunk.z
        for offset_y in i32(-1) ..= 1 {
            for offset_x in i32(-1) ..= 1 {
                chunk_x := p.chunk.x + offset_x
                chunk_y := p.chunk.y + offset_y
                
                center := vec_cast(f32, offset_x, offset_y) * buffer_size
                // TODO(viktor): look into wang hashing here or some other spatial seed generation "thing"
                series := seed_random_series(cast(u32) (463 * chunk_x + 311 * chunk_y + 185 * chunk_z) + 99)
                
                for _ in 0..<120 {
                    stamp := random_bitmap_from(tran_state.assets, .Grass, &series)
                    p := center + random_bilateral_2(&series, f32) * half_dim 
                    push_bitmap(render_group, stamp, transform, 5, offset = V3(p, 0))
                }
            }
        }
        assert(all_assets_valid(render_group))
        
        render_group_to_output(render_group, bitmap^, &task.arena)
        
        end_render(render_group)
    }
    end_task_with_memory(task)
}

fill_ground_chunk :: proc(tran_state: ^TransientState, world: ^World, ground_buffer: ^GroundBuffer, p: WorldPosition){
    if task := begin_task_with_memory(tran_state); task != nil {
        work := push(&task.arena, FillGroundChunkWork, no_clear())
            
        work^ = {
            task = task,
    
            ground_buffer = ground_buffer,
            
            tran_state = tran_state, 
            world = world,
            p = p,
        }
        
        ground_buffer.p = p
        
        Platform.enqueue_work(tran_state.low_priority_queue, do_fill_ground_chunk_work, work)
    }
}

@(private="file")
UninitializedChunk :: min(i32)