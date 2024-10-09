package game

import "core:fmt"


TILE_BITS  :: 4
CHUNK_BITS :: 32 - TILE_BITS

CHUNK_SIZE :: 1 << TILE_BITS

Tile :: u32
Chunk :: [CHUNK_SIZE][CHUNK_SIZE]Tile

Tilemap :: struct {
	tile_size_in_meters: f32,
	chunks_size: [3]u32,
	chunks: []^Chunk,
}

TilemapPosition :: struct {
	using _chunk_tile_union : struct #raw_union {
		chunk_tile: [3]u32,
		using _components : bit_field [3]u32 {
			tile_x:  u32 | TILE_BITS,
			chunk_x: u32 | CHUNK_BITS,
			tile_y:  u32 | TILE_BITS,
			chunk_y: u32 | CHUNK_BITS,
			chunk_z: u32 | 32,
		}
	},
	
	tile_position: [2]f32,
}
#assert(size_of(TilemapPosition{}._chunk_tile_union.chunk_tile) == size_of(TilemapPosition{}._chunk_tile_union._components))

cannonicalize_position :: #force_inline proc(tilemap: ^Tilemap, point: TilemapPosition) -> TilemapPosition {
	result := point

	// NOTE: the world is assumed to be toroidal topology
	// if you leave on one end you end up the other end
	offset := round(point.tile_position / tilemap.tile_size_in_meters)
	result.chunk_tile.xy  = cast_vec(u32, cast_vec(i32, result.chunk_tile.xy) + offset)
	result.tile_position -= cast_vec(f32, offset) * tilemap.tile_size_in_meters

	assert(result.tile_position.x >= -tilemap.tile_size_in_meters * 0.5)
	assert(result.tile_position.y >= -tilemap.tile_size_in_meters * 0.5)
	assert(result.tile_position.x <=  tilemap.tile_size_in_meters * 0.5)
	assert(result.tile_position.y <=  tilemap.tile_size_in_meters * 0.5)

	return result
}

is_tilemap_position_empty :: proc(tilemap: ^Tilemap, point: TilemapPosition) -> b32 {
	empty : b32
	current_chunk := get_chunk(tilemap, point)
	if current_chunk != nil {
		tile := get_tile_value(current_chunk, point.tile_x, point.tile_y)
		empty = tile != 2
	}
	return empty
}
 


set_tile_value :: proc(arena: ^MemoryArena, tilemap: ^Tilemap, point: TilemapPosition, value: Tile) {
	chunk_ptr := get_chunk_ref(tilemap, point)
	// TODO on demand tilechunk creatton
	chunk: ^Chunk
	if chunk_ptr == nil || chunk_ptr^ == nil {
		chunk = push_struct(arena, Chunk)
		tilemap.chunks[point.chunk_z * tilemap.chunks_size.y * tilemap.chunks_size.x + point.chunk_y * tilemap.chunks_size.x + point.chunk_x] = chunk
		for &row in chunk {
			for &tile in row {
				tile = 1
			}
		}
	} else{
		assert(chunk_ptr^ != nil)
		chunk = chunk_ptr^
	}

	if in_bounds(chunk[:], point.tile_x, point.tile_y) {
		chunk[point.tile_y][point.tile_x] = value
	}
}


get_chunk_ref :: proc {
	get_chunk_ref_pos,
	get_chunk_ref_2,
}

get_chunk_ref_pos :: proc(tilemap: ^Tilemap, point: TilemapPosition) -> ^^Chunk {
	return get_chunk_ref(tilemap, point.chunk_x, point.chunk_y, point.chunk_z)
}
get_chunk_ref_2 :: proc(tilemap: ^Tilemap, chunk_x, chunk_y, chunk_z: u32) -> ^^Chunk {
	if  0 <= chunk_x && chunk_x <= tilemap.chunks_size.x && 
		0 <= chunk_y && chunk_y <= tilemap.chunks_size.y &&
		0 <= chunk_z && chunk_z <= tilemap.chunks_size.z {
		return &tilemap.chunks[
			chunk_z * tilemap.chunks_size.y * tilemap.chunks_size.x + 
			chunk_y * tilemap.chunks_size.x + 
			chunk_x]
	}
	return nil
}


get_chunk :: proc {
	get_chunk_pos,
	get_chunk_2,
}

get_chunk_pos :: proc(tilemap: ^Tilemap, point: TilemapPosition) -> ^Chunk {
	value := get_chunk_ref_pos(tilemap, point)
	return value != nil ? value^ : nil
}
get_chunk_2 :: proc(tilemap: ^Tilemap, chunk_x, chunk_y, chunk_z: u32) -> ^Chunk {
	value := get_chunk_ref_2(tilemap, chunk_x, chunk_y, chunk_z)
	return value != nil ? value^ : nil
}

get_tile_value_checked :: proc(tilemap: ^Tilemap, point: TilemapPosition) -> (tile: Tile) {
	return get_tile_value(get_chunk(tilemap, point.chunk_x, point.chunk_y, point.chunk_z), point.tile_x, point.tile_y)
}

get_tile_value :: proc(chunk: ^Chunk, tile_x, tile_y: u32) -> (tile: Tile) {
	if chunk != nil && in_bounds(chunk[:], tile_x, tile_y) {
		tile = chunk[tile_y][tile_x]
	}
	return tile
}
