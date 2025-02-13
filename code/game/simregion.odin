package game

Entity :: struct {
    // NOTE(viktor): these are only for the sim region
    storage_index: StorageIndex,
    updatable: b32,
    
    type: EntityType,
    flags: EntityFlags,
    
    p, dp: v3,
    
    collision: ^EntityCollisionVolumeGroup,
    
    distance_limit: f32,
    
    hit_point_max: u32,
    hit_points: [16]HitPoint,
    
    arrow: EntityReference,
    
    facing_direction: f32,
    t_bob: f32,
    // TODO(viktor): generation index so we know how " to date" this entity is
    
    // TODO(viktor): only for stairwells
    walkable_dim: v2,
    walkable_height: f32,
}

EntityCollisionVolumeGroup :: struct {
    total_volume: EntityCollisionVolume,
    // TODO(viktor): volumes is always expected to be non-empty if the entity
    // has any volume... in the future, this could be compressed if necessary
    // that the length can be 0 if the total_volume should be used as the only
    // collision volume for the entity.
    volumes: []EntityCollisionVolume,
}

EntityCollisionVolume :: struct {
    dim, offset: v3,
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
    sim_entity_hash: [4096]SimEntityHash,
}
// NOTE(viktor): https://graphics.stanford.edu/~seander/bithacks.html#DetermineIfPowerOf2
#assert( len(SimRegion{}.sim_entity_hash) & ( len(SimRegion{}.sim_entity_hash) - 1 ) == 0)

