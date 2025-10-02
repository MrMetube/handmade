package game

SimRegion :: struct {
    world: ^World,
    
    origin: WorldPosition, 
    bounds, updatable_bounds: Rectangle3,
    
    entities: Array(Entity),
    brains:   Array(Brain),
    
    // @todo(viktor): Do I really want a hash for this?
    entity_hash: [MaxEntityCount] EntityHash,
    brain_hash:  [MaxBrainCount]  BrainHash,
    entity_hash_occupancy: [MaxEntityCount / 64] u64,
    brain_hash_occupancy:  [MaxBrainCount  / 64] u64,
    
    null_entity: Entity,
}

MaxEntityCount :: 4096
MaxBrainCount  :: 256

BrainHash :: struct {
    pointer: ^Brain,
}

EntityHash :: struct {
    pointer: ^Entity,
}

////////////////////////////////////////////////

World_Sim :: struct {
    region: ^SimRegion, 
    memory: TemporaryMemory,
}

begin_sim :: proc (sim_arena: ^Arena, world: ^World, origin: WorldPosition, bounds: Rectangle3, dt: f32) -> (simulation: World_Sim) {
    simulation.memory = begin_temporary_memory(sim_arena)
    simulation.region = begin_world_changes(simulation.memory.arena, world, origin, bounds, dt)
    
    return simulation
}

simulate :: proc (simulation: ^World_Sim, dt: f32, game_entropy: ^RandomSeries, typical_floor_height: f32, render_group: ^RenderGroup, state: ^State, input: ^Input, haze_color: v4, particle_cache: ^Particle_Cache) {
    timed_function()
    
    region := simulation.region
    
    { timed_block("execute_brains")
        for &brain in slice(region.brains) {
            mark_brain_active(&brain)
        }
        
        for &brain in slice(region.brains) {
            execute_brain(region, dt, &brain, state, input, game_entropy)
        }
    }
    
    update_and_render_entities(region, dt, render_group, typical_floor_height, haze_color, particle_cache)
}

end_sim :: proc (simulation: ^World_Sim) {
    // @todo(viktor): Make sure we hoist the camera update out to a place where the renderer
    // can know about the location of the camera at the end of the frame so there isn't
    // a frame of lag in camera updating compared to the hero.
    end_world_changes(simulation.region)
    end_temporary_memory(simulation.memory)
}

////////////////////////////////////////////////

begin_world_changes :: proc (sim_arena: ^Arena, world: ^World, origin: WorldPosition, bounds: Rectangle3, dt: f32) -> (region: ^SimRegion) {
    timed_function()
    
    region = push(sim_arena, SimRegion, no_clear())
    
    region.world = world
    region.origin = origin
    region.bounds = bounds
    region.updatable_bounds = bounds
    
    region.entities = make_array(sim_arena, Entity, MaxEntityCount, no_clear())
    region.brains   = make_array(sim_arena, Brain,  MaxBrainCount,  no_clear())
    
    zero(region.entity_hash_occupancy[:])
    zero(region.brain_hash_occupancy[:])
    
    region.null_entity = {}
    
    ////////////////////////////////////////////////
    
    min_p := map_into_worldspace(region.world, region.origin, region.bounds.min)
    max_p := map_into_worldspace(region.world, region.origin, region.bounds.max)
    
    // @todo(viktor): @speed this needs to be accelarated, but man, this CPU is crazy fast
    for chunk_z in min_p.chunk.z ..= max_p.chunk.z {
        for chunk_y in min_p.chunk.y ..= max_p.chunk.y {
            for chunk_x in min_p.chunk.x ..= max_p.chunk.x {
                chunk_p := v3i{chunk_x, chunk_y, chunk_z}
                
                chunk := extract_chunk(region.world, chunk_p)
                
                if chunk != nil {
                    chunk_world_p := WorldPosition { chunk = chunk_p }
                    chunk_delta := world_distance(region.world, chunk_world_p, region.origin)
                    
                    first_block := chunk.first_block
                    last_block  := first_block
                    for block := first_block; block != nil; block = block.next {
                        last_block = block
                        
                        entities := slice_from_parts(Entity, &block.entity_data.data, block.entity_count)
                        for &source in entities {
                            // @todo(viktor): check a seconds rectangle to set the source to be "moveable" or not
                            assert(source.id != 0)
                            
                            if region.entities.count < auto_cast len(region.entities.data) {
                                dest := append(&region.entities)
                                
                                // @todo(viktor): this should really be a decompression not a copy
                                dest ^= source
                                
                                dest.id = source.id
                                dest.p += chunk_delta
                                
                                // @todo(viktor): @transient marked members should not be unpacked
                                dest.manual_sort_key = {}
                                dest.z_layer = chunk_z
                                
                                add_entity_to_hash(region, dest)
                                
                                if entity_overlaps_rectangle(region.updatable_bounds, dest.p, dest.collision.total_volume) {
                                    dest.flags += { .active }
                                }
                                
                                if dest.brain_id != 0 {
                                    brain := get_or_add_brain(region, dest.brain_id, dest.brain_kind)
                                    assert(brain != nil)
                                    
                                    index := dest.brain_slot.index
                                    brain.slots[index] = dest
                                }
                            } else {
                                unreachable()
                            }
                        }
                    }
                    
                    add_to_free_list(region.world, chunk, first_block, last_block)
                }
            }
        }
    }
    
    connect_entity_references(region)
    
    return region
}

