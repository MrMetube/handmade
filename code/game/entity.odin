package game

Entity :: struct {
    id: EntityId,
    updatable: b32,
    
    type:  EntityType,
    flags: EntityFlags,
    
    p, dp: v3,
    
    collision: ^EntityCollisionVolumeGroup,
    
    distance_limit: f32,
    
    hit_point_max: u32, // :Array
    hit_points: [16]HitPoint,
    
    head: EntityReference,
    
    movement_mode: MovementMode,
    t_movement:      f32,
    movement_from:   v3,
    movement_to: v3,
    
    t_bob: f32,
    dt_bob: f32,
    facing_direction: f32,
    // @todo(viktor): generation index so we know how " to date" this entity is
    
    // @todo(viktor): only for stairwells
    walkable_dim: v2,
    walkable_height: f32,
    
    x_axis, y_axis: v2,
}

EntityId :: distinct u32

EntityFlag :: enum {
    Collides,
    Moveable,
    Deleted,
}
EntityFlags :: bit_set[EntityFlag]

EntityType :: enum u32 {
    Nil, 
    
    Floor,
    
    HeroHead, 
    HeroBody, 
    
    Wall, Familiar, Monster, Stairwell,
}

HitPointPartCount :: 4
HitPoint :: struct {
    flags:         u8,
    filled_amount: u8,
}

PairwiseCollsionRule :: #type SingleLinkedList(PairwiseCollsionRuleData)
PairwiseCollsionRuleData :: struct {
    can_collide: b32,
    id_a, id_b:  EntityId,
}

PairwiseCollsionRuleFlag :: enum {
    ShouldCollide,
    Temporary,
}

MovementMode :: enum {
    Planted, Hopping,
}

EntityCollisionVolumeGroup :: struct {
    total_volume: Rectangle3,
    // @todo(viktor): volumes is always expected to be non-empty if the entity
    // has any volume... in the future, this could be compressed if necessary
    // that the length can be 0 if the total_volume should be used as the only
    // collision volume for the entity.
    volumes: []Rectangle3,
    
    traversable_count: u32, // :Array
    traversables:      []TraversablePoint,
}

TraversablePoint :: struct {
    p: v3,
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

begin_entity :: proc(world: ^World, type: EntityType) -> (result: ^Entity) {
    assert(world.creation_buffer_index < len(world.creation_buffer))
    world.creation_buffer_index += 1
    
    result = &world.creation_buffer[world.creation_buffer_index]
    // @todo(viktor): Worry about this taking a while, once the entities are large (sparse clear?)
    result ^= {}
    
    world.last_used_entity_id += 1
    result.id = world.last_used_entity_id
    result.collision = world.null_collision
    result.type = type
        
    return result
}

end_entity :: proc(world: ^World, entity: ^Entity, p: WorldPosition) {
    assert(world.creation_buffer_index > 0)
    world.creation_buffer_index -= 1
    
    entity.p = p.offset

    pack_entity_into_world(world, entity, p)
}

delete_entity :: proc(entity: ^Entity) {
    entity.flags += { .Deleted }
}

begin_grounded_entity :: proc(world: ^World, type: EntityType, collision: ^EntityCollisionVolumeGroup) -> (result: ^Entity) {
    result = begin_entity(world, type)
    result.collision = collision

    return result
}

add_wall :: proc(world: ^World, p: WorldPosition) {
    entity := begin_grounded_entity(world, .Wall, world.wall_collision)

    entity.flags += {.Collides}

    end_entity(world, entity, p)
}

add_stairs :: proc(world: ^World, p: WorldPosition) {
    entity := begin_grounded_entity(world, .Stairwell, world.stairs_collision)

    entity.flags += {.Collides}
    entity.walkable_height = world.typical_floor_height
    entity.walkable_dim    = rectangle_get_dimension(entity.collision.total_volume).xy

    end_entity(world, entity, p)
}

add_hero :: proc(world: ^World) -> (result: EntityId) {
    entity := begin_grounded_entity(world, .HeroHead, world.hero_head_collision)
        
    entity.flags += {.Collides, .Moveable}
    result = entity.id
    
        body := begin_grounded_entity(world, .HeroBody, world.hero_body_collision)
        
        body.flags += {.Moveable}
        body.head.id = result

    entity.head.id = body.id
        
        end_entity(world, body, world.camera_p)
    
    init_hitpoints(entity, 3)
    
    if world.camera_following_id == 0 {
        world.camera_following_id = result
    }
        
    end_entity(world, entity, world.camera_p)
    
    return result
}

add_monster :: proc(world: ^World, p: WorldPosition) {
    entity := begin_grounded_entity(world, .Monster, world.monstar_collision)

    entity.flags += {.Collides, .Moveable}

    init_hitpoints(entity, 3)

    end_entity(world, entity, p)
}

add_familiar :: proc(world: ^World, p: WorldPosition) {
    entity := begin_grounded_entity(world, .Familiar, world.familiar_collision)

    entity.flags += {.Moveable}
    
    end_entity(world, entity, p)
}

add_standart_room :: proc(world: ^World, p: WorldPosition) {
    width  :i32= 17
    height :i32=  9
    for offset_y in 0..=height {
        for offset_x in 0..=width {
            floor_p := chunk_position_from_tile_positon(world, p.chunk.x + offset_x, p.chunk.y + offset_y, p.chunk.z)
            entity := begin_grounded_entity(world, .Floor, world.floor_collision)
            end_entity(world, entity, floor_p)
        }
    }
}

init_hitpoints :: proc(entity: ^Entity, count: u32) {
    assert(count < len(entity.hit_points))

    entity.hit_point_max = count
    for &hit_point in entity.hit_points[:count] {
        hit_point = { filled_amount = HitPointPartCount }
    }
}

// @cleanup
add_collision_rule :: proc(world:^World, a, b: EntityId, should_collide: b32) {
    timed_function()
    // @todo(viktor): collapse this with should_collide
    a, b := a, b
    if a > b do swap(&a, &b)
    // @todo(viktor): BETTER HASH FUNCTION!!!
    found: ^PairwiseCollsionRule
    hash_bucket := a & (len(world.collision_rule_hash) - 1)
    for rule := world.collision_rule_hash[hash_bucket]; rule != nil; rule = rule.next {
        if rule.id_a == a && rule.id_b == b {
            found = rule
            break
        }
    }

    if found == nil {
        found = list_pop(&world.first_free_collision_rule) or_else push(&world.arena, PairwiseCollsionRule)
        list_push(&world.collision_rule_hash[hash_bucket], found)
    }

    if found != nil {
        found.id_a = a
        found.id_b = b
        found.can_collide = should_collide
    }
}

// @cleanup
clear_collision_rules :: proc(world: ^World, entity_id: EntityId) {
    timed_function()
    // @todo(viktor): need to make a better data structute that allows for
    // the removal of collision rules without searching the entire table
    // @note(viktor): One way to make removal easy would be to always
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
            if rule.id_a == entity_id || rule.id_b == entity_id {
                // :ListEntryRemovalInLoop
                list_push(&world.first_free_collision_rule, rule)
                rule_pointer^ = rule.next
            } else {
                rule_pointer = &rule.next
            }
        }
    }
}
