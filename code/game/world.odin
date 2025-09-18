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
}

// @note(viktor): https://graphics.stanford.edu/~seander/bithacks.html#DetermineIfPowerOf2
#assert( len(World_Mode{}.collision_rule_hash) & ( len(World_Mode{}.collision_rule_hash) - 1 ) == 0)

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
    // @todo(viktor): It seems like we have to store ChunkX/Y/Z with each
    // entity because even though the sim region gather doesn't need it
    // at first, and we could get by without it, but entity references pull
    // in entities WITHOUT going through their world_chunk, and thus
    // still need to know the ChunkX/Y/Z
    chunk: v3i,
    offset: v3,
}

////////////////////////////////////////////////

create_world :: proc (chunk_dim_in_meters: v3, arena: ^Arena) -> (result: ^ World) {
    result = push(arena, World)
    result.chunk_dim_meters = chunk_dim_in_meters
    result.arena = arena
    
    return result
}

chunk_position_from_tile_positon :: proc(world_mode: ^World_Mode, tile_x, tile_y, tile_z: i32, additional_offset := v3{}) -> (result: WorldPosition) {
    // @volatile
    tile_size_in_meters  :: 1.5
    tile_depth_in_meters := world_mode.typical_floor_height
    
    offset := v3{tile_size_in_meters, tile_size_in_meters, tile_depth_in_meters} * (vec_cast(f32, tile_x, tile_y, tile_z) + {0.5, 0.5, 0})
    offset.z -= 0.4 * tile_depth_in_meters
    result = map_into_worldspace(world_mode.world, result, offset + additional_offset)
    
    assert(is_canonical(world_mode.world, result.offset))
    
    return result
}

