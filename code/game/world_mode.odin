package game

World_Mode :: struct {
    world: ^World,

    camera: Game_Camera,
    ////////////////////////////////////////////////
    // General
    tile_size_in_meters:  f32,
    typical_floor_height: f32,
    standard_room_dimension: v3,
    
    last_used_entity_id: EntityId, // @todo(viktor): Worry about wrapping - Free list of ids?
    
    effects_entropy: RandomSeries, // @note(viktor): this is randomness that does NOT effect the gameplay
    particle_cache:  ^Particle_Cache,
    creation_region: ^SimRegion,
    
    use_debug_camera:   bool,
    debug_last_mouse_p: v2,
    debug_camera_pitch: f32,
    debug_camera_orbit: f32,
    debug_camera_dolly: f32,
    
    camera_pitch: f32,
    camera_orbit: f32,
    camera_dolly: f32,
}

Game_Camera :: struct {
    // @todo(viktor): Should we allow split-screen?
    following_id: EntityId,
    simulation_center: WorldPosition,
    
    p:      WorldPosition,
    offset: v3,
    
    target_p:      WorldPosition,
    target_offset: v3,
    
    special:   EntityId,
    t_special: f32,
}

////////////////////////////////////////////////

play_world :: proc (state: ^State, tran_state: ^TransientState) {
    mode := set_game_mode(state, tran_state, World_Mode)
    
    ////////////////////////////////////////////////
    
    mode.last_used_entity_id = cast(EntityId) ReservedBrainId.FirstFree
    
    mode.effects_entropy = seed_random_series(500)
    
    mode.tile_size_in_meters = 1.4
    mode.typical_floor_height = 5
    
    // :RoomSize
    chunk_dim_meters := v3{17 * mode.tile_size_in_meters, 9 * mode.tile_size_in_meters, mode.typical_floor_height}
    mode.world = create_world(chunk_dim_meters, &state.mode_arena)
    mode.standard_room_dimension = chunk_dim_meters
    
    ////////////////////////////////////////////////
    // "World Gen"
    
    creation_memory := begin_temporary_memory(&tran_state.arena)
    mode.creation_region = begin_world_changes(creation_memory.arena, mode.world, {}, {}, 0)
    
    door_left, door_right: bool
    door_top, door_bottom: bool
    stair_up, stair_down:  bool
    
    room_center: v3i
    choice: u32
    screen_count :: 10
    for screen_index in 0 ..< screen_count {
        room_radius := v2i {7, 4} + {random_between(&mode.world.game_entropy, i32, 0, 3), random_between(&mode.world.game_entropy, i32, 0, 3)} // :RoomSize
        room_size := room_radius * 2 + 1
        
        switch choice {
          case 0: room_center.x += room_radius.x
          case 1: room_center.y += room_radius.y
          case 2: room_center.z -= 1
          case 3: room_center.z += 1
          case 4: room_center.x -= room_radius.x
          case 5: room_center.y -= room_radius.y
        }
        
        when false {
            choice = random_between(&mode.world.game_entropy, u32, 0, 1)
        } else {
            choice = 3
        }
        
        switch choice {
          case 0: door_right  = true
          case 1: door_top    = true
          case 2: stair_down  = true
          case 3: stair_up    = true
          case 4: door_left   = true
          case 5: door_bottom = true
        }
        
        left_hole  := true || screen_index % 2 == 0
        right_hole := true || !left_hole
        if screen_index == 0 {
            left_hole  = false
            right_hole = false
        }
        
        room := add_standart_room(mode, room_center, left_hole, right_hole, room_radius)
        
        for tile_y in 0..< room_size.y {
            tile_x := 0
            if !(door_left && tile_y == room_size.y / 2) {
                add_wall(mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_y in 0..< room_size.y {
            tile_x := room_size.x-1
            if !(door_right && tile_y == room_size.y / 2) {
                add_wall(mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_x in 0 ..< room_size.x {
            tile_y := 0
            if !(door_bottom && tile_x == room_size.x / 2) {
                add_wall(mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_x in 0 ..< room_size.x {
            tile_y := room_size.y-1
            if !(door_top && tile_x == room_size.x / 2) {
                add_wall(mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        
        add_monster(mode,  room.p[3][4], room.ground[3][4])
        // add_familiar(mode, room.p[2][5], room.ground[2][5])
        
        snake_brain := add_brain(mode)
        for piece_index in u32(0)..<len(BrainSnake{}.segments) {
            x := 1+piece_index
            add_snake_piece(mode, room.p[x][7], room.ground[x][7], snake_brain, piece_index)
        }
        
        
        door_left   = door_right
        door_bottom = door_top
        door_right  = false
        door_top    = false
        
        stair_up   = false
        stair_down = false
        
        if screen_index + 1 == screen_count do break
        
        switch choice {
          case 0: room_center.x += room_radius.x + 1
          case 1: room_center.y += room_radius.y + 1
          case 2: room_center.z -= 1
          case 3: room_center.z += 1
          case 4: room_center.x -= room_radius.x + 1
          case 5: room_center.y -= room_radius.y + 1
        }
    }
    
    new_camera_p := chunk_position_from_tile_positon(mode, room_center)
    
    mode.camera.p = new_camera_p
    mode.camera.simulation_center = mode.camera.p
    
    end_world_changes(mode.creation_region)
    mode.creation_region = nil
    end_temporary_memory(creation_memory)
        
    mode.particle_cache = push(&tran_state.arena, Particle_Cache)
    init_particle_cache(mode.particle_cache, tran_state.assets)
}

////////////////////////////////////////////////

begin_entity :: proc (mode: ^World_Mode) -> (result: ^Entity) {
    result = create_entity(mode.creation_region, allocate_entity_id(mode))
 
    // @todo(viktor): Worry about this taking a while, once the entities are large (sparse clear?)
    result ^= { id = result.id }
    
    result.x_axis = {1, 0}
    result.y_axis = {0, 1}
    
    return result
}

allocate_entity_id :: proc (mode: ^World_Mode) -> (result: EntityId) {
    mode.last_used_entity_id += 1
    result = mode.last_used_entity_id
 
    return result
}

end_entity :: proc (mode: ^World_Mode, entity: ^Entity, p: WorldPosition) {
    entity.p = world_distance(mode.world, p, mode.creation_region.origin)
}

add_brain :: proc (mode: ^World_Mode) -> (result: BrainId) {
    mode.last_used_entity_id += 1
    for mode.last_used_entity_id < cast(EntityId) ReservedBrainId.FirstFree {
        mode.last_used_entity_id += 1
    }
    result = cast(BrainId) mode.last_used_entity_id
    
    return result
}

add_wall :: proc (mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_entity(mode)
    defer end_entity(mode, entity, p)
    
    entity.collision_volume = grounded_collision({mode.tile_size_in_meters, mode.tile_size_in_meters, mode.typical_floor_height})
    entity.flags += {.Collides}
    entity.occupying = occupying
    append(&entity.pieces, VisiblePiece {
        asset     = .Tree,
        dimension = {1, 2.5},
        color     = 1,
    })
}

add_hero :: proc (mode: ^World_Mode, region: ^SimRegion, occupying: TraversableReference, brain_id: BrainId) {
    mode.creation_region = region
    defer mode.creation_region = nil
    
    p := map_into_worldspace(mode.world, region.origin, get_sim_space_traversable(occupying).p)
    
    body := begin_entity(mode)
        body.brain_id = brain_id
        body.brain_kind = .Hero
        body.brain_slot = brain_slot_for(BrainHero, "body")
        
        // @todo(viktor): We will probably need a creation-time system for guaranteeing no overlapping occupation.
        body.occupying = occupying
        
        append(&body.pieces, VisiblePiece{
            asset     = .Shadow,
            dimension = {0, hero_height*1},
            color     = {1,1,1,0.5},
        }) 
        append(&body.pieces, VisiblePiece{
            asset     = .Cape,
            dimension = {0, hero_height*1.2},
            color     = 1,
            flags     = { .SquishAxis, .BobUpAndDown },
        })
        append(&body.pieces, VisiblePiece{
            asset     = .Torso,
            dimension = {0, hero_height*1.2},
            offset    = {0, -0.1, 0},
            color     = 1,
            flags     = { .SquishAxis },
        })
        
    end_entity(mode, body, p)
    
    head := begin_entity(mode)
        head.flags += {.Collides}
        head.brain_id = brain_id
        head.brain_kind = .Hero
        head.brain_slot = brain_slot_for(BrainHero, "head")
        head.movement_mode = ._Floating
        head.collision_volume = grounded_collision({1, 0.5, 0.5}, 0.7)
        
        hero_height :: 3
        // @todo(viktor): should render above the body
        append(&head.pieces, VisiblePiece{
            asset     = .Head,
            dimension = {0, hero_height*1.2},
            offset    = {0, -0.7, 0},
            color     = 1,
        })
        
        init_hitpoints(head, 3)
        
        if mode.camera.following_id == 0 {
            mode.camera.following_id = head.id
        }
    end_entity(mode, head, p)
    
    
    glove := begin_entity(mode)
        glove.collision_volume = grounded_collision(v3{0.2, 0.2, 0.2})
        glove.flags += {.Collides}
        glove.brain_id = brain_id
        glove.brain_kind = .Hero
        glove.brain_slot = brain_slot_for(BrainHero, "glove")
        
        glove.movement_mode = .AngleOffset
        glove.angle_current = -0.25 * Tau
        glove.angle_base_offset  = 0.3
        glove.angle_swipe_offset = 1
        glove.angle_current_offset = 0.3
        
        append(&head.pieces, VisiblePiece{
            asset     = .Sword,
            dimension = {0, 0.25*hero_height},
            offset    = 0,
            color     = 1,
        })
        
    end_entity(mode, glove, p)
}

add_snake_piece :: proc (mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference, brain_id: BrainId, segment_index: u32) {
    entity := begin_entity(mode)
    defer end_entity(mode, entity, p)
    
    entity.brain_id = brain_id
    entity.brain_kind = .Snake
    entity.brain_slot = brain_slot_for(BrainSnake, "segments", segment_index)
    entity.occupying = occupying
    
    height :: 1.5
    append(&entity.pieces, VisiblePiece{
        asset     = .Shadow,
        dimension = {0, height},
        offset    = {0, 0, 0},
        color     = {1,1,1,0.5},
    })
    
    append(&entity.pieces, VisiblePiece{
        asset  = segment_index == 0 ? .Head : .Torso,
        dimension = {0, height},
        color  = 1,
    })
    
    init_hitpoints(entity, 3)
}

add_monster :: proc (mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_entity(mode)
    defer end_entity(mode, entity, p)
    
    entity.brain_id = add_brain(mode)
    entity.brain_kind = .Monster
    entity.brain_slot = brain_slot_for(BrainMonster, "body")
    entity.occupying = occupying
    
    height :: 4.5
    append(&entity.pieces, VisiblePiece{
        asset     = .Shadow,
        dimension = {0, height},
        offset    = {0, 0, 0},
        color     = {1,1,1,0.5},
    })
    
    append(&entity.pieces, VisiblePiece{
        asset     = .Torso,
        dimension = {0, height},
        color     = 1,
    })
    
    init_hitpoints(entity, 3)
}

add_familiar :: proc (mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_entity(mode)
    defer end_entity(mode, entity, p)
    
    entity.brain_id   = add_brain(mode)
    entity.brain_kind = .Familiar
    entity.brain_slot = brain_slot_for(BrainFamiliar, "familiar")
    entity.occupying  = occupying
    entity.movement_mode = ._Floating
    
    append(&entity.pieces, VisiblePiece{
        asset     = .Head,
        dimension = {0, 2.5},
        color     = 1,
        offset    = {0, 0, 0},
        flags     = { .BobUpAndDown },
    })
    
    append(&entity.pieces, VisiblePiece{
        asset     = .Shadow,
        dimension = {0, 2.5},
        color     = {1,1,1,0.5},
    })
}

StandartRoom :: struct {
    p:      [64][64] WorldPosition,
    ground: [64][64] TraversableReference,
}

add_standart_room :: proc (mode: ^World_Mode, tile_p: v3i, left_hole, right_hole: bool, radius: v2i) -> (result: StandartRoom) {
    floor_tile_height :: 0.5
    
    for offset_y in -radius.y ..= radius.y {
        for offset_x in -radius.x ..= radius.x {
            p := chunk_position_from_tile_positon(mode, tile_p + {offset_x, offset_y, 0})
            
            index_x := offset_x+radius.x
            index_y := offset_y+radius.y
            
            jitter_top: v3
            jitter_left: v3
            jitter_left.x += random_bilateral(&mode.world.game_entropy, f32) * 0.2
            jitter_left.y += random_bilateral(&mode.world.game_entropy, f32) * 0.2
            jitter_left.z += random_unilateral(&mode.world.game_entropy, f32) * 0.2
            jitter_top.x += random_bilateral(&mode.world.game_entropy, f32) * 0.2
            jitter_top.y += random_bilateral(&mode.world.game_entropy, f32) * 0.2
            jitter_top.z += random_unilateral(&mode.world.game_entropy, f32) * 0.2
            
            jitter_now := linear_blend(jitter_left, jitter_top, 0.5)
            p.offset += jitter_now + {0, 0, floor_tile_height}
            
            result.p[index_x][index_y] = p
            
            if left_hole && (offset_x >= -5 && offset_x <= -3 && offset_y >= 0 && offset_y <= 1) {
                // @note(viktor): hole down to floor below
            }else if right_hole && (offset_x >= 3 && offset_x <= 4 && offset_y >= -2 && offset_y <= 2) {
                // @note(viktor): hole down to floor below
            } else {
                entity := begin_entity(mode)
                entity.traversables = make_array(mode.world.arena, TraversablePoint, 1)
                append(&entity.traversables, TraversablePoint{})
                append(&entity.pieces, VisiblePiece {
                    asset     = .Tuft,
                    dimension = {.75, floor_tile_height},
                    color     = srgb_to_linear(Green),
                    flags     = {.cube},
                })
                end_entity(mode, entity, p)
                
                occupying: TraversableReference
                occupying.entity.id = entity.id
                occupying.entity.pointer = entity
                result.ground[index_x][index_y] = occupying
            }
        }
    }
    
    tile := mode.tile_size_in_meters
    
    stair_p: [5] WorldPosition
    for offset_y in cast(i32) -2 ..= 2 {
        offset_x: i32 = 3
        p := chunk_position_from_tile_positon(mode, tile_p + {offset_x, offset_y, 0}, {0.5 * tile, 0, 0})
        
        index_x := offset_x+radius.x
        index_y := offset_y+radius.y
        
        t := clamp_01_map_to_range(cast(f32) -2.5, cast(f32) offset_y, 2.5)
        p.offset.z += linear_blend(cast(f32) 0, -mode.typical_floor_height*1.8, t)
        
        entity := begin_entity(mode)
        entity.traversables = make_array(mode.world.arena, TraversablePoint, 1)
        append(&entity.traversables, TraversablePoint{})
        append(&entity.pieces, VisiblePiece {
            asset     = .Tuft,
            dimension = {1, floor_tile_height},
            color     = srgb_to_linear(Green),
            flags     = {.cube},
        })
        end_entity(mode, entity, p)
        stair_p[offset_y - -2] = p
        
        occupying: TraversableReference
        occupying.entity.id = entity.id
        occupying.entity.pointer = entity
        result.ground[index_x][index_y] = occupying
    }
    
    { // @note(viktor): Hole camera
        entity := begin_entity(mode)
        entity.camera_behaviour = { .inspect, .offset, .general_velocity_constraint }
        entity.camera_offset    = {0, 2*tile, 4}
        entity.camera_min_time  = 1
        entity.camera_velocity_max = 0.01
        
        x_dim := 3 * tile
        y_dim := 1 * tile
        entity.collision_volume = grounded_collision(v3{x_dim, y_dim,1})
        end_entity(mode, entity, result.p[-4+radius.x][-1+radius.y])
    }
    
    { // @note(viktor): Stair camera
        entity := begin_entity(mode)
        entity.camera_behaviour = { .follow_player }
        x_dim := 0.5 * tile
        y_dim := 3   * tile - tile*0.5
        entity.collision_volume = Rectangle3{
            {tile*0.5 + -x_dim, -y_dim,   -0.8 * mode.typical_floor_height},
            {tile*0.5 +  x_dim,  y_dim+tile*0.5, 1.1 * mode.typical_floor_height},
        }
        end_entity(mode, entity, stair_p[2])
        
        entity = begin_entity(mode)
        entity.camera_behaviour = { .inspect, .directional_velocity_constraint }
        entity.camera_velocity_dir = {0, 1, 0}
        entity.camera_velocity_min = 0.2
        entity.camera_velocity_max = +Infinity
        entity.collision_volume = grounded_collision({2, 1, 1} * tile)
        entity.collision_volume.min.x += 0.5 * tile
        entity.collision_volume.max.x += 0.5 * tile
        end_entity(mode, entity, result.p[3+radius.x][-3+radius.y])
    }
    
    p := chunk_position_from_tile_positon(mode, tile_p)
    scale := v3{tile, tile, mode.typical_floor_height}
    
    size := V3(vec_cast(f32, radius) * 2 + 1, 2) * scale
    
    room := begin_entity(mode)
    room.collision_volume = grounded_collision(size)
    room.brain_kind = .Room
    end_entity(mode, room, p)
    
    return result
}

init_hitpoints :: proc (entity: ^Entity, count: u32) {
    for _ in 0..<count {
        append(&entity.hit_points, HitPoint { filled_amount = HitPointPartCount })
    }
}

grounded_collision :: proc (size: v3, offset_z: f32 = 0) -> (result: Rectangle3) {
    result = rectangle_center_dimension(v3{0, 0, 0.5 * size.z}, size)
    result = add_offset(result, v3{0, 0, offset_z})
    return result
}