package game

import "core:fmt"


TILE_BITS  :: 8
CHUNK_BITS :: 32 - TILE_BITS

CHUNK_SIZE :: 1 << TILE_BITS

Tile :: u32
Chunk :: struct {
	tile_chunk: [3]i32,
	tiles: []Tile,

	next_in_hash: ^Chunk,
}

Tilemap :: struct {
	tile_size_in_meters: f32,
	chunk_hash: [4096]Chunk,
}

TilemapPosition :: struct {
	using _chunk_tile_union : struct #raw_union {
		position: [3]i32,
		using _components : bit_field [3]u32 {
			tile_x:  u32 | TILE_BITS,
			chunk_x: i32 | CHUNK_BITS,
			tile_y:  u32 | TILE_BITS,
			chunk_y: i32 | CHUNK_BITS,
			chunk_z: i32 | 32,
		}
	},
	
	offset_: [2]f32,
}
#assert(size_of(TilemapPosition{}._chunk_tile_union.position) == size_of(TilemapPosition{}._chunk_tile_union._components))



map_into_tilespace :: proc(tilemap: ^Tilemap, center: TilemapPosition, offset: v3 = 0) -> TilemapPosition {
	result := center
	result.offset_ += offset.xy
	// NOTE: the world is assumed to be toroidal topology
	// if you leave on one end you end up the other end
    rounded_offset := round(result.offset_ / tilemap.tile_size_in_meters)
	result.position.xy  = result.position.xy + rounded_offset
	result.offset_ -= vec_cast(f32, rounded_offset) * tilemap.tile_size_in_meters

	assert(result.offset_.x >= -0.5 * tilemap.tile_size_in_meters)
	assert(result.offset_.y >= -0.5 * tilemap.tile_size_in_meters)
	assert(result.offset_.x <=  0.5 * tilemap.tile_size_in_meters)
	assert(result.offset_.y <=  0.5 * tilemap.tile_size_in_meters)

	return result
}

tilemap_difference :: #force_inline proc(tilemap: ^Tilemap, a, b: TilemapPosition) -> v3 {
	chunk_tile_delta := vec_cast(f32, a.position.xy) - vec_cast(f32, b.position.xy)
	offset_delta     := a.offset_ - b.offset_
	total_delta      := (chunk_tile_delta * tilemap.tile_size_in_meters + offset_delta)
	return {total_delta.x, total_delta.y, cast(f32) (a.position.z - b.position.z)}
}



is_tilemap_position_empty :: proc(tilemap: ^Tilemap, point: TilemapPosition) -> b32 {
	empty : b32
	current_chunk := get_chunk(tilemap, point)
	if current_chunk != nil {
		tile := get_tile_value(current_chunk, point.tile_x, point.tile_y)
		empty = is_tile_empty(tile)
	}
	return empty
}

is_tile_empty :: #force_inline proc(tile: u32) -> b32 {
	return tile != 2 && tile != 0
}
 
are_on_same_tile :: #force_inline proc(a, b: TilemapPosition) -> b32 {
	return a.position == b.position
}

set_tile_value :: proc(arena: ^Arena= nil, tilemap: ^Tilemap, point: TilemapPosition, value: Tile) {
	chunk := get_chunk(tilemap, point, arena)
	assert(chunk.tiles != nil)

	if point.tile_x < CHUNK_SIZE && point.tile_y < CHUNK_SIZE {
		chunk.tiles[point.tile_y * CHUNK_SIZE + point.tile_x] = value
	}
}


get_chunk :: proc {
	get_chunk_pos,
	get_chunk_2,
}

get_chunk_pos :: proc(tilemap: ^Tilemap, point: TilemapPosition, arena: ^Arena = nil) -> ^Chunk {
	return get_chunk(tilemap, point.chunk_x, point.chunk_y, point.chunk_z, arena)
}
get_chunk_2 :: proc(tilemap: ^Tilemap, chunk_x, chunk_y, chunk_z: i32, arena: ^Arena = nil) -> ^Chunk {
	CHUNK_SAFE_MARGIN :: 256

	assert(chunk_x > I32_MIN + CHUNK_SAFE_MARGIN)
	assert(chunk_x < I32_MAX - CHUNK_SAFE_MARGIN)
	assert(chunk_y > I32_MIN + CHUNK_SAFE_MARGIN)
	assert(chunk_y < I32_MAX - CHUNK_SAFE_MARGIN)
	assert(chunk_z > I32_MIN + CHUNK_SAFE_MARGIN)
	assert(chunk_z < I32_MAX - CHUNK_SAFE_MARGIN)

	// TODO(viktor): BETTER HASH FUNCTION !!
	hash_value := 19*chunk_x + 7*chunk_y + 3*chunk_z
	hash_slot := hash_value & (len(tilemap.chunk_hash)-1)

	assert(hash_slot < len(tilemap.chunk_hash))

	chunk := &tilemap.chunk_hash[hash_slot]
	for chunk != nil {
		if chunk_x == chunk.tile_chunk.x && chunk_y == chunk.tile_chunk.y && chunk_z == chunk.tile_chunk.z {
			break
		}
		
		if arena != nil && chunk.tile_chunk.x != EMPTY_CHUNK_HASH_TILE_X && chunk.next_in_hash == nil {
			chunk.next_in_hash = push_struct(arena, Chunk)
			chunk.tile_chunk.x = EMPTY_CHUNK_HASH_TILE_X
			chunk = chunk.next_in_hash
		}

		if arena != nil && chunk.tile_chunk.x == EMPTY_CHUNK_HASH_TILE_X {
			chunk.tiles = push_slice(arena, Tile, CHUNK_SIZE*CHUNK_SIZE)

			chunk.tile_chunk = {chunk_x, chunk_y, chunk_z}
			chunk.next_in_hash = nil

			for &tile in chunk.tiles {
				tile = 1
			}

			break
		}
	}

	return chunk
}

get_tile_value :: proc {
	get_tile_value_unchecked,
	get_tile_value_checked_tile,
	get_tile_value_checked_tilemap_position,
}

get_tile_value_checked_tile :: proc(tilemap: ^Tilemap, x,y,z: i32) -> (tile: Tile) {
	return get_tile_value_checked_tilemap_position(tilemap, { position = {x, y, z} })
}

get_tile_value_checked_tilemap_position :: proc(tilemap: ^Tilemap, point: TilemapPosition) -> (tile: Tile) {
	chunk := get_chunk(tilemap, point.chunk_x, point.chunk_y, point.chunk_z)
	return get_tile_value(chunk, point.tile_x, point.tile_y)
}

get_tile_value_unchecked :: proc(chunk: ^Chunk, tile_x, tile_y: u32) -> (tile: Tile) {
	if chunk != nil && tile_x < CHUNK_SIZE && tile_y < CHUNK_SIZE {
		tile = chunk.tiles[tile_y * CHUNK_SIZE + tile_x]
	}
	return tile
}

@(private="file")
EMPTY_CHUNK_HASH_TILE_X :: I32_MIN


init_tilemap :: proc(tilemap: ^Tilemap, tile_size_in_meters: f32) {
	tilemap.tile_size_in_meters = tile_size_in_meters
	for &chunk in tilemap.chunk_hash {
		chunk.tile_chunk.x = EMPTY_CHUNK_HASH_TILE_X
	}
}