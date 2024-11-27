package game

import "core:fmt"

Entity :: struct {
    // NOTE(viktor): these are only for the sim region
	storage_index: StorageIndex,
    updatable: b32,
    
	type: EntityType,
    flags: EntityFlags,

    p, dp: v3,

    size: v3,

    distance_limit: f32,

    hit_point_max: u32,
    hit_points: [16]HitPoint,

    sword: EntityReference,

	facing_index: i32,
	t_bob: f32,
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
	bounds, updatable_bounds: Rectangle3,

    max_entity_radius: f32,
    max_entity_velocity: f32,

	entity_count: EntityIndex,
    entities: []Entity,

	// TODO(viktor): Do I really want a hash for this?
	// NOTE(viktor): Must be a power of two
	sim_entity_hash: [4096]SimEntityHash,
}

begin_sim :: proc(sim_arena: ^Arena, state: ^GameState, world: ^World, origin: WorldPosition, bounds: Rectangle3, dt: f32) -> (region: ^SimRegion) {
	// TODO(viktor): make storedEntities part of world
	region = push_struct(sim_arena, SimRegion)
	MAX_ENTITY_COUNT :: 4096
	zero_struct(region)
	region.entities = push_slice(sim_arena, Entity, MAX_ENTITY_COUNT)

    // TODO(viktor): Try to make these get enforced more rigorously
    // TODO(viktor): Perhaps try using a dual system here where we support 
    // entities larger than the max entity radius by adding them multiple 
    // times to the spatial partition?
    region.max_entity_radius   = 5
    region.max_entity_velocity = 30
    update_safety_margin := region.max_entity_radius + dt * region.max_entity_velocity
    UPDATE_SAFETY_MARGIN_Z :: 1 // TODO(viktor): what should this be?

	region.world = world
	region.origin = origin
	region.updatable_bounds = rectangle_add(bounds, update_safety_margin)
	region.bounds = rectangle_add(bounds, v3{update_safety_margin, update_safety_margin, UPDATE_SAFETY_MARGIN_Z})

    min_p := map_into_worldspace(world, region.origin, region.bounds.min )
    max_p := map_into_worldspace(world, region.origin, region.bounds.max )
    // TODO(viktor): this needs to be accelarated, but man, this CPU is crazy fast
    // TODO(viktor): entities get visually duplicated when crossing the edge of the sim_region, fix it
    for chunk_y in min_p.chunk.y ..= max_p.chunk.y {
        for chunk_x in min_p.chunk.x ..= max_p.chunk.x {
            chunk := get_chunk(nil, world, chunk_x, chunk_y, region.origin.chunk.z)
            if chunk != nil {
                for block := &chunk.first_block; block != nil; block = block.next {
                    for storage_index in block.indices[:block.entity_count] {
						stored := &state.stored_entities[storage_index]
                        if .Nonspatial not_in stored.sim.flags {
                            sim_space_p := get_sim_space_p(region, stored)
                            if entity_overlaps_rectangle(region.bounds, sim_space_p, stored.sim.size) {
                                // TODO(viktor): check a seconds rectangle to set the entity to be "moveable" or not
                                add_entity(state, region, storage_index, stored, &sim_space_p)
                            }
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
	for entity in region.entities[:region.entity_count] {
        assert(entity.storage_index != 0)
		stored := &state.stored_entities[entity.storage_index]

        assert(.Simulated in entity.flags)
		stored.sim = entity
        stored.sim.flags -= {.Simulated}
        assert(.Simulated not_in stored.sim.flags)

		store_entity_reference(&stored.sim.sword)
		// TODO(viktor): Save state back to stored entity, once high entities do state decompression

		new_p := .Nonspatial in entity.flags ? null_position() : map_into_worldspace(state.world, region.origin, entity.p)
		change_entity_location(&state.world_arena, region.world, entity.storage_index, stored, new_p)
		
		if entity.storage_index == state.camera_following_index {
            new_camera_p: WorldPosition
            when false {
                new_camera_p = state.camera_p
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
				new_camera_p.chunk  = stored.p.chunk
				new_camera_p.offset.xy = stored.p.offset.xy
			}
            state.camera_p = new_camera_p
		}
	}
}

entity_overlaps_rectangle :: #force_inline proc(bounds: Rectangle3, p, dim: v3) -> (result: b32) {
    grown := rectangle_add(bounds, 0.5 * dim)
    result = rectangle_contains(grown, p)
    return result
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
            entity := get_low_entity(state, ref.index)
            p := get_sim_space_p(region, entity)
			entry.ptr = add_entity(state, region, ref.index, entity, &p)
		}
		ref.ptr = entry.ptr
	}
}

store_entity_reference :: #force_inline proc(ref: ^EntityReference) {
	if ref.ptr != nil {
		ref.index = ref.ptr.storage_index
	}
}

add_entity :: #force_inline proc(state: ^GameState, region: ^SimRegion, storage_index: StorageIndex, source: ^StoredEntity, sim_p: ^v3) -> (dest: ^Entity) {
	dest = add_entity_raw(state, region, storage_index, source)

	if dest != nil {
		if sim_p != nil {
			dest.p = sim_p^
            dest.updatable = entity_overlaps_rectangle(region.updatable_bounds, dest.p, dest.size)
		} else {
			dest.p = get_sim_space_p(region, source)
		}
	}

	return dest
}

add_entity_raw :: proc(state: ^GameState, region: ^SimRegion, storage_index: StorageIndex, source: ^StoredEntity) -> (entity: ^Entity) {
	assert(storage_index != 0)
        
    entry := get_hash_from_index(region, storage_index)
    if entry.ptr == nil {
        entity = &region.entities[region.entity_count]
        region.entity_count += 1
        
        assert(entry.index == 0 || entry.index == storage_index)
        entry.index = storage_index
        entry.ptr = entity

        if source != nil {
            // TODO(viktor): this should really be a decompression not a copy
            entity^ = source.sim

            load_entity_reference(state, region, &entity.sword)

            assert(.Simulated not_in entity.flags)
            entity.flags += { .Simulated }
        }
        entity.storage_index = storage_index
        entity.updatable = false
    }
	
    assert(entity == nil || .Simulated in entity.flags)
	return entity
}

INVALID_P :: v3{100_000, 100_000, 100_000}

get_sim_space_p :: #force_inline proc(region: ^SimRegion, stored: ^StoredEntity) -> (result: v3) {
    // TODO(viktor): Do we want to set this to signaling NAN in 
    // debug mode to make sure nobody ever uses the position of
    // a nonspatial entity?
    result = INVALID_P
    if .Nonspatial not_in stored.sim.flags {
        result = world_difference(region.world, stored.p, region.origin)
    }
    return result
}

