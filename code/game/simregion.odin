package game

SimRegion :: struct {
    world: ^World,
    
    origin: WorldPosition, 
    bounds, updatable_bounds: Rectangle3,
    
    max_entity_radius: f32,
    max_entity_velocity: f32,
    
    entities: Array(Entity),
    brains:   Array(Brain),
    
    // @todo(viktor): Do I really want a hash for this?
    entity_hash: [4096]EntityHash,
    brain_hash:  [128]BrainHash,
}

BrainHash :: struct {
    pointer: ^Brain,
    id:      BrainId, // @todo(viktor): Why are we storing these in the hash?
}

EntityHash :: struct {
    pointer: ^Entity,
    id:      EntityId, // @todo(viktor): Why are we storing these in the hash?
}

////////////////////////////////////////////////

begin_sim :: proc(sim_arena: ^Arena, world: ^World, origin: WorldPosition, bounds: Rectangle3, dt: f32) -> (region: ^SimRegion) {
    timed_function()
    
    region = push(sim_arena, SimRegion)
    
    MaxEntityCount :: 4096
    MaxBrainCount  :: 128
    region.entities = make_array(sim_arena, Entity, MaxEntityCount, no_clear())
    region.brains   = make_array(sim_arena, Brain,  MaxBrainCount,  no_clear())
    
    // @todo(viktor): Try to make these get enforced more rigorously
    // @todo(viktor): Perhaps try using a dual system here where we support 
    // entities larger than the max entity radius by adding them multiple 
    // times to the spatial partition?
    region.max_entity_radius   = 5
    region.max_entity_velocity = 300
    update_safety_margin := region.max_entity_radius + dt * region.max_entity_velocity
    UpdateSafetyMarginZ :: 1 // @todo(viktor): what should this be?
    
    region.world = world
    region.origin = origin
    region.updatable_bounds = rectangle_add_radius(bounds, v3{region.max_entity_radius, region.max_entity_radius, 0})
    region.bounds = rectangle_add_radius(bounds, v3{update_safety_margin, update_safety_margin, UpdateSafetyMarginZ})
    
    min_p := map_into_worldspace(world, region.origin, region.bounds.min)
    max_p := map_into_worldspace(world, region.origin, region.bounds.max)
    
    // @todo(viktor): @speed this needs to be accelarated, but man, this CPU is crazy fast
    for chunk_z in min_p.chunk.z ..= max_p.chunk.z {
        for chunk_y in min_p.chunk.y ..= max_p.chunk.y {
            for chunk_x in min_p.chunk.x ..= max_p.chunk.x {
                chunk_p := [3]i32{chunk_x, chunk_y, chunk_z}
                chunk := extract_chunk(world, chunk_p)
                
                if chunk != nil {
                    chunk_world_p := WorldPosition { chunk = chunk_p }
                    chunk_delta := world_distance(world, chunk_world_p, region.origin)
                    block := chunk.first_block
                    for block != nil {
                        // :PointerArithmetic
                        entities := (cast([^]Entity) &block.entity_data.data)[:block.entity_count]
                        for &source in entities {
                            // @todo(viktor): check a seconds rectangle to set the source to be "moveable" or not
                            assert(source.id != 0)
                            
                            hash := get_entity_hash_from_id(region, source.id)
                            assert(hash != nil)
                            assert(hash.pointer == nil)
                            
                            dest := append(&region.entities)
                            
                            assert(hash.id == 0 || hash.id == source.id)
                            hash.id = source.id
                            hash.pointer = dest
                            
                            // @todo(viktor): this should really be a decompression not a copy
                            dest ^= source
                            
                            dest.id = source.id
                            dest.p += chunk_delta
                            
                            dest.updatable = entity_overlaps_rectangle(region.updatable_bounds, dest.p, dest.collision.total_volume)
                            
                            if dest.brain_id != 0 {
                                brain := get_or_add_brain(region, dest.brain_id, dest.brain_kind)
                                // :PointerArtthmetic
                                base := cast([^]^Entity) &brain.parts
                                base[dest.brain_slot.index] = dest
                            }
                        }
                        
                        next_block := block.next
                        list_push(&world.first_free_block, block)
                        block = next_block
                    }
                    
                    list_push(&world.first_free_chunk, chunk)
                }
            }
        }
    }
    
    connect_entity_references(region)
    
    return region
}

