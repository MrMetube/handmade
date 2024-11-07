package game

import "core:fmt"


WorldPosition :: struct {
	tile: [3]i32,
	offset_: v2,
}

// TODO(viktor): is this a [dynamic]LowEntity ?
// TODO(viktor): Could make this just Chunk and then allow multiple tile chunks per X/Y/Z
WorldEntityBlock :: struct {
	entity_count: u32,
	indices: [16]LowIndex,
	next: ^WorldEntityBlock,
}

Chunk :: struct {
	chunk: [3]i32,

	first_block: WorldEntityBlock,

	next_in_hash: ^Chunk,
}

TILE_BITS  :: 8
CHUNK_BITS :: 32 - TILE_BITS

CHUNK_SIZE :: 1 << TILE_BITS

World :: struct {
	tile_size_in_meters: f32,
	// TODO(viktor): chunk_hash should probably switch to pointers IF 
	// tile_entity_blocks continue to be stored en masse in the tile chunk!
	chunk_hash: [4096]Chunk,
}



map_into_worldspace :: proc(world: ^World, center: WorldPosition, offset: v3 = 0) -> WorldPosition {
	result := center
	result.offset_ += offset.xy
	// NOTE: the world is assumed to be toroidal topology
	// if you leave on one end you end up the other end
    rounded_offset := round(result.offset_ / world.tile_size_in_meters)
	result.tile.xy  = result.tile.xy + rounded_offset
	result.offset_ -= vec_cast(f32, rounded_offset) * world.tile_size_in_meters

	assert(result.offset_.x >= -0.5 * world.tile_size_in_meters)
	assert(result.offset_.y >= -0.5 * world.tile_size_in_meters)
	assert(result.offset_.x <=  0.5 * world.tile_size_in_meters)
	assert(result.offset_.y <=  0.5 * world.tile_size_in_meters)

	return result
}

world_difference :: #force_inline proc(world: ^World, a, b: WorldPosition) -> v3 {
	position_delta := vec_cast(f32, a.tile.xy) - vec_cast(f32, b.tile.xy)
	offset_delta     := a.offset_ - b.offset_
	total_delta      := (position_delta * world.tile_size_in_meters + offset_delta)
	return {total_delta.x, total_delta.y, cast(f32) (a.tile.z - b.tile.z)}
}


 
are_on_same_tile :: #force_inline proc(a, b: WorldPosition) -> b32 {
	return a.tile == b.tile
}

get_chunk :: proc {
	// get_chunk_pos,
	get_chunk_3,
}

// TODO(viktor): arena as allocator, maybe on the context?
// get_chunk_pos :: proc(world: ^World, point: WorldPosition, arena: ^Arena = nil) -> ^Chunk {
// 	return get_chunk(world, point.chunk_x, point.chunk_y, point.chunk_z, arena)
// }
get_chunk_3 :: proc(world: ^World, chunk_x, chunk_y, chunk_z: i32, arena: ^Arena = nil) -> ^Chunk {
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

	chunk := &world.chunk_hash[hash_slot]
	for chunk != nil {
		if chunk_x == chunk.chunk.x && chunk_y == chunk.chunk.y && chunk_z == chunk.chunk.z {
			break
		}
		
		if arena != nil && chunk.chunk.x != EMPTY_CHUNK_HASH_TILE_X && chunk.next_in_hash == nil {
			chunk.next_in_hash = push_struct(arena, Chunk)
			chunk.chunk.x = EMPTY_CHUNK_HASH_TILE_X
			chunk = chunk.next_in_hash
		}

		if arena != nil && chunk.chunk.x == EMPTY_CHUNK_HASH_TILE_X {
			chunk.chunk = {chunk_x, chunk_y, chunk_z}
			chunk.next_in_hash = nil

			break
		}
	}

	return chunk
}

init_world :: proc(world: ^World, tile_size_in_meters: f32) {
	world.tile_size_in_meters = tile_size_in_meters
	for &chunk in world.chunk_hash {
		chunk.chunk.x = EMPTY_CHUNK_HASH_TILE_X
	}
}

@(private="file")
EMPTY_CHUNK_HASH_TILE_X :: I32_MIN
