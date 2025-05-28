package game

World :: struct {
    arena: Arena,
    
    ////////////////////////////////////////////////
    // World specific    
    chunk_dim_meters: v3,
    
    // @todo(viktor): chunk_hash should probably switch to pointers IF
    // tile_entity_blocks continue to be stored en masse in the tile chunk!
    chunk_hash: [4096]^Chunk,
    first_free: ^WorldEntityBlock,
    
    ////////////////////////////////////////////////
    // General
    typical_floor_height: f32,
    
    // @todo(viktor): Should we allow split-screen?
    camera_following_id: EntityId,
    camera_p :           WorldPosition,
    camera_offset:       v3,
    // @todo(viktor): Should which players joined be part of the general state?
    controlled_heroes: [len(Input{}.controllers)]ControlledHero,
    
    collision_rule_hash:       [256]^PairwiseCollsionRule,
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
    
    game_entropy: RandomSeries,
    effects_entropy: RandomSeries, // @note(viktor): this is randomness that does NOT effect the gameplay
    
    first_free_chunk: ^Chunk,
    first_free_block: ^WorldEntityBlock,
    
    // @note(viktor): Particle System tests
    next_particle: u32,
    particles:     [256]Particle,
    cells:         [ParticleCellSize][ParticleCellSize]ParticleCell,
}

// @note(viktor): https://graphics.stanford.edu/~seander/bithacks.html#DetermineIfPowerOf2
#assert( len(World{}.collision_rule_hash) & ( len(World{}.collision_rule_hash) - 1 ) == 0)

Chunk :: #type SingleLinkedList(ChunkData)
ChunkData :: struct {
    chunk: [3]i32,
    
    first_block: ^WorldEntityBlock,
}

// @todo(viktor): Could make this just Chunk and then allow multiple tile chunks per X/Y/Z
WorldEntityBlock :: #type SingleLinkedList(WorldEntityBlockData)
WorldEntityBlockData :: struct {
    entity_count: u32,
    // @note(viktor): entity_data'count =^= size_of(Entity) * entity_count  for now, because there is no compression
    entity_data: FixedArray(1 << 14, u8), // :DisjointArray of Entity Data and inlined member arrays or specialized :Arena
}

WorldPosition :: struct {
    // @todo(viktor): It seems like we have to store ChunkX/Y/Z with each
    // entity because even though the sim region gather doesn't need it
    // at first, and we could get by without it, but entity references pull
    // in entities WITHOUT going through their world_chunk, and thus
    // still need to know the ChunkX/Y/Z
    chunk:  [3]i32,
    offset: v3,
}

chunk_position_from_tile_positon :: proc(world: ^World, tile_x, tile_y, tile_z: i32, additional_offset := v3{}) -> (result: WorldPosition) {
    // @volatile
    tile_size_in_meters  :: 1.5
    tile_depth_in_meters := world.typical_floor_height
    
    offset := v3{tile_size_in_meters, tile_size_in_meters, tile_depth_in_meters} * (vec_cast(f32, tile_x, tile_y, tile_z) + {0.5, 0.5, 0})
    
    result = map_into_worldspace(world, result, offset + additional_offset)
    
    assert(is_canonical(world, result.offset))

    return result
}