update_and_render_world :: proc(state: ^State, tran_state: ^TransientState, render_group: ^RenderGroup, input: ^Input, mode: ^World_Mode) -> (rerun: bool) {
    timed_function()
    
    camera := get_standard_camera_params(get_dimension(render_group.screen_area).x, 0.3)
    distance_above_ground: f32 = 11
    perspective(render_group, camera.meters_to_pixels, camera.focal_length, distance_above_ground)
    
    haze_color := DarkBlue
    push_clear(render_group, haze_color)
    
    screen_bounds := get_camera_rectangle_at_target(render_group)
    camera_bounds := Rect3(screen_bounds, -0.5 * mode.typical_floor_height, 4 * mode.typical_floor_height)
    
    // @todo(viktor): by how much should we expand the sim region?
    sim_bounds  := add_radius(camera_bounds, v3{ 15, 15, 15})
    sim_bounds2 := add_offset(sim_bounds,    v3{-70, -40, 0})
    update_and_render_simregion(&tran_state.arena, mode, input.delta_time, screen_bounds, sim_bounds, input.mouse.p, render_group, state, input, haze_color)
    update_and_render_simregion(&tran_state.arena, mode, input.delta_time, screen_bounds, sim_bounds2, input.mouse.p, render_group, nil, nil, 0)
    
    ////////////////////////////////////////////////
    
    enviroment_test()
    
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

update_and_render_simregion :: proc (sim_arena: ^Arena, mode: ^World_Mode, dt: f32, screen_bounds: Rectangle2, sim_bounds: Rectangle3, mouse_p: v2, render_group: ^RenderGroup, state: ^State, input: ^Input, haze_color: v4) {
    timed_function()
    
    sim_origin := mode.camera_p
    
    sim_memory := begin_temporary_memory(sim_arena)
    
    sim_region := begin_sim(sim_memory.arena, mode, sim_origin, sim_bounds, dt, mode.particle_cache)
    
    frame_to_frame_camera_delta := world_distance(mode.world, mode.last_camera_p, mode.camera_p)
    mode.last_camera_p = mode.camera_p
    camera_p := mode.camera_offset + world_distance(mode.world, mode.camera_p, sim_origin)
    
    ////////////////////////////////////////////////
    // Look to see if any players are trying to join
    
    if state != nil && input != nil {
        handle_join_inputs := begin_timed_block("handle_join_inputs")
        for controller, controller_index in input.controllers {
            con_hero := &state.controlled_heroes[controller_index]
            if con_hero.brain_id == 0 {
                if was_pressed(controller.start) {
                    standing_on, ok := get_closest_traversable(sim_region, camera_p, {.Unoccupied} )
                    assert(ok) // @todo(viktor): GameUI that tells you there is no safe space...maybe keep trying on subsequent frames?
                    
                    brain_id := cast(BrainId) controller_index + cast(BrainId) ReservedBrainId.FirstHero
                    con_hero ^= { brain_id = brain_id }
                    add_hero(mode, sim_region, standing_on, brain_id)
                }
            } else {
                if is_down(controller.shoulder_left) {
                    standing_on, ok := get_closest_traversable(sim_region, camera_p, {.Unoccupied} )
                    if ok {
                        p := map_into_worldspace(mode.world, mode.camera_p, standing_on.entity.pointer.p)
                        add_monster(mode, p, standing_on)
                    }
                }
            }
        }
        end_timed_block(handle_join_inputs)
    }
    
    ////////////////////////////////////////////////
    
    execute_brains := begin_timed_block("execute_brains")
    for &brain in slice(sim_region.brains) {
        mark_brain_active(&brain)
    }
    for &brain in slice(sim_region.brains) {
        execute_brain(mode, sim_region, dt, &brain, state, input)
    }
    end_timed_block(execute_brains)
    
    ////////////////////////////////////////////////
    
    update_and_render_entities(mode, sim_region, dt, mouse_p, render_group, camera_p, haze_color)
    
    if render_group != nil {
        update_and_render_particle_systems(mode.particle_cache, render_group, dt, frame_to_frame_camera_delta, camera_p)
     
        if ShowRenderAndSimulationBounds {
            world_transform := default_flat_transform()
            world_transform.offset -= camera_p 
            push_rectangle_outline(render_group, screen_bounds,               world_transform, Orange, 0.1)
            push_rectangle_outline(render_group, sim_region.bounds,           world_transform, Blue,   0.2)
            push_rectangle_outline(render_group, sim_region.updatable_bounds, world_transform, Green,  0.2)
        }
    }
    
    // @todo(viktor): Make sure we hoist the camera update out to a place where the renderer
    // can know about the location of the camera at the end of the frame so there isn't
    // a frame of lag in camera updating compared to the hero.
    end_sim(sim_region, mode)
    end_temporary_memory(sim_memory)
}

////////////////////////////////////////////////

map_into_worldspace :: proc (world: ^World, center: WorldPosition, offset: v3 = {0,0,0}) -> WorldPosition {
    result := center
    result.offset += offset
    
    rounded_offset := round(i32, result.offset / world.chunk_dim_meters)
    result.chunk   =  result.chunk + rounded_offset
    result.offset  -= vec_cast(f32, rounded_offset) * world.chunk_dim_meters
    
    assert(is_canonical(world, result.offset))
    
    return result
}

world_distance :: proc (world: ^World, a, b: WorldPosition) -> (result: v3) {
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
get_chunk_3_internal :: proc(world: ^World, chunk_p: v3i) -> (result: ^^Chunk) {
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
get_chunk_3 :: proc(arena: ^Arena = nil, world: ^World, chunk_p: v3i) -> (result: ^Chunk) {
    next_pointer_of_the_chunks_previous_chunk := get_chunk_3_internal(world, chunk_p)
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

////////////////////////////////////////////////

extract_chunk :: proc(world: ^World, chunk_p: v3i) -> (result: ^Chunk) {
    next_pointer_of_the_chunks_previous_chunk := get_chunk_3_internal(world, chunk_p)
    result = next_pointer_of_the_chunks_previous_chunk^
    
    if result != nil {
        next_pointer_of_the_chunks_previous_chunk ^= result.next
    }
    
    return result
}

use_space_in_world :: proc(world: ^World, pack_size: i64, p: WorldPosition) -> (result: ^Entity) {
    chunk := get_chunk(world.arena, world, p)
    assert(chunk != nil)
    
    result = use_space_in_chunk(world, pack_size, chunk)
    
    return result
}

use_space_in_chunk :: proc(world: ^World, pack_size: i64, chunk: ^Chunk) -> (result: ^Entity) {
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

clear_world_entity_block :: proc(block: ^WorldEntityBlock) {
    block.entity_count = 0
    block.entity_data.count = 0
    block.next = nil
}

block_has_room :: proc(block: ^WorldEntityBlock, size: i64) -> b32 {
    return block.entity_data.count + size < len(block.entity_data.data)
}