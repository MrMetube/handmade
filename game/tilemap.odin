package game

import "core:fmt"


TILE_BITS  :: 8
CHUNK_BITS :: 32 - TILE_BITS

CHUNK_SIZE :: 1 << TILE_BITS

Chunk :: [CHUNK_SIZE][CHUNK_SIZE]u32

Tilemap :: struct {
	tile_size_in_meters: f32,
	tile_size_in_pixels: u32,
	meters_to_pixels: f32,
	chunks_size: [2]u32,
	chunks : []Chunk,
}

TilemapPosition :: struct {
	using _ : struct #raw_union {
		chunk_tile: [2]u32,
		using _ : bit_field u64 { // TODO is this worth it?
			tile_x:  u32 | TILE_BITS,
			chunk_x: u32 | CHUNK_BITS,
			tile_y:  u32 | TILE_BITS,
			chunk_y: u32 | CHUNK_BITS,
		}
	},
	
	tile_position: [2]f32,
}

cannonicalize_position :: #force_inline proc(tilemap: ^Tilemap, point: TilemapPosition) -> TilemapPosition {
	result := point

	// NOTE: the world is assumed to be toroidal topology
	// if you leave on one end you end up the other end
	offset := round(point.tile_position / tilemap.tile_size_in_meters)
	result.chunk_tile    += cast_vec(u32, offset)
	result.tile_position -= cast_vec(f32, offset) * tilemap.tile_size_in_meters

	assert(result.tile_position.x >= -tilemap.tile_size_in_meters * 0.5)
	assert(result.tile_position.y >= -tilemap.tile_size_in_meters * 0.5)
	assert(result.tile_position.x <=  tilemap.tile_size_in_meters * 0.5)
	assert(result.tile_position.y <=  tilemap.tile_size_in_meters * 0.5)

	return result
}

is_tilemap_position_empty :: proc(tilemap: ^Tilemap, point: TilemapPosition) -> b32 {
	empty : b32
	current_chunk, ok := get_chunk(tilemap, point)
	if ok {
		tile := get_tile_value(current_chunk, point.tile_x, point.tile_y)
		empty = tile == 0
	}
	return empty
}



set_tile_value :: proc(tilemap: ^Tilemap, point: TilemapPosition, value: u32) {
	chunk, ok := get_chunk(tilemap, point)
	// TODO on demand tilechunk creatton
	assert(chunk != nil && auto_cast ok)
	if in_bounds(chunk[:], point.tile_x, point.tile_y) {
		chunk[point.tile_y][point.tile_x] = value
	}
}



get_chunk :: proc {
	get_chunk_pos,
	get_chunk_2,
}

get_chunk_pos :: proc(tilemap: ^Tilemap, point: TilemapPosition) -> (chunk: ^Chunk, ok: b32) #optional_ok {
	return get_chunk(tilemap, point.chunk_x, point.chunk_y)
}
get_chunk_2 :: proc(tilemap: ^Tilemap, chunk_x, chunk_y: u32) -> (chunk: ^Chunk, ok: b32) #optional_ok {
	if 0 <= chunk_x && chunk_x <= tilemap.chunks_size.x && 0 <= chunk_y && chunk_y <= tilemap.chunks_size.y {
		return &tilemap.chunks[chunk_y * tilemap.chunks_size.x + chunk_x], true
	}
	return
}

get_tile_value :: proc(chunk: ^Chunk, tile_x, tile_y: u32) -> (tile: u32) {
	if in_bounds(chunk[:], tile_x, tile_y) {
		tile = chunk[tile_y][tile_x]
	}
	return tile
}