end_sim :: proc(region: ^SimRegion) {
    timed_function()
    
    for &entity in slice(region.entities) {
        assert(entity.id != 0)
        if .MarkedForDeletion in entity.flags do continue
        
        entity_p := map_into_worldspace(region.world, region.origin, entity.p)
        chunk_p  := entity_p
        chunk_p.offset = 0
        chunk_delta := entity_p.offset - entity.p
        
        if entity.id == region.world.camera_following_id {
            // @volatile Room size
            room_delta := v3{25.5, 13.5, region.world.typical_floor_height}
            half_room_delta := room_delta*0.5
            half_room_apron := half_room_delta - {1, 1, 1} * 0.7
            height :f32= 0.5
            region.world.camera_offset = 0
            
            offset: v3
            delta := world_distance(region.world, entity_p, region.world.camera_p)
            
            for i in 0..<3 {
                if delta[i] >  half_room_delta[i] do offset[i] += room_delta[i]
                if delta[i] < -half_room_delta[i] do offset[i] -= room_delta[i]
            }
            
            region.world.camera_p = map_into_worldspace(region.world, region.world.camera_p, offset)
            
            delta -= offset
            if delta.y >  half_room_apron.y {
                t := clamp_01_to_range(half_room_apron.y, delta.y, half_room_delta.y)
                region.world.camera_offset.y = t*half_room_delta.y
                region.world.camera_offset.z = (-(t*t)+2*t)*height
            }
            
            if delta.y < -half_room_apron.y {
                t := clamp_01_to_range(-half_room_apron.y, delta.y, -half_room_delta.y)
                region.world.camera_offset.y = t*-half_room_delta.y
                region.world.camera_offset.z = (-(t*t)+2*t)*height
            }
            
            if delta.x >  half_room_apron.x {
                t := clamp_01_to_range(half_room_apron.x, delta.x, half_room_delta.x)
                region.world.camera_offset.x = t*half_room_delta.x
                region.world.camera_offset.z = (-(t*t)+2*t)*height
            }
            
            if delta.x < -half_room_apron.x {
                t := clamp_01_to_range(-half_room_apron.x, delta.x, -half_room_delta.x)
                region.world.camera_offset.x = t*-half_room_delta.x
                region.world.camera_offset.z = (-(t*t)+2*t)*height
            }
            
            if delta.z >  half_room_apron.z {
                t := clamp_01_to_range(half_room_apron.z, delta.z, half_room_delta.z)
                region.world.camera_offset.z = t*half_room_delta.z
            }
            
            if delta.z < -half_room_apron.z {
                t := clamp_01_to_range(-half_room_apron.z, delta.z, -half_room_delta.z)
                region.world.camera_offset.z = t*-half_room_delta.z
            }
        }
        
        entity.p += chunk_delta

        pack_entity_into_world(region, region.world, &entity, entity_p)
    }
}

////////////////////////////////////////////////
// @cleanup spacial queries and sim functions

get_closest_entity_by_brain_kind :: proc(region: ^SimRegion, from: v3, kind: BrainKind, max_radius: f32) -> (result: ^Entity, distance_squared: f32) {
    distance_squared = square(max_radius)
    // @todo(viktor): We could return the delta and more as we already computed them but do we need that?
        
    for &test in slice(region.entities) {
        if test.brain_kind == kind {
            dsq := length_squared(test.p.xy - from.xy)
            if dsq < distance_squared {
                distance_squared = dsq
                result = &test
            }
        }
    }
    
    return result, distance_squared
}