init_world :: proc(world: ^World, parent_arena: ^Arena) {
    sub_arena(&world.arena, parent_arena, arena_remaining_size(parent_arena))

    world.last_used_entity_id = cast(EntityId) ReservedBrainId.FirstFree
    
    world.game_entropy = seed_random_series(123)
    world.effects_entropy = seed_random_series(500)
    
    pixels_to_meters :: 1.0 / 42.0
    chunk_dim_in_meters :f32= pixels_to_meters * 256
    world.typical_floor_height = 3
    
    world.chunk_dim_meters = v3{chunk_dim_in_meters, chunk_dim_in_meters, world.typical_floor_height}
    
    world.first_free = nil
    
    ////////////////////////////////////////////////
    
    tiles_per_screen :: [2]i32{17,9}
    
    tile_size_in_meters :f32= 1.5
    world.null_collision     = make_null_collision(world)
    
    world.wall_collision      = world.null_collision // make_simple_grounded_collision(world, {tile_size_in_meters, tile_size_in_meters, world.typical_floor_height})
    world.stairs_collision    = world.null_collision//make_simple_grounded_collision(world, {tile_size_in_meters, tile_size_in_meters * 2, world.typical_floor_height + 0.1})
    world.glove_collision = make_simple_grounded_collision(world, {0.2, 0.2, 0.2})
    world.hero_body_collision = world.null_collision//make_simple_grounded_collision(world, {0.75, 0.4, 0.6})
    world.hero_head_collision = world.null_collision//make_simple_grounded_collision(world, {0.75, 0.4, 0.5}, .7)
    world.monstar_collision   = world.null_collision//make_simple_grounded_collision(world, {0.75, 0.75, 1.5})
    world.familiar_collision  = world.null_collision//make_simple_grounded_collision(world, {0.5, 0.5, 1})
    
    world.floor_collision    = make_simple_floor_collision(world, v3{tile_size_in_meters, tile_size_in_meters, world.typical_floor_height})
    
    ////////////////////////////////////////////////
    // "World Gen"
    
    screen_base: [3]i32
    
    new_camera_p := chunk_position_from_tile_positon(
        world,
        screen_base.x * tiles_per_screen.x + tiles_per_screen.x/2,
        screen_base.y * tiles_per_screen.y + tiles_per_screen.y/2,
        screen_base.z,
    )
    
    world.camera_p = new_camera_p
    
    screen_row, screen_col, tile_z := screen_base.x, screen_base.y, screen_base.z
    created_stair: b32
    door_left, door_right: b32
    door_top, door_bottom: b32
    stair_up, stair_down:  b32
    for room in u32(0) ..< 5 {
        when !true {
            choice := random_choice(&world.game_entropy, 2)
        } else {
            choice := 2
        }
        
        created_stair = false
        switch(choice) {
          case 0: door_right  = true
          case 1: door_top    = true
          case 2: stair_down  = true
          case 3: stair_up    = true
          // case 4: door_left   = true
          // case 5: door_bottom = true
        }
        
        created_stair = stair_down || stair_up
        need_to_place_stair := created_stair
        
        room_x := screen_col * tiles_per_screen.x
        room_y := screen_row * tiles_per_screen.y
        
        p := chunk_position_from_tile_positon(world, room_x + tiles_per_screen.x/2, room_y + tiles_per_screen.y/2, tile_z)
        room := add_standart_room(world, p) 
        
        for tile_y in 0..< len(room.p[0]) {
            tile_x :: 0
            if !door_left || tile_y != len(room.p[0]) / 2 {
                add_wall(world, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_y in 0..< len(room.p[0]) {
            tile_x :: tiles_per_screen.x-1
            if !door_right || tile_y != len(room.p[0]) / 2 {
                add_wall(world, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_x in 0 ..< len(room.p) {
            tile_y :: 0
            if !door_bottom || tile_x != len(room.p) / 2 {
                add_wall(world, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        for tile_x in 0 ..< len(room.p) {
            tile_y :: tiles_per_screen.y-1
            if !door_top || tile_x != len(room.p) / 2 {
                add_wall(world, room.p[tile_x][tile_y], room.ground[tile_x][tile_y])
            }
        }
        
        add_monster(world,  room.p[3][4], room.ground[3][4])
        // add_familiar(world, room.p[2][5], room.ground[2][5])
        
        snake_brain := add_brain(world)
        for piece_index in u32(0)..<len(BrainSnake{}.segments) {
            x := 1+piece_index
            add_snake_piece(world, room.p[x][7], room.ground[x][7], snake_brain, piece_index)
        }
        
        door_left   = door_right
        door_bottom = door_top
        door_right  = false
        door_top    = false
        
        stair_up   = false
        stair_down = false
        
        switch(choice) {
        case 0: screen_col += 1
        case 1: screen_row += 1
        case 2: tile_z -= 1
        case 3: tile_z += 1
        case 4: screen_col -= 1
        case 5: screen_row -= 1
        }
    }
}

update_and_render_world :: proc(world: ^World, tran_state: ^TransientState, render_group: ^RenderGroup, input: Input) {
    timed_function()
    
    dt := input.delta_time * TimestepPercentage/100.0
    
    monitor_width_in_meters :: 0.635
    buffer_size := [2]i32{render_group.commands.width, render_group.commands.height}
    meters_to_pixels_for_monitor := cast(f32) buffer_size.x * monitor_width_in_meters
    
    focal_length, distance_above_ground : f32 = 0.6, 10
    perspective(render_group, buffer_size, meters_to_pixels_for_monitor, focal_length, distance_above_ground)
    
    haze_color := DarkBlue
    clear(render_group, haze_color)
    
    screen_bounds := get_camera_rectangle_at_target(render_group)
    camera_bounds := rectangle_min_max(
        V3(screen_bounds.min, -0.5 * world.typical_floor_height), 
        V3(screen_bounds.max, 4 * world.typical_floor_height),
    )
    
    sim_memory := begin_temporary_memory(&tran_state.arena)
    // @todo(viktor): by how much should we expand the sim region?
    // @todo(viktor): do we want to simulate upper floors, etc?
    sim_bounds := rectangle_add_radius(camera_bounds, v3{30, 30, 10})
    sim_origin := world.camera_p
    sim_region := begin_sim(&tran_state.arena, world, sim_origin, sim_bounds, dt)
    
    camera_p := world.camera_offset + world_distance(world, world.camera_p, sim_origin)
    
    if ShowRenderAndSimulationBounds {
        transform := default_flat_transform()
        transform.offset -= camera_p
        transform.sort_bias = 10000
        push_rectangle_outline(render_group, screen_bounds,               transform, Orange, 0.1)
        push_rectangle_outline(render_group, sim_region.bounds,           transform, Blue,   0.2)
        push_rectangle_outline(render_group, sim_region.updatable_bounds, transform, Green,  0.2)
    }
    
    fade_top_end      :=  0.75 * world.typical_floor_height
    fade_top_start    :=  0.5  * world.typical_floor_height
    fade_bottom_start := -1    * world.typical_floor_height
    fade_bottom_end   := -4    * world.typical_floor_height
    
    rect := rectangle_min_dimension(v2{0,0}, vec_cast(f32, buffer_size))
    
    MinimumLayer :: -4
    MaximumLayer :: 1
    clip_rect_index: [MaximumLayer - MinimumLayer + 1]u16
    for &clip_rect, index in clip_rect_index {
        relative_layer_index := MinimumLayer + index
        camera_relative_ground_z: f32 = sim_region.origin.offset.z + world.typical_floor_height * cast(f32) relative_layer_index
        
        fx: ClipRectFX
        if camera_relative_ground_z > fade_top_start {
            // Above the current level
            render_group.current_clip_rect_index = clip_rect_index[0]
            
            fx.t_color.a = clamp_01_to_range(fade_top_start, camera_relative_ground_z, fade_top_end)
        } else if camera_relative_ground_z < fade_bottom_start {
            // Below the current level
            render_group.current_clip_rect_index = clip_rect_index[2]
            
            fx.t_color.rgb = clamp_01_to_range(fade_bottom_start, camera_relative_ground_z, fade_bottom_end)
            fx.color = haze_color
        } else { 
            // The current level
            render_group.current_clip_rect_index = clip_rect_index[1]
        }
        
        clip_rect = push_clip_rect(render_group, rect, fx)
    }
    
    ////////////////////////////////////////////////
    // Look to see if any players are trying to join
    
    for controller, controller_index in input.controllers {
        con_hero := &world.controlled_heroes[controller_index]
        if con_hero.brain_id == 0 {
            if was_pressed(controller.start) {
                standing_on, ok := get_closest_traversable(sim_region, camera_p, {.Unoccupied} )
                assert(ok) // @todo(viktor): GameUI that tells you there is no safe space...
                // maybe keep trying on subsequent frames?
                
                brain_id := cast(BrainId) controller_index + cast(BrainId) ReservedBrainId.FirstHero
                con_hero^ = { brain_id = brain_id }
                add_hero(world, sim_region, standing_on, brain_id)
            }
        } else {
            if is_down(controller.shoulder_left) {
                standing_on, ok := get_closest_traversable(sim_region, camera_p, {.Unoccupied} )
                if ok {
                    p := map_into_worldspace(world, world.camera_p, standing_on.entity.pointer.p)
                    add_monster(world, p, standing_on)
                }
            }
        }
    }

    ////////////////////////////////////////////////
    
    execute_brains := begin_timed_block("execute_brains")
    for &brain in slice(sim_region.brains) {
        execute_brain(input, world, sim_region, &brain)
    }
    end_timed_block(execute_brains)
    
    ////////////////////////////////////////////////
    
    // @todo(viktor): :TransientClipRect
    old_clip_rect_index := render_group.current_clip_rect_index
    defer render_group.current_clip_rect_index = old_clip_rect_index

    render_group.current_clip_rect_index = clip_rect_index[0]
    
    simulate_entities := begin_timed_block("simulate_entities")
    for &entity in slice(sim_region.entities) {
        simulate_entity(input, world, sim_region, render_group, camera_p, &entity, dt, haze_color, clip_rect_index[:], MinimumLayer, MaximumLayer)
    }
    end_timed_block(simulate_entities)
    
    ////////////////////////////////////////////////
    
    fountain_test(render_group, world, dt)
    enviroment_test()
    
    ////////////////////////////////////////////////
    
    // @todo(viktor): Make sure we hoist the camera update out to a place where the renderer
    // can know about the location of the camera at the end of the frame so there isn't
    // a frame of lag in camera updating compared to the hero.
    end_sim(sim_region)
    end_temporary_memory(sim_memory)
    
    check_arena(&world.arena)
    
    // @todo(viktor): Should switch mode. Implemented in :CutsceneEpisodes
    heroes_exist: b32
    for con_hero in world.controlled_heroes {
        if con_hero.brain_id != 0 {
            heroes_exist = true
            break
        }
    }
}



////////////////////////////////////////////////

fountain_test :: proc(render_group: ^RenderGroup, world: ^World, dt: f32) {
    if FountainTest { 
        ////////////////////////////////////////////////
        // @note(viktor): Particle system test
        font_id := first_font_from(render_group.assets, .Font)
        font := get_font(render_group.assets, font_id, render_group.generation_id)
        if font == nil {
            load_font(render_group.assets, font_id, false)
        } else {
            font_info := get_font_info(render_group.assets, font_id)
            for _ in 0..<2 {
                particle := &world.particles[world.next_particle]
                world.next_particle += 1
                if world.next_particle >= len(world.particles) {
                    world.next_particle = 0
                }
                particle.p = {random_bilateral(&world.effects_entropy, f32)*0.1, 0, 0}
                particle.dp = {random_bilateral(&world.effects_entropy, f32)*0, (random_unilateral(&world.effects_entropy, f32)*0.4)+7, 0}
                particle.ddp = {0, -9.8, 0}
                particle.color = V4(random_unilateral(&world.effects_entropy, v3), 1)
                particle.dcolor = {0,0,0,-0.2}
                
                nothings := "Handmade"
                
                r := random_choice_data(&world.effects_entropy, transmute([]u8) nothings)^
                
                particle.bitmap_id = get_bitmap_for_glyph(font, font_info, cast(rune) r)
            }
            
            for &row in world.cells {
                zero(row[:])
            }
            
            grid_scale :f32= 0.3
            grid_origin:= v3{-0.5 * grid_scale * ParticleCellSize, 0, 0}
            for particle in world.particles {
                p := ( particle.p - grid_origin ) / grid_scale
                x := truncate(p.x)
                y := truncate(p.y)
                
                x = clamp(x, 1, ParticleCellSize-2)
                y = clamp(y, 1, ParticleCellSize-2)
                
                cell := &world.cells[y][x]
                
                density: f32 = particle.color.a
                cell.density                += density
                cell.velocity_times_density += density * particle.dp
            }
            
            if ShowGrid {
                for row, y in world.cells {
                    for cell, x in row {
                        alpha := clamp_01(0.1 * cell.density)
                        color := v4{1,1,1, alpha}
                        position := (vec_cast(f32, x, y, 0) + {0.5,0.5,0})*grid_scale + grid_origin
                        push_rectangle_outline(render_group, rectangle_center_dimension(position.xy, grid_scale), default_flat_transform(), color, 0.05)
                    }
                }
            }
            
            for &particle in world.particles {
                p := ( particle.p - grid_origin ) / grid_scale
                x := truncate(p.x)
                y := truncate(p.y)
                
                x = clamp(x, 1, ParticleCellSize-2)
                y = clamp(y, 1, ParticleCellSize-2)
                
                cell := &world.cells[y][x]
                cell_l := &world.cells[y][x-1]
                cell_r := &world.cells[y][x+1]
                cell_u := &world.cells[y+1][x]
                cell_d := &world.cells[y-1][x]
                
                dispersion: v3
                dc : f32 = 0.3
                dispersion += dc * (cell.density - cell_l.density) * v3{-1, 0, 0}
                dispersion += dc * (cell.density - cell_r.density) * v3{ 1, 0, 0}
                dispersion += dc * (cell.density - cell_d.density) * v3{ 0,-1, 0}
                dispersion += dc * (cell.density - cell_u.density) * v3{ 0, 1, 0}
                
                particle_ddp := particle.ddp + dispersion
                // @note(viktor): simulate particle forward in time
                particle.p     += particle_ddp * 0.5 * square(dt) + particle.dp * dt
                particle.dp    += particle_ddp * dt
                particle.color += particle.dcolor * dt
                // @todo(viktor): should we just clamp colors in the renderer?
                color := clamp_01(particle.color)
                if color.a > 0.9 {
                    color.a = 0.9 * clamp_01_to_range(1, color.a, 0.9)
                }

                if particle.p.y < 0 {
                    coefficient_of_restitution :f32= 0.3
                    coefficient_of_friction :f32= 0.7
                    particle.p.y *= -1
                    particle.dp.y *= -coefficient_of_restitution
                    particle.dp.x *= coefficient_of_friction
                }
                // @note(viktor): render the particle
                push_bitmap(render_group, particle.bitmap_id, default_flat_transform(), 0.4, particle.p, color)
            }
        }             
    }
}

enviroment_test :: proc() {
    when false do if EnvironmentTest { 
        ////////////////////////////////////////////////
        // @note(viktor): Coordinate System and Environment Map Test
        map_color := [?]v4{Red, Green, Blue}
        
        for it, it_index in tran_state.envs {
            lod := it.LOD[0]
            checker_dim: [2]i32 = 32
            
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

////////////////////////////////////////////////

make_null_collision :: proc(world: ^World) -> (result: ^EntityCollisionVolumeGroup) {
    result = push(&world.arena, EntityCollisionVolumeGroup, no_clear())
    result^ = {}
    
    return result
}

make_simple_grounded_collision :: proc(world: ^World, size: v3, offset_z:f32=0) -> (result: ^EntityCollisionVolumeGroup) {
    // @todo(viktor): NOT WORLD ARENA!!! change to using the fundamental types arena
    result = push(&world.arena, EntityCollisionVolumeGroup, no_clear())
    result^ = {
        total_volume = rectangle_center_dimension(v3{0, 0, 0.5 * size.z + offset_z}, size),
        volumes = push(&world.arena, Rectangle3, 1),
    }
    result.volumes[0] = result.total_volume
    
    return result
}

make_simple_floor_collision :: proc(world: ^World, size: v3) -> (result: ^EntityCollisionVolumeGroup) {
    // @todo(viktor): NOT WORLD ARENA!!! change to using the fundamental types arena
    result = push(&world.arena, EntityCollisionVolumeGroup, no_clear())
    result^ = {
        total_volume = rectangle_center_dimension(v3{0, 0, -0.5 * size.z}, size),
        volumes = {},
    }
    
    return result
}


map_into_worldspace :: proc(world: ^World, center: WorldPosition, offset: v3 = {0,0,0}) -> WorldPosition {
    result := center
    result.offset += offset
    
    rounded_offset := round(result.offset / world.chunk_dim_meters, i32)
    result.chunk   =  result.chunk + rounded_offset
    result.offset  -= vec_cast(f32, rounded_offset) * world.chunk_dim_meters
    
    assert(is_canonical(world, result.offset))
    
    return result
}

world_distance :: proc(world: ^World, a, b: WorldPosition) -> (result: v3) {
    chunk_delta  := vec_cast(f32, a.chunk) - vec_cast(f32, b.chunk)
    offset_delta := a.offset - b.offset
    result = chunk_delta * world.chunk_dim_meters
    result += offset_delta
    return result
}

is_canonical :: proc(world: ^World, offset: v3) -> b32 {
    epsilon: f32 = 0.0001
    half_size := 0.5 * world.chunk_dim_meters + epsilon
    return -half_size.x <= offset.x && offset.x <= half_size.x &&
           -half_size.y <= offset.y && offset.y <= half_size.y &&
           -half_size.z <= offset.z && offset.z <= half_size.z
}

get_chunk :: proc (arena: ^Arena = nil, world: ^World, point: WorldPosition) -> ^Chunk {
    return get_chunk_3(arena, world, point.chunk)
}
get_chunk_3_internal :: proc(world: ^World, chunk_p: [3]i32) -> (result: ^^Chunk) {
    ChunkSafeMargin :: 256
    
    assert(chunk_p.x > min(i32) + ChunkSafeMargin)
    assert(chunk_p.x < max(i32) - ChunkSafeMargin)
    assert(chunk_p.y > min(i32) + ChunkSafeMargin)
    assert(chunk_p.y < max(i32) - ChunkSafeMargin)
    assert(chunk_p.z > min(i32) + ChunkSafeMargin)
    assert(chunk_p.z < max(i32) - ChunkSafeMargin)
    
    // @todo(viktor): BETTER HASH FUNCTION !!
    hash_value := 19*chunk_p.x + 7*chunk_p.y + 3*chunk_p.z
    hash_slot := hash_value & (len(world.chunk_hash)-1)
    
    assert(hash_slot < len(world.chunk_hash))
    
    result = &world.chunk_hash[hash_slot]
    for result^ != nil && chunk_p != (result^).chunk {
        result = &(result^).next
    }
    
    return result
}
get_chunk_3 :: proc(arena: ^Arena = nil, world: ^World, chunk_p: [3]i32) -> (result: ^Chunk) {
    next_pointer_of_the_chunks_previous_chunk := get_chunk_3_internal(world, chunk_p)
    result = next_pointer_of_the_chunks_previous_chunk^
        
    if arena != nil && result == nil {
        result = push(arena, Chunk)
        result.chunk = chunk_p
        
        result.next = next_pointer_of_the_chunks_previous_chunk^
        next_pointer_of_the_chunks_previous_chunk^ = result
    }
    
    return result
}

////////////////////////////////////////////////

extract_chunk :: proc(world: ^World, chunk_p: [3]i32) -> (result: ^Chunk) {
    next_pointer_of_the_chunks_previous_chunk := get_chunk_3_internal(world, chunk_p)
    result = next_pointer_of_the_chunks_previous_chunk^
    
    if result != nil {
        next_pointer_of_the_chunks_previous_chunk ^= result.next
    }
    
    return result
}

pack_entity_into_world :: proc(region: ^SimRegion, world: ^World, source: ^Entity, p: WorldPosition) {
    chunk := get_chunk(&world.arena, world, p)
    assert(chunk != nil)
    
    source.p = p.offset

    pack_entity_into_chunk(region, world, source, chunk)
}

pack_entity_into_chunk :: proc(region: ^SimRegion, world: ^World, source: ^Entity, chunk: ^Chunk) {
    assert(chunk != nil)
    
    // :PointerArithmetic
    pack_size := cast(i64) size_of(Entity)
    
    if chunk.first_block == nil || !block_has_room(chunk.first_block, pack_size) {
        new_block := list_pop(&world.first_free_block) or_else push(&world.arena, WorldEntityBlock, no_clear())
        clear_world_entity_block(new_block)
        
        list_push(&chunk.first_block, new_block)
    }
    assert(block_has_room(chunk.first_block, pack_size))
    
    block := chunk.first_block
    
    // :PointerArithmetic
    dest := &block.entity_data.data[block.entity_data.count]
    block.entity_data.count += pack_size
    
    block.entity_count += 1
    
    entity := (cast(^Entity) dest)
    entity ^= source^
    
    // @volatile see Entity definition @metaprogram
    entity.ddp = 0
    entity.ddt_bob = 0
    
    // pack_entity_reference(region, &entity.head)
    pack_traversable_reference(region, &entity.came_from)
    pack_traversable_reference(region, &entity.occupying)
}

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

clear_world_entity_block :: proc(block: ^WorldEntityBlock) {
    block.entity_count = 0
    block.entity_data.count = 0
    block.next = nil
}

block_has_room :: proc(block: ^WorldEntityBlock, size: i64) -> b32 {
    return block.entity_data.count + size < len(block.entity_data.data)
}
