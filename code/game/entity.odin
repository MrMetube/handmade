package game

Entity :: struct {
    id: EntityId,
    
    brain_kind: BrainKind,
    brain_slot: BrainSlot,
    brain_id:   BrainId,
    
    z_layer: i32,
    
    // @todo(viktor): if load from world and store to world become more complex we could use a @metaprogram to generate the code and mark members with @transient if needed
    
    ////////////////////////////////////////////////
    // @note(viktor): Everything below here is not worked out
    
    flags: Entity_Flags,
    
    p, dp: v3,
    ddp: v3, // @transient 
    
    t_bob, dt_bob: f32,
    ddt_bob:  f32, // @transient
    
    collision: ^EntityCollisionVolumeGroup,
    
    distance_limit: f32,
    
    hit_points: FixedArray(16, HitPoint),
    
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
    
    auto_boost_to: TraversableReference,
    
    camera_height: f32,
}

EntityId :: distinct u32

Entity_Flag :: enum {
    Collides,
    MarkedForDeletion,
    active
}
Entity_Flags :: bit_set[Entity_Flag]

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

PairwiseCollsionRule :: struct {
    next: ^PairwiseCollsionRule,
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
    volumes: [] Rectangle3,
}

EntityReference :: struct {
    pointer: ^Entity,
    id:      EntityId,
}

TraversablePoint :: struct {
    p:        v3,
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

update_and_render_entities :: proc (sim_region: ^SimRegion, dt: f32, render_group: ^RenderGroup, typical_floor_height: f32, haze_color: v4, particle_cache: ^Particle_Cache) {
    timed_function()
    
    fade_top_end      := .9 * typical_floor_height
    fade_top_start    := .5 * typical_floor_height
    fade_bottom_start := -1 * typical_floor_height
    fade_bottom_end   := -4 * typical_floor_height
    
    MinimumLayer :: -4
    MaximumLayer :: 1
    
    // @volatile
    camera_p_z := render_group != nil ? render_group.camera.p.z - BaseCamHeight : 0
    
    fog_amount: [MaximumLayer - MinimumLayer + 1] f32
    camera_relative_ground_z: [len(fog_amount)] f32
    
    test_alpha: f32
    for &fog_amount, index in fog_amount {
        relative_layer_index := MinimumLayer + index
        camera_relative_ground_z[index] = typical_floor_height * cast(f32) relative_layer_index - camera_p_z
        
        test_alpha = clamp_01_map_to_range(fade_top_end,      camera_relative_ground_z[index], fade_top_start)
        fog_amount = clamp_01_map_to_range(fade_bottom_start, camera_relative_ground_z[index], fade_bottom_end)
    }
    
    alpha_render_target: u32 = 2
    
    normal_floor_clip_rect: u16 
    alpha_floor_clip_rect: u16
    if render_group != nil {
        normal_floor_clip_rect= render_group.current_clip_rect_index
        screen_area := rectangle_zero_dimension(render_group.screen_size)
        alpha_floor_clip_rect = push_clip_rect(render_group, screen_area, alpha_render_target, render_group.camera.focal_length)
    }
    defer if render_group != nil {
        render_group.current_clip_rect_index = normal_floor_clip_rect
        push_blend_render_targets(render_group, alpha_render_target, test_alpha)
    }
    
    current_absolute_layer := sim_region.entities.count > 0 ? slice(sim_region.entities)[0].z_layer : 0
    
    for &entity in slice(sim_region.entities) {
        if .active in entity.flags {
            // @todo(viktor): Should non-active entities not do simmy stuff?
            boost_to := get_traversable(entity.auto_boost_to)
            if boost_to != nil {
                for traversable in slice(entity.traversables) {
                    occupant := traversable.occupant
                    if occupant != nil && occupant.movement_mode == .Planted {
                        occupant.came_from = occupant.occupying
                        if transactional_occupy(occupant, &occupant.occupying, entity.auto_boost_to) {
                            occupant.movement_mode = .Hopping
                            occupant.t_movement = 0
                        }
                    }
                }
            }
            
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
                    entity.angle_current = linear_blend(entity.angle_start, entity.angle_target, entity.t_movement)
                    entity.angle_current_offset = linear_blend(entity.angle_base_offset, entity.angle_swipe_offset, sin_01(entity.t_movement))
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
                t_jump :f32: 0.1
                t_thrust :f32: 0.8
                if entity.t_movement < t_thrust {
                    entity.ddt_bob -= 60
                }
                
                occupying := get_sim_space_traversable(entity.occupying).p
                came_from := get_sim_space_traversable(entity.came_from).p
                pt := occupying
                
                if t_jump <= entity.t_movement {
                    t := clamp_01_map_to_range(t_jump, entity.t_movement, 1)
                    entity.t_bob = sin(t * Pi) * 0.1
                    entity.p = linear_blend(came_from, occupying, entity.t_movement)
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
                    
                    camera_relative_ground_z := typical_floor_height * cast(f32) (entity.z_layer - sim_region.origin.chunk.z) - camera_p_z
                    spawn_fire(particle_cache, entity.p, camera_relative_ground_z, entity.z_layer)
                }
                
                hop_duration :f32: 0.2
                entity.t_movement += dt * (1 / hop_duration)
                
                if entity.t_movement >= 1 {
                    entity.t_movement = 1
                }
            }
                            
            if entity.ddp != 0 || entity.dp != 0 {
                move_entity(sim_region, &entity, dt)
            }
            
            ////////////////////////////////////////////////
            // Rendering
            
            if render_group != nil {
                facing_match   := #partial AssetVector{ .FacingDirection = entity.facing_direction }
                facing_weights := #partial AssetVector{ .FacingDirection = 1 }
                            
                relative_layer := entity.z_layer - sim_region.origin.chunk.z
                if !(MinimumLayer <= relative_layer && relative_layer <= MaximumLayer) do continue
                
                transform := default_upright_transform()
                transform.offset = get_entity_ground_point(&entity)
                transform.chunk_z = entity.z_layer
                transform.floor_z = camera_relative_ground_z[relative_layer - MinimumLayer]
                
                if current_absolute_layer != entity.z_layer {
                    assert(current_absolute_layer < entity.z_layer)
                    current_absolute_layer = entity.z_layer
                    push_sort_barrier(render_group)
                }
                
                if relative_layer == MaximumLayer {
                    render_group.current_clip_rect_index = alpha_floor_clip_rect
                } else {
                    render_group.current_clip_rect_index = normal_floor_clip_rect
                    transform.color = haze_color
                    transform.t_color.rgb = fog_amount[relative_layer - MinimumLayer]
                }
                
                shadow_transform := default_flat_transform()
                shadow_transform.offset = get_entity_ground_point(&entity)
                shadow_transform.offset.y -= 0.5
                
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
                }
                
                draw_hitpoints(render_group, &entity, 0.5, transform)
                
                for volume in entity.collision.volumes {
                    push_rectangle_outline(render_group, volume, default_upright_transform(), SeaGreen, 0.1)
                }
                
                if RenderCollisionOutlineAndTraversablePoints {
                    flat_transform := transform
                    flat_transform.is_upright = false
                    
                    for traversable in slice(entity.traversables) {
                        rect := rectangle_center_dimension(traversable.p, 1.5)
                        color := traversable.occupant != nil ? Red : Green
                        if get_traversable(entity.auto_boost_to) != nil {
                            color = Blue
                        }
                        push_rectangle(render_group, rect, flat_transform, color)
                    }
                }
                
                debug_pick_entity(&entity, transform, render_group)
            }
        }
    }
}