MoveSpec :: struct {
    normalize_accelaration: b32,
    drag: f32,
    speed: f32,
}

default_move_spec :: #force_inline proc() -> MoveSpec {
    return { false, 1, 0}
}

move_entity :: proc(state: ^GameState, region: ^SimRegion, entity: ^Entity, ddp: v3, move_spec: MoveSpec, dt: f32) {
    assert(.Nonspatial not_in entity.flags)

    ddp := ddp
    
    if move_spec.normalize_accelaration {
        ddp_length_squared := length_squared(ddp)

        if ddp_length_squared > 1 {
            ddp *= 1 / square_root(ddp_length_squared)
        }
    }

    ddp *= move_spec.speed

    // TODO(viktor): ODE here
    ddp += -move_spec.drag * entity.dp
    GRAVITY :: -9.8
    ddp.z += GRAVITY

    entity_delta := 0.5*ddp * square(dt) + entity.dp * dt
    entity.dp = ddp * dt + entity.dp
    // TODO(viktor): upgrade physical motion routines to handle capping the maximum velocity?
    assert(length_squared(entity.dp) <= square(region.max_entity_velocity))

    distance_remaining := entity.distance_limit
    if distance_remaining == 0 {
        // TODO(viktor): Do we want to formalize this number?
        distance_remaining = 1_000_000
    }
    
    overlapping_count: u32
    overlapping_entities: [16]^Entity
    { // NOTE(viktor): check for initial inclusion
        entity_rect := rectangle_center_diameter(entity.p, entity.size)
        // TODO(viktor): spatial partition here
        for &test_entity in region.entities[:region.entity_count] {
            if should_collide(state, entity, &test_entity) {
                test_entity_rect := rectangle_center_diameter(test_entity.p, test_entity.size)
                if rectangle_intersect(entity_rect, test_entity_rect) {
                    /* if add_collision_rule(state, entity.storage_index, test_entity.storage_index, false) */ {
                        overlapping_entities[overlapping_count] = &test_entity
                        overlapping_count += 1
                    }
                }
            }
        }
    }

    for iteration in 0..<4 {
        t_min: f32 = 1
        wall_normal: v3
        hit: ^Entity

        entity_delta_length := length(entity_delta)
        // TODO(viktor): What do we want to do for epsilons here?
        if entity_delta_length > 0 {
            if entity_delta_length > distance_remaining {
                t_min = distance_remaining / entity_delta_length
            }

            desired_p := entity.p + entity_delta

            if .Nonspatial not_in entity.flags {
                // TODO(viktor): spatial partition here
                for &test_entity in region.entities[:region.entity_count] {
                    if should_collide(state, entity, &test_entity) {
                        if .Collides in test_entity.flags && .Nonspatial not_in test_entity.flags {
                            minkowski_diameter := entity.size + test_entity.size
                            min_corner := -0.5 * minkowski_diameter
                            max_corner :=  0.5 * minkowski_diameter

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
                                wall_normal = {-1,  0, 0}
                                hit = &test_entity
                            }
                            if test_wall(max_corner.x, entity_delta.x, entity_delta.y, rel.x, rel.y, min_corner.y, max_corner.y, &t_min) {
                                wall_normal = { 1,  0, 0}
                                hit = &test_entity
                            }
                            if test_wall(min_corner.y, entity_delta.y, entity_delta.x, rel.y, rel.x, min_corner.x, max_corner.x, &t_min) {
                                wall_normal = { 0, -1, 0}
                                hit = &test_entity
                            }
                            if test_wall(max_corner.y, entity_delta.y, entity_delta.x, rel.y, rel.x, min_corner.x, max_corner.x, &t_min) {
                                wall_normal = { 0,  1, 0}
                                hit = &test_entity
                            }
                        }
                    }
                }
            } 

            entity.p += t_min * entity_delta
            distance_remaining -= t_min * entity_delta_length
            if hit != nil {
                entity_delta = desired_p - entity.p
                
                overlap_index := overlapping_count
                #reverse for overlapping_entity, index in overlapping_entities[:overlapping_count] {
                    if hit == overlapping_entity {
                        overlap_index = cast(u32) index
                        break
                    }
                }
                
                was_overlapping: b32 = overlap_index != overlapping_count
                add_to_overlapping, remove_from_overlapping: b32

                stops_on_collision := handle_collision(state, entity, hit, was_overlapping)
                if stops_on_collision {
                    entity.dp    = project(entity.dp, wall_normal)
                    entity_delta = project(entity_delta, wall_normal)
                } else {
                    if was_overlapping {
                        overlapping_entities[overlap_index] = overlapping_entities[overlapping_count]
                        overlapping_count -= 1
                    } else {
                        overlapping_entities[overlapping_count] = hit
                        overlapping_count += 1
                    }
                }

            } else {
                break
            }
        } else {
            break
        }
    }
    // TODO(viktor): this has to become real height handling, ground collision, etc.
    if entity.p.z < 0 {
        entity.p.z = 0;
        entity.dp.z = 0;
    }

    if entity.distance_limit != 0 {
        entity.distance_limit = distance_remaining
    }

    if entity.dp.x < 0  {
        entity.facing_index = 0
    } else {
        entity.facing_index = 1
    }
}

