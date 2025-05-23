package game

Entity :: struct {
    
    id: EntityId,
    
    brain_kind: BrainKind,
    brain_slot: BrainSlot,
    brain_id:   BrainId,
    
    ////////////////////////////////////////////////
    // @note(viktor): Everything below here is not worked out

    updatable: b32,
        
    flags: EntityFlags,
    
    p, dp: v3,
    ddp: v3, // @NoPack @todo(viktor): @metaprogram

    t_bob, dt_bob: f32,
    ddt_bob:  f32, // @NoPack @todo(viktor): @metaprogram
    
    collision: ^EntityCollisionVolumeGroup,
    
    distance_limit: f32,
    
    hit_point_max: u32, // :Array
    hit_points: [16]HitPoint,
    
    movement_mode: MovementMode,
    t_movement:    f32,
    occupying: TraversableReference,
    came_from: TraversableReference,
    
    facing_direction: f32,
    // @todo(viktor): generation index so we know how " to date" this entity is
    
    x_axis, y_axis: v2,
    
    traversables: Array(TraversablePoint),
    
    pieces: FixedArray(4, VisiblePiece),
}

EntityId :: distinct u32

EntityFlag :: enum {
    Collides,
    MarkedForDeletion,
}
EntityFlags :: bit_set[EntityFlag]

VisiblePiece :: struct {
    asset:  AssetTypeId,
    height: f32,
    offset: v3,
    color:  v4,
    
    flags: bit_set[ enum {
        SquishAxis,
        BobUpAndDown,
    }],
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
    Planted, 
    Hopping,
}

EntityCollisionVolumeGroup :: struct {
    total_volume: Rectangle3,
    // @todo(viktor): volumes is always expected to be non-empty if the entity
    // has any volume... in the future, this could be compressed if necessary
    // that the length can be 0 if the total_volume should be used as the only
    // collision volume for the entity.
    volumes: []Rectangle3,
}

EntityReference :: struct {
    pointer: ^Entity,
    id:      EntityId,
}

TraversablePoint :: struct {
    p:       v3,
    occupant: ^Entity,
}

