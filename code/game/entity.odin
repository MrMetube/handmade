package game

Entity :: struct {
    id: EntityId,
    
    brain_kind: BrainKind,
    brain_slot: BrainSlot,
    brain_id:   BrainId,
    
    camera_behaviour:    Camera_Behaviour,
    camera_min_time:     f32,
    camera_offset:       v3,
    camera_velocity_min: f32,
    camera_velocity_max: f32,
    camera_velocity_dir: v3,
    // @todo(viktor): if load from world and store to world become more complex we could use a @metaprogram to generate the code and mark members with @transient if needed
    
    ////////////////////////////////////////////////
    // @note(viktor): Everything below here is not worked out
    
    flags: Entity_Flags,
    
    p, dp: v3,
    ddp: v3, // @transient 
    
    t_bob, dt_bob: f32,
    ddt_bob:  f32, // @transient
    
    collision_volume: Rectangle3,
    
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
}

EntityId :: distinct u32

Entity_Flag :: enum {
    Collides,
    MarkedForDeletion,
    active,
}
Entity_Flags :: bit_set[Entity_Flag]

VisiblePiece :: struct {
    asset:     AssetTypeId,
    dimension: v2,
    offset:    v3,
    color:     v4,
    
    flags: bit_set[ enum {
        SquishAxis,
        BobUpAndDown,
        cube,
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

Camera_Behaviour :: bit_set[enum {
    inspect,
    offset,
    follow_player,
    
    general_velocity_constraint,
    directional_velocity_constraint,
}]

////////////////////////////////////////////////

update_and_render_entities :: proc (sim_region: ^SimRegion, dt: f32, render_group: ^RenderGroup, typical_floor_height: f32, particle_cache: ^Particle_Cache) {
    timed_function()
    
    for &entity in slice(sim_region.entities) {
        if .active in entity.flags {
            boost := begin_timed_block("entity boost")
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
            end_timed_block(boost)
            
            ////////////////////////////////////////////////
            // Physics
            
            physics := begin_timed_block("entity physics")
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
                    
                    spawn_fire(particle_cache, entity.p)
                }
                
                hop_duration :f32: 0.2
                entity.t_movement += dt * (1 / hop_duration)
                
                if entity.t_movement >= 1 {
                    entity.t_movement = 1
                }
            }
            end_timed_block(physics)
                            
            if entity.ddp != 0 || entity.dp != 0 {
                move_entity(sim_region, &entity, dt)
            }
            
            if render_group == nil do continue
            ////////////////////////////////////////////////
            // Rendering
            
            rendering := begin_timed_block("entity rendering")
            facing_match := #partial AssetVector{ .FacingDirection = {entity.facing_direction, 1} }
            
            transform := default_upright_transform()
            transform.offset = entity.p
            
            shadow_transform := default_flat_transform()
            shadow_transform.offset = entity.p
            shadow_transform.offset.y -= 0.5
            
            rendering_pieces := begin_timed_block("entity rendering pieces")
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
                
                if .cube in piece.flags {
                    p := transform.offset + offset
                    push_cube_raw(render_group, &render_group.commands.white_bitmap, p, piece.dimension.x, piece.dimension.y, color)
                } else {
                    bitmap_id := best_match_bitmap_from(render_group.assets, piece.asset, facing_match)
                    push_bitmap(render_group, bitmap_id, transform, piece.dimension.y, offset, color, x_axis = x_axis, y_axis = y_axis)
                }
            }
            draw_hitpoints(render_group, &entity, 0.5, transform)
            
            end_timed_block(rendering_pieces)
            
            rendering_volumes := begin_timed_block("entity rendering volumes")
            if has_volume(entity.collision_volume) {
                color := srgb_to_linear(SeaGreen)
                if .Collides in entity.flags {
                    color = srgb_to_linear(Hazel)
                }
                push_volume_outline(render_group, entity.collision_volume, transform, color, 0.01)
            }
            end_timed_block(rendering_volumes)
            end_timed_block(rendering)
            
            debug_pick_entity(&entity, transform, render_group)
        }
    }
}

debug_pick_entity :: proc (entity: ^Entity, transform: Transform, render_group: ^RenderGroup) {
    when !DebugEnabled do return
    
    timed_function()
    
    // @todo(viktor): we dont really have a way to unique-ify these :(
    debug_id := debug_pointer_id(cast(pmm) cast(umm) entity.id)
    if       debug_requested(debug_id) do debug_begin_data_block("Game/Entity")
    defer if debug_requested(debug_id) do debug_end_data_block()
    
    if .active in entity.flags {
        for piece in slice(&entity.pieces) {
            if debug_requested(debug_id) { 
                facing_match   := #partial AssetVector{ .FacingDirection = {entity.facing_direction, 1} }
                bitmap_id := best_match_bitmap_from(render_group.assets, piece.asset, facing_match)
                debug_record_value(&bitmap_id)
            }
        }
        
        volume := entity.collision_volume
        mouse_p := debug_get_mouse_p()
        
        // @todo(viktor): This needs to do ray casting now, if we want to reenable it!
        local_mouse_p := unproject_with_transform(render_group, render_group.debug_cam, mouse_p, 1)
        if contains(volume, local_mouse_p) {
            debug_hit(debug_id, local_mouse_p.z)
        }
        
        highlighted, color := debug_highlighted(debug_id)
        if highlighted {
            push_volume_outline(render_group, volume, transform, color, 0.05)
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

draw_hitpoints :: proc (group: ^RenderGroup, entity: ^Entity, offset_y: f32, transform: Transform) {
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