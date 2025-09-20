package game

// @cleanup #placeholder
@(common) INTERNAL :: #config(INTERNAL, false)
@(common) SlowCode :: INTERNAL

////////////////////////////////////////////////
// @todo(viktor): Find a better place for these configurations

LoadAssetsSingleThreaded:      b32
SoundPanningWithMouse:         b32
SoundPitchingWithMouse:        b32
EnvironmentTest:               b32
UseDebugCamera:                b32
DebugCameraDistance:           f32 = 5
ShowRenderAndSimulationBounds: b32
TimestepPercentage:            f32 = 100
RenderCollisionOutlineAndTraversablePoints: b32 = true

////////////////////////////////////////////////

@(common) 
InputButton :: struct {
    half_transition_count: u32,
    ended_down:            b32,
}

@(common) 
InputController :: struct {
    // @todo(viktor): allow outputing vibration
    is_connected: b32,
    is_analog:    b32,
    
    stick_average: [2]f32,
    
    using _buttons_array_and_enum : struct #raw_union {
        buttons: [18]InputButton,
        using _buttons_enum : struct {
            stick_up,  stick_down,  stick_left,  stick_right, 
            button_up, button_down, button_left, button_right,
            dpad_up,   dpad_down,   dpad_left,   dpad_right,  
            
            start, back,
            shoulder_left, shoulder_right,
            thumb_left,    thumb_right:    InputButton,
        },
    },
    
}
#assert(size_of(InputController{}._buttons_array_and_enum.buttons) == size_of(InputController{}._buttons_array_and_enum._buttons_enum))

