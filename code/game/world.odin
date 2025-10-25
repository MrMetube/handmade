package game

World :: struct {
    arena: ^Arena,
    
    chunk_dim_meters: v3,
    
    // @todo(viktor): chunk_hash should probably switch to pointers IF
    // tile_entity_blocks continue to be stored en masse in the tile chunk!
    chunk_hash: [4096] ^Chunk,
    first_free: ^WorldEntityBlock,
    
    first_free_chunk: ^Chunk,
    first_free_block: ^WorldEntityBlock,

    game_entropy: RandomSeries,
    
    change_ticket: TicketMutex,
}

Chunk :: struct {
    next: ^Chunk,
    chunk: v3i,
    
    first_block: ^WorldEntityBlock,
}

// @todo(viktor): Could make this just Chunk and then allow multiple tile chunks per X/Y/Z
WorldEntityBlock :: struct {
    next: ^WorldEntityBlock,
    entity_count: u32,
    // @note(viktor): entity_data'count =^= size_of(Entity) * entity_count  for now, because there is no compression
    entity_data: FixedArray(1 << 14, u8),
}

WorldPosition :: struct {
    // @todo(viktor): It seems like we have to store ChunkX/Y/Z with each entity because even though the sim region gather doesn't need it at first, and we could get by without it, but entity references pull in entities WITHOUT going through their world_chunk, and thus still need to know the ChunkX/Y/Z
    chunk:  v3i,
    offset: v3,
}

////////////////////////////////////////////////

create_world :: proc (chunk_dim_in_meters: v3, arena: ^Arena) -> (result: ^ World) {
    result = push(arena, World)
    result.chunk_dim_meters = chunk_dim_in_meters
    result.arena = arena
    result.game_entropy = seed_random_series(123)
    
    return result
}

chunk_position_from_tile_positon :: proc (mode: ^World_Mode, tile_p: v3i, additional_offset: v3 = {}) -> (result: WorldPosition) {
    world := mode.world
    tile_size_in_meters  := mode.tile_size_in_meters
    
    tile_depth_in_meters := world.chunk_dim_meters.z
    
    offset := v3{tile_size_in_meters, tile_size_in_meters, tile_depth_in_meters} * (vec_cast(f32, tile_p) + {0.5, 0.5, 0})
    offset.z -= 0.4 * tile_depth_in_meters
    result = map_into_worldspace(world, result, additional_offset + offset)
    
    assert(is_canonical(world, result.offset))
    
    return result
}

