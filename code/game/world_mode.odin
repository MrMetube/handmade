package game

World_Mode :: struct {
    ////////////////////////////////////////////////
    // World specific
    world: ^World_,
    
    ////////////////////////////////////////////////
    // General
    typical_floor_height: f32,
    
    // @todo(viktor): Should we allow split-screen?
    camera_following_id: EntityId,
    camera_p :           WorldPosition,
    camera_offset:       v3,
    
    collision_rule_hash:       [256] ^PairwiseCollsionRule,
    first_free_collision_rule: ^PairwiseCollsionRule,
    
    null_collision, 
    wall_collision,    
    floor_collision,
    stairs_collision, 
    hero_body_collision, 
    hero_head_collision, 
    glove_collision,
    monstar_collision, 
    familiar_collision: ^EntityCollisionVolumeGroup, 
    
    // @note(viktor): Only for testing, use Input.delta_time and your own t-values.
    time: f32,
    
    // @todo(viktor): This could just be done in temporary memory.
    // @todo(viktor): This should catch bugs, remove once satisfied.
    creation_buffer_index: u32,
    creation_buffer:       [4]Entity,
    last_used_entity_id:   EntityId, // @todo(viktor): Worry about wrapping - Free list of ids?
    
    game_entropy:    RandomSeries,
    effects_entropy: RandomSeries, // @note(viktor): this is randomness that does NOT effect the gameplay
    
    // @cleanup Particle System tests
    next_particle: u32,
    particles:     [256] Particle,
    cells:         [ParticleCellSize] [ParticleCellSize] ParticleCell,
    
    particle_cache: ^Particle_Cache,
}

ParticleCellSize :: 16

ParticleCell :: struct {
    density: f32,
    velocity_times_density: v3,
}

Particle :: struct {
    p:      v3,
    dp:     v3,
    ddp:    v3,
    color:  v4,
    dcolor: v4,
    
    bitmap_id: BitmapId,
}

////////////////////////////////////////////////

