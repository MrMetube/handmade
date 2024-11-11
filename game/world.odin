package game

import "core:fmt"

TILES_PER_CHUNK :: 16

WorldPosition :: struct {
	chunk: [3]i32,
	offset_: v2,
}

// TODO(viktor): Could make this just Chunk and then allow multiple tile chunks per X/Y/Z
WorldEntityBlock :: struct {
	entity_count: LowIndex,
	indices: [16]LowIndex,
	next: ^WorldEntityBlock,
}

Chunk :: struct {
	chunk: [3]i32,

	first_block: WorldEntityBlock,

	next_in_hash: ^Chunk,
}

World :: struct {
	tile_size_in_meters: f32,
	chunk_size_in_meters: f32,

	// TODO(viktor): chunk_hash should probably switch to pointers IF 
	// tile_entity_blocks continue to be stored en masse in the tile chunk!
	chunk_hash: [4096]Chunk,

	first_free: ^WorldEntityBlock
}

change_entity_location :: #force_inline proc(arena: ^Arena = nil, world: ^World, index: LowIndex, new_p: WorldPosition,  old_p: ^WorldPosition = nil) {
	if old_p != nil && are_in_same_chunk(world, old_p^, new_p) {
		// NOTE(viktor): leave entity where it is
	} else {
		if old_p != nil {
			// NOTE(viktor): Pull the entity out of its old block
			chunk := get_chunk(nil, world, old_p^)
			assert(chunk != nil)
			if chunk != nil {
				first_block := &chunk.first_block
				outer: for block := first_block; block != nil; block = block.next {
					for i in 0..<block.entity_count {
						if block.indices[i] == index {
							first_block.entity_count -= 1
							block.indices[i] = first_block.indices[first_block.entity_count]
							
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
		// NOTE(viktor): Insert the entity into its new block
		chunk := get_chunk(arena, world, new_p)
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

		block.indices[block.entity_count] = index
		block.entity_count += 1
	}
}

map_into_worldspace :: proc(world: ^World, center: WorldPosition, offset: v2 = 0) -> WorldPosition {
	result := center
	result.offset_ += offset
	// NOTE: the world is assumed to be toroidal topology
	// if you leave on one end you end up the other end
    rounded_offset := round(result.offset_ / world.chunk_size_in_meters)
	result.chunk.xy  = result.chunk.xy + rounded_offset
	result.offset_ -= vec_cast(f32, rounded_offset) * world.chunk_size_in_meters

	assert(auto_cast is_canonical(world, result.offset_))

	return result
}

world_difference :: #force_inline proc(world: ^World, a, b: WorldPosition) -> v3 {
	chunk_delta  := vec_cast(f32, a.chunk.xy) - vec_cast(f32, b.chunk.xy)
	offset_delta := a.offset_ - b.offset_
	total_delta  := (chunk_delta * world.chunk_size_in_meters + offset_delta)
	return {total_delta.x, total_delta.y, cast(f32) (a.chunk.z - b.chunk.z)}
}

is_canonical :: #force_inline proc(world: ^World, offset: v2) -> b32 {
	return offset.x >= -0.5 * world.chunk_size_in_meters && offset.x <= 0.5 * world.chunk_size_in_meters &&
			offset.y >= -0.5 * world.chunk_size_in_meters && offset.y <= 0.5 * world.chunk_size_in_meters
}

are_in_same_chunk :: #force_inline proc(world: ^World, a, b: WorldPosition) -> b32 {
	assert(auto_cast is_canonical(world, a.offset_))
	assert(auto_cast is_canonical(world, b.offset_))
	return a.chunk == b.chunk
}

chunk_position_from_tile_positon :: #force_inline proc(world: ^World, tile_x, tile_y, tile_z: i32) -> WorldPosition {
	result: WorldPosition
	result.chunk.x = tile_x / TILES_PER_CHUNK
	result.chunk.y = tile_y / TILES_PER_CHUNK
	result.chunk.z = tile_z

	result.offset_.x = cast(f32) (tile_x - result.chunk.x * TILES_PER_CHUNK) * world.tile_size_in_meters
	result.offset_.y = cast(f32) (tile_y - result.chunk.y * TILES_PER_CHUNK) * world.tile_size_in_meters

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
	CHUNK_SAFE_MARGIN :: 256

	assert(chunk_x > I32_MIN + CHUNK_SAFE_MARGIN)
	assert(chunk_x < I32_MAX - CHUNK_SAFE_MARGIN)
	assert(chunk_y > I32_MIN + CHUNK_SAFE_MARGIN)
	assert(chunk_y < I32_MAX - CHUNK_SAFE_MARGIN)
	assert(chunk_z > I32_MIN + CHUNK_SAFE_MARGIN)
	assert(chunk_z < I32_MAX - CHUNK_SAFE_MARGIN)

	// TODO(viktor): BETTER HASH FUNCTION !!
	hash_value := 19*chunk_x + 7*chunk_y + 3*chunk_z
	hash_slot := hash_value & (len(world.chunk_hash)-1)

	assert(hash_slot < len(world.chunk_hash))

    world_chunk := &world.chunk_hash[hash_slot]
	for {
		if chunk_x == world_chunk.chunk.x && chunk_y == world_chunk.chunk.y && chunk_z == world_chunk.chunk.z {
			break
		}
		
		if arena != nil && world_chunk.chunk.x != UNINITIALIZED_CHUNK && world_chunk.next_in_hash == nil {
			world_chunk.next_in_hash = push_struct(arena, Chunk)
			world_chunk = world_chunk.next_in_hash
			world_chunk.chunk.x = UNINITIALIZED_CHUNK
		}

		if arena != nil && world_chunk.chunk.x == UNINITIALIZED_CHUNK {
			world_chunk.chunk = {chunk_x, chunk_y, chunk_z}
			world_chunk.next_in_hash = nil

			break
		}

		world_chunk = world_chunk.next_in_hash
		if world_chunk == nil do break
	}

	return world_chunk
}

init_world :: proc(world: ^World, tile_size_in_meters: f32) {
	world.tile_size_in_meters  = tile_size_in_meters
	world.chunk_size_in_meters = TILES_PER_CHUNK * tile_size_in_meters
	world.first_free = nil

	for &chunk_block in world.chunk_hash {
		chunk_block.chunk.x = UNINITIALIZED_CHUNK
		chunk_block.first_block.entity_count = 0
	}
}

@(private="file")
UNINITIALIZED_CHUNK :: I32_MIN