get_closest_traversable_along_ray :: proc(region: ^SimRegion, from_p: v3, dir: v3, skip: TraversableReference, flags: bit_set[enum{ Unoccupied }] = {}) -> (result: TraversableReference, ok: b32) {
    timed_function()
    // @todo(viktor): Actually implement a smarter spatial query
    for probe in 0..<10 {
        factor := cast(f32) probe * 0.5
        sample := from_p + dir * factor
        result, _ = get_closest_traversable(region, sample, flags)
        if result != skip {
            ok = true
            break
        }
    }
    
    return result, ok
}

get_closest_traversable :: proc(region: ^SimRegion, from_p: v3, flags: bit_set[enum{ Unoccupied }] = {}) -> (result: TraversableReference, ok: b32) {
    timed_function()
    // @todo(viktor): make spatial queries easy for things
    closest_point_dsq :f32= 1000
    for &test in slice(region.entities) {
        for point_index in 0..<test.traversables.count {
            point := get_sim_space_traversable(&test, point_index)
            
            valid := true
            if .Unoccupied in flags {
                valid = point.occupant == nil
            }
            
            if valid {
                delta_p := point.p - from_p
                // @todo(viktor): what should this value be
                delta_p.z *= max(0, abs(delta_p.z) - 1.0)
                
                dsq := length_squared(delta_p)
                if dsq < closest_point_dsq {
                    result.entity.pointer = &test
                    result.entity.id = test.id
                    result.index = point_index
                    
                    closest_point_dsq = dsq
                    ok = true
                }
            }
        }
    }
    
    return result, ok
}

entity_overlaps_rectangle :: proc(bounds: Rectangle3, p: v3, volume: Rectangle3) -> (result: b32) {
    grown := rectangle_add_radius(bounds, 0.5 * rectangle_get_dimension(volume))
    result = rectangle_contains(grown, p + rectangle_get_center(volume))
    return result
}

get_brain_hash_from_id :: proc(region: ^SimRegion, id: BrainId) -> (result: ^BrainHash) {
    assert(id != 0)
    
    hash := cast(u32) id
    for offset in u32(0)..<len(region.brain_hash) {
        hash_index := (hash + offset) % len(region.brain_hash)
        
        entry := &region.brain_hash[hash_index]
        if entry.id == 0 || entry.id == id {
            result = entry
            break
        }
    }
    
    return result
}

get_entity_hash_from_id :: proc(region: ^SimRegion, id: EntityId) -> (result: ^EntityHash) {
    assert(id != 0)
    
    hash := cast(u32) id
    for offset in u32(0)..<len(region.entity_hash) {
        hash_index := (hash + offset) % len(region.entity_hash)
        
        entry := &region.entity_hash[hash_index]
        if entry.id == 0 || entry.id == id {
            result = entry
            break
        }
    }

    return result
}

get_or_add_brain :: proc(region: ^SimRegion, id: BrainId, kind: BrainKind) -> (result: ^Brain) {
    hash := get_brain_hash_from_id(region, id)
    result = hash.pointer
    
    if result == nil {
        result = append(&region.brains)
        result.id = id
        result.kind = kind
        
        hash.pointer = result
    }
    
    return result
}

connect_entity_references :: proc(region: ^SimRegion) {
    timed_function()
    
    for &entity in slice(region.entities) {
        // for &ref in slice(entity.paired_entities) {
        //     load_entity_reference(region, &ref)
        // }
        
        load_traversable_reference(region, &entity.came_from)
        load_traversable_reference(region, &entity.occupying)
        if entity.occupying.entity.pointer != nil {
            entity.occupying.entity.pointer.traversables.data[entity.occupying.index].occupant = &entity
        }
    }
}

load_entity_reference :: proc(region: ^SimRegion, ref: ^EntityReference) {
    if ref.id != 0 {
        entry := get_entity_hash_from_id(region, ref.id)
        ref.pointer = entry == nil ? nil : entry.pointer
    }
}

load_traversable_reference :: proc(region: ^SimRegion, ref: ^TraversableReference) {
    load_entity_reference(region, &ref.entity)
}

