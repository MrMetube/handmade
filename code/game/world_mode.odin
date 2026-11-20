#+vet !unused-procedures
package game

World_Mode :: struct {
    world: ^World,
    
    go_to_cutscene_at_the_start_of_the_next_frame: bool,
    
    camera: Game_Camera,
    ////////////////////////////////////////////////
    // General
    tile_size_in_meters:  f32,
    typical_floor_height: f32,
    standard_room_dimension: v3,
    
    last_used_entity_id: EntityId, // @todo(viktor): Worry about wrapping - Free list of ids?
    
    effects_entropy: RandomSeries, // @note(viktor): this is randomness that does NOT effect the gameplay
    particle_cache:  ^Particle_Cache,
    creation_region: ^SimRegion,
    
    use_debug_camera:   bool,
    debug_last_mouse_p: v2,
    debug_camera_pitch: f32,
    debug_camera_orbit: f32,
    debug_camera_dolly: f32,
    
    camera_pitch: f32,
    camera_orbit: f32,
    camera_dolly: f32,
    
    ////////////////////////////////////////////////
    
    debug_lighting: [light_points_per_chunk] LightPointState,
    
    show_lighting: bool,
    test_lighting: LightingSolution,
    test_textures: LightingTextures,
}

Game_Camera :: struct {
    // @todo(viktor): Should we allow split-screen?
    following_id: EntityId,
    simulation_center: WorldPosition,
    
    p:      WorldPosition,
    offset: v3,
    
    target_p:      WorldPosition,
    target_offset: v3,
    
    special:   EntityId,
    t_special: f32,
}

////////////////////////////////////////////////