TraversableReference :: struct {
    entity: EntityReference,
    index:  i64,
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

begin_entity :: proc(world: ^World) -> (result: ^Entity) {
    assert(world.creation_buffer_index < len(world.creation_buffer))
    world.creation_buffer_index += 1
    
    result = &world.creation_buffer[world.creation_buffer_index]
    // @todo(viktor): Worry about this taking a while, once the entities are large (sparse clear?)
    result ^= {}
    
    world.last_used_entity_id += 1
    result.id = world.last_used_entity_id
    result.collision = world.null_collision
    
    result.x_axis = {1, 0}
    result.y_axis = {0, 1}
    
    return result
}

end_entity :: proc(world: ^World, entity: ^Entity, p: WorldPosition) {
    assert(world.creation_buffer_index > 0)
    world.creation_buffer_index -= 1
    entity.p = p.offset
    
    pack_entity_into_world(nil, world, entity, p)
}

begin_grounded_entity :: proc(world: ^World, collision: ^EntityCollisionVolumeGroup) -> (result: ^Entity) {
    result = begin_entity(world)
    result.collision = collision
    
    return result
}

add_brain :: proc(world: ^World) -> (result: BrainId) {
    world.last_used_entity_id += 1
    for world.last_used_entity_id < cast(EntityId) ReservedBrainId.FirstFree {
        world.last_used_entity_id += 1
    }
    result = cast(BrainId) world.last_used_entity_id
    
    return result
}

mark_for_deletion :: proc(entity: ^Entity) {
    if entity != nil {
        entity.flags += { .MarkedForDeletion }
    }
}

add_wall :: proc(world: ^World, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_grounded_entity(world, world.wall_collision)
    defer end_entity(world, entity, p)
    
    entity.flags += {.Collides}
    entity.occupying = occupying
    append(&entity.pieces, VisiblePiece{
        asset = .Rock,
        height = 1.5, // random_between_f32(&world.general_entropy, 0.9, 1.7),
        color = 1,    // {random_unilateral(&world.general_entropy, f32), 1, 1, 1},
    })
}

add_hero :: proc(world: ^World, region: ^SimRegion, occupying: TraversableReference, brain_id: BrainId) {
    p := map_into_worldspace(world, region.origin, get_sim_space_traversable(occupying).p)
    
    body := begin_grounded_entity(world, world.hero_body_collision)
        body.brain_id = brain_id
        body.brain_kind = .Hero
        body.brain_slot = brain_slot_for(BrainHeroParts, "body")
        
        // @todo(viktor): We will probably need a creation-time system for
        // guaranteeing no overlapping occupation.
        body.occupying = occupying
        
        append(&body.pieces, VisiblePiece{
            asset  = .Cape,
            height = hero_height*1.3,
            offset = {0, -0.3, 0},
            color  = 1,
            flags  = { .SquishAxis, .BobUpAndDown }
        })
        append(&body.pieces, VisiblePiece{
            asset  = .Body,
            height = hero_height,
            color  = 1,
            flags  = { .SquishAxis }
        })
        append(&body.pieces, VisiblePiece{
            asset  = .Shadow,
            height = 0.5,
            offset = {0, -0.5, 0},
            color  = {1,1,1,0.5},
        })
    end_entity(world, body, p)
    
    head := begin_grounded_entity(world, world.hero_head_collision)
        head.flags += {.Collides}
        head.brain_id = brain_id
        head.brain_kind = .Hero
        head.brain_slot = brain_slot_for(BrainHeroParts, "head")
        
        hero_height :: 3.5
        // @todo(viktor): should render above the body
        append(&head.pieces, VisiblePiece{
            asset  = .Head,
            height = hero_height*1.4,
            offset = {0, -0.9*hero_height, 0},
            color  = 1,
        })

        init_hitpoints(head, 3)
        
        if world.camera_following_id == 0 {
            world.camera_following_id = head.id
        }
    end_entity(world, head, p)
}

add_monster :: proc(world: ^World, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_grounded_entity(world, world.monstar_collision)
    defer end_entity(world, entity, p)
    
    entity.flags += {.Collides}
    
    entity.brain_id = add_brain(world)
    entity.brain_kind = .Monster
    entity.brain_slot = brain_slot_for(BrainMonster, "body")
    entity.occupying = occupying
    
    height :: 0.75
    append(&entity.pieces, VisiblePiece{
        asset  = .Shadow,
        height = height,
        offset = {0, -height, 0},
        color  = {1,1,1,0.5},
    })
    
    append(&entity.pieces, VisiblePiece{
        asset  = .Monster,
        height = 1.5,
        color  = 1,
    })
    
    init_hitpoints(entity, 3)
}

add_familiar :: proc(world: ^World, p: WorldPosition) {
    entity := begin_grounded_entity(world, world.familiar_collision)
    defer end_entity(world, entity, p)
    
    entity.brain_id   = add_brain(world)
    entity.brain_kind = .Familiar
    entity.brain_slot = brain_slot_for(BrainFamiliarParts, "familiar")
    
    append(&entity.pieces, VisiblePiece{
        asset  = .Head,
        height = 1,
        color  = 1,
        offset = {0, 1, 0},
        flags  = { .BobUpAndDown }
    })
    
    append(&entity.pieces, VisiblePiece{
        asset  = .Shadow,
        height = 0.3,
        color  = {1,1,1,0.5},
    })
}

StandartRoom :: struct {
    p:      [17][9]WorldPosition,
    ground: [17][9]TraversableReference,
}

add_standart_room :: proc(world: ^World, p: WorldPosition) -> (result: StandartRoom) {
    // @volatile
    h_width  :i32= 17/2
    h_height :i32=  9/2
    tile_size_in_meters :: 1.5
    
    for offset_y in -h_height..=h_height {
        for offset_x in -h_width..=h_width {
            p := p
            p.offset.x = cast(f32) (offset_x) * tile_size_in_meters
            p.offset.y = cast(f32) (offset_y) * tile_size_in_meters
            
            entity := begin_grounded_entity(world, world.floor_collision)
                entity.traversables = make_array(&world.arena, TraversablePoint, 1)
                append(&entity.traversables, TraversablePoint{})
            end_entity(world, entity, p)
            
            occupying: TraversableReference
            occupying.entity.id = entity.id
            
            result.p[offset_x+8][offset_y+4] = p
            result.ground[offset_x+8][offset_y+4] = occupying
        }
    }
    
    return result
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