play_world :: proc(state: ^State, tran_state: ^TransientState) {
    set_game_mode(state, tran_state, ^World_Mode)
    world_mode := push(&state.mode_arena, World_Mode)
    defer state.game_mode = world_mode
    // sub_arena(&world.arena, parent_arena, arena_remaining_size(parent_arena))
    
    ////////////////////////////////////////////////
    
    world_mode.last_used_entity_id = cast(EntityId) ReservedBrainId.FirstFree
    
    world_mode.game_entropy    = seed_random_series(123)
    world_mode.effects_entropy = seed_random_series(500)
    
    pixels_to_meters :: 1.0 / 42.0
    chunk_dim_in_meters :f32= pixels_to_meters * 256
    world_mode.typical_floor_height = 3

    chunk_dim_meters := v3{chunk_dim_in_meters, chunk_dim_in_meters, world_mode.typical_floor_height}
    world_mode.world = create_world(chunk_dim_meters, &state.mode_arena)
    
    ////////////////////////////////////////////////
    
    // :RoomSize
    tiles_per_screen :: v2i{17,9}
    
    tile_size_in_meters :f32= 1.5
    world_mode.null_collision     = make_null_collision(world_mode)
    
    world_mode.wall_collision      = world_mode.null_collision // make_simple_grounded_collision(world, {tile_size_in_meters, tile_size_in_meters, world_mode.typical_floor_height})
    world_mode.stairs_collision    = world_mode.null_collision//make_simple_grounded_collision(world, {tile_size_in_meters, tile_size_in_meters * 2, world_mode.typical_floor_height + 0.1})
    world_mode.glove_collision = make_simple_grounded_collision(world_mode, {0.2, 0.2, 0.2})
    world_mode.hero_body_collision = world_mode.null_collision//make_simple_grounded_collision(world, {0.75, 0.4, 0.6})
    world_mode.hero_head_collision = world_mode.null_collision//make_simple_grounded_collision(world, {0.75, 0.4, 0.5}, .7)
    world_mode.monstar_collision   = world_mode.null_collision//make_simple_grounded_collision(world, {0.75, 0.75, 1.5})
    world_mode.familiar_collision  = world_mode.null_collision//make_simple_grounded_collision(world, {0.5, 0.5, 1})
    
    world_mode.floor_collision    = make_simple_floor_collision(world_mode, v3{tile_size_in_meters, tile_size_in_meters, world_mode.typical_floor_height})
    
    ////////////////////////////////////////////////
    // "World Gen"
    
    screen_base: v3i
    
    screen_row, screen_col, tile_z := screen_base.x, screen_base.y, screen_base.z
    created_stair: b32
    door_left, door_right: b32
    door_top, door_bottom: b32
    stair_up, stair_down:  b32
    
    previous_room: StandartRoom
    room_count: u32 = 4
    last: v3i
    for screen_index in 0 ..< room_count {
        last = {screen_row, screen_col, tile_z}
        when !true {
            choice := random_choice(&world.game_entropy, 2)
        } else {
            choice := 3
        }
        
        created_stair = false
        switch choice {
          case 0: door_right  = true
          case 1: door_top    = true
          case 2: stair_down  = true
          case 3: stair_up    = true
          // case 4: door_left   = true
          // case 5: door_bottom = true
        }
        
        created_stair = stair_down || stair_up
        
        room_x := screen_col * tiles_per_screen.x
        room_y := screen_row * tiles_per_screen.y
        
        left_hole := screen_index % 2 == 0
        right_hole := !left_hole
        if screen_index == 0 {
            left_hole  = false
            right_hole = false
        }
        
        
        target: TraversableReference
        if left_hole {
            target = previous_room.ground[-3+8][1+4]
        } else if right_hole {
            target = previous_room.ground[ 3+8][1+4]
        }
        
        p := chunk_position_from_tile_positon(world_mode, room_x + tiles_per_screen.x/2, room_y + tiles_per_screen.y/2, tile_z)
        room := add_standart_room(world_mode, p, left_hole, right_hole, target)
        defer previous_room = room
        
        for tile_y in 0..< len(room.p[0]) {
            tile_x :: 0
            if !door_left || tile_y != len(room.p[0]) / 2 {
                add_wall(world_mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_y in 0..< len(room.p[0]) {
            tile_x :: tiles_per_screen.x-1
            if !door_right || tile_y != len(room.p[0]) / 2 {
                add_wall(world_mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_x in 0 ..< len(room.p) {
            tile_y :: 0
            if !door_bottom || tile_x != len(room.p) / 2 {
                add_wall(world_mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_x in 0 ..< len(room.p) {
            tile_y :: tiles_per_screen.y-1
            if !door_top || tile_x != len(room.p) / 2 {
                add_wall(world_mode, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        
        // add_monster(world,  room.p[3][4], room.ground[3][4])
        // add_familiar(world, room.p[2][5], room.ground[2][5])
        
        snake_brain := add_brain(world_mode)
        for piece_index in u32(0)..<len(BrainSnake{}.segments) {
            x := 1+piece_index
            add_snake_piece(world_mode, room.p[x][7], room.ground[x][7], snake_brain, piece_index)
        }
        
        door_left   = door_right
        door_bottom = door_top
        door_right  = false
        door_top    = false
        
        stair_up   = false
        stair_down = false
        
        switch choice {
          case 0: screen_col += 1
          case 1: screen_row += 1
          case 2: tile_z -= 1
          case 3: tile_z += 1
          case 4: screen_col -= 1
          case 5: screen_row -= 1
        }
    }
    
    
    new_camera_p := chunk_position_from_tile_positon(
        world_mode,
        last.x * tiles_per_screen.x + tiles_per_screen.x/2,
        last.y * tiles_per_screen.y + tiles_per_screen.y/2,
        last.z,
    )
    
    world_mode.camera_p = new_camera_p
    
    world_mode.particle_cache = push(&tran_state.arena, Particle_Cache, no_clear())
    init_particle_cache(world_mode.particle_cache)
}

////////////////////////////////////////////////

begin_entity :: proc(world: ^World_Mode) -> (result: ^Entity) {
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

end_entity :: proc(world_mode: ^World_Mode, entity: ^Entity, p: WorldPosition) {
    assert(world_mode.creation_buffer_index > 0)
    world_mode.creation_buffer_index -= 1
    entity.p = p.offset
    
    pack_entity_into_world(nil, world_mode.world, entity, p)
}

// @cleanup
begin_grounded_entity :: proc(world_mode: ^World_Mode, collision: ^EntityCollisionVolumeGroup) -> (result: ^Entity) {
    result = begin_entity(world_mode)
    result.collision = collision
    
    return result
}

add_brain :: proc(world_mode: ^World_Mode) -> (result: BrainId) {
    world_mode.last_used_entity_id += 1
    for world_mode.last_used_entity_id < cast(EntityId) ReservedBrainId.FirstFree {
        world_mode.last_used_entity_id += 1
    }
    result = cast(BrainId) world_mode.last_used_entity_id
    
    return result
}

mark_for_deletion :: proc(entity: ^Entity) {
    if entity != nil {
        entity.flags += { .MarkedForDeletion }
    }
}

add_wall :: proc(world_mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_grounded_entity(world_mode, world_mode.wall_collision)
    defer end_entity(world_mode, entity, p)
    
    entity.flags += {.Collides}
    entity.occupying = occupying
    append(&entity.pieces, VisiblePiece{
        asset = .Rock,
        height = 1.5, // random_between_f32(&world.general_entropy, 0.9, 1.7),
        color = 1,    // {random_unilateral(&world.general_entropy, f32), 1, 1, 1},
    })
}

add_hero :: proc(world_mode: ^World_Mode, region: ^SimRegion, occupying: TraversableReference, brain_id: BrainId) {
    p := map_into_worldspace(world_mode.world, region.origin, get_sim_space_traversable(occupying).p)
    
    body := begin_grounded_entity(world_mode, world_mode.hero_body_collision)
        body.brain_id = brain_id
        body.brain_kind = .Hero
        body.brain_slot = brain_slot_for(BrainHero, "body")
        
        // @todo(viktor): We will probably need a creation-time system for
        // guaranteeing no overlapping occupation.
        body.occupying = occupying
        
        append(&body.pieces, VisiblePiece{
            asset  = .Shadow,
            height = 0.5,
            offset = {0, -0.5, 0},
            color  = {1,1,1,0.5},
        })        
        append(&body.pieces, VisiblePiece{
            asset  = .Cape,
            height = hero_height*1.3,
            offset = {0, -0.3, 0},
            color  = 1,
            flags  = { .SquishAxis, .BobUpAndDown },
        })
        append(&body.pieces, VisiblePiece{
            asset  = .Body,
            height = hero_height,
            color  = 1,
            flags  = { .SquishAxis },
        })
        
    end_entity(world_mode, body, p)
    
    head := begin_grounded_entity(world_mode, world_mode.hero_head_collision)
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
        
        if world_mode.camera_following_id == 0 {
            world_mode.camera_following_id = head.id
        }
    end_entity(world_mode, head, p)
    
    glove := begin_grounded_entity(world_mode, world_mode.glove_collision)
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
        
    end_entity(world_mode, glove, p)
}

add_snake_piece :: proc(world_mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference, brain_id: BrainId, segment_index: u32) {
    entity := begin_grounded_entity(world_mode, world_mode.monstar_collision)
    defer end_entity(world_mode, entity, p)
    
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

add_monster :: proc(world_mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_grounded_entity(world_mode, world_mode.monstar_collision)
    defer end_entity(world_mode, entity, p)
    
    entity.flags += {.Collides}
    
    entity.brain_id = add_brain(world_mode)
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

add_familiar :: proc(world_mode: ^World_Mode, p: WorldPosition, occupying: TraversableReference) {
    entity := begin_grounded_entity(world_mode, world_mode.familiar_collision)
    defer end_entity(world_mode, entity, p)
    
    entity.brain_id   = add_brain(world_mode)
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

StandartRoom :: struct { // :RoomSize
    p:      [17][9] WorldPosition,
    ground: [17][9] TraversableReference,
}

add_standart_room :: proc(world_mode: ^World_Mode, p: WorldPosition, left_hole, right_hole: bool, target: TraversableReference) -> (result: StandartRoom) {
    // @volatile :RoomSize
    h_width  :i32= 17/2
    h_height :i32=  9/2
    tile_size_in_meters :: 1.5
    
    for offset_y in -h_height..=h_height {
        for offset_x in -h_width..=h_width {
            p := p
            p.offset.x = cast(f32) (offset_x) * tile_size_in_meters
            p.offset.y = cast(f32) (offset_y) * tile_size_in_meters
            result.p[offset_x+8][offset_y+4] = p
            
            if left_hole && (offset_x >= -3 && offset_x <= -2 && offset_y >= -1 && offset_y <= 1) {
                // @note(viktor): hole down to floor below
            } else if right_hole && (offset_x >= 2 && offset_x <= 3 && offset_y >= -1 && offset_y <= 1) {
                // @note(viktor): hole down to floor below
            } else {
                entity := begin_grounded_entity(world_mode, world_mode.floor_collision)
                entity.traversables = make_array(&world_mode.world.arena, TraversablePoint, 1)
                append(&entity.traversables, TraversablePoint{})
                if (right_hole && offset_x == 1 && offset_y == 0) || (left_hole && offset_x == -1 && offset_y == 0) {
                    entity.auto_boost_to = target
                }
                end_entity(world_mode, entity, p)
                
                occupying: TraversableReference
                occupying.entity.id = entity.id
                result.ground[offset_x+8][offset_y+4] = occupying
            }
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

////////////////////////////////////////////////
// @cleanup

make_null_collision :: proc(world_mode: ^World_Mode) -> (result: ^EntityCollisionVolumeGroup) {
    // @todo(viktor): not world arena! change to using the fundamental types arena
    result = push(&world_mode.world.arena, EntityCollisionVolumeGroup, no_clear())
    result ^= {}
    
    return result
}

make_simple_grounded_collision :: proc(world_mode: ^World_Mode, size: v3, offset_z:f32=0) -> (result: ^EntityCollisionVolumeGroup) {
    // @todo(viktor): not world arena! change to using the fundamental types arena
    result = push(&world_mode.world.arena, EntityCollisionVolumeGroup, no_clear())
    result ^= {
        total_volume = rectangle_center_dimension(v3{0, 0, 0.5 * size.z + offset_z}, size),
        volumes = push(&world_mode.world.arena, Rectangle3, 1),
    }
    result.volumes[0] = result.total_volume
    
    return result
}

make_simple_floor_collision :: proc(world_mode: ^World_Mode, size: v3) -> (result: ^EntityCollisionVolumeGroup) {
    // @todo(viktor): not world arena! change to using the fundamental types arena
    result = push(&world_mode.world.arena, EntityCollisionVolumeGroup, no_clear())
    result ^= {
        total_volume = rectangle_center_dimension(v3{0, 0, -0.5 * size.z}, size),
        volumes = {},
    }
    
    return result
}


add_collision_rule :: proc(world_mode: ^World_Mode, a, b: EntityId, should_collide: b32) {
    timed_function()
    // @todo(viktor): collapse this with should_collide
    a, b := a, b
    if a > b do swap(&a, &b)
    // @todo(viktor): BETTER HASH FUNCTION!!!
    found: ^PairwiseCollsionRule
    hash_bucket := a & (len(world_mode.collision_rule_hash) - 1)
    for rule := world_mode.collision_rule_hash[hash_bucket]; rule != nil; rule = rule.next {
        if rule.id_a == a && rule.id_b == b {
            found = rule
            break
        }
    }

    if found == nil {
        found = list_pop_head(&world_mode.first_free_collision_rule) or_else push(&world_mode.world.arena, PairwiseCollsionRule)
        list_push(&world_mode.collision_rule_hash[hash_bucket], found)
    }

    if found != nil {
        found.id_a = a
        found.id_b = b
        found.can_collide = should_collide
    }
}

// @cleanup
clear_collision_rules :: proc(world_mode: ^World_Mode, entity_id: EntityId) {
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
    for hash_bucket in 0..<len(world_mode.collision_rule_hash) {
        for rule_pointer := &world_mode.collision_rule_hash[hash_bucket]; rule_pointer^ != nil;  {
            rule := rule_pointer^
            if rule.id_a == entity_id || rule.id_b == entity_id {
                // :ListEntryRemovalInLoop
                list_push(&world_mode.first_free_collision_rule, rule)
                rule_pointer ^= rule.next
            } else {
                rule_pointer = &rule.next
            }
        }
    }
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

enviroment_test :: proc() {
    when false do if EnvironmentTest { 
        ////////////////////////////////////////////////
        // @note(viktor): Coordinate System and Environment Map Test
        map_color := [?]v4{Red, Green, Blue}
        
        for it, it_index in tran_state.envs {
            lod := it.LOD[0]
            checker_dim: v2i = 32
            
            row_on: b32
            for y: i32; y < lod.height; y += checker_dim.y {
                on := row_on
                for x: i32; x < lod.width; x += checker_dim.x {
                    color := map_color[it_index]
                    size := vec_cast(f32, checker_dim)
                    draw_rectangle(lod, rectangle_min_dimension(vec_cast(f32, x, y), size), on ? color : Black, {min(i32), max(i32)})
                    on = !on
                }
                row_on = !row_on
            }
        }
        tran_state.envs[0].pz = -4
        tran_state.envs[1].pz =  0
        tran_state.envs[2].pz    =  4
        
        world.time += input.delta_time
        
        angle :f32= world.time
        when !true {
            disp :f32= 0
        } else {
            disp := v2{cos(angle*2) * 100, cos(angle*4.1) * 50}
        }
        origin := vec_cast(f32, buffer_size) * 0.5
        scale :: 100
        x_axis := scale * v2{cos(angle), sin(angle)}
        y_axis := perpendicular(x_axis)
        transform := default_flat_transform()
        if entry := coordinate_system(render_group, transform); entry != nil {
            entry.origin = origin - x_axis*0.5 - y_axis*0.5 + disp
            entry.x_axis = x_axis
            entry.y_axis = y_axis
            
            assert(tran_state.test_diffuse.memory != nil)
            entry.texture = tran_state.test_diffuse
            entry.normal  = tran_state.test_normal
            
            entry.top    = tran_state.envs[2]
            entry.middle = tran_state.envs[1]
            entry.bottom = tran_state.envs[0]
        }
        
        for it, it_index in tran_state.envs {
            size := vec_cast(f32, it.LOD[0].width, it.LOD[0].height) / 2
            
            if entry := coordinate_system(render_group, transform); entry != nil {
                entry.x_axis = {size.x, 0}
                entry.y_axis = {0, size.y}
                entry.origin = 20 + (entry.x_axis + {20, 0}) * auto_cast it_index
                
                entry.texture = it.LOD[0]
                assert(it.LOD[0].memory != nil)
            }
        }
    }
}
