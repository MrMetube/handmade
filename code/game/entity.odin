package game

EntityFlag :: enum {
    // TODO(viktor): Collides and Grounded probably can be removed now/soon
    Collides,
    Nonspatial,
    Moveable,

    Simulated,
}
EntityFlags :: bit_set[EntityFlag]

EntityType :: enum u32 {
    Nil, 
    
    Floor,
    
    Hero, Wall, Familiar, Monster, Arrow, Stairwell,
}

HitPointPartCount :: 4
HitPoint :: struct {
    flags:         u8,
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

PairwiseCollsionRule :: #type SingleLinkedList(PairwiseCollsionRuleData)
PairwiseCollsionRuleData :: struct {
    can_collide: b32,
    index_a, index_b: StorageIndex,
}

PairwiseCollsionRuleFlag :: enum {
    ShouldCollide,
    Temporary,
}

make_entity_nonspatial :: proc(entity: ^Entity) {
    entity.flags += {.Nonspatial}
    entity.p = InvalidP
}

make_entity_spatial :: proc(entity: ^Entity, p, dp: v3) {
    entity.flags -= {.Nonspatial}
    entity.p = p
    entity.dp = dp
}

get_entity_ground_point :: proc { get_entity_ground_point_, get_entity_ground_point_with_p }
get_entity_ground_point_ :: proc(entity: ^Entity) -> (result: v3) {
    result = get_entity_ground_point(entity, entity.p)

    return result
}

get_entity_ground_point_with_p :: proc(entity: ^Entity, for_entity_p: v3) -> (result: v3) {
    result = for_entity_p

    return result
}

get_low_entity :: proc(world: ^World, storage_index: StorageIndex) -> (entity: ^StoredEntity) #no_bounds_check {
    if storage_index > 0 && storage_index <= world.stored_entity_count {
        entity = &world.stored_entities[storage_index]
    }

    return entity
}

add_stored_entity :: proc(world: ^World, type: EntityType, p: WorldPosition) -> (index: StorageIndex, stored: ^StoredEntity) #no_bounds_check {
    index = world.stored_entity_count
    world.stored_entity_count += 1
    assert(world.stored_entity_count < len(world.stored_entities))
    
    stored = &world.stored_entities[index]
    stored.sim = { type = type }
    
    stored.sim.collision = world.null_collision
    stored.p = null_position()
    
    change_entity_location(&world.arena, world, index, stored, p)
    
    return index, stored
}

add_grounded_entity :: proc(world: ^World, type: EntityType, p: WorldPosition, collision: ^EntityCollisionVolumeGroup) -> (index: StorageIndex, stored: ^StoredEntity) #no_bounds_check {
    index, stored = add_stored_entity(world, type, p)
    stored.sim.collision = collision

    return index, stored
}

add_arrow :: proc(world: ^World) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_stored_entity(world, .Arrow, null_position())
    
    entity.sim.collision = world.arrow_collision
    entity.sim.flags += {.Moveable}

    return index, entity
}

add_wall :: proc(world: ^World, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(world, .Wall, p, world.wall_collision)

    entity.sim.flags += {.Collides}

    return index, entity
}

add_stairs :: proc(world: ^World, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(world, .Stairwell, p, world.stairs_collision)

    entity.sim.flags += {.Collides}
    entity.sim.walkable_height = world.typical_floor_height
    entity.sim.walkable_dim    = rectangle_get_dimension(entity.sim.collision.total_volume).xy

    return index, entity
}

add_player :: proc(world: ^World) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(world, .Hero, world.camera_p, world.player_collision)

    entity.sim.flags += {.Collides, .Moveable}

    init_hitpoints(entity, 3)

    arrow_index, _ := add_arrow(world)
    entity.sim.arrow.index = arrow_index

    if world.camera_following_index == 0 {
        world.camera_following_index = index
    }

    return index, entity
}

add_monster :: proc(world: ^World, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(world, .Monster, p, world.monstar_collision)

    entity.sim.flags += {.Collides, .Moveable}

    init_hitpoints(entity, 3)

    return index, entity
}

add_familiar :: proc(world: ^World, p: WorldPosition) -> (index: StorageIndex, entity: ^StoredEntity) {
    index, entity = add_grounded_entity(world, .Familiar, p, world.familiar_collision)

    entity.sim.flags += {.Moveable}

    return index, entity
}

add_standart_room :: proc(world: ^World, p: WorldPosition) {
    width  :i32= 17
    height :i32=  9
    for offset_y in 0..=height {
        for offset_x in 0..=width {
            floor_p := chunk_position_from_tile_positon(world, p.chunk.x + offset_x, p.chunk.y + offset_y, p.chunk.z)
            index, entity := add_grounded_entity(world, .Floor, floor_p, world.floor_collision)
        }
    }
}

init_hitpoints :: proc(entity: ^StoredEntity, count: u32) {
    assert(count < len(entity.sim.hit_points))

    entity.sim.hit_point_max = count
    for &hit_point in entity.sim.hit_points[:count] {
        hit_point = { filled_amount = HitPointPartCount }
    }
}

add_collision_rule :: proc(world:^World, a, b: StorageIndex, should_collide: b32) {
    timed_function()
    // TODO(viktor): collapse this with should_collide
    a, b := a, b
    if a > b do swap(&a, &b)
    // TODO(viktor): BETTER HASH FUNCTION!!!
    found: ^PairwiseCollsionRule
    hash_bucket := a & (len(world.collision_rule_hash) - 1)
    for rule := world.collision_rule_hash[hash_bucket]; rule != nil; rule = rule.next {
        if rule.index_a == a && rule.index_b == b {
            found = rule
            break
        }
    }

    if found == nil {
        found = list_pop(&world.first_free_collision_rule) or_else push(&world.arena, PairwiseCollsionRule)
        list_push(&world.collision_rule_hash[hash_bucket], found)
    }

    if found != nil {
        found.index_a = a
        found.index_b = b
        found.can_collide = should_collide
    }
}

clear_collision_rules :: proc(world: ^World, storage_index: StorageIndex) {
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
    for hash_bucket in 0..<len(world.collision_rule_hash) {
        for rule_pointer := &world.collision_rule_hash[hash_bucket]; rule_pointer^ != nil;  {
            rule := rule_pointer^
            if rule.index_a == storage_index || rule.index_b == storage_index {
                // :ListEntryRemovalInLoop
                list_push(&world.first_free_collision_rule, rule)
                rule_pointer^ = rule.next
            } else {
                rule_pointer = &rule.next
            }
        }
    }
}
