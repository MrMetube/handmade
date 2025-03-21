package game

@common 
INTERNAL :: #config(INTERNAL, false)

/* TODO(viktor):
    - Simd draw_rectangle
    
    - Since the correction to unproject_with_transform the sim region bounds are too small
    - Is this still relevant? Dead Lock on Load when a lot of assets are loaded at once
    - Font Rendering Robustness
        - Kerning
    
    - :PointerArithmetic
        - change the types to a less c-mindset
        - or if necessary make utilities to these operations
    
    - Debug code
        - Diagramming
        - (a little gui) switches / sliders / etc
        - Draw tile chunks so we can verify that things are aligned / in the chunks we want them to be in / etc
        - Thread visualization 
    
    - Audio
        - Fix clicking Bug at the end of samples
    
    - Rendering
        - Real projections with solid concept of project/unproject
        - Straighten out all coordinate systems!
            - Screen
            - World
            - Texture
        - Lighting
        - Final Optimization    
        
    ARCHITECTURE EXPLORATION
    - Z !
        - debug drawing of Z levels and inclusion of Z to make sure
            that there are no bugs
        - Concept of ground in the collision loop so it can handle 
            collisions coming onto and off of stairs, for example
        - make sure flying things can go over walls
        - how is going "up" and "down" rendered?

    - Collision detection
        - Clean up predicate proliferation! Can we make a nice clean
            set of flags/rules so that it's easy to understand how
            things work in terms of special handling? This may involve
            making the iteration handle everything instead of handling 
            overlap outside and so on.
        - transient collision rules
            - allow non-transient rules to override transient once
            - Entry/Exit
        - Whats the plan for robustness / shape definition ?
        - "Things pushing other things"

    - Animation
        - Skeletal animation

    - Implement multiple sim regions per frame
        - per-entity clocking
        - sim region merging?  for multiple players?
        - simple zoomed out view for testing

    PRODUCTION
    -> Game
        - Entity system
        
        - Rudimentary worldgen (no quality just "what sorts of things" we do
            - Map displays
            - Placement of background things
            - Connectivity?
            - Non-overlapping?

        - AI
            - Rudimentary monstar behaviour
            - Pathfinding
            - AI "storage"

      
    - Metagame / save game?
        - how do you enter a "save slot"?
        - persistent unlocks/etc.
        - Do we allow saved games? Probably yes, just only for "pausing"
        - continuous save for crash recovery?

*/

@common 
InputButton :: struct {
    half_transition_count: u32,
    ended_down:            b32,
}

@common 
InputController :: struct {
    // TODO: allow outputing vibration
    is_connected: b32,
    is_analog:    b32,

    stick_average: [2]f32,

    using _buttons_array_and_enum : struct #raw_union {
        buttons: [18]InputButton,
        using _buttons_enum : struct {
            stick_up , stick_down , stick_left , stick_right ,
            button_up, button_down, button_left, button_right,
            dpad_up  , dpad_down  , dpad_left  , dpad_right  ,

            start, back,
            shoulder_left, shoulder_right,
            thumb_left   , thumb_right:    InputButton,
        },
    },
    
}
#assert(size_of(InputController{}._buttons_array_and_enum.buttons) == size_of(InputController{}._buttons_array_and_enum._buttons_enum))

@common 
Input :: struct {
    delta_time: f32,

    controllers: [5]InputController,
        
    // NOTE(viktor): this is for debugging only
    mouse: struct {
        using _buttons_array_and_enum : struct #raw_union {
            buttons: [5]InputButton,
            using _buttons_enum : struct {
                left, 
                right, 
                middle,
                extra1, 
                extra2: InputButton,
            },
        },
        p:     v2,
        wheel: f32,
    },
    
    shift_down, 
    alt_down, 
    control_down: b32,
}
#assert(size_of(Input{}.mouse._buttons_array_and_enum.buttons) == size_of(Input{}.mouse._buttons_array_and_enum._buttons_enum))

@common 
GameMemory :: struct {
    reloaded_executable: b32,
    // NOTE: REQUIRED to be cleared to zero at startup
    permanent_storage: []u8,
    transient_storage: []u8,
    debug_storage:     []u8,
    
    high_priority_queue: ^PlatformWorkQueue,
    low_priority_queue:  ^PlatformWorkQueue,
    
    Platform_api: PlatformAPI,
}

State :: struct {
    is_initialized: b32,
    
    mode_arena: Arena,
    
    mixer: Mixer,
    
    world: World,
    
    effects_entropy: RandomSeries, // NOTE(viktor): this is randomness that does NOT effect the gameplay
    
    // NOTE(viktor): This is for testing the changing of volume and pitch and should not persist.
    music: ^PlayingSound,
    
    // NOTE(viktor): Particle System tests
    next_particle: u32,
    particles:     [256]Particle,
    cells:         [ParticleCellSize][ParticleCellSize]ParticleCell,
}

