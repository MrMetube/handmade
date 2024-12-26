package game

import "core:fmt"

TilesPerChunk :: 16

WorldPosition :: struct {
    // TODO(viktor): It seems like we have to store ChunkX/Y/Z with each
    // entity because even though the sim region gather doesn't need it
    // at first, and we could get by without it, but entity references pull
    // in entities WITHOUT going through their world_chunk, and thus
    // still need to know the ChunkX/Y/Z
    chunk: [3]i32,
    offset: v3,
}

// TODO(viktor): Could make this just Chunk and then allow multiple tile chunks per X/Y/Z
WorldEntityBlock :: struct {
    entity_count: StorageIndex,
    indices: [16]StorageIndex,
    next: ^WorldEntityBlock,
}

Chunk :: struct {
    chunk: [3]i32,

    first_block: WorldEntityBlock,

    next_in_hash: ^Chunk,
}

World :: struct {
    tile_size_in_meters: f32,
    tile_depth_in_meters: f32,
    chunk_dim_meters: v3,

    // TODO(viktor): chunk_hash should probably switch to pointers IF
    // tile_entity_blocks continue to be stored en masse in the tile chunk!
        chunk_hash: [4096]Chunk,

    first_free: ^WorldEntityBlock
}

null_position :: #force_inline proc() -> (result:WorldPosition) {
    result.chunk.x = UninitializedChunk
    return result
}

is_valid :: #force_inline proc(p: WorldPosition) -> b32 {
    return p.chunk.x != UninitializedChunk
}

change_entity_location :: #force_inline proc(arena: ^Arena = nil, world: ^World, index: StorageIndex, stored: ^StoredEntity, new_p_init: WorldPosition) {
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

change_entity_location_raw :: #force_inline proc(arena: ^Arena = nil, world: ^World, storage_index: StorageIndex, new_p: ^WorldPosition, old_p: ^WorldPosition = nil) {
    // TODO(viktor): if the entity moves  into the camera bounds, shoulds this force the entity into the high set immediatly?
    assert(auto_cast (old_p == nil || is_valid(old_p^)))
    assert(auto_cast (new_p == nil || is_valid(new_p^)))

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
                                    next_block := first_block.next
                                    first_block^ = next_block^

                                    next_block.next = world.first_free
                                    world.first_free = next_block
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
                old_block := world.first_free
                if old_block != nil {
                    world.first_free = old_block.next
                } else {
                    old_block = push_struct(arena, WorldEntityBlock)
                }
                old_block^ = block^
                block.next = old_block
                block.entity_count = 0
            }
            assert(block.entity_count < len(block.indices))

            block.indices[block.entity_count] = storage_index
            block.entity_count += 1
        }
    }
}

map_into_worldspace :: proc(world: ^World, center: WorldPosition, offset: v3 = {}) -> WorldPosition {
    result := center
    result.offset += offset

    rounded_offset  := round(result.offset / world.chunk_dim_meters)
    result.chunk  = result.chunk + rounded_offset
    result.offset -= vec_cast(f32, rounded_offset) * world.chunk_dim_meters

    assert(auto_cast is_canonical(world, result.offset))

    return result
}

world_difference :: #force_inline proc(world: ^World, a, b: WorldPosition) -> (result: v3) {
    chunk_delta  := vec_cast(f32, a.chunk) - vec_cast(f32, b.chunk)
    offset_delta := a.offset - b.offset
    result = chunk_delta * world.chunk_dim_meters
    result += offset_delta
    return result
}

is_canonical :: #force_inline proc(world: ^World, offset: v3) -> b32 {
    epsilon: f32 = 0.0001
    half_size := 0.5 * world.chunk_dim_meters + epsilon
    return -half_size.x <= offset.x && offset.x <= half_size.x &&
           -half_size.y <= offset.y && offset.y <= half_size.y &&
           -half_size.z <= offset.z && offset.z <= half_size.z
}

are_in_same_chunk :: #force_inline proc(world: ^World, a, b: WorldPosition) -> b32 {
    assert(auto_cast is_canonical(world, a.offset))
    assert(auto_cast is_canonical(world, b.offset))

    return a.chunk == b.chunk
}

chunk_position_from_tile_positon :: #force_inline proc(world: ^World, tile_x, tile_y, tile_z: i32, additional_offset := v3{}) -> (result: WorldPosition) {
    offset := world.tile_size_in_meters * vec_cast(f32, tile_x, tile_y, tile_z)
    
    result = map_into_worldspace(world, result, offset + additional_offset)
    
    assert(auto_cast is_canonical(world, result.offset))

    return result
}

get_chunk :: proc {
    get_chunk_pos,
    get_chunk_3,
}

// TODO(viktor): arena as allocator, maybe on the context?
get_chunk_pos :: proc(arena: ^Arena = nil, world: ^World, point: WorldPosition) -> ^Chunk {
    return get_chunk_3(arena, world, point.chunk.x, point.chunk.y, point.chunk.z)
}
get_chunk_3 :: proc(arena: ^Arena = nil, world: ^World, chunk_x, chunk_y, chunk_z: i32) -> ^Chunk {
    ChunkSafeMargin :: 256

    assert(chunk_x > min(i32) + ChunkSafeMargin)
    assert(chunk_x < max(i32) - ChunkSafeMargin)
    assert(chunk_y > min(i32) + ChunkSafeMargin)
    assert(chunk_y < max(i32) - ChunkSafeMargin)
    assert(chunk_z > min(i32) + ChunkSafeMargin)
    assert(chunk_z < max(i32) - ChunkSafeMargin)

    // TODO(viktor): BETTER HASH FUNCTION !!
    hash_value := 19*chunk_x + 7*chunk_y + 3*chunk_z
    hash_slot := hash_value & (len(world.chunk_hash)-1)

    assert(hash_slot < len(world.chunk_hash))

    world_chunk := &world.chunk_hash[hash_slot]
    for {
        if chunk_x == world_chunk.chunk.x && chunk_y == world_chunk.chunk.y && chunk_z == world_chunk.chunk.z {
            break
        }

        if arena != nil && world_chunk.chunk.x != UninitializedChunk && world_chunk.next_in_hash == nil {
            world_chunk.next_in_hash = push_struct(arena, Chunk)
            world_chunk = world_chunk.next_in_hash
            world_chunk.chunk.x = UninitializedChunk
        }

        if arena != nil && world_chunk.chunk.x == UninitializedChunk {
            world_chunk.chunk = {chunk_x, chunk_y, chunk_z}
            world_chunk.next_in_hash = nil

            break
        }

        world_chunk = world_chunk.next_in_hash
        if world_chunk == nil do break
    }

    return world_chunk
}

init_world :: proc(world: ^World, tile_size_in_meters, tile_depth_in_meters: f32) {
    world.tile_size_in_meters  = tile_size_in_meters
    world.tile_depth_in_meters = tile_depth_in_meters
    world.chunk_dim_meters = { TilesPerChunk * tile_size_in_meters,
                               TilesPerChunk * tile_size_in_meters,
                               world.tile_depth_in_meters }

    world.first_free = nil
    for &chunk_block in world.chunk_hash {
        chunk_block.chunk.x = UninitializedChunk
        chunk_block.first_block.entity_count = 0
    }
}

@(private="file")
UninitializedChunk :: min(i32)