update_and_render_world :: proc (state: ^State, tran_state: ^TransientState, render_group: ^RenderGroup, input: ^Input, mode: ^World_Mode) -> (rerun: bool) {
    timed_function()
    
    when false {
        temp := begin_temporary_memory(&tran_state.arena)
        
        N: i32 : 5
        works := push(temp.arena, World_Sim_Work, N*N)
        for sim_x in 0..<N {
            for sim_y in 0..<N {
                middle :: N/2
                if sim_x == middle && sim_y == middle do continue
                
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
    near_clip_plane :: 3
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
    
    // @todo(viktor): by how much should we expand the sim region?
    sim_bounds := rectangle_zero_center_dimension(mode.standard_room_dimension * {3, 3, 10})
    
    dt := input.delta_time
    simulation := begin_sim(&tran_state.arena, mode.world, mode.camera.simulation_center, sim_bounds, input.delta_time)
    
    check_for_joining_player(state, input, simulation.region, mode)
    
    simulate(&simulation, dt, &mode.world.game_entropy, mode.typical_floor_height, render_group, state, input, mode.particle_cache)
    
    last_camera_p := mode.camera.p
    camera_entity := get_entity_by_id(simulation.region, mode.camera.following_id)
    if camera_entity != nil {
        update_camera(simulation.region, mode.world, &mode.camera, camera_entity, dt)
    }
    
    frame_to_frame_camera_delta := world_distance(mode.world, last_camera_p, mode.camera.p)
    update_and_render_particle_systems(mode.particle_cache, render_group, dt, frame_to_frame_camera_delta)
    
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
        
        t0 := v2{0, 0}
        t1 := v2{1, 0}
        t2 := v2{1, 1}
        t3 := v2{0, 1}
        
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
    
    end_sim(&simulation)
    
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
        play_intro_cutscene(state, tran_state)
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
    for &test in slice(region.entities) {
        if test.brain_kind == .Room && entity_overlaps_entity(&test, entity) {
            in_room = &test
        }
        
        if test.camera_behaviour != {} && entity_overlaps_entity(&test, entity)  {
            ok := true
            
            if .general_velocity_constraint in test.camera_behaviour {
                ok &&= contains(test.camera_velocity_min, length(entity.dp), test.camera_velocity_max)
            }
            
            if .directional_velocity_constraint in test.camera_behaviour {
                ok &&= contains(test.camera_velocity_min, dot(test.camera_velocity_dir, entity.dp), test.camera_velocity_max)
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

map_into_worldspace :: proc (world: ^World, center: WorldPosition, offset: v3 = {0,0,0}) -> WorldPosition {
    result := center
    result.offset += offset
    
    rounded_offset := round(i32, result.offset / world.chunk_dim_meters)
    result.chunk   += rounded_offset
    result.offset  -= vec_cast(f32, rounded_offset) * world.chunk_dim_meters
    
    assert(is_canonical(world, result.offset))
    
    return result
}

get_chunk_bounds :: proc (world: ^World, chunk_p: v3i) -> (result: Rectangle3) {
    chunk_center := vec_cast(f32, chunk_p) * world.chunk_dim_meters
    result = rectangle_center_dimension(chunk_center, world.chunk_dim_meters)
    return result
}

world_distance :: proc (world: ^World, a, b: WorldPosition) -> (result: v3) {
    chunk_delta  := vec_cast(f32, a.chunk) - vec_cast(f32, b.chunk)
    offset_delta := a.offset - b.offset
    result = chunk_delta * world.chunk_dim_meters
    result += offset_delta
    return result
}

is_canonical :: proc (world: ^World, offset: v3) -> bool {
    epsilon: f32 = 0.0001
    half_size := 0.5 * world.chunk_dim_meters + epsilon
    return -half_size.x <= offset.x && offset.x <= half_size.x &&
           -half_size.y <= offset.y && offset.y <= half_size.y &&
           -half_size.z <= offset.z && offset.z <= half_size.z
}

////////////////////////////////////////////////

get_chunk :: proc (arena: ^Arena, world: ^World, point: WorldPosition) -> (result: ^Chunk) {
    chunk_p := point.chunk
    
    next_pointer_of_the_chunks_previous_chunk := get_chunk_internal(world, chunk_p)
    result = next_pointer_of_the_chunks_previous_chunk^
    
    if arena != nil && result == nil {
        result = list_pop_head(&world.first_free_chunk) or_else push(arena, Chunk, no_clear())
        result ^= {
            chunk = chunk_p,
        }
        
        list_push(next_pointer_of_the_chunks_previous_chunk, result) 
    }
    
    return result
}

get_chunk_internal :: proc (world: ^World, chunk_p: v3i) -> (result: ^^Chunk) {
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

////////////////////////////////////////////////

extract_chunk :: proc (world: ^World, chunk_p: v3i) -> (result: ^Chunk) {
    begin_ticket_mutex(&world.change_ticket)
    
    next_pointer_of_the_chunks_previous_chunk := get_chunk_internal(world, chunk_p)
    result = next_pointer_of_the_chunks_previous_chunk^
    
    if result != nil {
        next_pointer_of_the_chunks_previous_chunk ^= result.next
    }
    
    end_ticket_mutex(&world.change_ticket)    

    return result
}

add_to_free_list :: proc (world: ^World, chunk: ^Chunk, first_block, last_block: ^WorldEntityBlock) {
    begin_ticket_mutex(&world.change_ticket)
    
    list_push(&world.first_free_chunk, chunk)
    if first_block != nil {
        // @note(viktor): push on the whole list from first to last
        last_block.next = world.first_free_block
        world.first_free_block = first_block
    }
    
    end_ticket_mutex(&world.change_ticket)
}

use_space_in_world :: proc (world: ^World, pack_size: i64, p: WorldPosition) -> (result: ^Entity) {
    begin_ticket_mutex(&world.change_ticket)
    
    chunk := get_chunk(world.arena, world, p)
    assert(chunk != nil)
    
    result = use_space_in_chunk(world, pack_size, chunk)
    
    end_ticket_mutex(&world.change_ticket)
    
    return result
}

use_space_in_chunk :: proc (world: ^World, pack_size: i64, chunk: ^Chunk) -> (result: ^Entity) {
    assert(chunk != nil)
    
    if !block_has_room(chunk.first_block, pack_size) {
        new_block := list_pop_head(&world.first_free_block) or_else push(world.arena, WorldEntityBlock, no_clear())
        
        clear_world_entity_block(new_block)
        
        list_push(&chunk.first_block, new_block)
    }
    assert(block_has_room(chunk.first_block, pack_size))
    
    block := chunk.first_block
    
    // :PointerArithmetic
    result = cast(^Entity) &block.entity_data.data[block.entity_data.count]
    block.entity_data.count += pack_size
    block.entity_count += 1
    
    return result
}

clear_world_entity_block :: proc (block: ^WorldEntityBlock) {
    block.entity_count = 0
    block.entity_data.count = 0
    block.next = nil
}

block_has_room :: proc (block: ^WorldEntityBlock, size: i64) -> (result: bool) {
    if block != nil {
        result = block.entity_data.count + size < len(block.entity_data.data)
    }
    
    return result
}