end_world_changes :: proc (region: ^SimRegion) {
    timed_function()
    
    for &entity in slice(region.entities) {
        assert(entity.id != 0)
        if .MarkedForDeletion in entity.flags do continue
        
        entity_p := map_into_worldspace(region.world, region.origin, entity.p)
        chunk_p  := entity_p
        chunk_p.offset = 0
        chunk_delta := entity_p.offset - entity.p
        
        entity.p += chunk_delta
        
        dest := use_space_in_world(region.world, size_of(Entity), entity_p)
        entity.p = entity_p.offset
        
        dest ^= entity
        
        // @volatile see Entity definition @metaprogram
        dest.ddp = 0
        dest.ddt_bob = 0
        
        pack_traversable_reference(region, &dest.came_from)
        pack_traversable_reference(region, &dest.occupying)
        
        pack_traversable_reference(region, &dest.auto_boost_to)
    }
}

////////////////////////////////////////////////

pack_entity_reference :: proc(region: ^SimRegion, ref: ^EntityReference) {
    if ref.pointer != nil {
        if .MarkedForDeletion in ref.pointer.flags {
            ref.id = 0
        } else {
            ref.id = ref.pointer.id
        }
    } else if ref.id != 0 {
        if region != nil && get_entity_hash_from_id(region, ref.id) != nil {
            ref.id = 0
        }
    }
}

pack_traversable_reference :: proc(region: ^SimRegion, ref: ^TraversableReference) {
    pack_entity_reference(region, &ref.entity)
}

////////////////////////////////////////////////

create_entity :: proc (region: ^SimRegion, id: EntityId) -> (result: ^Entity) {
    result = &region.null_entity
    if region.entities.count < auto_cast len(region.entities.data) {
        result = append(&region.entities)
    } else {
        unreachable()
    }
    
    // @todo(viktor): worry about this taking a while once the entity is large (sparse clear?)
    result ^= { id = id }
    
    add_entity_to_hash(region, result)
    
    return result
}

mark_for_deletion :: proc(entity: ^Entity) {
    if entity != nil {
        entity.flags += { .MarkedForDeletion }
    }
}

