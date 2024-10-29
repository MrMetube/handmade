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
	
	offset: [2]f32,
}
#assert(size_of(TilemapPosition{}._chunk_tile_union.chunk_tile) == size_of(TilemapPosition{}._chunk_tile_union._components))

//
//
// TODO do these belong here?
//

cannonicalize_position :: #force_inline proc(tilemap: ^Tilemap, point: TilemapPosition) -> TilemapPosition {
	result := point

	// NOTE: the world is assumed to be toroidal topology
	// if you leave on one end you end up the other end
	offset := round(point.offset / tilemap.tile_size_in_meters)
	result.chunk_tile.xy  = vec_cast(u32, vec_cast(i32, result.chunk_tile.xy) + offset)
	result.offset -= vec_cast(f32, offset) * tilemap.tile_size_in_meters

	assert(result.offset.x >= -tilemap.tile_size_in_meters * 0.5)
	assert(result.offset.y >= -tilemap.tile_size_in_meters * 0.5)
	assert(result.offset.x <=  tilemap.tile_size_in_meters * 0.5)
	assert(result.offset.y <=  tilemap.tile_size_in_meters * 0.5)

	return result
}

//
//
//
//

tilemap_difference :: #force_inline proc(state: ^GameState, a, b: TilemapPosition) -> v2 {
	chunk_tile_delta := vec_cast(f32, a.chunk_tile.xy) - vec_cast(f32, b.chunk_tile.xy)
	offset_delta     := a.offset - b.offset
	total_delta      := (chunk_tile_delta * cast(f32) state.tile_size_in_pixels + offset_delta * state.meters_to_pixels)
	return total_delta
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
	return tile != 2
}
 
are_on_same_tile :: #force_inline proc(a, b: TilemapPosition) -> b32 {
	return a.chunk_tile == b.chunk_tile
}

set_tile_value :: proc(arena: ^Arena, tilemap: ^Tilemap, point: TilemapPosition, value: Tile) {
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

	#no_bounds_check if in_bounds(chunk[:], point.tile_x, point.tile_y) {
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
	#no_bounds_check if  
		0 <= chunk_x && chunk_x <= tilemap.chunks_size.x && 
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

get_tile_value :: proc {
	get_tile_value_unchecked,
	get_tile_value_checked_tile,
	get_tile_value_checked_tilemap_position,
}

get_tile_value_checked_tile :: proc(tilemap: ^Tilemap, x,y,z: u32) -> (tile: Tile) {
	return get_tile_value_checked_tilemap_position(tilemap, { chunk_tile = {x, y, z} })
}

get_tile_value_checked_tilemap_position :: proc(tilemap: ^Tilemap, point: TilemapPosition) -> (tile: Tile) {
	chunk := get_chunk(tilemap, point.chunk_x, point.chunk_y, point.chunk_z)
	return get_tile_value(chunk, point.tile_x, point.tile_y)
}

get_tile_value_unchecked :: proc(chunk: ^Chunk, tile_x, tile_y: u32) -> (tile: Tile) {
	if chunk != nil && in_bounds(chunk[:], tile_x, tile_y) {
		tile = chunk[tile_y][tile_x]
	}
	return tile
}
