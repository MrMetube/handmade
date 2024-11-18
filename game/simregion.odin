package game

Entity :: struct {
	storage_index: StorageIndex,

	type: EntityType,

    p: v3,
	dp: v3,

    size: v2,

    // NOTE(viktor): This is for "stairs"
    d_tile_z: i32,
    collides: b32,

    hit_point_max: u32,
    hit_points: [16]HitPoint,

    sword: EntityReference,
    distance_remaining: f32,

	facing_index: i32,
	t_bob:f32,

	// TODO(viktor): generation index so we know how " to date" this entity is
}

EntityReference :: struct #raw_union {
	ptr: ^Entity,
	index: StorageIndex,
}

SimEntityHash :: struct {
	ptr: ^Entity,
	index: StorageIndex,
}

SimRegion :: struct {
	world: ^World,

	origin: WorldPosition, 
	bounds: Rectangle,

	entity_count: EntityIndex,
    entities: []Entity,

	// TODO(viktor): Do I really want a hash for this?
	// NOTE(viktor): Must be a power of two
	sim_entity_hash: [4096]SimEntityHash,
}

begin_sim :: proc(sim_arena: ^Arena, state: ^GameState, world: ^World, origin: WorldPosition, bounds: Rectangle) -> (region: ^SimRegion) {
	// TODO(viktor): make storedEntities part of world
	region = push_struct(sim_arena, SimRegion)
	MAX_ENTITY_COUNT :: 4096
	region.entities = push_slice(sim_arena, Entity, MAX_ENTITY_COUNT)
	zero_struct(&region.sim_entity_hash)

	region.world = world
	region.origin = origin
	region.bounds = bounds

    min_p := map_into_worldspace(world, region.origin, region.bounds.min)
    max_p := map_into_worldspace(world, region.origin, region.bounds.max)
    // TODO(viktor): this needs to be accelarated, but man, this CPU is crazy fast
    for chunk_y in min_p.chunk.y ..= max_p.chunk.y {
        for chunk_x in min_p.chunk.x ..= max_p.chunk.x {
            chunk := get_chunk(nil, world, chunk_x, chunk_y, region.origin.chunk.z)
            if chunk != nil {
                for block := &chunk.first_block; block != nil; block = block.next {
                    for entity_index in 0..< block.entity_count {
                        storage_index := block.indices[entity_index]
						stored := &state.stored_entities[storage_index]

						sim_space_p := get_sim_space_p(region, stored)
						if is_in_rectangle(region.bounds, sim_space_p.xy) {
							// TODO(viktor): check a seconds rectangle to set the entity to be "moveable" or not
							add_entity(state, region, storage_index, stored, &sim_space_p)
						}
                    }
                }
            }
        }
    }

	return region
}

end_sim :: proc(region: ^SimRegion, state: ^GameState) {
	// TODO(viktor): make storedEntities part of world
	for entity_index in 0..<region.entity_count {
		entity := region.entities[entity_index]
		stored := state.stored_entities[entity.storage_index]
		stored.sim = entity
		store_entity_reference(&stored.sim.sword)
		// TODO(viktor): Save state back to stored entity

		new_p := map_into_worldspace(state.world, region.origin, entity.p.xy)
		change_entity_location(&state.world_arena, region.world, entity.storage_index, &stored, &new_p, &stored.p)
		
		// TODO(viktor): should this be written to anywhere=
		if entity.storage_index == state.camera_following_index {
			new_camera_p := state.camera_p
			when false {
				new_camera_p.chunk.z = entity.low.p.chunk.z
				offset := entity.high.p

				if offset.x < -9 * world.tile_size_in_meters {
					new_camera_p.offset_.x -= 17
				}
				if offset.x > 9 * world.tile_size_in_meters {
					new_camera_p.offset_.x += 17
				}
				if offset.y < -5 * world.tile_size_in_meters {
					new_camera_p.offset_.y -= 9
				}
				if offset.y > 5 * world.tile_size_in_meters {
					new_camera_p.offset_.y += 9
				}
			} else {
				new_camera_p = stored.p
			}
		}
	}
}

get_hash_from_index :: proc(region: ^SimRegion, storage_index: StorageIndex) -> (result: ^SimEntityHash) {
	assert(storage_index != 0)

	hash := cast(u32) storage_index
	for offset in u32(0)..<len(region.sim_entity_hash) {
		hash_mask: u32 = len(region.sim_entity_hash)-1
		hash_index := (hash + offset) & hash_mask
		entry := &region.sim_entity_hash[hash_index]
		if entry.index == 0 || entry.index == storage_index {
			result = entry
			break
		}
	}
	return result
}

map_storage_index_to_entity :: proc(region: ^SimRegion, storage_index: StorageIndex, entity: ^Entity) {
	entry := get_hash_from_index(region, storage_index)
	assert(entry != nil)
	assert(entry.index == 0 || entry.index == storage_index)

	entry.index = storage_index
	entry.ptr = entity
}

get_entity_by_storage_index :: #force_inline proc(region: ^SimRegion, storage_index: StorageIndex) -> (result: ^Entity) {
	entry := get_hash_from_index(region, storage_index)
	result = entry.ptr
	return result
}