debug_pick_entity :: proc (entity: ^Entity, transform: Transform, render_group: ^RenderGroup) {
    when !DebugEnabled do return
    
    // @todo(viktor): we dont really have a way to unique-ify these :(
    debug_id := debug_pointer_id(cast(pmm) cast(umm) entity.id)
    if       debug_requested(debug_id) do debug_begin_data_block("Game/Entity")
    defer if debug_requested(debug_id) do debug_end_data_block()
    
    if .active in entity.flags {
        for piece in slice(&entity.pieces) {
            if debug_requested(debug_id) { 
                facing_match   := #partial AssetVector{ .FacingDirection = entity.facing_direction }
                facing_weights := #partial AssetVector{ .FacingDirection = 1 }
                bitmap_id := best_match_bitmap_from(render_group.assets, piece.asset, facing_match, facing_weights)
                debug_record_value(&bitmap_id)
            }
        }
        
        for volume in entity.collision.volumes {
            mouse_p := debug_get_mouse_p()
            local_mouse_p := unproject_with_transform(render_group, render_group.camera, transform, mouse_p)
            
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

draw_hitpoints :: proc(group: ^RenderGroup, entity: ^Entity, offset_y: f32, transform: Transform) {
    if entity.hit_points.count > 1 {
        health_size: v2 = 0.1
        spacing_between: f32 = health_size.x * 1.5
        health_x := -0.5 * (cast(f32) entity.hit_points.count - 1) * spacing_between

        for hit_point in slice(&entity.hit_points) {
            color := hit_point.filled_amount == 0 ? Gray : Red
            // @cleanup rect
            push_rectangle(group, rectangle_center_dimension(v3{health_x, -offset_y, 0}, V3(health_size, 0)), transform, color)
            health_x += spacing_between
        }
    }
}