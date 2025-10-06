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

chunk_position_from_tile_positon :: proc (mode: ^World_Mode, tile_p: v3i) -> (result: WorldPosition) {
    world := mode.world
    tile_size_in_meters  := mode.tile_size_in_meters
    
    tile_depth_in_meters := world.chunk_dim_meters.z
    
    offset := v3{tile_size_in_meters, tile_size_in_meters, tile_depth_in_meters} * (vec_cast(f32, tile_p) + {0.5, 0.5, 0})
    offset.z -= 0.4 * tile_depth_in_meters
    result = map_into_worldspace(world, result, offset)
    
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
    
    {
        debug_set_mouse_p(input.mouse.p)
        
        push_clear(render_group, DarkBlue)
        
        ////////////////////////////////////////////////
        
        camera := get_standard_camera_params(0.6)
        
            mode.camera_pitch = 0.0125 * Tau
        mode.camera_orbit = 0
        mode.camera_dolly = 0
        
        camera_object := xy_rotation(mode.camera_orbit) * yz_rotation(mode.camera_pitch)
        offset := mode.camera.offset
        offset.z += mode.camera_dolly
        offset = multiply(camera_object, offset)
        x := get_column(camera_object, 0)
        y := get_column(camera_object, 1)
        z := get_column(camera_object, 2)
        push_perspective(render_group, camera.focal_length, x, y, z, offset)
        
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
                        zoom_speed := 0.005 * (mode.camera.offset.z + mode.debug_camera_dolly)
                        mode.debug_camera_dolly += -dmousep.y * zoom_speed
                    } else if is_down(input.mouse.buttons[.middle]) {
                        mode.debug_camera_orbit = 0
                        mode.debug_camera_pitch = 0
                        mode.debug_camera_dolly = 0
                    }
                }
            }
            
            camera_object = xy_rotation(mode.debug_camera_orbit) * yz_rotation(mode.debug_camera_pitch)
            debug_offset.z += mode.debug_camera_dolly
            debug_offset = multiply(camera_object, debug_offset)
            x = get_column(camera_object, 0)
            y = get_column(camera_object, 1)
            z = get_column(camera_object, 2)
            push_perspective(render_group, camera.focal_length, x, y, z, debug_offset, flags = {.debug})
        }
        
        world_camera_rect := get_camera_rectangle_at_target(render_group)
        screen_bounds := rectangle_center_dimension(v2{0,0}, get_dimension(world_camera_rect).xy)
        
        // @todo(viktor): by how much should we expand the sim region?
        sim_bounds := rectangle_center_dimension(V3(get_center(screen_bounds), 0), 3 * mode.standard_room_dimension)
        
        simulation := begin_sim(&tran_state.arena, mode.world, mode.camera.p, sim_bounds, input.delta_time)
        
        check_for_joining_player(state, input, simulation.region, mode)
        
        simulate(&simulation, input.delta_time, &mode.world.game_entropy, mode.typical_floor_height, render_group, state, input, mode.particle_cache)
        
        frame_to_frame_camera_delta := world_distance(mode.world, mode.camera.last_p, mode.camera.p)
        mode.camera.last_p = mode.camera.p
        
        update_and_render_particle_systems(mode.particle_cache, render_group, input.delta_time, frame_to_frame_camera_delta)
        
        if ShowRenderAndSimulationBounds {
            world_transform := default_flat_transform()
            push_rectangle_outline(render_group, screen_bounds,                      world_transform, Orange, 0.1)
            push_rectangle_outline(render_group, simulation.region.bounds,           world_transform, Blue,   0.2)
            push_rectangle_outline(render_group, simulation.region.updatable_bounds, world_transform, Green,  0.2)
        }
        
        camera_entity := get_entity_by_id(simulation.region, mode.camera.following_id)
        if camera_entity != nil {
            update_camera(simulation.region, mode.world, &mode.camera, camera_entity)
        }
        
        end_sim(&simulation)
    }
    
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

update_camera :: proc (region: ^SimRegion, world: ^World, camera: ^Game_Camera, entity: ^Entity) {
    // @note(viktor): It is _mandatory_ that the camera "center" be the sim region center for this code to work properly, because it cannot add the offset from the sim center to the camera as a displacement or it will fail when moving between room at the changeover point.
    assert(entity.id == camera.following_id)
    
    in_room: ^Entity
    room_p: v3
    
    // @todo(viktor): Probably don't want to loop over all entities - maintain a separate list of room entities during unpack!
    for &test in slice(region.entities) {
        if test.brain_kind != .Room do continue
        
        volume := add_offset(test.collision.total_volume, test.p)
        if contains(volume, entity.p) {
            in_room = &test
            room_p = entity.p - test.p
            break
        }
    }
    if in_room == nil do return
    
    room_delta := get_dimension(in_room.collision.total_volume)
    
    half_room_delta := room_delta * 0.5
    half_room_apron := half_room_delta - 0.7
    height: f32 = 0.5
    camera.offset = 0
    camera.p = map_into_worldspace(world, region.origin, in_room.p)
    
    delta := room_p
    if delta.y >  half_room_apron.y {
        t := clamp_01_map_to_range(half_room_apron.y, delta.y, half_room_delta.y)
        camera.offset.y = t * half_room_delta.y
        camera.offset.z = (-(t*t) + 2*t) * height
    }
    
    if delta.y < -half_room_apron.y {
        t := clamp_01_map_to_range(-half_room_apron.y, delta.y, -half_room_delta.y)
        camera.offset.y = t * -half_room_delta.y
        camera.offset.z = (-(t*t) + 2*t) * height
    }
    
    if delta.x >  half_room_apron.x {
        t := clamp_01_map_to_range(half_room_apron.x, delta.x, half_room_delta.x)
        camera.offset.x = t * half_room_delta.x
        camera.offset.z = (-(t*t) + 2*t) * height
    }
    
    if delta.x < -half_room_apron.x {
        t := clamp_01_map_to_range(-half_room_apron.x, delta.x, -half_room_delta.x)
        camera.offset.x = t * -half_room_delta.x
        camera.offset.z = (-(t*t) + 2*t) * height
    }
    
    if delta.z >  half_room_apron.z {
        t := clamp_01_map_to_range(half_room_apron.z, delta.z, half_room_delta.z)
        camera.offset.z = t * half_room_delta.z
    }
    
    if delta.z < -half_room_apron.z {
        t := clamp_01_map_to_range(-half_room_apron.z, delta.z, -half_room_delta.z)
        camera.offset.z = t * -half_room_delta.z
    }
    
    camera.offset.z += in_room.camera_height
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
            chunk = chunk_p
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
    
    if chunk.first_block == nil || !block_has_room(chunk.first_block, pack_size) {
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

block_has_room :: proc (block: ^WorldEntityBlock, size: i64) -> bool {
    return block.entity_data.count + size < len(block.entity_data.data)
}