TransientState :: struct {
    is_initialized: b32,
    arena: Arena,
    
    assets:        ^Assets,
    generation_id: AssetGenerationId,
    
    tasks: [4]TaskWithMemory,

    test_diffuse: Bitmap,
    test_normal:  Bitmap,
    
    ground_buffers: []GroundBuffer,
    
    high_priority_queue: ^PlatformWorkQueue,
    low_priority_queue:  ^PlatformWorkQueue,
    
    env_size: [2]i32,
    envs: [3]EnvironmentMap,
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

TaskWithMemory :: struct {
    in_use: b32,
    arena: Arena,
    
    memory_flush: TemporaryMemory,
}

ControlledHero :: struct {
    storage_index: StorageIndex,

    // NOTE(viktor): these are the controller requests for simulation
    ddp: v3,
    darrow: v2,
    dz: f32,
}

// NOTE(viktor): Platform specific structs
PlatformWorkQueue  :: struct{}
Platform: PlatformAPI

debug_get_game_assets_work_queue_and_generation_id :: proc(memory: ^GameMemory) -> (assets: ^Assets, work_queue: ^PlatformWorkQueue, generation_id: AssetGenerationId) {
    tran_state := cast(^TransientState) raw_data(memory.transient_storage)
    if tran_state.is_initialized {
        assets = tran_state.assets
        work_queue = tran_state.high_priority_queue
        generation_id = tran_state.generation_id
    }
    
    return assets, work_queue, generation_id
}

@export
update_and_render :: proc(memory: ^GameMemory, input: Input, render_commands: ^RenderCommands) {
    Platform = memory.Platform_api
    
    when DebugEnabled {
        if memory.debug_storage == nil do return
        assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
        GlobalDebugMemory = memory
    }
    
    ground_buffer_size :: 512
    
    ////////////////////////////////////////////////

    assert(size_of(State) <= len(memory.permanent_storage), "The State cannot fit inside the permanent memory")
    state := cast(^State) raw_data(memory.permanent_storage)
    if !state.is_initialized {
        init_arena(&state.mode_arena, memory.permanent_storage[size_of(State):])
        
        state.effects_entropy = seed_random_series(500)
        
        init_mixer(&state.mixer, &state.mode_arena)
        init_world(&state.world, &state.mode_arena, ground_buffer_size)
        
        state.is_initialized = true
    }

    assert(size_of(TransientState) <= len(memory.transient_storage), "The Transient State cannot fit inside the permanent memory")
    tran_state := cast(^TransientState) raw_data(memory.transient_storage)
    if !tran_state.is_initialized {
        init_arena(&tran_state.arena, memory.transient_storage[size_of(TransientState):])

        tran_state.high_priority_queue = memory.high_priority_queue
        tran_state.low_priority_queue  = memory.low_priority_queue
        
        for &task in tran_state.tasks {
            task.in_use = false
            sub_arena(&task.arena, &tran_state.arena, 16 * Megabyte)
        }

        tran_state.assets = make_assets(&tran_state.arena, 64 * Megabyte, tran_state)
        
        state.mixer.master_volume = 0.1
        
        // TODO(viktor): pick a real number here!
        tran_state.ground_buffers = push(&state.world.arena, GroundBuffer, 256, no_clear())
        for &ground_buffer in tran_state.ground_buffers {
            ground_buffer.p = null_position()
            ground_buffer.bitmap = make_empty_bitmap(&tran_state.arena, ground_buffer_size, false)
        }
        
        test_size: [2]i32= 256
        tran_state.test_diffuse = make_empty_bitmap(&tran_state.arena, test_size, false)
        tran_state.test_normal  = make_empty_bitmap(&tran_state.arena, test_size, false)
        make_sphere_normal_map(tran_state.test_normal, 0)
        make_sphere_diffuse_map(tran_state.test_diffuse)
        
        tran_state.env_size = {512, 256}
        for &env_map in tran_state.envs {
            size := tran_state.env_size
            for &lod in env_map.LOD {
                lod = make_empty_bitmap(&tran_state.arena, size, false)
                size /= 2
            }
        }
        
        tran_state.is_initialized = true
    }
    
    if memory.reloaded_executable {
        for &ground_buffer in tran_state.ground_buffers {
            ground_buffer.p = null_position()
        }
        
        make_sphere_normal_map(tran_state.test_normal, 0)
        make_sphere_diffuse_map(tran_state.test_diffuse)
    }
    
    ////////////////////////////////////////////////
    // Input

    if debug_variable(b32, "Audio/SoundPanningWithMouse") {
        // NOTE(viktor): test sound panning with the mouse 
        music_volume := input.mouse.p - vec_cast(f32, render_commands.width, render_commands.height) * 0.5
        if state.music == nil {
            if state.mixer.first_playing_sound == nil {
                play_sound(&state.mixer, first_sound_from(tran_state.assets, .Music))
            }
            state.music = state.mixer.first_playing_sound
        }
        change_volume(&state.mixer, state.music, 0.01, music_volume)
    }
    
    if debug_variable(b32, "Audio/SoundPitchingWithMouse") {
        // NOTE(viktor): test sound panning with the mouse 
        if state.music == nil {
            if state.mixer.first_playing_sound == nil {
                play_sound(&state.mixer, first_sound_from(tran_state.assets, .Music))
            }
            state.music = state.mixer.first_playing_sound
        }
        
        delta: f32
        if was_pressed(input.mouse.middle) {
            if input.mouse.p.x > 10  do delta = 0.1
            if input.mouse.p.x < -10 do delta = -0.1
            change_pitch(&state.mixer, state.music, state.music.d_sample + delta)
        }
    }
    
    ////////////////////////////////////////////////
    // Update and Render
    
    render_group: RenderGroup
    init_render_group(&render_group, tran_state.assets, render_commands, false, tran_state.generation_id)
    
    if debug_variable(b32, "Particles/FountainTest") { 
        ////////////////////////////////////////////////
        // NOTE(viktor): Particle system test
        font_id := first_font_from(tran_state.assets, .Font)
        font := get_font(tran_state.assets, font_id, render_group.generation_id)
        if font == nil {
            load_font(tran_state.assets, font_id, false)
        } else {
            font_info := get_font_info(tran_state.assets, font_id)
            for _ in 0..<4 {
                particle := &state.particles[state.next_particle]
                state.next_particle += 1
                if state.next_particle >= len(state.particles) {
                    state.next_particle = 0
                }
                particle.p = {random_bilateral(&state.effects_entropy, f32)*0.1, 0, 0}
                particle.dp = {random_bilateral(&state.effects_entropy, f32)*0, (random_unilateral(&state.effects_entropy, f32)*0.4)+7, 0}
                particle.ddp = {0, -9.8, 0}
                particle.color = V4(random_unilateral_3(&state.effects_entropy, f32), 1)
                particle.dcolor = {0,0,0,-0.2}
                
                nothings := "NOTHINGS"
                
                r := random_choice_data(&state.effects_entropy, transmute([]u8) nothings)^
                
                particle.bitmap_id = get_bitmap_for_glyph(font, font_info, cast(rune) r)
            }
            
            for &row in state.cells {
                zero(row[:])
            }
            
            grid_scale :f32= 0.3
            grid_origin:= v3{-0.5 * grid_scale * ParticleCellSize, 0, 0}
            for particle in state.particles {
                p := ( particle.p - grid_origin ) / grid_scale
                x := truncate(p.x)
                y := truncate(p.y)
                
                x = clamp(x, 1, ParticleCellSize-2)
                y = clamp(y, 1, ParticleCellSize-2)
                
                cell := &state.cells[y][x]
                
                density: f32 = particle.color.a
                cell.density                += density
                cell.velocity_times_density += density * particle.dp
            }
            
            if debug_variable(b32, "Particles/ShowGrid") {
                for row, y in state.cells {
                    for cell, x in row {
                        alpha := clamp_01(0.1 * cell.density)
                        color := v4{1,1,1, alpha}
                        position := (vec_cast(f32, x, y, 0) + {0.5,0.5,0})*grid_scale + grid_origin
                        push_rectangle(&render_group, rectangle_center_diameter(position.xy, grid_scale), default_flat_transform(), color)
                    }
                }
            }
            
            for &particle in state.particles {
                p := ( particle.p - grid_origin ) / grid_scale
                x := truncate(p.x)
                y := truncate(p.y)
                
                x = clamp(x, 1, ParticleCellSize-2)
                y = clamp(y, 1, ParticleCellSize-2)
                
                cell := &state.cells[y][x]
                cell_l := &state.cells[y][x-1]
                cell_r := &state.cells[y][x+1]
                cell_u := &state.cells[y+1][x]
                cell_d := &state.cells[y-1][x]
                
                dispersion: v3
                dc : f32 = 0.3
                dispersion += dc * (cell.density - cell_l.density) * v3{-1, 0, 0}
                dispersion += dc * (cell.density - cell_r.density) * v3{ 1, 0, 0}
                dispersion += dc * (cell.density - cell_d.density) * v3{ 0,-1, 0}
                dispersion += dc * (cell.density - cell_u.density) * v3{ 0, 1, 0}
                
                particle_ddp := particle.ddp + dispersion
                // NOTE(viktor): simulate particle forward in time
                particle.p     += particle_ddp * 0.5 * square(input.delta_time) + particle.dp * input.delta_time
                particle.dp    += particle_ddp * input.delta_time
                particle.color += particle.dcolor * input.delta_time
                // TODO(viktor): should we just clamp colors in the renderer?
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
                // NOTE(viktor): render the particle
                push_bitmap(&render_group, particle.bitmap_id, default_flat_transform(), 0.4, particle.p, color)
            }
        }             
    }
    
    update_and_render_world(&state.world, tran_state, &render_group, input)
    
    // TODO(viktor): We should probably pull the generation stuff, because
    // if we don't do ground chunks its a huge waste of effort
    if tran_state.generation_id != 0 {
        end_generation(tran_state.assets, tran_state.generation_id)
    }
    tran_state.generation_id = begin_generation(tran_state.assets)
    
    // TODO(viktor): :CutsceneEpisodes quit requested
    
    check_arena(&state.mode_arena)
    check_arena(&tran_state.arena)
}

// NOTE: at the moment this has to be a really fast function. It shall not be slower than a
// millisecond or so.
// TODO: reduce the pressure on the performance of this function by measuring
// TODO: Allow sample offsets here for more robust platform options
@export 
output_sound_samples :: proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer){
    state      := cast(^State)          raw_data(memory.permanent_storage)
    tran_state := cast(^TransientState) raw_data(memory.transient_storage)
    
    output_playing_sounds(&state.mixer, &tran_state.arena, tran_state.assets, sound_buffer)
}