@(common) 
Input :: struct {
    delta_time:     f32,
    quit_requested: bool,
    
    controllers: [5]InputController,
        
    // @note(viktor): this is for debugging only
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

@(common) 
GameMemory :: struct {
    reloaded_executable: b32,
    // @note(viktor): REQUIRED to be cleared to zero at startup
    state:           pmm, // ^State
    transient_state: pmm, // ^TransientState
    
    debug_state:   (pmm         when INTERNAL else struct {}), // ^DebugState
    debug_table:   (^DebugTable when INTERNAL else struct {}),
        
    high_priority_queue: ^WorkQueue,
    low_priority_queue:  ^WorkQueue,
    
    platform_texture_op_queue: TextureOpQueue,
    
    Platform_api: Platform_Api,
}

////////////////////////////////////////////////

State :: struct {
    total_arena: Arena,
    mode_arena:  Arena,
    audio_arena: Arena, // @todo(viktor): move this out into the audio system properly!
    
    controlled_heroes: [len(Input{}.controllers)] ControlledHero,
    
    mixer: Mixer,
    // @note(viktor): This is for testing the changing of volume and pitch and should not persist.
    music: ^PlayingSound,
    
    game_mode: Game_Mode,
}

TransientState :: struct {
    arena: Arena,
    
    assets:        ^Assets,
    generation_id: AssetGenerationId,
        
    tasks: [4] TaskWithMemory,
    
    test_diffuse: Bitmap,
    test_normal:  Bitmap,
    
    high_priority_queue: ^WorkQueue,
    low_priority_queue:  ^WorkQueue,
    
    env_size: v2i,
    envs: [3]EnvironmentMap,
    
    // @todo(viktor): potentially remove this system, it is just for asset locking
    next_generation:            AssetGenerationId,
    memory_operation_lock:      u32,
    in_flight_generation_count: u32,
    in_flight_generations:      [32] AssetGenerationId,    
}

Game_Mode :: union {
    ^Titlescreen_Mode,
    ^Cutscene_Mode,
    ^World_Mode,
}

TaskWithMemory :: struct {
    in_use: b32,
    depends_on_game_mode: b32,
    arena: Arena,
    
    memory_flush: TemporaryMemory,
}

ControlledHero :: struct {
    brain_id: BrainId,
    recenter_t: f32,
}

@(export)
update_and_render :: proc(memory: ^GameMemory, input: ^Input, render_commands: ^RenderCommands) {
    input := input
    Platform = memory.Platform_api
    
    when DebugEnabled {
        if GlobalDebugMemory == nil {
            GlobalDebugMemory = memory
            GlobalDebugTable = memory.debug_table
        }
    }
    
    ////////////////////////////////////////////////

    state := cast(^State) memory.state
    if state == nil {
        memory.state = bootstrap_arena(State, "total_arena")
        state = cast(^State) memory.state
        
        init_mixer(&state.mixer, &state.audio_arena)
        
        when DebugEnabled do debug_set_event_recording(true)
    }

    tran_state := cast(^TransientState) memory.transient_state
    if tran_state == nil {
        memory.transient_state = bootstrap_arena(TransientState, "arena")
        tran_state = cast(^TransientState) memory.transient_state
        
        tran_state.high_priority_queue = memory.high_priority_queue
        tran_state.low_priority_queue  = memory.low_priority_queue
        
        for &task in tran_state.tasks {
            task.in_use = false
        }
        
        tran_state.assets = make_assets(512 * Megabyte, tran_state, &memory.platform_texture_op_queue)
        
        state.mixer.master_volume = 0.1
        
        test_size: v2i= 256
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
    }
    
    ////////////////////////////////////////////////
    
    { debug_data_block("Profile")
        { debug_data_block("Memory")
            debug_ui_element(ArenaOccupancy{ &state.total_arena }, "State Total Arena")
            debug_ui_element(ArenaOccupancy{ &tran_state.arena }, "Transient State Arena")
            debug_ui_element(ArenaOccupancy{ &state.audio_arena }, "Audio Arena")
        }
        debug_ui_element(FrameSlider{})
        debug_ui_element(FrameBarsGraph{})
        debug_ui_element(FrameInfo{})
    }
    
    { debug_data_block("Game")
 
        { debug_data_block("Camera")
            debug_record_value(&ShowRenderAndSimulationBounds)
            debug_record_value(&UseDebugCamera)
            debug_record_value(&DebugCameraDistance)
        }
        
        debug_record_value(&RenderCollisionOutlineAndTraversablePoints)
        debug_record_value(&LoadAssetsSingleThreaded)
        
        TimestepPercentage = clamp(TimestepPercentage, 0, 1000)
        debug_record_value(&TimestepPercentage)
        
        { debug_data_block("Audio")
            debug_record_value(&SoundPanningWithMouse)
            debug_record_value(&SoundPitchingWithMouse)
        }
        
        { debug_data_block("Tests")
            debug_record_value(&EnvironmentTest)
        }
    }
    
    if SoundPanningWithMouse {
        // @note(viktor): test sound panning with the mouse 
        music_volume := input.mouse.p - vec_cast(f32, render_commands.width, render_commands.height) * 0.5
        if state.music == nil {
            if state.mixer.first_playing_sound == nil {
                play_sound(&state.mixer, first_sound_from(tran_state.assets, .Music))
            }
            state.music = state.mixer.first_playing_sound
        }
        change_volume(&state.mixer, state.music, 0.01, music_volume)
    }
    
    if SoundPitchingWithMouse {
        // @note(viktor): test sound panning with the mouse 
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
    
    if state.game_mode == nil {
        play_intro_cutscene(state, tran_state)
        when true { // go directly into the game
            controller := &input.controllers[0]
            controller.start.ended_down = true
            controller.start.half_transition_count = 1
        }
    }
    
    render_group: RenderGroup
    init_render_group(&render_group, tran_state.assets, render_commands, false, tran_state.generation_id)
    
    input.delta_time *= TimestepPercentage/100.0
    
    rerun := false
    for {
        switch mode in state.game_mode {
          case ^Titlescreen_Mode: 
            rerun = update_and_render_title_screen(state, tran_state, &render_group, input, mode)
          case ^Cutscene_Mode:
            rerun = update_and_render_cutscene(state, tran_state, &render_group, input, mode)
          case ^World_Mode:
            rerun = update_and_render_world(state, tran_state, &render_group, input, mode)
        }
        
        if !rerun do break
    }
    
    // @todo(viktor): We should probably pull the generation stuff, because
    // if we don't do ground chunks its a huge waste of effort
    if tran_state.generation_id != 0 {
        end_generation(tran_state.assets, tran_state.generation_id)
    }
    tran_state.generation_id = begin_generation(tran_state.assets)
    
    check_arena(&state.mode_arena)
    check_arena(&tran_state.arena)
}

set_game_mode :: proc (state: ^State, tran_state: ^TransientState, $mode: typeid) -> (result: ^mode) {
    need_to_wait := false
    for task in tran_state.tasks {
        need_to_wait ||= task.depends_on_game_mode
    }
    
    if need_to_wait {
        Platform.complete_all_work(tran_state.low_priority_queue)
    }
    clear_arena(&state.mode_arena)
    
    result = push(&state.mode_arena, mode)
    state.game_mode = result
    return result
}

// @note(viktor): at the moment this has to be a really fast function. It shall not be slower than a
// millisecond or so.
// @todo(viktor): reduce the pressure on the performance of this function by measuring
// @todo(viktor): Allow sample offsets here for more robust platform options
@(export) 
output_sound_samples :: proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer) {
    state      := cast(^State)          memory.state
    tran_state := cast(^TransientState) memory.transient_state
    
    output_playing_sounds(&state.mixer, &tran_state.arena, tran_state.assets, sound_buffer)
}

////////////////////////////////////////////////

debug_get_game_assets_work_queue_and_generation_id :: proc(memory: ^GameMemory) -> (assets: ^Assets, generation_id: AssetGenerationId) {
    tran_state := cast(^TransientState) memory.transient_state
    if tran_state != nil {
        assets = tran_state.assets
        generation_id = tran_state.generation_id
    }
    
    return assets, generation_id
}

////////////////////////////////////////////////

begin_task_with_memory :: proc(tran_state: ^TransientState, depends_on_game_mode: b32) -> (result: ^TaskWithMemory) {
    for &task in tran_state.tasks {
        if !task.in_use {
            result = &task
            
            result.memory_flush = begin_temporary_memory(&result.arena)
            result.in_use = true
            result.depends_on_game_mode = depends_on_game_mode
            break
        }
    }
    
    return result
}

end_task_with_memory :: proc (task: ^TaskWithMemory) {
    end_temporary_memory(task.memory_flush)
    
    complete_previous_writes_before_future_writes()
    
    task.in_use = false
}

////////////////////////////////////////////////
// @cleanup

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
            dst ^= vec_cast(u8, color)
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
            dst ^= vec_cast(u8, color)
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
            dst ^= vec_cast(u8, color)
        }
    }
}

make_empty_bitmap :: proc(arena: ^Arena, dim: v2i, clear_to_zero: b32 = true) -> (result: Bitmap) {
    result = {
        memory = push(arena, Color, (dim.x * dim.y), align_clear(32, clear_to_zero)),
        width  = dim.x,
        height = dim.y,
        width_over_height = safe_ratio_1(cast(f32) dim.x,  cast(f32) dim.y),
    }
    
    return result
}