load_entity_reference :: #force_inline proc(state: ^GameState, region: ^SimRegion, ref: ^EntityReference) {
	if ref.index != 0 {
		entry := get_hash_from_index(region, ref.index)
		if entry.ptr == nil {
			entry.index = ref.index
			entry.ptr = add_entity(state, region, ref.index, get_low_entity(state, ref.index))
		}
		ref.ptr = entry.ptr
	}
}

store_entity_reference :: #force_inline proc(ref: ^EntityReference) {
	if ref.ptr != nil {
		ref.index = ref.ptr.storage_index
	}
}

add_entity :: proc { add_entity_new, add_entity_from_world_entity }

add_entity_new :: proc(state: ^GameState, region: ^SimRegion, storage_index: StorageIndex, copy: ^StoredEntity) -> (entity: ^Entity) {
	assert(storage_index != 0)

	entity = &region.entities[region.entity_count]
	region.entity_count += 1
	map_storage_index_to_entity(region, storage_index, entity)
	if copy != nil {
		// TODO(viktor): this should really be a decompression not a copy
		entity^ = copy.sim
		load_entity_reference(state, region, &entity.sword)
	}
	entity.storage_index = storage_index
	
	return entity
}

add_entity_from_world_entity :: proc(state: ^GameState, region: ^SimRegion, storage_index: StorageIndex, source: ^StoredEntity, sim_p: ^v2) -> (dest: ^Entity) {
	assert(source != nil)
	dest = add_entity_new(state, region, storage_index, source)

	if dest != nil {
		if sim_p != nil {
			dest.p.xy = sim_p^
		} else {
			dest.p.xy = get_sim_space_p(region, source)
		}
	}

	return dest
}

get_sim_space_p :: #force_inline proc(region: ^SimRegion, stored: ^StoredEntity) -> v2 {
    diff := world_difference(region.world, stored.p, region.origin) 
    return diff.xy
}

MoveSpec :: struct {
    normalize_accelaration: b32,
    drag: f32,
    speed: f32,
}

default_move_spec :: #force_inline proc() -> MoveSpec {
    return { false, 1, 0}
}

move_entity :: proc(region: ^SimRegion, entity: ^Entity, ddp: v2, move_spec: MoveSpec, dt: f32) {
    ddp := ddp
    
    if move_spec.normalize_accelaration {
        ddp_length_squared := length_squared(ddp)

        if ddp_length_squared > 1 {
            ddp *= 1 / square_root(ddp_length_squared)
        }
    }

    ddp *= move_spec.speed

    // TODO(viktor): ODE here
    ddp += -move_spec.drag * entity.dp.xy

    entity_delta := 0.5*ddp * square(dt) + entity.dp.xy * dt
    entity.dp.xy = ddp * dt + entity.dp.xy

    for iteration in 0..<4 {
        desired_p := entity.p.xy + entity_delta

        t_min: f32 = 1
        wall_normal: v2
        hit: ^Entity
        
        if entity.collides {
			// TODO(viktor): spatial partition here
            for test_entity_index in 0..<region.entity_count {
				test_entity := &region.entities[test_entity_index]

                if entity != test_entity {
                    if test_entity.collides {
                        diameter := entity.size + test_entity.size
                        min_corner := -0.5 * diameter
                        max_corner :=  0.5 * diameter

                        rel := entity.p - test_entity.p

                        test_wall :: proc(wall_x, entity_delta_x, entity_delta_y, rel_x, rel_y, min_y, max_y: f32, t_min: ^f32) -> (collided: b32) {
                            EPSILON :: 0.01
                            if entity_delta_x != 0 {
                                t_result := (wall_x - rel_x) / entity_delta_x
                                y := rel_y + t_result * entity_delta_y
                                if 0 <= t_result && t_result < t_min^ {
                                    if y >= min_y && y <= max_y {
                                        t_min^ = max(0, t_result-EPSILON)
                                        collided = true
                                    }
                                }
                            }
                            return collided
                        }

                        if test_wall(min_corner.x, entity_delta.x, entity_delta.y, rel.x, rel.y, min_corner.y, max_corner.y, &t_min) {
                            wall_normal = {-1,  0}
                            hit = test_entity
                        }
                        if test_wall(max_corner.x, entity_delta.x, entity_delta.y, rel.x, rel.y, min_corner.y, max_corner.y, &t_min) {
                            wall_normal = { 1,  0}
                            hit = test_entity
                        }
                        if test_wall(min_corner.y, entity_delta.y, entity_delta.x, rel.y, rel.x, min_corner.x, max_corner.x, &t_min) {
                            wall_normal = { 0, -1}
                            hit = test_entity
                        }
                        if test_wall(max_corner.y, entity_delta.y, entity_delta.x, rel.y, rel.x, min_corner.x, max_corner.x, &t_min) {
                            wall_normal = { 0,  1}
                            hit = test_entity
                        }
                    }
                }
            }
        }

        entity.p.xy += t_min * entity_delta

        if hit != nil {
            entity.dp.xy = project(entity.dp.xy, wall_normal)
            entity_delta = desired_p - entity.p.xy
            entity_delta = project(entity_delta, wall_normal)

            // entity.p.chunk.z += hit_stored_entity.d_tile_z
        } else {
            break
        }
    }

    if ddp.x < 0  {
        entity.facing_index = 0
    } else {
        entity.facing_index = 1
    }
}
