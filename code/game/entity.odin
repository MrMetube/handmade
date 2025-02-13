package game

EntityFlag :: enum {
    // TODO(viktor): Collides and Grounded probably can be removed now/soon
    Collides,
    Nonspatial,
    Moveable,
    Grounded,
    Traversable,

    Simulated,
}
EntityFlags :: bit_set[EntityFlag]

EntityType :: enum u32 {
    Nil, 
    
    Space,
    
    Hero, Wall, Familiar, Monster, Arrow, Stairwell,
}

HitPointPartCount :: 4
HitPoint :: struct {
    flags: u8,
    filled_amount: u8,
}

EntityIndex :: u32
StorageIndex :: distinct EntityIndex

StoredEntity :: struct {
    // TODO(viktor): its kind of busted that ps can be invalid  here
    // AND we stored whether they would be invalid in the flags field...
    // Can we do something better here?
    sim: Entity,
    p: WorldPosition,
}

PairwiseCollsionRule :: SingleLinkedListEntry(PairwiseCollsionRuleData)
PairwiseCollsionRuleData :: struct {
    can_collide: b32,
    index_a, index_b: StorageIndex,
}

PairwiseCollsionRuleFlag :: enum {
    ShouldCollide,
    Temporary,
}

make_entity_nonspatial :: #force_inline proc(entity: ^Entity) {
    entity.flags += {.Nonspatial}
    entity.p = InvalidP
}

make_entity_spatial :: #force_inline proc(entity: ^Entity, p, dp: v3) {
    entity.flags -= {.Nonspatial}
    entity.p = p
    entity.dp = dp
}

get_entity_ground_point :: proc { get_entity_ground_point_, get_entity_ground_point_with_p }
get_entity_ground_point_ :: #force_inline proc(entity: ^Entity) -> (result: v3) {
    result = get_entity_ground_point(entity, entity.p)

    return result
}

get_entity_ground_point_with_p :: #force_inline proc(entity: ^Entity, for_entity_p: v3) -> (result: v3) {
    result = for_entity_p

    return result
}

get_low_entity :: #force_inline proc(state: ^State, storage_index: StorageIndex) -> (entity: ^StoredEntity) #no_bounds_check {
    if storage_index > 0 && storage_index <= state.stored_entity_count {
        entity = &state.stored_entities[storage_index]
    }

    return entity
}

add_stored_entity :: proc(state: ^State, type: EntityType, p: WorldPosition) -> (index: StorageIndex, stored: ^StoredEntity) #no_bounds_check {
    assert(state.world != nil)
    
    index = state.stored_entity_count
    state.stored_entity_count += 1
    assert(state.stored_entity_count < len(state.stored_entities))
    stored = &state.stored_entities[index]
    stored.sim = { type = type }

    stored.sim.collision = state.null_collision
    stored.p = null_position()

    change_entity_location(&state.world_arena, state.world, index, stored, p)

    return index, stored
}

add_grounded_entity :: proc(state: ^State, type: EntityType, p: WorldPosition, collision: ^EntityCollisionVolumeGroup) -> (index: StorageIndex, stored: ^StoredEntity) #no_bounds_check {
    index, stored = add_stored_entity(state, type, p)
    stored.sim.collision = collision

    return index, stored
}

add_arrow :: proc(state: ^State) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_stored_entity(state, .Arrow, null_position())
    
    entity.sim.collision = state.arrow_collision
    entity.sim.flags += {.Moveable}

    return index, entity
}

add_wall :: proc(state: ^State, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Wall, p, state.wall_collision)

    entity.sim.flags += {.Collides}

    return index, entity
}

add_stairs :: proc(state: ^State, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Stairwell, p, state.stairs_collision)

    entity.sim.flags += {.Collides}
    entity.sim.walkable_height = state.typical_floor_height
    entity.sim.walkable_dim    = entity.sim.collision.total_volume.dim.xy

    return index, entity
}

add_player :: proc(state: ^State) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Hero, state.camera_p, state.player_collision)

    entity.sim.flags += {.Collides, .Moveable}

    init_hitpoints(entity, 3)

    arrow_index, _ := add_arrow(state)
    entity.sim.arrow.index = arrow_index

    if state.camera_following_index == 0 {
        state.camera_following_index = index
    }

    return index, entity
}

add_monster :: proc(state: ^State, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Monster, p, state.monstar_collision)

    entity.sim.flags += {.Collides, .Moveable}

    init_hitpoints(entity, 3)

    return index, entity
}

add_familiar :: proc(state: ^State, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Familiar, p, state.familiar_collision)

    entity.sim.flags += {.Moveable}

    return index, entity
}

add_standart_room :: proc(state: ^State, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(state, .Space, p, state.standart_room_collision)

    entity.sim.flags += { .Traversable }

    return index, entity
}

init_hitpoints :: proc(entity: ^StoredEntity, count: u32) {
    assert(count < len(entity.sim.hit_points))

    entity.sim.hit_point_max = count
    for &hit_point in entity.sim.hit_points[:count] {
        hit_point = { filled_amount = HitPointPartCount }
    }
}

add_collision_rule :: proc(state:^State, a, b: StorageIndex, should_collide: b32) {
    timed_function()
    // TODO(viktor): collapse this with should_collide
    a, b := a, b
    if a > b do swap(&a, &b)
    // TODO(viktor): BETTER HASH FUNCTION!!!
    found: ^PairwiseCollsionRule
    hash_bucket := a & (len(state.collision_rule_hash) - 1)
    for rule := state.collision_rule_hash[hash_bucket]; rule != nil; rule = rule.next {
        if rule.index_a == a && rule.index_b == b {
            found = rule
            break
        }
    }

    if found == nil {
        found = list_pop(&state.first_free_collision_rule) or_else push(&state.world_arena, PairwiseCollsionRule)
        list_push(&state.collision_rule_hash[hash_bucket], found)
    }

    if found != nil {
        found.index_a = a
        found.index_b = b
        found.can_collide = should_collide
    }
}

clear_collision_rules :: proc(state: ^State, storage_index: StorageIndex) {
    timed_function()
    // TODO(viktor): need to make a better data structute that allows for
    // the removal of collision rules without searching the entire table
    // NOTE(viktor): One way to make removal easy would be to always
    // add _both_ orders of the pairs of storage indices to the
    // hash table, so no matter which position the entity is in,
    // you can always find it. Then, when you do your first pass
    // through for removal, you just remember the original top
    // of the free list, and when you're done, do a pass through all
    // the new things on the free list, and remove the reverse of
    // those pairs.
    for hash_bucket in 0..<len(state.collision_rule_hash) {
        for rule_pointer := &state.collision_rule_hash[hash_bucket]; rule_pointer^ != nil;  {
            rule := rule_pointer^
            if rule.index_a == storage_index || rule.index_b == storage_index {
                // :ListEntryRemovalInLoop
                list_push(&state.first_free_collision_rule, rule)
                rule_pointer^ = rule.next
            } else {
                rule_pointer = &rule.next
            }
        }
    }
}
