#+vet !unused-procedures
package game

World :: struct {
    arena: ^Arena,
    
    chunk_dim_meters: v3,
    
    // @todo(viktor): chunk_hash should probably switch to pointers IF tile_entity_blocks continue to be stored en masse in the tile chunk!
    chunk_hash: [4096] ^Chunk,
    
    chunk_freelist: FreeList(Chunk),
    block_freelist: FreeList(WorldEntityBlock),
    
    game_entropy: RandomSeries,
    
    change_ticket: TicketMutex,
}

Chunk :: struct {
    next: ^Chunk,
    chunk: iv3,
    
    first_block: ^WorldEntityBlock,
}

// @todo(viktor): Could make this just Chunk and then allow multiple tile chunks per X/Y/Z
WorldEntityBlock :: struct {
    next: ^WorldEntityBlock,
    entity_count: u32,
    // @note(viktor): entity_data'count =^= size_of(Entity) * entity_count  for now, because there is no compression
    entity_data: [dynamic; 1 << 14] u8,
}

WorldPosition :: struct {
    // @todo(viktor): It seems like we have to store ChunkX/Y/Z with each entity because even though the sim region gather doesn't need it at first, and we could get by without it, but entity references pull in entities WITHOUT going through their world_chunk, and thus still need to know the ChunkX/Y/Z
    chunk:  iv3,
    offset: v3,
}

////////////////////////////////////////////////

create_world :: proc (chunk_dim_in_meters: v3, arena: ^Arena) -> ^World {
    result := push(arena, World)
    result.chunk_dim_meters = chunk_dim_in_meters
    result.arena = arena
    result.game_entropy = seed_random_series(12345)
    
    freelist_init(&result.chunk_freelist, result.arena)
    freelist_init(&result.block_freelist, result.arena)
    
    return result
}

chunk_position_from_tile_positon :: proc (mode: ^World_Mode, tile_p: iv3, additional_offset: v3 = {}) -> WorldPosition {
    world := mode.world
    tile_size_in_meters  := mode.tile_size_in_meters
    
    tile_depth_in_meters := world.chunk_dim_meters.z
    
    offset := v3{tile_size_in_meters, tile_size_in_meters, tile_depth_in_meters} * (cast(v3) tile_p + {0.5, 0.5, 0})
    offset.z -= 0.4 * tile_depth_in_meters
    result: WorldPosition
    result = map_into_worldspace(world, result, additional_offset + offset)
    
    assert(is_canonical(world, result.offset))
    
    return result
}

////////////////////////////////////////////////

map_into_worldspace :: proc (world: ^World, center: WorldPosition, offset: v3 = {0,0,0}) -> WorldPosition {
    result := center
    result.offset += offset
    
    rounded_offset := round(i32, result.offset / world.chunk_dim_meters)
    result.chunk   += rounded_offset
    result.offset  -= cast(v3) rounded_offset * world.chunk_dim_meters
    
    assert(is_canonical(world, result.offset))
    
    return result
}

get_chunk_bounds :: proc (world: ^World, chunk_p: iv3) -> Rectangle3 {
    chunk_center := cast(v3) chunk_p * world.chunk_dim_meters
    result := rectangle_center_dimension(chunk_center, world.chunk_dim_meters)
    return result
}

world_distance :: proc (world: ^World, a, b: WorldPosition) -> v3 {
    chunk_delta  := cast(v3) a.chunk - cast(v3) b.chunk
    offset_delta := a.offset - b.offset
    result := chunk_delta * world.chunk_dim_meters
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

get_chunk :: proc (arena: ^Arena, world: ^World, point: WorldPosition) -> ^Chunk {
    chunk_p := point.chunk
    
    next_pointer_of_the_chunks_previous_chunk := get_chunk_internal(world, chunk_p)
    result := next_pointer_of_the_chunks_previous_chunk^
    
    if arena != nil && result == nil {
        assert(arena == world.chunk_freelist.arena, "When I started using the freelist, all callers used world.arena, so its hardcoded as that in the freelist")
        result = freelist_push_next(&world.chunk_freelist, no_clear())
        result ^= {
            chunk = chunk_p,
        }
        
        list_push_next(next_pointer_of_the_chunks_previous_chunk, result) 
    }
    
    return result
}

get_chunk_internal :: proc (world: ^World, chunk_p: iv3) -> ^^Chunk {
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
    
    result := &world.chunk_hash[hash_slot]
    for result^ != nil && chunk_p != (result^).chunk {
        result = &(result^).next
    }
    
    return result
}

////////////////////////////////////////////////

extract_chunk :: proc (world: ^World, chunk_p: iv3) -> ^Chunk {
    begin_ticket_mutex(&world.change_ticket)
    
    next_pointer_of_the_chunks_previous_chunk := get_chunk_internal(world, chunk_p)
    result := next_pointer_of_the_chunks_previous_chunk^
    
    if result != nil {
        next_pointer_of_the_chunks_previous_chunk ^= result.next
    }
    
    end_ticket_mutex(&world.change_ticket)    
    
    return result
}

add_to_free_list :: proc (world: ^World, chunk: ^Chunk, first_block, last_block: ^WorldEntityBlock) {
    begin_ticket_mutex(&world.change_ticket)
    
    freelist_free_next(&world.chunk_freelist, chunk)
    if first_block != nil {
        // @note(viktor): push on the whole list from first to last
        freelist_free_list(&world.block_freelist, first_block, last_block)
    }
    
    end_ticket_mutex(&world.change_ticket)
}

use_space_in_world :: proc (world: ^World, pack_size: i64, p: WorldPosition) -> ^Entity {
    begin_ticket_mutex(&world.change_ticket)
    
    chunk := get_chunk(world.arena, world, p)
    assert(chunk != nil)
    
    result := use_space_in_chunk(world, pack_size, chunk)
    
    end_ticket_mutex(&world.change_ticket)
    
    return result
}

use_space_in_chunk :: proc (world: ^World, pack_size: i64, chunk: ^Chunk) -> ^Entity {
    assert(chunk != nil)
    
    if !block_has_room(chunk.first_block, pack_size) {
        new_block := freelist_push_next(&world.block_freelist, no_clear())
        
        clear_world_entity_block(new_block)
        
        list_push_next(&chunk.first_block, new_block)
    }
    assert(block_has_room(chunk.first_block, pack_size))
    
    block := chunk.first_block
    
    // :PointerArithmetic:
    count := len(block.entity_data)
    resize(&block.entity_data, count + cast(int) pack_size)
    result := cast(^Entity) &block.entity_data[count]
    block.entity_count += 1
    
    return result
}

clear_world_entity_block :: proc (block: ^WorldEntityBlock) {
    block.entity_count = 0
    clear(&block.entity_data)
    block.next = nil
}

block_has_room :: proc (block: ^WorldEntityBlock, size: i64) -> bool {
    result: bool
    if block != nil {
        result = len(block.entity_data) + cast(int) size < cap(block.entity_data)
    }
    
    return result
}
