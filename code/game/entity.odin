package game

Entity :: struct {
    id: EntityId,
    
    brain_kind: BrainKind,
    brain_slot: BrainSlot,
    brain_id:   BrainId,
    
    // @todo(viktor): @metaprogram
    manual_sort_key: ManualSortKey, // @transient
    
    ////////////////////////////////////////////////
    // @note(viktor): Everything below here is not worked out

    updatable: b32,
        
    flags: EntityFlags,
    
    p, dp: v3,
    ddp: v3, // @transient 

    t_bob, dt_bob: f32,
    ddt_bob:  f32, // @transient
    
    collision: ^EntityCollisionVolumeGroup,
    
    distance_limit: f32,
    
    hit_point_max: u32, // :Array
    hit_points: [16]HitPoint,
    
    movement_mode: MovementMode,
    t_movement:    f32,
    occupying: TraversableReference,
    came_from: TraversableReference,
    
    angle_base: v3,
    angle_current: f32,
    angle_start: f32,
    angle_target: f32,
    angle_current_offset: f32,
    angle_base_offset: f32,
    angle_swipe_offset: f32,
    
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
    _Floating,
    
    AngleOffset,
    AngleAttackSwipe,
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

// @cleanup
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

// @cleanup
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
        body.brain_slot = brain_slot_for(BrainHero, "body")
        
        // @todo(viktor): We will probably need a creation-time system for
        // guaranteeing no overlapping occupation.
        body.occupying = occupying
        
        append(&body.pieces, VisiblePiece{
            asset  = .Body,
            height = hero_height,
            color  = 1,
            flags  = { .SquishAxis },
        })
        append(&body.pieces, VisiblePiece{
            asset  = .Cape,
            height = hero_height*1.3,
            offset = {0, -0.3, 0},
            color  = 1,
            flags  = { .SquishAxis, .BobUpAndDown },
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
        head.brain_slot = brain_slot_for(BrainHero, "head")
        head.movement_mode = ._Floating
        
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
    
    glove := begin_grounded_entity(world, world.glove_collision)
        glove.flags += {.Collides}
        glove.brain_id = brain_id
        glove.brain_kind = .Hero
        glove.brain_slot = brain_slot_for(BrainHero, "glove")
        
        glove.movement_mode = .AngleOffset
        glove.angle_current = -0.25 * Tau
        glove.angle_base_offset  = 0.75
        glove.angle_swipe_offset = 1.5
        
        append(&head.pieces, VisiblePiece{
            asset  = .Sword,
            height = hero_height,
            offset = {0, -0.5*hero_height, 0},
            color  = 1,
        })
        
    end_entity(world, glove, p)
}

add_snake_piece :: proc(world: ^World, p: WorldPosition, occupying: TraversableReference, brain_id: BrainId, segment_index: u32) {
    entity := begin_grounded_entity(world, world.monstar_collision)
    defer end_entity(world, entity, p)
    
    entity.flags += {.Collides}
    
    entity.brain_id = brain_id
    entity.brain_kind = .Snake
    entity.brain_slot = brain_slot_for(BrainSnake, "segments", segment_index)
    entity.occupying = occupying
    
    height :: 0.5
    append(&entity.pieces, VisiblePiece{
        asset  = .Shadow,
        height = height,
        offset = {0, -height, 0},
        color  = {1,1,1,0.5},
    })
    
    append(&entity.pieces, VisiblePiece{
        asset  = segment_index == 0 ? .Head : .Body,
        height = 1,
        color  = 1,
    })
    
    init_hitpoints(entity, 3)
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

add_familiar :: proc(world: ^World, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_grounded_entity(world, world.familiar_collision)
    defer end_entity(world, entity, p)
    
    entity.brain_id   = add_brain(world)
    entity.brain_kind = .Familiar
    entity.brain_slot = brain_slot_for(BrainFamiliar, "familiar")
    entity.occupying  = occupying
    entity.movement_mode = ._Floating
    
    append(&entity.pieces, VisiblePiece{
        asset  = .Head,
        height = 2,
        color  = 1,
        offset = {0, 1, 0},
        flags  = { .BobUpAndDown },
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
            
            if offset_x >= -4 && offset_x <= -1 && offset_y >= -1 && offset_y <= 1 {
                continue
            }
            
            when false {
                p.offset.x += random_bilateral(&world.game_entropy, f32) * 0.2
                p.offset.y += random_bilateral(&world.game_entropy, f32) * 0.2
            }
            
            if offset_x == 3  && offset_y >= -3 && offset_y <= 3 {
                p.offset.z += 0.4 * cast(f32) (offset_y - -3)
            }
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

simulate_entity :: proc(input: Input, world: ^World, sim_region: ^SimRegion, render_group: ^RenderGroup, camera_p: v3, entity: ^Entity, dt: f32, haze_color: v4, clip_rect_index: []u16, minimum_layer: i32, maximum_layer: i32) {
    // @todo(viktor): we dont really have a way to unique-ify these :(
    debug_id := debug_pointer_id(cast(pmm) cast(umm) entity.id)
    if debug_requested(debug_id) { 
        debug_begin_data_block("Game/Entity")
    }
    defer if debug_requested(debug_id) {
        debug_end_data_block()
    }

    // @cleanup is this still relevant
    if entity.updatable { // @todo(viktor):  move this out into entity.odin
        ////////////////////////////////////////////////
        // Physics
        if entity.movement_mode == .Planted {
            if entity.occupying.entity.pointer != nil {
                entity.p = get_sim_space_traversable(entity.occupying).p
            }
        }
        
        switch entity.movement_mode {
            case ._Floating: // nothing
            
            case .AngleAttackSwipe:
            if entity.t_movement < 1 {
                entity.angle_current = lerp(entity.angle_start, entity.angle_target, entity.t_movement)
                entity.angle_current_offset = lerp(entity.angle_base_offset, entity.angle_swipe_offset, sin_01(entity.t_movement))
            } else  {
                entity.movement_mode = .AngleOffset
                
                entity.angle_current = entity.angle_target
                entity.angle_current_offset = entity.angle_base_offset
            }
            
            entity.t_movement += dt * 8
            entity.t_movement = min(entity.t_movement, 1)
            
            fallthrough
          case .AngleOffset:
            arm_ := entity.angle_current_offset * arm(entity.angle_current + entity.facing_direction)
            entity.p = entity.angle_base + V3(arm_.xy, 0) + v3{0, .2, 0}
            
          case .Planted:
            if entity.occupying.entity.pointer != nil {
                entity.p = entity.occupying.entity.pointer.p
            }
            
          case .Hopping:
            t_jump :: 0.1
            t_thrust :: 0.8
            if entity.t_movement < t_thrust {
                entity.ddt_bob -= 60
            }
            
            occupying := get_sim_space_traversable(entity.occupying).p
            came_from := get_sim_space_traversable(entity.came_from).p
            pt := occupying
            
            if t_jump <= entity.t_movement {
                t := clamp_01_to_range(t_jump, entity.t_movement, 1)
                entity.t_bob = sin(t * Pi) * 0.1
                entity.p = lerp(came_from, occupying, entity.t_movement)
                entity.dp = 0
                
                pf := came_from
                
                // :ZHandling
                height := v3{0, 0.3, 0.3}
                
                c := pf
                a := -4 * height
                b := pt - pf - a
                entity.p = a * square(t) + b * t + c
            }
            
            if entity.t_movement >= 1 {
                entity.movement_mode = .Planted
                entity.dt_bob = -3
                entity.p = pt
                entity.came_from = entity.occupying
            }
            
            hop_duration :f32: 0.2
            entity.t_movement += dt * (1 / hop_duration)
            
            if entity.t_movement >= 1 {
                entity.t_movement = 1
            }
        }
        
        if entity.ddp != 0 || entity.dp != 0 {
            move_entity(sim_region, entity, dt)
        }
        
        ////////////////////////////////////////////////
        // Rendering
        
        transform := default_upright_transform()
        transform.offset = get_entity_ground_point(entity) - camera_p
        transform.manual_sort_key = entity.manual_sort_key
        
        shadow_transform := default_flat_transform()
        shadow_transform.offset = get_entity_ground_point(entity) - camera_p
        shadow_transform.offset.y -= 0.5
        
        facing_match   := #partial AssetVector{ .FacingDirection = entity.facing_direction }
        facing_weights := #partial AssetVector{ .FacingDirection = 1 }
        
        convert_to_relative_layer :: proc(world: ^World, z: f32) -> (relative_index: i32, offset_z: f32) {
            p := map_into_worldspace(world, {chunk = {0, 0, relative_index}}, z)
            offset_z = p.offset.z
            relative_index = p.chunk.z
            return relative_index, offset_z
        }
        
        relative_layer, offset_z := convert_to_relative_layer(world, transform.offset.z)
        // transform.offset.z = offset_z
        
        if !(minimum_layer <= relative_layer && relative_layer <= maximum_layer) {
            return
        }
        
        render_group.current_clip_rect_index = clip_rect_index[relative_layer - minimum_layer]
        
        if entity.pieces.count > 1 do begin_aggregate_sort_key(render_group)
        for piece in slice(&entity.pieces) {
            offset := piece.offset
            color  := piece.color
            x_axis := entity.x_axis
            y_axis := entity.y_axis
            
            if .BobUpAndDown in piece.flags {
                // @todo(viktor): Reenable this floating animation
                // entity.t_bob += dt
                // if entity.t_bob > Tau {
                //     entity.t_bob -= Tau
                // }
                // hz :: 4
                // coeff := sin(entity.t_bob * hz)
                // z := (coeff) * 0.3 + 0.1
                
                // offset += {0, z, 0}
                // color = {1,1,1,1 - 0.5 / 2 * (coeff+1)}
            }
            
            if .SquishAxis in piece.flags {
                y_axis *= 0.4
            }
            
            bitmap_id := best_match_bitmap_from(render_group.assets, piece.asset, facing_match, facing_weights)
            push_bitmap(render_group, bitmap_id, transform, piece.height, offset, color, x_axis = x_axis, y_axis = y_axis)
            
            if debug_requested(debug_id) { 
                debug_record_value(&bitmap_id)
            }
        }
        if entity.pieces.count > 1 do end_aggregate_sort_key(render_group)
        
        draw_hitpoints(render_group, entity, 0.5, transform)
        
        if RenderCollisionOutlineAndTraversablePoints {
            color := Green
            color.rgb *= 0.4
            flat_transform := transform
            flat_transform.is_upright = false
            
            for traversable in slice(entity.traversables) {
                rect := rectangle_center_dimension(traversable.p, 1.3)
                push_rectangle(render_group, rect, flat_transform, traversable.occupant != nil ? Red : Green)
                // push_rectangle_outline(render_group, rect, flat_transform, Black)
            }
        }
        
        when DebugEnabled do if false {
            for volume in entity.collision.volumes {
                local_mouse_p := unproject_with_transform(render_group.camera, transform, input.mouse.p)
                
                if local_mouse_p.x >= volume.min.x && local_mouse_p.x < volume.max.x && local_mouse_p.y >= volume.min.y && local_mouse_p.y < volume.max.y  {
                    debug_hit(debug_id, local_mouse_p.z)
                }
                
                highlighted, color := debug_highlighted(debug_id)
                if highlighted {
                    push_rectangle_outline(render_group, volume, transform, color, 0.05)
                }
            }
            
            if debug_requested(debug_id) { 
                debug_record_value(cast(^u32) &entity.id, name = "entity_id")
                debug_record_value(&entity.p.x)
                debug_record_value(&entity.p.y)
                debug_record_value(&entity.p.y)
                debug_record_value(&entity.dp)
            }
        }
        
    }
}

draw_hitpoints :: proc(group: ^RenderGroup, entity: ^Entity, offset_y: f32, transform: Transform) {
    if entity.hit_point_max > 1 {
        health_size: v2 = 0.1
        spacing_between: f32 = health_size.x * 1.5
        health_x := -0.5 * (cast(f32) entity.hit_point_max - 1) * spacing_between

        for index in 0..<entity.hit_point_max {
            hit_point := entity.hit_points[index]
            color := hit_point.filled_amount == 0 ? Gray : Red
            // @cleanup rect
            push_rectangle(group, rectangle_center_dimension(v3{health_x, -offset_y, 0}, V3(health_size, 0)), transform, color)
            health_x += spacing_between
        }
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
                rule_pointer ^= rule.next
            } else {
                rule_pointer = &rule.next
            }
        }
    }
}