play_world :: proc (state: ^State, tran_state: ^TransientState) {
    mode := set_game_mode(state, tran_state, World_Mode)
    
    ////////////////////////////////////////////////
    
    mode.last_used_entity_id = cast(EntityId) ReservedBrainId.FirstFree
    
    mode.effects_entropy = seed_random_series(555)
    
    mode.tile_size_in_meters = 1.4
    mode.typical_floor_height = 5
    
    // :RoomSize:
    chunk_dim_meters := v3{17 * mode.tile_size_in_meters, 9 * mode.tile_size_in_meters, mode.typical_floor_height}
    mode.world = create_world(chunk_dim_meters, &state.mode_arena)
    mode.standard_room_dimension = chunk_dim_meters
    
    ////////////////////////////////////////////////
    // "World Gen"
    
    creation_memory := begin_temporary_memory(&tran_state.arena)
    mode.creation_region = begin_world_changes(creation_memory.arena, mode.world, {}, {}, 0)
    
    door_left, door_right: bool
    door_top, door_bottom: bool
    stair_up, stair_down:  bool
    
    room_center: iv3
    choice: u32
    // @todo undo this
    screen_count :: 2
    for screen_index in 0 ..< screen_count {
        room_radius := iv2 {7, 4} + {random_between(&mode.world.game_entropy, i32, 0, 3), random_between(&mode.world.game_entropy, i32, 0, 3)} // :RoomSize:
        room_size := room_radius * 2 + 1
        
        switch choice {
          case 0: room_center.x += room_radius.x
          case 1: room_center.y += room_radius.y
          case 2: room_center.z -= 1
          case 3: room_center.z += 1
          case 4: room_center.x -= room_radius.x
          case 5: room_center.y -= room_radius.y
        }
        
        if !false {
            choice = random_between(&mode.world.game_entropy, u32, 0, 1)
        } else {
            choice = 3
        }
        
        switch choice {
          case 0: door_right  = true
          case 1: door_top    = true
          case 2: stair_down  = true
          case 3: stair_up    = true
          case 4: door_left   = true
          case 5: door_bottom = true
        }
        
        left_hole  := true || screen_index % 2 == 0
        right_hole := true || !left_hole
        if screen_index == 0 {
            left_hole  = false
            right_hole = false
        }
        
        room := add_standart_room(mode, room_center, left_hole, right_hole, room_radius)
        
        for tile_y in 0..< room_size.y {
            tile_x := 0
            if !(door_left && tile_y == room_size.y / 2) {
                add_wall(mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_y in 0..< room_size.y {
            tile_x := room_size.x-1
            if !(door_right && tile_y == room_size.y / 2) {
                add_wall(mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_x in 0 ..< room_size.x {
            tile_y := 0
            if !(door_bottom && tile_x == room_size.x / 2) {
                add_wall(mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_x in 0 ..< room_size.x {
            tile_y := room_size.y-1
            if !(door_top && tile_x == room_size.x / 2) {
                add_wall(mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        
        // @todo undo this
        if false do add_monster(mode,  room.p[3][4], room.ground[3][4])
        // add_familiar(mode, room.p[2][5], room.ground[2][5])
        
        snake_brain := add_brain(mode)
        for piece_index in u32(0)..<len(BrainSnake{}.segments) {
            x := 1+piece_index
            add_snake_piece(mode, room.p[x][7], room.ground[x][7], snake_brain, piece_index)
        }
        
        door_left   = door_right
        door_bottom = door_top
        door_right  = false
        door_top    = false
        
        stair_up   = false
        stair_down = false
        
        if screen_index + 1 == screen_count { break }
        
        switch choice {
          case 0: room_center.x += room_radius.x + 1
          case 1: room_center.y += room_radius.y + 1
          case 2: room_center.z -= 1
          case 3: room_center.z += 1
          case 4: room_center.x -= room_radius.x + 1
          case 5: room_center.y -= room_radius.y + 1
        }
    }
    
    new_camera_p := chunk_position_from_tile_positon(mode, room_center)
    
    mode.camera.p = new_camera_p
    mode.camera.simulation_center = mode.camera.p
    
    end_world_changes(mode.creation_region)
    mode.creation_region = nil
    end_temporary_memory(creation_memory)
        
    mode.particle_cache = push(&tran_state.arena, Particle_Cache)
    init_particle_cache(mode.particle_cache, tran_state.assets)
}

////////////////////////////////////////////////

update_and_render_world :: proc (state: ^State, tran_state: ^TransientState, render_group: ^RenderGroup, input: ^Input, mode: ^World_Mode) -> (rerun: bool) {
    timed_function()
    
    if mode.go_to_cutscene_at_the_start_of_the_next_frame {
        // If this is done immediatly, we still have filled the rendergroup with commands. Specifically the Lighting Data is then still read by the renderer, but we already reused the game memory for the next mode and may also have unmapped parts of the freed memory.
        play_intro_cutscene(state, tran_state)
        return true
    }
    
    
    when false {
        temp := begin_temporary_memory(&tran_state.arena)
        
        N: i32 : 5
        works := push(temp.arena, World_Sim_Work, N*N)
        for sim_x in 0..<N {
            for sim_y in 0..<N {
                middle :: N/2
                if sim_x == middle && sim_y == middle { continue }
                
                work := &works[sim_x + sim_y * N]
                work.dt = input.delta_time
                work.mode = mode
                work.center = mode.camera.p
                work.center.chunk += {sim_x - middle, sim_y - middle, 0} * 70
                work.bounds = sim_bounds
                
                when false {
                    do_world_simulation_immediatly(work)
                } else {
                    Platform.enqueue_work(tran_state.high_priority_queue, work, do_world_simulation_immediatly)
                }
            }
        }
        
        Platform.complete_all_work(tran_state.high_priority_queue)
        end_temporary_memory(temp)
    }
    
    ////////////////////////////////////////////////
    
    debug_set_mouse_p(input.mouse.p)
    
    push_begin_depth_peel(render_group)
    
    push_clear(render_group, DarkBlue)
    
    ////////////////////////////////////////////////
    
    focal_length :: 0.6
    
    mode.camera_pitch = 0.0125 * Tau
    mode.camera_orbit = 0
    mode.camera_dolly = 0
    
    camera_offset := mode.camera.offset
    
    delta_from_sim := world_distance(mode.world, mode.camera.p, mode.camera.simulation_center)
    camera_offset += delta_from_sim
    
    camera_offset.z += mode.camera_dolly
    
    camera_object := xy_rotation(mode.camera_orbit) * yz_rotation(mode.camera_pitch)
    camera_offset = multiply(camera_object, camera_offset)
    x := get_column(camera_object, 0)
    y := get_column(camera_object, 1)
    z := get_column(camera_object, 2)
    near_clip_plane :: 0.1
    push_camera(render_group, flags = {}, x = x, y = y, z = z, p = camera_offset, focal_length = focal_length, fog = true, near_clip_plane = near_clip_plane)
    
    ////////////////////////////////////////////////
    
    if input != nil {
        if was_pressed(input.mouse.buttons[.extra1]) {
            mode.use_debug_camera = !mode.use_debug_camera
        }
    }
    
    if mode.use_debug_camera {
        debug_offset := mode.camera.offset
        
        if input != nil {
            dmousep := input.mouse.p - mode.debug_last_mouse_p
            defer mode.debug_last_mouse_p = input.mouse.p
            
            if mode.use_debug_camera {
                if is_down(input.mouse.buttons[.left]) {
                    rotation_speed :: 0.001 * Tau
                    mode.debug_camera_orbit += -dmousep.x * rotation_speed
                    mode.debug_camera_pitch += dmousep.y * rotation_speed
                } else if is_down(input.mouse.buttons[.right]) {
                    zoom_speed := 0.005 * (debug_offset.z + mode.debug_camera_dolly)
                    mode.debug_camera_dolly += -dmousep.y * zoom_speed
                } else if is_down(input.mouse.buttons[.middle]) {
                    mode.debug_camera_orbit = mode.camera_orbit
                    mode.debug_camera_pitch = mode.camera_pitch
                    mode.debug_camera_dolly = mode.camera_dolly
                }
            }
        }
        
        debug_camera_object := xy_rotation(mode.debug_camera_orbit) * yz_rotation(mode.debug_camera_pitch)
        debug_offset.z += mode.debug_camera_dolly
        debug_offset = multiply(debug_camera_object, debug_offset)
        
        x = get_column(debug_camera_object, 0)
        y = get_column(debug_camera_object, 1)
        z = get_column(debug_camera_object, 2)
        
        push_camera(render_group, { .debug }, x, y, z, debug_offset, focal_length)
    }
    
    ////////////////////////////////////////////////
    
    recompute_lighting: bool
    if input.fkey_pressed[3] {
        if LightingIterationCount > 0 {
            LightingIterationCount -= 1
            recompute_lighting = true
        }
    }
    if input.fkey_pressed[4] {
        LightingIterationCount += 1
        recompute_lighting = true
    }
    
    if input.fkey_pressed[1] {
        mode.show_lighting = !mode.show_lighting
    }
    
    if !recompute_lighting && mode.show_lighting {
        render_lighting_points(render_group, &mode.test_lighting, &mode.test_textures)
    } else {
        // @todo(viktor): by how much should we expand the sim region?
        sim_bounds := box_zero_center_dimension(mode.standard_room_dimension * {3, 3, 10})
        
        enable_lighting(render_group, box_zero_center_dimension(mode.standard_room_dimension * {1, 1, 10}))
        
        dt := input.delta_time
        simulation := begin_sim(&tran_state.arena, mode.world, mode.camera.simulation_center, sim_bounds, input.delta_time)
        
        check_for_joining_player(state, input, simulation.region, mode)
        
        simulate(&simulation, dt, &mode.world.game_entropy, mode.typical_floor_height, render_group, state, input, mode.particle_cache)
        
        // @todo undo this
        // last_camera_p := mode.camera.p
        camera_entity := get_entity_by_id(simulation.region, mode.camera.following_id)
        debug_light_p: v3
        if camera_entity != nil {
            debug_light_p = camera_entity.p + {0,0,1}
            update_camera(simulation.region, mode.world, &mode.camera, camera_entity, dt)
        }
        
        push_light(render_group, debug_light_p, .5, 1, 1, mode.debug_lighting[:])
        
        // @todo undo this
        // frame_to_frame_camera_delta := world_distance(mode.world, last_camera_p, mode.camera.p)
        // update_and_render_particle_systems(mode.particle_cache, render_group, dt, frame_to_frame_camera_delta)
        unused(update_and_render_particle_systems)
        
        if ShowSimulationBounds {
            world_transform := default_flat_transform()
            push_volume_outline(render_group, simulation.region.bounds, world_transform, Salmon, 0.2)
        }
        
        if ShowRenderFrustum {
            near: f32 = 1
            far:  f32 =  20
            min: v2 = 0
            max: v2 = render_group.screen_size
            
            bitmap := &render_group.commands.white_bitmap
            thickness: f32 = 0.02
            cn := srgb_to_linear(Orange)
                cf := srgb_to_linear(Red)
            
            near_min := unproject_with_transform(render_group, render_group.game_cam, min, near)
            near_max := unproject_with_transform(render_group, render_group.game_cam, max, near)
            far_min  := unproject_with_transform(render_group, render_group.game_cam, min, far)
            far_max  := unproject_with_transform(render_group, render_group.game_cam, max, far)
            
            p0 := V4(far_max, 0)
            p1 := V4(far_min.x, far_max.yz, 0)
            p2 := V4(near_max, 0)
            p3 := V4(near_min.x, near_max.yz, 0)
            p4 := V4(far_max.x, far_min.yz, 0)
            p5 := V4(far_min, 0)
            p6 := V4(near_max.x, near_min.yz, 0)
            p7 := V4(near_min, 0)
            
            c0 := v4_to_rgba(store_color(cf))
            c1 := v4_to_rgba(store_color(cn))
            
            push_line_segment(render_group, bitmap, p0, p1, c0, c0, thickness)
            push_line_segment(render_group, bitmap, p0, p2, c0, c1, thickness)
            push_line_segment(render_group, bitmap, p0, p4, c0, c0, thickness)
            
            push_line_segment(render_group, bitmap, p3, p1, c1, c0, thickness)
            push_line_segment(render_group, bitmap, p3, p2, c1, c1, thickness)
            push_line_segment(render_group, bitmap, p3, p7, c1, c1, thickness)
            
            push_line_segment(render_group, bitmap, p5, p1, c0, c0, thickness)
            push_line_segment(render_group, bitmap, p5, p4, c0, c0, thickness)
            push_line_segment(render_group, bitmap, p5, p7, c0, c1, thickness)
            
            push_line_segment(render_group, bitmap, p6, p2, c1, c1, thickness)
            push_line_segment(render_group, bitmap, p6, p4, c1, c0, thickness)
            push_line_segment(render_group, bitmap, p6, p7, c1, c1, thickness)
        }
        
        lighting_test(render_group, &mode.test_lighting)
        push_lighting_values(render_group, &mode.test_lighting, &mode.test_textures)
        
        end_sim(&simulation)
    }
    
    push_end_depth_peel(render_group)
    
    ////////////////////////////////////////////////
    
    check_arena(mode.world.arena)
    
    heroes_exist: bool
    for con_hero in state.controlled_heroes {
        if con_hero.brain_id != 0 {
            heroes_exist = true
            break
        }
    }
    
    if !heroes_exist {
        mode.go_to_cutscene_at_the_start_of_the_next_frame = true
    }
    
    return false
}

////////////////////////////////////////////////

World_Sim_Work :: struct {
    mode: ^World_Mode,
    dt: f32,
    bounds: Rectangle3,
    center: WorldPosition,
}

do_world_simulation_immediatly :: proc (data: pmm) {
    timed_function()
    
    // @todo(viktor): with the new and improved Platform Api can we get back the polymorphic arguments so that the call site is better checked
    using work := cast(^World_Sim_Work) data
    
    // @todo(viktor): It is inefficient to reallocate every time - this should be something that is passed in as a property of the worker thread
    arena: Arena
    defer clear_arena(&arena)
    
    simulation := begin_sim(&arena, mode.world, center, bounds, dt)
    simulate(&simulation, dt, &mode.world.game_entropy, mode.typical_floor_height, nil,  nil, nil, nil)
    end_sim(&simulation)
}

check_for_joining_player :: proc (state: ^State, input: ^Input, region: ^SimRegion, mode: ^World_Mode) {
    timed_function()
    
    for controller, controller_index in input.controllers {
        con_hero := &state.controlled_heroes[controller_index]
        if con_hero.brain_id == 0 {
            if was_pressed(controller.buttons[.start]) {
                standing_on, ok := get_closest_traversable(region, {0, 0, 0}, {.Unoccupied} )
                assert(ok) // @todo(viktor): Game UI that tells you there is no safe space...maybe keep trying on subsequent frames?
                
                brain_id := cast(BrainId) controller_index + cast(BrainId) ReservedBrainId.FirstHero
                con_hero ^= { brain_id = brain_id }
                add_hero(mode, region, standing_on, brain_id)
            }
        }
    }
}

update_camera :: proc (region: ^SimRegion, world: ^World, camera: ^Game_Camera, entity: ^Entity, dt: f32) {
    // @note(viktor): It is _mandatory_ that the camera "center" be the sim region center for this code to work properly, because it cannot add the offset from the sim center to the camera as a displacement or it will fail when moving between room at the changeover point.
    assert(entity.id == camera.following_id)
    
    in_room: ^Entity
    special: ^Entity
    // @todo(viktor): Probably don't want to loop over all entities - maintain a separate list of room entities during unpack!
    for &test in region.entities {
        if test.brain_kind == .Room && entity_overlaps_entity(&test, entity) {
            in_room = &test
        }
        
        if test.camera_behaviour != {} && entity_overlaps_entity(&test, entity)  {
            ok := true
            
            if .general_velocity_constraint in test.camera_behaviour {
                ok &&= contains(test.camera_velocity_min, test.camera_velocity_max, length(entity.dp))
            }
            
            if .directional_velocity_constraint in test.camera_behaviour {
                ok &&= contains(test.camera_velocity_min, test.camera_velocity_max, dot(test.camera_velocity_dir, entity.dp))
            }
            
            if ok {
                special = &test
            }
        }
    }
    
    if special != nil {
        if special.id == camera.special {
            camera.t_special += dt
        } else {
            camera.t_special = 0
            camera.special = special.id
        }
    } else {
        camera.special = 0
    }
    
    if in_room != nil {
        room_volume := add_offset(in_room.collision_volume, in_room.p)
        
        simulation_center := V3(get_center(room_volume).xy, room_volume.min.z)
        
        target_p := simulation_center
        target_offset := v3{0, 0, 8}
        if special != nil {
            if .follow_player in special.camera_behaviour {
                target_p = entity.p
            }
            
            if camera.t_special > special.camera_min_time && .inspect in special.camera_behaviour {
                target_p = special.p
            }
            
            if camera.t_special > special.camera_min_time && .offset in special.camera_behaviour {
                target_offset = special.camera_offset
            }
        }
        
        camera.simulation_center = map_into_worldspace(world, region.origin, simulation_center)
        camera.target_p = map_into_worldspace(world, region.origin, target_p)
        camera.target_offset = target_offset
    }
    
    p        := world_distance(world, camera.p, camera.simulation_center)
    target_p := world_distance(world, camera.target_p, camera.simulation_center)
    offset        := camera.offset
    target_offset := camera.target_offset
    
    delta_p := target_p - p
    p += delta_p * dt
    
    delta_offset := target_offset - camera.offset
    offset += delta_offset * dt
    
    camera.p = map_into_worldspace(world, region.origin, p)
    camera.offset = offset
}

////////////////////////////////////////////////

begin_entity :: proc (mode: ^World_Mode) -> ^Entity {
    result := create_entity(mode.creation_region, allocate_entity_id(mode))
 
    // @todo(viktor): Worry about this taking a while, once the entities are large (sparse clear?)
    result ^= { id = result.id }
    
    result.x_axis = {1, 0}
    result.y_axis = {0, 1}
    
    return result
}

allocate_entity_id :: proc (mode: ^World_Mode) -> EntityId {
    mode.last_used_entity_id += 1
    result := mode.last_used_entity_id
 
    return result
}

end_entity :: proc (mode: ^World_Mode, entity: ^Entity, p: WorldPosition) {
    entity.p = world_distance(mode.world, p, mode.creation_region.origin)
}

add_brain :: proc (mode: ^World_Mode) -> BrainId {
    mode.last_used_entity_id += 1
    for mode.last_used_entity_id < cast(EntityId) ReservedBrainId.FirstFree {
        mode.last_used_entity_id += 1
    }
    result := cast(BrainId) mode.last_used_entity_id
    
    return result
}

add_wall :: proc (mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_entity(mode)
    defer end_entity(mode, entity, p)
    
    entity.collision_volume = grounded_collision({mode.tile_size_in_meters, mode.tile_size_in_meters, mode.typical_floor_height})
    entity.flags += {.Collides}
    entity.occupying = occupying
    append(&entity.pieces, VisiblePiece {
        asset     = .Tree,
        dimension = {1, 2.5},
        color     = 1,
    })
}

add_hero :: proc (mode: ^World_Mode, region: ^SimRegion, occupying: TraversableReference, brain_id: BrainId) {
    mode.creation_region = region
    defer mode.creation_region = nil
    
    p := map_into_worldspace(mode.world, region.origin, get_sim_space_traversable(occupying).p)
    
    body := begin_entity(mode)
        body.brain_id = brain_id
        body.brain_kind = .Hero
        body.brain_slot = brain_slot_for(BrainHero, "body")
        
        // @todo(viktor): We will probably need a creation-time system for guaranteeing no overlapping occupation.
        body.occupying = occupying
        
        // @todo reenable these
        // append(&body.pieces, VisiblePiece{
        //     asset     = .Shadow,
        //     dimension = {0, hero_height*1},
        //     color     = {1,1,1,0.5},
        // }) 
        // append(&body.pieces, VisiblePiece{
        //     asset     = .Cape,
        //     dimension = {0, hero_height*1.2},
        //     color     = 1,
        //     flags     = { .SquishAxis, .BobUpAndDown },
        // })
        // append(&body.pieces, VisiblePiece{
        //     asset     = .Torso,
        //     dimension = {0, hero_height*1.2},
        //     offset    = {0, -0.1, 0},
        //     color     = 1,
        //     flags     = { .SquishAxis },
        // })
        
    end_entity(mode, body, p)
    
    head := begin_entity(mode)
        head.flags += {.Collides}
        head.brain_id = brain_id
        head.brain_kind = .Hero
        head.brain_slot = brain_slot_for(BrainHero, "head")
        head.movement_mode = ._Floating
        head.collision_volume = grounded_collision({1, 0.5, 0.5}, 0.7)
        
        hero_height :: 3
        // @todo(viktor): should render above the body
        // @todo reenable these
        // append(&head.pieces, VisiblePiece{
        //     asset     = .Head,
        //     dimension = {0, hero_height*1.2},
        //     offset    = {0, -0.7, 0},
        //     color     = 1,
        // })
        
        // @todo reenable these
        // init_hitpoints(head, 3)
        
        if mode.camera.following_id == 0 {
            mode.camera.following_id = head.id
        }
    end_entity(mode, head, p)
    
    
    glove := begin_entity(mode)
        glove.collision_volume = grounded_collision(v3{0.2, 0.2, 0.2})
        glove.flags += {.Collides}
        glove.brain_id = brain_id
        glove.brain_kind = .Hero
        glove.brain_slot = brain_slot_for(BrainHero, "glove")
        
        glove.movement_mode = .AngleOffset
        glove.angle_current = -0.25 * Tau
        glove.angle_base_offset  = 0.3
        glove.angle_swipe_offset = 1
        glove.angle_current_offset = 0.3
        
        // @todo reenable these
        // append(&head.pieces, VisiblePiece{
        //     asset     = .Sword,
        //     dimension = {0, 0.25*hero_height},
        //     offset    = 0,
        //     color     = 1,
        // })
        
    end_entity(mode, glove, p)
}

add_snake_piece :: proc (mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference, brain_id: BrainId, segment_index: u32) {
    entity := begin_entity(mode)
    defer end_entity(mode, entity, p)
    
    entity.brain_id = brain_id
    entity.brain_kind = .Snake
    entity.brain_slot = brain_slot_for(BrainSnake, "segments", segment_index)
    entity.occupying = occupying
    
    height :: 1.5
    append(&entity.pieces, {
        asset     = .Shadow,
        dimension = {0, height},
        offset    = {0, 0, 0},
        color     = {1,1,1,0.5},
    })
    
    append(&entity.pieces, {
        asset     = segment_index == 0 ? .Head : .Torso,
        dimension = {0, height},
        color     = 1,
    })
    
    add_piece_light(entity, 0, 0.5, {1,1,0}, 1)
    
    init_hitpoints(entity, 3)
}

add_piece_light :: proc (entity: ^Entity, offset: v3, radius: f32, color: v3, emission: f32) {
    append(&entity.pieces, {
        offset    = offset,
        dimension = { radius, emission },
        color     = V4(color, 1),
        flags     = { .light},
    })
}

add_monster :: proc (mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_entity(mode)
    defer end_entity(mode, entity, p)
    
    entity.brain_id = add_brain(mode)
    entity.brain_kind = .Monster
    entity.brain_slot = brain_slot_for(BrainMonster, "body")
    entity.occupying = occupying
    
    height :: 4.5
    append(&entity.pieces, VisiblePiece{
        asset     = .Shadow,
        dimension = {0, height},
        offset    = {0, 0, 0},
        color     = {1,1,1,0.5},
    })
    
    append(&entity.pieces, VisiblePiece{
        asset     = .Torso,
        dimension = {0, height},
        color     = 1,
    })
    
    init_hitpoints(entity, 3)
}

add_familiar :: proc (mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_entity(mode)
    defer end_entity(mode, entity, p)
    
    entity.brain_id   = add_brain(mode)
    entity.brain_kind = .Familiar
    entity.brain_slot = brain_slot_for(BrainFamiliar, "familiar")
    entity.occupying  = occupying
    entity.movement_mode = ._Floating
    
    append(&entity.pieces, VisiblePiece{
        asset     = .Head,
        dimension = {0, 2.5},
        color     = 1,
        offset    = {0, 0, 0},
        flags     = { .BobUpAndDown },
    })
    
    append(&entity.pieces, VisiblePiece{
        asset     = .Shadow,
        dimension = {0, 2.5},
        color     = {1,1,1,0.5},
    })
}

StandartRoom :: struct {
    p:      [64][64] WorldPosition,
    ground: [64][64] TraversableReference,
}

add_standart_room :: proc (mode: ^World_Mode, tile_p: iv3, left_hole, right_hole: bool, radius: iv2) -> StandartRoom {
    result: StandartRoom
    floor_tile_height: f32 : 0.5
    
    for offset_y in -radius.y ..= radius.y {
        for offset_x in -radius.x ..= radius.x {
            p := chunk_position_from_tile_positon(mode, tile_p + {offset_x, offset_y, 0})
            
            index_x := offset_x+radius.x
            index_y := offset_y+radius.y
            
            // color := srgb_to_linear(Green)
            color := srgb_to_linear(White) // @todo undo this
            wall_height := floor_tile_height
            if offset_x >= -2 && offset_x <= 1 && (offset_y == 2 || offset_y == -1) {
                wall_height = 3
                if offset_y == 2 {
                    color = srgb_to_linear(v4{0.2, 0.1, 0.8, 1})
                } else {
                    color = srgb_to_linear(v4{0.8, 0.2, 0.1, 1})
                }
            }
            
            jitter_top: v3
            jitter_left: v3
            jitter_left.x += random_bilateral(&mode.world.game_entropy, f32) * 0.2
            jitter_left.y += random_bilateral(&mode.world.game_entropy, f32) * 0.2
            jitter_left.z += random_unilateral(&mode.world.game_entropy, f32) * 0.2
            jitter_top.x  += random_bilateral(&mode.world.game_entropy, f32) * 0.2
            jitter_top.y  += random_bilateral(&mode.world.game_entropy, f32) * 0.2
            jitter_top.z  += random_unilateral(&mode.world.game_entropy, f32) * 0.2
            
            jitter_now := linear_blend(jitter_left, jitter_top, 0.5)
            jitter_now.z += wall_height
            p.offset += jitter_now + {0, 0, floor_tile_height}
            
            result.p[index_x][index_y] = p
            
            if left_hole && (offset_x >= -5 && offset_x <= -3 && offset_y >= 0 && offset_y <= 1) {
                // @note(viktor): hole down to floor below
            }else if right_hole && (offset_x >= 3 && offset_x <= 4 && offset_y >= -2 && offset_y <= 2) {
                // @note(viktor): hole down to floor below
            } else {
                entity := begin_entity(mode)
                entity.traversables = make_array(mode.world.arena, TraversablePoint, 1)
                append(&entity.traversables, {})
                append(&entity.pieces, VisiblePiece {
                    asset     = .Tuft,
                    dimension = {.75, wall_height},
                    color     = color,
                    flags     = {.cube},
                })
                end_entity(mode, entity, p)
                
                occupying: TraversableReference
                occupying.entity.id = entity.id
                occupying.entity.pointer = entity
                result.ground[index_x][index_y] = occupying
            }
        }
    }
    
    tile := mode.tile_size_in_meters
    
    stair_p: [5] WorldPosition
    for offset_y in cast(i32) -2 ..= 2 {
        offset_x: i32 = 3
        p := chunk_position_from_tile_positon(mode, tile_p + {offset_x, offset_y, 0}, {0.5 * tile, 0, 0})
        
        index_x := offset_x+radius.x
        index_y := offset_y+radius.y
        
        t := clamp_01_map_to_range(cast(f32) -2.5, cast(f32) offset_y, 2.5)
        p.offset.z += linear_blend(cast(f32) 0, -mode.typical_floor_height*1.8, t)
        
        entity := begin_entity(mode)
        entity.traversables = make_array(mode.world.arena, TraversablePoint, 1)
        append(&entity.traversables, {})
        append(&entity.pieces, VisiblePiece {
            asset     = .Tuft,
            dimension = {1, floor_tile_height},
            color     = srgb_to_linear(Green),
            flags     = {.cube},
        })
        end_entity(mode, entity, p)
        stair_p[offset_y - -2] = p
        
        occupying: TraversableReference
        occupying.entity.id = entity.id
        occupying.entity.pointer = entity
        result.ground[index_x][index_y] = occupying
    }
    
    { // @note(viktor): Hole camera
        entity := begin_entity(mode)
        entity.camera_behaviour = { .inspect, .offset, .general_velocity_constraint }
        entity.camera_offset    = {0, 2*tile, 4}
        entity.camera_min_time  = 1
        entity.camera_velocity_max = 0.01
        
        x_dim := 3 * tile
        y_dim := 1 * tile
        entity.collision_volume = grounded_collision(v3 { x_dim, y_dim, 1 })
        end_entity(mode, entity, result.p[-4+radius.x][-1+radius.y])
    }
    
    { // @note(viktor): Stair camera
        entity := begin_entity(mode)
        entity.camera_behaviour = { .follow_player }
        x_dim := 0.5 * tile
        y_dim := 3   * tile - tile*0.5
        entity.collision_volume = Rectangle3{
            {tile*0.5 + -x_dim, -y_dim,   -0.8 * mode.typical_floor_height},
            {tile*0.5 +  x_dim,  y_dim+tile*0.5, 1.1 * mode.typical_floor_height},
        }
        end_entity(mode, entity, stair_p[2])
        
        entity = begin_entity(mode)
        entity.camera_behaviour = { .inspect, .directional_velocity_constraint }
        entity.camera_velocity_dir = {0, 1, 0}
        entity.camera_velocity_min = 0.2
        entity.camera_velocity_max = +Infinity
        entity.collision_volume = grounded_collision({2, 1, 1} * tile)
        entity.collision_volume.min.x += 0.5 * tile
        entity.collision_volume.max.x += 0.5 * tile
        end_entity(mode, entity, result.p[3+radius.x][-3+radius.y])
    }
    
    p := chunk_position_from_tile_positon(mode, tile_p)
    scale := v3{tile, tile, mode.typical_floor_height}
    
    size := V3(cast(v2) radius * 2 + 1, 2) * scale
    
    room := begin_entity(mode)
    room.collision_volume = grounded_collision(size)
    room.brain_kind = .Room
    end_entity(mode, room, p)
    
    return result
}

init_hitpoints :: proc (entity: ^Entity, count: u32) {
    for _ in 0..<count {
        append(&entity.hit_points, HitPoint { filled_amount = HitPointPartCount })
    }
}

grounded_collision :: proc (size: v3, offset_z: f32 = 0) -> Rectangle3 {
    result := rectangle_center_dimension(v3{0, 0, 0.5 * size.z}, size)
    result = add_offset(result, v3{0, 0, offset_z})
    return result
}