begin_sim :: proc(sim_arena: ^Arena, state: ^State, world: ^World, origin: WorldPosition, bounds: Rectangle3, dt: f32) -> (region: ^SimRegion) {
    timed_function()
    // TODO(viktor): make storedEntities part of world
    region = push(sim_arena, SimRegion)
    MaxEntityCount :: 4096
    region.entities = push(sim_arena, Entity, MaxEntityCount)
    
    // TODO(viktor): Try to make these get enforced more rigorously
    // TODO(viktor): Perhaps try using a dual system here where we support 
    // entities larger than the max entity radius by adding them multiple 
    // times to the spatial partition?
    region.max_entity_radius   = 5
    region.max_entity_velocity = 30
    update_safety_margin := region.max_entity_radius + dt * region.max_entity_velocity
    UpdateSafetyMarginZ :: 1 // TODO(viktor): what should this be?
    
    region.world = world
    region.origin = origin
    region.updatable_bounds = rectangle_add_radius(bounds, v3{region.max_entity_radius, region.max_entity_radius, 0})
    region.bounds = rectangle_add_radius(bounds, v3{update_safety_margin, update_safety_margin, UpdateSafetyMarginZ})
    
    min_p := map_into_worldspace(world, region.origin, region.bounds.min)
    max_p := map_into_worldspace(world, region.origin, region.bounds.max)
    // TODO(viktor): @Speed this needs to be accelarated, but man, this CPU is crazy fast
    for chunk_z in min_p.chunk.z ..= max_p.chunk.z {
        for chunk_y in min_p.chunk.y ..= max_p.chunk.y {
            for chunk_x in min_p.chunk.x ..= max_p.chunk.x {
                chunk := get_chunk(nil, world, [3]i32{chunk_x, chunk_y, chunk_z})
                if chunk != nil {
                    for block := &chunk.first_block; block != nil; block = block.next {
                        for storage_index in block.indices[:block.entity_count] {
                            stored := &state.stored_entities[storage_index]
                            if .Nonspatial not_in stored.sim.flags {
                                sim_space_p := get_sim_space_p(region, stored)
                                if entity_overlaps_rectangle(region.bounds, sim_space_p, stored.sim.collision.total_volume) {
                                    // TODO(viktor): check a seconds rectangle to set the entity to be "moveable" or not
                                    add_entity(state, region, storage_index, stored, &sim_space_p)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    return region
}

end_sim :: proc(region: ^SimRegion, state: ^State) {
    timed_function()
    // TODO(viktor): make storedEntities part of world
    for entity in region.entities[:region.entity_count] {
        assert(entity.storage_index != 0)
        stored := &state.stored_entities[entity.storage_index]
        
        assert(.Simulated in entity.flags)
        stored.sim = entity
        stored.sim.flags -= {.Simulated}
        assert(.Simulated not_in stored.sim.flags)
        
        store_entity_reference(&stored.sim.arrow)
        // TODO(viktor): Save state back to stored entity, once high entities do state decompression
        
        new_p := .Nonspatial in entity.flags ? null_position() : map_into_worldspace(state.world, region.origin, entity.p)
        change_entity_location(&state.world_arena, region.world, entity.storage_index, stored, new_p)
        
        if entity.storage_index == state.camera_following_index {
            new_camera_p: WorldPosition
            new_camera_p.chunk  = stored.p.chunk
            new_camera_p.offset = stored.p.offset
            state.camera_p = new_camera_p
        }
    }
}

entity_overlaps_rectangle :: #force_inline proc(bounds: Rectangle3, p: v3, volume: EntityCollisionVolume) -> (result: b32) {
    grown := rectangle_add_radius(bounds, 0.5 * volume.dim)
    result = rectangle_contains(grown, p + volume.offset)
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

load_entity_reference :: #force_inline proc(state: ^State, region: ^SimRegion, ref: ^EntityReference) {
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

add_entity :: #force_inline proc(state: ^State, region: ^SimRegion, storage_index: StorageIndex, source: ^StoredEntity, sim_p: ^v3) -> (dest: ^Entity) {
    dest = add_entity_raw(state, region, storage_index, source)
    
    if dest != nil {
        if sim_p != nil {
            dest.p = sim_p^
            dest.updatable = entity_overlaps_rectangle(region.updatable_bounds, dest.p, dest.collision.total_volume)
        } else {
            dest.p = get_sim_space_p(region, source)
        }
    }
    
    return dest
}

add_entity_raw :: proc(state: ^State, region: ^SimRegion, storage_index: StorageIndex, source: ^StoredEntity) -> (entity: ^Entity) {
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
            
            load_entity_reference(state, region, &entity.arrow)
            
            assert(.Simulated not_in entity.flags)
            entity.flags += { .Simulated }
        }
        entity.storage_index = storage_index
        entity.updatable = false
    }
    
    assert(entity == nil || .Simulated in entity.flags)
    return entity
}

InvalidP :: v3{100_000, 100_000, 100_000}

get_sim_space_p :: #force_inline proc(region: ^SimRegion, stored: ^StoredEntity) -> (result: v3) {
    // TODO(viktor): Do we want to set this to signaling NAN in 
    // debug mode to make sure nobody ever uses the position of
    // a nonspatial entity?
    result = InvalidP
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


move_entity :: proc(state: ^State, region: ^SimRegion, entity: ^Entity, ddp: v3, move_spec: MoveSpec, dt: f32) {
    timed_function()
    assert(.Nonspatial not_in entity.flags)
    
    if entity.type == .Hero {
        BreakHere :: 1
        _ = BreakHere  
    } 
    
    ddp := ddp
    
    if move_spec.normalize_accelaration {
        ddp_length_squared := length_squared(ddp)
        
        if ddp_length_squared > 1 {
            ddp *= 1 / square_root(ddp_length_squared)
        }
    }
    
    ddp *= move_spec.speed
    
    // TODO(viktor): ODE here
    drag := -move_spec.drag * entity.dp
    drag.z = 0
    ddp += drag
    if .Grounded not_in entity.flags {
        Gravity :: -9.8
        ddp.z += Gravity
    }
    
    entity_delta := 0.5*ddp * square(dt) + entity.dp * dt
    entity.dp = ddp * dt + entity.dp
    // TODO(viktor): upgrade physical motion routines to handle capping the maximum velocity?
    assert(length_squared(entity.dp) <= square(region.max_entity_velocity))
    
    distance_remaining := entity.distance_limit
    if distance_remaining == 0 {
        // TODO(viktor): Do we want to formalize this number?
        distance_remaining = 1_000_000
    }
    
    for _ in 0..<4 {
        t_min, t_max: f32 = 1, 0
        wall_normal_min, wall_normal_max: v2
        hit_min, hit_max: ^Entity
        
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
                    
                    // TODO(viktor): Robustness!
                    OverlapEpsilon :: 0.001
                    if .Traversable in test_entity.flags && entities_overlap(entity, &test_entity, OverlapEpsilon) ||
                    can_collide(state, entity, &test_entity) {
                        
                        for volume in entity.collision.volumes {
                            for test_volume in test_entity.collision.volumes {
                                minkowski_diameter := volume.dim + test_volume.dim
                                min_corner := -0.5 * minkowski_diameter
                                max_corner :=  0.5 * minkowski_diameter
                                
                                rel := (entity.p + volume.offset) - (test_entity.p + test_volume.offset)
                                
                                // TODO(viktor): do we want an close inclusion on the max_corner?
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
                                    if .Traversable in test_entity.flags {
                                        test_t := t_max
                                        test_wall_normal: v2
                                        test_hit: b32
                                        
                                        for wall in walls {
                                            collided: b32
                                            if wall.delta_x != 0 {
                                                t_result := (wall.x - wall.rel_x) / wall.delta_x
                                                y        := wall.rel_y + t_result * wall.delta_y
                                                
                                                if t_result >= 0 && test_t < t_result {
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
                                            t_max = test_t
                                            wall_normal_max = test_wall_normal
                                            hit_max = &test_entity
                                        }
                                    } else {
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
                                            test_p := entity.p + entity_delta * test_t
                                            
                                            if speculative_collide(entity, &test_entity, test_p) {
                                                t_min = test_t
                                                wall_normal_min = test_wall_normal
                                                hit_min = &test_entity
                                            }
                                        }
                                    }
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
                
                stops_on_collision := handle_collision(state, entity, hit)
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
    
    ground: f32
    { // NOTE(viktor): handle events based on area overlapping
        // TODO(viktor): handle collision percisly by moving it into the collision loop
        // TODO(viktor): spatial partition here
        for &test_entity in region.entities[:region.entity_count] {
            if can_overlap(state, entity, &test_entity) && entities_overlap(entity, &test_entity) {
                handle_overlap(state, entity, &test_entity, dt, &ground)
            }
        }
    }
    
    ground += entity.p.z - get_entity_ground_point(entity).z
    // TODO(viktor): this has to become real height handling, ground collision, etc.
    if (entity.p.z <= ground) || (.Grounded in entity.flags && entity.dp.z == 0) {
        entity.p.z = ground;
        entity.dp.z = 0;
        entity.flags += { .Grounded }
    } else {
        entity.flags -= { .Grounded }
    }
    
    if entity.distance_limit != 0 {
        entity.distance_limit = distance_remaining
    }
    
    if entity.dp.x != 0  {
        entity.facing_direction = atan2(entity.dp.y, entity.dp.x)
    } else {
        // NOTE(viktor): leave the facing direction what it was
    }
}

entities_overlap :: proc(a, b: ^Entity, epsilon := v3{}) -> (result: b32) {
    outer: for a_volume in a.collision.volumes {
        for b_volume in b.collision.volumes {
            a_rect := rectangle_center_diameter(a.p + a_volume.offset, a_volume.dim + epsilon)
            b_rect := rectangle_center_diameter(b.p + b_volume.offset, b_volume.dim)
            
            if rectangle_intersects(a_rect, b_rect) {
                result = true
                break outer
            }
        }
    }
    
    return result
}

can_collide :: proc(state:^State, a, b: ^Entity) -> (result: b32) {
    if a != b {
        a, b := a, b
        if a.storage_index > b.storage_index do swap(&a, &b)
        
        if .Collides in a.flags && .Collides in b.flags {
            if .Nonspatial not_in a.flags && .Nonspatial not_in b.flags {
                // TODO(viktor): property-based logic goes here
                result = true
            }
            
            // TODO(viktor): BETTER HASH FUNCTION!!!
            hash_bucket := a.storage_index & (len(state.collision_rule_hash) - 1)
            for rule := state.collision_rule_hash[hash_bucket]; rule != nil; rule = rule.next {
                if rule.index_a == a.storage_index && rule.index_b == b.storage_index {
                    result = rule.can_collide
                    break
                }
            }
        }
    }
    return result
}

get_stair_ground :: #force_inline proc(region: ^Entity, at_ground_point: v3) -> (result: f32) {
    assert(region.type == .Stairwell)
    
    region_rect := rectangle_center_diameter(region.p.xy, region.walkable_dim)
    bary := clamp_01(rectangle_get_barycentric(region_rect, at_ground_point.xy))
    result = region.p.z + region.walkable_height * bary.y
    
    return result
}

handle_overlap :: proc(state: ^State, mover, region: ^Entity, dt: f32, ground: ^f32) {
    if region.type == .Stairwell {
        ground^ = get_stair_ground(region, get_entity_ground_point(mover))
    }
}

speculative_collide :: proc(mover, region: ^Entity, test_p: v3) -> (result: b32 = true) {
    if region.type == .Stairwell {
        mover_ground_point := get_entity_ground_point(mover, test_p)
        ground := get_stair_ground(region, mover_ground_point)
        step_height :: 0.1
        result = (abs(mover_ground_point.z - ground) > step_height) //  || (bary.y > 0.1 && bary.y < 0.9)
    }
    
    return result
}

handle_collision :: proc(state: ^State, a, b: ^Entity) -> (stops_on_collision: b32) {
    a, b := a, b
    if a.type > b.type do swap(&a, &b)
    
    if b.type == .Arrow {
        add_collision_rule(state, a.storage_index, b.storage_index, false)
        stops_on_collision = false
    } else {
        stops_on_collision = true
    }
    
    if a.type == .Monster && b.type == .Arrow {
        if a.hit_point_max > 0 {
            a.hit_point_max -= 1
        }
    }
    
    return stops_on_collision
}

can_overlap :: proc(state:^State, mover, region: ^Entity) -> (result: b32) {
    if mover != region {
        if region.type == .Stairwell {
            result = true
        }
    }
    
    return result
}