get_entity_by_id :: proc (region: ^SimRegion, id: EntityId) -> (result: ^Entity) {
    entry := get_entity_hash_from_id(region, id)
    result = entry != nil ? entry.pointer : nil
    return result
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

get_closest_traversable :: proc(region: ^SimRegion, from_p: v3, flags: bit_set[enum{ Unoccupied }] = {}) -> (result: TraversableReference, ok: bool) {
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
    grown := add_radius(bounds, 0.5 * get_dimension(volume))
    result = contains(grown, p + get_center(volume))
    return result
}

get_brain_hash_from_id :: proc(region: ^SimRegion, id: BrainId) -> (result: ^BrainHash) {
    result = get_hash_from_id(region.brain_hash[:], region.brain_hash_occupancy[:], cast(u32) id)
    return result
}
get_entity_hash_from_id :: proc(region: ^SimRegion, id: EntityId) -> (result: ^EntityHash) {
    result = get_hash_from_id(region.entity_hash[:], region.entity_hash_occupancy[:], cast(u32) id)
    return result
}

get_hash_from_id :: proc(hashes: [] $T, occupancy: [] u64, id: u32) -> (result: ^T) {
    assert(id != 0)
    
    hash := cast(u32) id
    count := cast(u32) len(hashes)
    for offset in 0 ..< count {
        hash_index := (hash + offset) % count
        
        entry := &hashes[hash_index]
        #assert(size_of(entry.pointer.id) == size_of(id))
        
        if is_empty(occupancy, hash_index) {
            result = entry
            result.pointer = nil
            break
        } else if cast(u32) entry.pointer.id == id {
            result = entry
            break
        }
    }
    
    assert(result != nil)
    return result
}

add_entity_to_hash :: proc (region: ^SimRegion, entity: ^Entity) {
    entry := get_entity_hash_from_id(region, entity.id)
    
    // :PointerArithmetic
    index := cast(umm) entry - cast(umm) &region.entity_hash[0]
    index /= size_of(EntityHash)
    assert(is_empty(region.entity_hash_occupancy[:], index))
    
    entry.pointer = entity
    
    mark_occupied_entity(region, entry)
    
    test := get_entity_hash_from_id(region, entity.id)
    assert(test == entry)
    assert(test.pointer == entity)
}

get_or_add_brain :: proc(region: ^SimRegion, id: BrainId, kind: BrainKind) -> (result: ^Brain) {
    entry := get_brain_hash_from_id(region, id)
    result = entry.pointer
    
    if result == nil {
        // :PointerArithmetic
        index := cast(umm) entry - cast(umm) &region.brain_hash[0]
        index /= size_of(BrainHash)
        assert(is_empty(region.brain_hash_occupancy[:], index))
        
        result = append(&region.brains)
        result ^= {
            id = id,
            kind = kind,
        }
        
        entry.pointer = result
        mark_occupied_brain(region, entry)
        
        test := get_brain_hash_from_id(region, id)
        assert(test == entry)
        assert(test.pointer == result)
    }
    
    return result
}

mark_occupied_entity :: proc (region: ^SimRegion, entry: ^EntityHash) {
    // :PointerArithmetic
    index := cast(umm) entry - cast(umm) &region.entity_hash[0]
    index /= size_of(EntityHash)
    mark_bit(region.entity_hash_occupancy[:], cast(u64) index)
}
mark_occupied_brain :: proc (region: ^SimRegion, entry: ^BrainHash) {
    // :PointerArithmetic
    index := cast(umm) entry - cast(umm) &region.brain_hash[0]
    index /= size_of(BrainHash)
    mark_bit(region.brain_hash_occupancy[:], cast(u64) index)
}

////////////////////////////////////////////////

mark_bit :: proc (array: [] u64, #any_int index: u64) {
    occ_index := index / 64
    bit_index := index % 64
    array[occ_index] |= (1 << bit_index)
}

is_empty :: proc (array: [] u64, #any_int index: u64) -> (result: bool) {
    occ_index := index / 64
    bit_index := index % 64
    result = (array[occ_index] & (1 << bit_index)) == 0
    return result
}

////////////////////////////////////////////////

connect_entity_references :: proc(region: ^SimRegion) {
    timed_function()
    
    for &entity in slice(region.entities) {
        load_traversable_reference(region, &entity.came_from)
        load_traversable_reference(region, &entity.occupying)
        load_traversable_reference(region, &entity.auto_boost_to)
        
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

////////////////////////////////////////////////

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

////////////////////////////////////////////////

move_entity :: proc(region: ^SimRegion, entity: ^Entity, dt: f32) {
    timed_function()
    
    entity_delta := 0.5*entity.ddp * square(dt) + entity.dp * dt
    entity.dp = entity.ddp * dt + entity.dp
    
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
                if can_collide(entity, &test_entity) {
                    for volume in entity.collision.volumes {
                        for test_volume in test_entity.collision.volumes {
                            minkowski_diameter := get_dimension(volume) + get_dimension(test_volume)
                            min_corner := -0.5 * minkowski_diameter
                            max_corner :=  0.5 * minkowski_diameter
                            
                            rel := (entity.p + get_center(volume)) - (test_entity.p + get_center(test_volume))
                            
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
                
                stops_on_collision := handle_collision(entity, hit)
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

can_collide :: proc(a, b: ^Entity) -> (result: b32) {
    if a != b {
        a, b := a, b
        if a.id > b.id do a, b = b, a
        
        if .Collides in a.flags && .Collides in b.flags {
            result = true
        }
    }
    return result
}


handle_collision :: proc(a, b: ^Entity) -> (stops_on_collision: b32) {
    when false {
        a, b := a, b
    
        if a.type > b.type do a, b = b, a
        
        stops_on_collision = true
    }
    
    return stops_on_collision
}
