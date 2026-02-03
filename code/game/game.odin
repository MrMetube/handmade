package game

@(common) INTERNAL :: #config(INTERNAL, false)
SlowCode :: INTERNAL

////////////////////////////////////////////////
// @todo(viktor): Find a better place for these configurations

LoadAssetsSingleThreaded: b32 = !false
SoundPanningWithMouse:    b32 = false
SoundPitchingWithMouse:   b32 = false
ShowSimulationBounds:     b32 = false
ShowRenderFrustum:        b32 = false
TimestepPercentage:       f32 = 100

////////////////////////////////////////////////

@(common) 
GameMemory :: struct {
    reloaded_executable: b32,
    
    state:           ^State,
    transient_state: ^TransientState,
    
    debug_state: (^DebugState when INTERNAL else struct {}),
    debug_table: (^DebugTable when INTERNAL else struct {}),
    
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
    
    high_priority_queue: ^WorkQueue,
    low_priority_queue:  ^WorkQueue,
    
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
update_and_render :: proc (memory: ^GameMemory, input: ^Input, render_commands: ^RenderCommands) {
    input := input
    Platform = memory.Platform_api
    
    when DebugEnabled {
        if GlobalDebugMemory == nil {
            GlobalDebugMemory = memory
            GlobalDebugTable = memory.debug_table
        }
    }
    
    ////////////////////////////////////////////////

    state := memory.state
    if state == nil {
        memory.state = bootstrap_arena(State, "total_arena")
        state = memory.state
        
        init_mixer(&state.mixer, &state.audio_arena)
        
        when DebugEnabled do debug_set_event_recording(true)
    }

    tran_state := memory.transient_state
    if tran_state == nil {
        memory.transient_state = bootstrap_arena(TransientState, "arena")
        tran_state = memory.transient_state
        
        tran_state.high_priority_queue = memory.high_priority_queue
        tran_state.low_priority_queue  = memory.low_priority_queue
        
        for &task in tran_state.tasks {
            task.in_use = false
        }
        
        tran_state.assets = make_assets(512 * Megabyte, tran_state, &memory.platform_texture_op_queue)
        
        state.mixer.master_volume = 0.1
    }
    
    ////////////////////////////////////////////////
    
    { debug_data_block("Profile")
        { debug_data_block("Memory")
            debug_ui_element(ArenaOccupancy{ &state.total_arena }, "State Total Arena")
            debug_ui_element(ArenaOccupancy{ &tran_state.arena }, "Transient State Arena")
            debug_ui_element(ArenaOccupancy{ &state.audio_arena }, "Audio Arena")
        }
        debug_ui_element(FrameSlider{})
        debug_ui_element(TopClocksList{})
        debug_ui_element(FrameInfo{})
    }
    
    { debug_data_block("Renderer")
        // @todo(viktor): tell the debug ui to move back into the screen area
        dim := vec_cast(f32, render_commands.dimension)
        debug_record_value(&dim.x, "Render Width")
        debug_record_value(&dim.y, "Render Height")
        render_commands.dimension = vec_cast(i32, dim)
        
        debug_record_value(&render_commands.multisampling_hint, "Multisampling")
        debug_record_value(&render_commands.pixelation_hint, "Pixelation")
        count := cast(f32) render_commands.depth_peel_count_hint
        debug_record_value(&count, "Depth Peel Count")
        render_commands.depth_peel_count_hint = cast(u32) count
    }
    
    { debug_data_block("Game")
 
        { debug_data_block("Camera")
            debug_record_value(&ShowRenderFrustum)
            debug_record_value(&ShowSimulationBounds)
        }
        
        debug_record_value(&LoadAssetsSingleThreaded)
        
        debug_record_value(&TimestepPercentage)
        TimestepPercentage = clamp(TimestepPercentage, 0, 1000)
        
        { debug_data_block("Audio")
            debug_record_value(&SoundPanningWithMouse)
            debug_record_value(&SoundPitchingWithMouse)
        }
    }
    
    if SoundPanningWithMouse {
        // @note(viktor): test sound panning with the mouse 
        music_volume := input.mouse.p - vec_cast(f32, render_commands.dimension) * 0.5
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
        if was_pressed(input.mouse.buttons[.middle]) {
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
            controller.buttons[.start].ended_down = true
            controller.buttons[.start].half_transition_count = 1
        }
    }
    
    render_group: RenderGroup
    init_render_group(&render_group, tran_state.assets, render_commands, tran_state.generation_id)
    
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
output_sound_samples :: proc (memory: ^GameMemory, sound_buffer: GameSoundBuffer) {
    state      := memory.state
    tran_state := memory.transient_state
    
    output_playing_sounds(&state.mixer, &tran_state.arena, tran_state.assets, sound_buffer)
}

////////////////////////////////////////////////

debug_get_game_assets_work_queue_and_generation_id :: proc (memory: ^GameMemory) -> (assets: ^Assets, generation_id: AssetGenerationId) {
    tran_state := memory.transient_state
    if tran_state != nil {
        assets = tran_state.assets
        generation_id = tran_state.generation_id
    }
    
    return assets, generation_id
}

////////////////////////////////////////////////

begin_task_with_memory :: proc (tran_state: ^TransientState, depends_on_game_mode: b32) -> (result: ^TaskWithMemory) {
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