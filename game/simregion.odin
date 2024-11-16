package game

SimRegion :: struct {
	world: ^World,

	origin: WorldPosition, 
	bounds: Rectangle,

	entity_count: EntityIndex,
    entities: []SimEntity,
}

SimEntity :: struct {
	storage_index: StorageIndex,

    p: v3,
}

begin_sim :: proc(sim_arena: ^Arena, state: ^GameState, world: ^World, origin: WorldPosition, bounds: Rectangle) -> (region: ^SimRegion) {
	// TODO(viktor): make storedEntities part of world
	region = push_struct(sim_arena, SimRegion)
	MAX_ENTITY_COUNT :: 4096
	region.entities = push_slice(sim_arena, SimEntity, MAX_ENTITY_COUNT)

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
							add_entity(region, stored, &sim_space_p)
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
	for entity in region.entities {
		stored := state.stored_entities[entity.storage_index]

		// TODO(viktor): Save state back to stored entity

		new_p := map_into_worldspace(state.world, region.origin, entity.p.xy)
		change_entity_location(&state.world_arena, region.world, entity.storage_index, &stored, &new_p, &stored.p)
		
		// TODO(viktor): entity mapping hashtable
		if entity := force_entity_into_high(state, state.camera_following_index); entity.high != nil {
			new_camera_p := state.camera_p
when !true {
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
			new_camera_p = entity.low.p
}
		}

	}

}

add_entity :: proc { add_entity_new, add_entity_from_world_entity }

add_entity_from_world_entity :: proc(region: ^SimRegion, source: ^StoredEntity, sim_p: ^v2) -> (dest: ^SimEntity) {
	dest = add_entity(region)

	if dest != nil {
		// TODO(viktor): convert the storage entity to a simulation entity
		if sim_p != nil {
			dest.p.xy = sim_p^
		} else {
			dest.p.xy = get_sim_space_p(region, source)
		}
	}

	return dest
}

add_entity_new :: proc(region: ^SimRegion) -> (entity: ^SimEntity) {
	if region.entity_count < auto_cast len(region.entities) {
		entity = &region.entities[region.entity_count]
		region.entity_count += 1
		// TODO(viktor): See what we want to do about clearing policy when the entity system is more fleshed out.
		entity^ = {}
	} else {
		unreachable()
	}

	return entity
}


get_sim_space_p :: #force_inline proc(region: ^SimRegion, stored: ^StoredEntity) -> v2 {
    diff := world_difference(region.world, stored.p, region.origin) 
    return diff.xy
}