begin_task_with_memory :: proc(tran_state: ^TransientState) -> (result: ^TaskWithMemory) {
    for &task in tran_state.tasks {
        if !task.in_use {
            result = &task
            
            task.memory_flush = begin_temporary_memory(&task.arena)
            result.in_use = true
            
            break
        }
    }
    
    return result
}

end_task_with_memory :: #force_inline proc (task: ^TaskWithMemory) {
    end_temporary_memory(task.memory_flush)
    
    complete_previous_writes_before_future_writes()
    
    task.in_use = false
}

make_pyramid_normal_map :: proc(bitmap: Bitmap, roughness: f32) {
    for y in 0..<bitmap.height {
        for x in 0..<bitmap.width {
            inv_x := bitmap.width - x
            InvSqrtTwo :: 1.0 / SqrtTwo
            normal: v3 = { 0, 0, InvSqrtTwo }
            if x < y {
                if inv_x < y {
                    normal.y = InvSqrtTwo
                } else {
                    normal.x = -InvSqrtTwo
                }
            } else {
                if inv_x < y {
                    normal.x = InvSqrtTwo
                } else {
                    normal.y = -InvSqrtTwo
                }
            }
            
            color := 255 * V4((normal + 1) * 0.5, roughness)
            
            dst := &bitmap.memory[y * bitmap.width + x]
            dst^ = vec_cast(u8, color)
        }
    }
}