should_collide :: proc(state:^GameState, a, b: ^Entity) -> (result: b32) {
    if a != b {
        a, b := a, b
        if a.storage_index > b.storage_index do swap(&a, &b)

        if .Nonspatial not_in a.flags && .Nonspatial not_in b.flags {
            // TODO(viktor): property-based logic goes here
            result = true
        }
        
        // TODO(viktor): BETTER HASH FUNCTION!!!
        hash_bucket := a.storage_index & (len(state.collision_rule_hash) - 1)
        for rule := state.collision_rule_hash[hash_bucket]; rule != nil; rule = rule.next_in_hash {
            if rule.index_a == a.storage_index && rule.index_b == b.storage_index {
                result = rule.should_collide
                break
            }
        }
    }
    return result
}

handle_collision :: proc(state: ^GameState, a, b: ^Entity, was_overlapping: b32) -> (stops_on_collision: b32) {
    a, b := a, b
    if a.type > b.type do swap(&a, &b)

    if b.type == .Sword {
        add_collision_rule(state, a.storage_index, b.storage_index, false)
        stops_on_collision = false
    } else {
        stops_on_collision = true
    }

    // TODO(viktor): stairs
    // entity.p.chunk.z += hit_stored_entity.d_tile_z
    
    if a.type == .Monster && b.type == .Sword {
        if a.hit_point_max > 0 {
            a.hit_point_max -= 1
        }
    }

    if a.type == .Hero && b.type == .Stairwell {
        stops_on_collision = false
    }

    return stops_on_collision
}