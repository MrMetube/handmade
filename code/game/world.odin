package game

World_ :: struct {
    arena: Arena,
    
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
    entity_data: FixedArray(1 << 14, u8), // :DisjointArray of Entity Data and inlined member arrays or specialized :Arena
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

create_world :: proc (chunk_dim_in_meters: v3, parent_arena: ^Arena) -> (result: ^ World_) {
    result = push(parent_arena, World_)
    result.chunk_dim_meters = chunk_dim_in_meters
    sub_arena(&result.arena, parent_arena, arena_remaining_size(parent_arena), no_clear())
    
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

update_and_render_world :: proc(state: ^State, world_mode: ^World_Mode, tran_state: ^TransientState, render_group: ^RenderGroup, input: Input) {
    timed_function()

    dt := input.delta_time * TimestepPercentage/100.0
    
    monitor_width_in_meters :: 0.635
    meters_to_pixels_for_monitor := cast(f32) render_group.commands.width / monitor_width_in_meters
    
    focal_length, distance_above_ground : f32 = 0.3, 10
    perspective(render_group, meters_to_pixels_for_monitor, focal_length, distance_above_ground)
    
    haze_color := DarkBlue
    push_clear(render_group, haze_color * {1,1,1,0})
    
    screen_bounds := get_camera_rectangle_at_target(render_group)
    camera_bounds := rectangle_min_max(
        V3(screen_bounds.min, -0.5 * world_mode.typical_floor_height), 
        V3(screen_bounds.max, 4 * world_mode.typical_floor_height),
    )
    
    sim_memory := begin_temporary_memory(&tran_state.arena)
    // @todo(viktor): by how much should we expand the sim region?
    // @todo(viktor): do we want to simulate upper floors, etc?
    sim_bounds := add_radius(camera_bounds, v3{30, 30, 20})
    sim_origin := world_mode.camera_p
    sim_region := begin_sim(&tran_state.arena, world_mode, sim_origin, sim_bounds, dt, world_mode.particle_cache)
    
    camera_p := world_mode.camera_offset + world_distance(world_mode.world, world_mode.camera_p, sim_origin)
    
    if ShowRenderAndSimulationBounds {
        transform := default_flat_transform()
        transform.offset -= camera_p
        transform.chunk_z = 10000
        push_rectangle_outline(render_group, screen_bounds,               transform, Orange, 0.1)
        push_rectangle_outline(render_group, sim_region.bounds,           transform, Blue,   0.2)
        push_rectangle_outline(render_group, sim_region.updatable_bounds, transform, Green,  0.2)
    }
    
    ////////////////////////////////////////////////
    // Look to see if any players are trying to join
    
    handle_join_inputs := begin_timed_block("handle_join_inputs")
    for controller, controller_index in input.controllers {
        con_hero := &state.controlled_heroes[controller_index]
        if con_hero.brain_id == 0 {
            if was_pressed(controller.start) {
                standing_on, ok := get_closest_traversable(sim_region, camera_p, {.Unoccupied} )
                assert(ok) // @todo(viktor): GameUI that tells you there is no safe space...
                // maybe keep trying on subsequent frames?
                
                brain_id := cast(BrainId) controller_index + cast(BrainId) ReservedBrainId.FirstHero
                con_hero ^= { brain_id = brain_id }
                add_hero(world_mode, sim_region, standing_on, brain_id)
            }
        } else {
            if is_down(controller.shoulder_left) {
                standing_on, ok := get_closest_traversable(sim_region, camera_p, {.Unoccupied} )
                if ok {
                    p := map_into_worldspace(world_mode.world, world_mode.camera_p, standing_on.entity.pointer.p)
                    add_monster(world_mode, p, standing_on)
                }
            }
        }
    }
    end_timed_block(handle_join_inputs)
    
    ////////////////////////////////////////////////
    
    execute_brains := begin_timed_block("execute_brains")
    for &brain in slice(sim_region.brains) {
        mark_brain_active(&brain)
    }
    for &brain in slice(sim_region.brains) {
        execute_brain(state, input, world_mode, sim_region, render_group, &brain)
    }
    end_timed_block(execute_brains)
    
    ////////////////////////////////////////////////
    
    // @todo(viktor): :TransientClipRect
    old_clip_rect_index := render_group.current_clip_rect_index
    defer render_group.current_clip_rect_index = old_clip_rect_index

    update_and_render_entities(input, world_mode, sim_region, render_group, camera_p, dt, haze_color)
    
    update_and_render_particle_systems(world_mode.particle_cache, render_group, dt)
    
    ////////////////////////////////////////////////
    
    enviroment_test()
    
    ////////////////////////////////////////////////
    
    // @todo(viktor): Make sure we hoist the camera update out to a place where the renderer
    // can know about the location of the camera at the end of the frame so there isn't
    // a frame of lag in camera updating compared to the hero.
    end_sim(sim_region, world_mode)
    end_temporary_memory(sim_memory)
    
    check_arena(&world_mode.world.arena)
    
    // @todo(viktor): Should switch mode. Implemented in :CutsceneEpisodes
    heroes_exist: b32
    for con_hero in state.controlled_heroes {
        if con_hero.brain_id != 0 {
            heroes_exist = true
            break
        }
    }
}

////////////////////////////////////////////////

map_into_worldspace :: proc(world: ^World_, center: WorldPosition, offset: v3 = {0,0,0}) -> WorldPosition {
    result := center
    result.offset += offset
    
    rounded_offset := round(i32, result.offset / world.chunk_dim_meters)
    result.chunk   =  result.chunk + rounded_offset
    result.offset  -= vec_cast(f32, rounded_offset) * world.chunk_dim_meters
    
    assert(is_canonical(world, result.offset))
    
    return result
}

world_distance :: proc(world: ^World_, a, b: WorldPosition) -> (result: v3) {
    chunk_delta  := vec_cast(f32, a.chunk) - vec_cast(f32, b.chunk)
    offset_delta := a.offset - b.offset
    result = chunk_delta * world.chunk_dim_meters
    result += offset_delta
    return result
}

is_canonical :: proc(world: ^World_, offset: v3) -> b32 {
    epsilon: f32 = 0.0001
    half_size := 0.5 * world.chunk_dim_meters + epsilon
    return -half_size.x <= offset.x && offset.x <= half_size.x &&
           -half_size.y <= offset.y && offset.y <= half_size.y &&
           -half_size.z <= offset.z && offset.z <= half_size.z
}

get_chunk :: proc (arena: ^Arena = nil, world: ^World_, point: WorldPosition) -> ^Chunk {
    return get_chunk_3(arena, world, point.chunk)
}
get_chunk_3_internal :: proc(world: ^World_, chunk_p: v3i) -> (result: ^^Chunk) {
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
get_chunk_3 :: proc(arena: ^Arena = nil, world: ^World_, chunk_p: v3i) -> (result: ^Chunk) {
    next_pointer_of_the_chunks_previous_chunk := get_chunk_3_internal(world, chunk_p)
    result = next_pointer_of_the_chunks_previous_chunk^
        
    if arena != nil && result == nil {
        result = list_pop_head(&world.first_free_chunk) or_else push(arena, Chunk)
        result ^= {
            chunk = chunk_p
        }
        
        list_push(next_pointer_of_the_chunks_previous_chunk, result) 
    }
    
    return result
}

////////////////////////////////////////////////

extract_chunk :: proc(world: ^World_, chunk_p: v3i) -> (result: ^Chunk) {
    next_pointer_of_the_chunks_previous_chunk := get_chunk_3_internal(world, chunk_p)
    result = next_pointer_of_the_chunks_previous_chunk^
    
    if result != nil {
        next_pointer_of_the_chunks_previous_chunk ^= result.next
    }
    
    return result
}

pack_entity_into_world :: proc(region: ^SimRegion, world: ^World_, source: ^Entity, p: WorldPosition) {
    chunk := get_chunk(&world.arena, world, p)
    assert(chunk != nil)
    
    source.p = p.offset

    pack_entity_into_chunk(region, world, source, chunk)
}

pack_entity_into_chunk :: proc(region: ^SimRegion, world: ^World_, source: ^Entity, chunk: ^Chunk) {
    assert(chunk != nil)
    
    pack_size := cast(i64) size_of(Entity)
    
    if chunk.first_block == nil || !block_has_room(chunk.first_block, pack_size) {
        new_block := list_pop_head(&world.first_free_block) or_else push(&world.arena, WorldEntityBlock, no_clear())
        
        clear_world_entity_block(new_block)
        
        list_push(&chunk.first_block, new_block)
    }
    assert(block_has_room(chunk.first_block, pack_size))
    
    block := chunk.first_block
    
    // :PointerArithmetic
    entity := cast(^Entity)  &block.entity_data.data[block.entity_data.count]
    block.entity_data.count += pack_size
    block.entity_count += 1
    
    entity ^= source^
    
    // @volatile see Entity definition @metaprogram
    entity.ddp = 0
    entity.ddt_bob = 0
    
    pack_traversable_reference(region, &entity.came_from)
    pack_traversable_reference(region, &entity.occupying)
    
    pack_traversable_reference(region, &entity.auto_boost_to)
}

pack_entity_reference :: proc(region: ^SimRegion, ref: ^EntityReference) {
    if ref.pointer != nil {
        if .MarkedForDeletion in ref.pointer.flags {
            ref.id = 0
        } else {
            ref.id = ref.pointer.id
        }
    } else if ref.id != 0 {
        if region != nil && get_entity_hash_from_id(region, ref.id) != nil {
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