get_traversable :: proc { get_traversable_ref, get_traversable_raw }
get_traversable_ref :: proc(ref: TraversableReference) -> (result: ^TraversablePoint) {
    return get_traversable_raw(ref.entity.pointer, ref.index)
}
get_traversable_raw :: proc(entity: ^Entity, index: i64) -> (result: ^TraversablePoint) {
    if entity != nil {
        result = &entity.traversables.data[index]
    }
    return result
}

get_sim_space_traversable :: proc { get_sim_space_traversable_ref, get_sim_space_traversable_raw }
get_sim_space_traversable_ref :: proc(ref: TraversableReference) -> (result: TraversablePoint) {
    return get_sim_space_traversable_raw(ref.entity.pointer, ref.index)
}
get_sim_space_traversable_raw :: proc(entity: ^Entity, index: i64) -> (result: TraversablePoint) {
    if entity != nil {
        point := get_traversable(entity, index)
        if point != nil {
            result = point^
        }
        
        result.p += entity.p
    }
    
    return result
}

transactional_occupy :: proc(entity: ^Entity, dest_ref: ^TraversableReference, desired_ref: TraversableReference) -> (result: b32) {
    desired := get_traversable(desired_ref)
    if desired.occupant == nil {
        dest := get_traversable(dest_ref^)
        if dest != nil {
            dest.occupant = nil
        }
        dest_ref ^= desired_ref
        desired.occupant = entity
        result = true
    }
    
    return result
}

move_entity :: proc(region: ^SimRegion, entity: ^Entity, dt: f32) {
    timed_function()
    
    entity_delta := 0.5*entity.ddp * square(dt) + entity.dp * dt
    entity.dp = entity.ddp * dt + entity.dp
    // @todo(viktor): upgrade physical motion routines to handle capping the maximum velocity?
    assert(length_squared(entity.dp) <= square(region.max_entity_velocity))
    
    distance_remaining := entity.distance_limit
    if distance_remaining == 0 {
        // @todo(viktor): Do we want to formalize this number?
        distance_remaining = 1_000_000
    }
    
    for _ in 0..<4 {
        t_min, t_max: f32 = 1, 1
        wall_normal_min, wall_normal_max: v2
        hit_min, hit_max: ^Entity
        
        entity_delta_length := length(entity_delta)
        // @todo(viktor): What do we want to do for epsilons here?
        if entity_delta_length > 0 {
            if entity_delta_length > distance_remaining {
                t_min = distance_remaining / entity_delta_length
            }
            
            desired_p := entity.p + entity_delta
            
            // @todo(viktor): spatial partition here
            for &test_entity in slice(region.entities) {
                    
                // @todo(viktor): Robustness!
                OverlapEpsilon :: 0.001
                if can_collide(region.world, entity, &test_entity) {
                    for volume in entity.collision.volumes {
                        for test_volume in test_entity.collision.volumes {
                            minkowski_diameter := rectangle_get_dimension(volume) + rectangle_get_dimension(test_volume)
                            min_corner := -0.5 * minkowski_diameter
                            max_corner :=  0.5 * minkowski_diameter
                            
                            rel := (entity.p + rectangle_get_center(volume)) - (test_entity.p + rectangle_get_center(test_volume))
                            
                            // @todo(viktor): do we want an close inclusion on the max_corner?
                            if rel.z >= min_corner.z && rel.z < max_corner.z {
                                Wall :: struct {
                                    x: f32, delta_x, delta_y, rel_x, rel_y, min_y, max_y: f32, 
                                    normal: v2,
                                }
                                
                                walls := [?]Wall{
                                    {min_corner.x, entity_delta.x, entity_delta.y, rel.x, rel.y, min_corner.y, max_corner.y, {-1,  0}},
                                    {max_corner.x, entity_delta.x, entity_delta.y, rel.x, rel.y, min_corner.y, max_corner.y, { 1,  0}},
                                    {min_corner.y, entity_delta.y, entity_delta.x, rel.y, rel.x, min_corner.x, max_corner.x, { 0, -1}},
                                    {max_corner.y, entity_delta.y, entity_delta.x, rel.y, rel.x, min_corner.x, max_corner.x, { 0,  1}},
                                }
                                
                                TEpsilon :: 0.0001
                                #assert(TEpsilon < OverlapEpsilon)
                                test_hit: b32
                                test_wall_normal: v2
                                test_t := t_min
                                
                                for wall in walls {
                                    collided: b32
                                    if wall.delta_x != 0 {
                                        t_result := (wall.x - wall.rel_x) / wall.delta_x
                                        y        := wall.rel_y + t_result * wall.delta_y
                                        
                                        if t_result >= 0 && test_t > t_result {
                                            if wall.min_y < y && y <= wall.max_y {
                                                test_t = max(0, t_result-TEpsilon)
                                                collided = true
                                            }
                                        }
                                    }
                                    
                                    if collided {
                                        test_wall_normal = wall.normal
                                        test_hit = true
                                    }
                                }
                                
                                if test_hit {
                                    t_min = test_t
                                    wall_normal_min = test_wall_normal
                                    hit_min = &test_entity
                                }
                            }
                            
                        }
                    }
                    
                }
            }
            
            t_stop: f32
            hit: ^Entity
            wall_normal: v2
            if t_min < t_max {
                t_stop      = t_min
                hit         = hit_min
                wall_normal = wall_normal_min
            } else {
                t_stop      = t_max
                hit         = hit_max
                wall_normal = wall_normal_max
            }
            
            entity.p += t_stop * entity_delta
            distance_remaining -= t_stop * entity_delta_length
            if hit != nil {
                entity_delta = desired_p - entity.p
                
                stops_on_collision := handle_collision(region.world, entity, hit)
                if stops_on_collision {
                    entity.dp.xy    = project(entity.dp.xy, wall_normal)
                    entity_delta.xy = project(entity_delta.xy, wall_normal)
                }
            } else {
                break
            }
            
        } else {
            break
        }
    }
    
    if entity.distance_limit != 0 {
        entity.distance_limit = distance_remaining
    }
}

