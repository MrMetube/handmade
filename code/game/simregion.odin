package game

SimRegion :: struct {
    world: ^World,
    
    origin: WorldPosition, 
    bounds, updatable_bounds: Rectangle3,
    
    max_entity_radius: f32,
    max_entity_velocity: f32,
    
    entity_count: EntityId, // :Array
    entities: []Entity,
    
    // @todo(viktor): Do I really want a hash for this?
    sim_entity_hash: [4096]SimEntityHash,
}
// @note(viktor): https://graphics.stanford.edu/~seander/bithacks.html#DetermineIfPowerOf2
#assert( len(SimRegion{}.sim_entity_hash) & ( len(SimRegion{}.sim_entity_hash) - 1 ) == 0)

EntityReference :: struct #raw_union {
    ptr: ^Entity,
    id:  EntityId,
}

SimEntityHash :: struct {
    ptr: ^Entity,
    id:  EntityId,
}

MoveSpec :: struct {
    normalize_accelaration: b32,
    drag: f32,
    speed: f32,
}

////////////////////////////////////////////////

begin_sim :: proc(sim_arena: ^Arena, world: ^World, origin: WorldPosition, bounds: Rectangle3, dt: f32) -> (region: ^SimRegion) {
    timed_function()
    
    region = push(sim_arena, SimRegion)
    MaxEntityCount :: 4096
    region.entities = push(sim_arena, Entity, MaxEntityCount)
    
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
                chunk :^Chunk= extract_chunk(world, chunk_p)
                if chunk != nil {
                    chunk_world_p := WorldPosition { chunk = chunk_p }
                    chunk_delta := world_difference(world, chunk_world_p, region.origin)
                    block := chunk.first_block
                    for block != nil {
                        
                        entities := (cast([^]Entity) &block.entity_data.data)[:block.entity_count]
                        for &entity in entities {
                            sim_space_p := entity.p + chunk_delta
                            if entity_overlaps_rectangle(region.bounds, sim_space_p, entity.collision.total_volume) {
                                // @todo(viktor): check a seconds rectangle to set the entity to be "moveable" or not
                                add_entity(region, &entity, chunk_delta)
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
    
    for &entity in region.entities[:region.entity_count] {
        assert(entity.id != 0)
        if .Deleted in entity.flags do continue

        entity_p := map_into_worldspace(region.world, region.origin, entity.p)
        chunk_p  := entity_p
        chunk_p.offset = 0
        chunk_delta := -world_difference(region.world, chunk_p, region.origin)
        
        if entity.id == region.world.camera_following_id {
            // @volatile Room size
            room_delta := v3{25.5, 13.5, 0}
            half_room_delta := room_delta*0.5
            half_room_apron := half_room_delta - {1, 1, 0} * 0.7
            height :f32= 0.5
            region.world.camera_offset = 0

            offset: v3
            delta := world_difference(region.world, entity_p, region.world.camera_p)
                        
            if delta.x >  half_room_delta.x do offset.x += room_delta.x
            if delta.x < -half_room_delta.x do offset.x -= room_delta.x
            if delta.y >  half_room_delta.y do offset.y += room_delta.y
            if delta.y < -half_room_delta.y do offset.y -= room_delta.y
            
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
        }
        
        entity.p             += chunk_delta
        entity.movement_from += chunk_delta
        entity.movement_to   += chunk_delta

        store_entity_reference(&entity.head)
        
        pack_entity_into_world(region.world, &entity, entity_p)
    }
}

entity_overlaps_rectangle :: proc(bounds: Rectangle3, p: v3, volume: Rectangle3) -> (result: b32) {
    grown := rectangle_add_radius(bounds, 0.5 * rectangle_get_dimension(volume))
    result = rectangle_contains(grown, p + rectangle_get_center(volume))
    return result
}

get_hash_from_index :: proc(region: ^SimRegion, entity_id: EntityId) -> (result: ^SimEntityHash) {
    assert(entity_id != 0)
    
    hash := cast(u32) entity_id
    for offset in u32(0)..<len(region.sim_entity_hash) {
        hash_mask: u32 = len(region.sim_entity_hash)-1
        hash_index := (hash + offset) & hash_mask
        
        entry := &region.sim_entity_hash[hash_index]
        if entry.id == 0 || entry.id == entity_id {
            result = entry
            break
        }
    }
    return result
}

add_entity :: proc(region: ^SimRegion, source: ^Entity, chunk_delta: v3) {
    assert(source != nil)
    assert(source.id != 0)

    entry := get_hash_from_index(region, source.id)
    assert(entry != nil)
    
    assert(entry.ptr == nil)
    dest := &region.entities[region.entity_count]
    region.entity_count += 1
    
    assert(entry.id == 0 || entry.id == source.id)
    entry.id = source.id
    entry.ptr = dest
    
    // @todo(viktor): this should really be a decompression not a copy
    dest^ = source^
    
    dest.id = source.id
    
    dest.p             += chunk_delta
    dest.movement_from += chunk_delta
    dest.movement_to   += chunk_delta
    
    dest.updatable = entity_overlaps_rectangle(region.updatable_bounds, dest.p, dest.collision.total_volume)
}

connect_entity_references :: proc(region: ^SimRegion) {
    for &entity in region.entities {
        load_entity_reference(region, &entity.head)
    }
}

load_entity_reference :: proc(region: ^SimRegion, ref: ^EntityReference) {
    if ref.id != 0 {
        entry := get_hash_from_index(region, ref.id)
        ref.ptr = entry == nil ? nil : entry.ptr 
    }
}

store_entity_reference :: proc(ref: ^EntityReference) {
    if ref.ptr != nil {
        ref.id = ref.ptr.id
    }
}

get_sim_space_traversable :: proc(entity: ^Entity, index: u32) -> (result: TraversablePoint) {
    result = entity.collision.traversables[index]
    result.p += entity.p
    return result
}

default_move_spec :: proc() -> MoveSpec {
    return { normalize_accelaration = false, drag = 1, speed = 0}
}

move_entity :: proc(region: ^SimRegion, entity: ^Entity, ddp: v3, move_spec: MoveSpec, dt: f32) {
    timed_function()
    
    ddp := ddp
    
    if move_spec.normalize_accelaration {
        ddp_length_squared := length_squared(ddp)
        
        if ddp_length_squared > 1 {
            ddp *= 1 / square_root(ddp_length_squared)
        }
    }
    
    ddp *= move_spec.speed
    
    // @todo(viktor): ODE here
    drag := -move_spec.drag * entity.dp
    drag.z = 0
    ddp += drag
    
    entity_delta := 0.5*ddp * square(dt) + entity.dp * dt
    entity.dp = ddp * dt + entity.dp
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
            for &test_entity in region.entities[:region.entity_count] {
                    
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

get_stair_ground :: proc(region: ^Entity, at_ground_point: v3) -> (result: f32) {
    assert(region.type == .Stairwell)
    
    region_rect := rectangle_center_dimension(region.p.xy, region.walkable_dim)
    bary := clamp_01(rectangle_get_barycentric(region_rect, at_ground_point.xy))
    result = region.p.z + region.walkable_height * bary.y
    
    return result
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

handle_collision :: proc(world: ^World, a, b: ^Entity) -> (stops_on_collision: b32) {
    a, b := a, b
    if a.type > b.type do a, b = b, a
    
    stops_on_collision = true
    
    return stops_on_collision
}

can_overlap :: proc(mover, region: ^Entity) -> (result: b32) {
    if mover != region {
        if region.type == .Stairwell {
            result = true
        }
    }
    
    return result
}