make_sphere_normal_map :: proc(buffer: Bitmap, roughness: f32, c:= v2{1,1}) {
    inv_size: v2 = 1 / (vec_cast(f32, buffer.width, buffer.height) - 1)
    
    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            bitmap_uv := inv_size * vec_cast(f32, x, y)
            nxy := c * ((2 * bitmap_uv) - 1)
            
            root_term := 1 - square(nxy.x) - square(nxy.y)

            InvSqrtTwo :: 1.0 / SqrtTwo
            normal := v3{0, InvSqrtTwo, InvSqrtTwo}
            if root_term >= 0 {
                nz := square_root(root_term)
                normal = V3(nxy, nz)
            }
            
            color := 255 * V4((normal + 1) * 0.5, roughness)
            
            dst := &buffer.memory[y * buffer.width + x]
            dst^ = vec_cast(u8, color)
        }
    }
}

make_sphere_diffuse_map :: proc(buffer: Bitmap, c := v2{1,1}) {
    inv_size: v2 = 1 / (vec_cast(f32, buffer.width, buffer.height) - 1)
    
    for y in 0..<buffer.height {
        for x in 0..<buffer.width {
            bitmap_uv := inv_size * vec_cast(f32, x, y)
            nxy := c * ((2 * bitmap_uv) - 1)
            
            root_term := 1 - square(nxy.x) - square(nxy.y)

            alpha: f32
            if root_term > 0 {
                alpha = 1
            }
            alpha *= 255
            base_color: v3 = 0
            color := V4(alpha * base_color, alpha)
            
            dst := &buffer.memory[y * buffer.width + x]
            dst^ = vec_cast(u8, color)
        }
    }
}

make_empty_bitmap :: proc(arena: ^Arena, dim: [2]i32, clear_to_zero: b32 = true) -> (result: Bitmap) {
    result = {
        memory = push(arena, Color, (dim.x * dim.y), align_clear(32, clear_to_zero)),
        width  = dim.x,
        height = dim.y,
        width_over_height = safe_ratio_1(cast(f32) dim.x,  cast(f32) dim.y),
    }
    
    return result
}