// @cleanup
entities_overlap :: proc(a, b: ^Entity, epsilon := v3{}) -> (result: b32) {
    outer: for a_volume in a.collision.volumes {
        for b_volume in b.collision.volumes {
            a_rect := rectangle_center_dimension(a.p + rectangle_get_center(a_volume), rectangle_get_dimension(a_volume) + epsilon)
            b_rect := rectangle_center_dimension(b.p + rectangle_get_center(b_volume), rectangle_get_dimension(b_volume))
            
            if rectangle_intersects(a_rect, b_rect) {
                result = true
                break outer
            }
        }
    }
    
    return result
}

can_collide :: proc(world: ^World, a, b: ^Entity) -> (result: b32) {
    if a != b {
        a, b := a, b
        if a.id > b.id do a, b = b, a
        
        if .Collides in a.flags && .Collides in b.flags {
            result = true
            
            // @todo(viktor): BETTER HASH FUNCTION!!!
            hash_bucket := a.id & (len(world.collision_rule_hash) - 1)
            for rule := world.collision_rule_hash[hash_bucket]; rule != nil; rule = rule.next {
                if rule.id_a == a.id && rule.id_b == b.id {
                    result = rule.can_collide
                    break
                }
            }
        }
    }
    return result
}


handle_collision :: proc(world: ^World, a, b: ^Entity) -> (stops_on_collision: b32) {
    when false {
        a, b := a, b
    
        if a.type > b.type do a, b = b, a
        
        stops_on_collision = true
    }
        
    return stops_on_collision
}

can_overlap :: proc(mover, region: ^Entity) -> (result: b32) {
    when false {
        if mover != region {
            
            if region.type == .Stairwell {
                result = true
            }
        }
    }
    
    return result
}
