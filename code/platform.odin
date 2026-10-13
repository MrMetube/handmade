#+vet explicit-allocators
package main

import "base:runtime"
import win "core:sys/windows"

/*
    @todo THIS IS NOT A FINAL PLATFORM LAYER !!!
    - Saved game locations
    - Getting a handle to our own executable file
    - Raw Input (support for multiple keyboards)
    - ClipCursor() (for multimonitor support)
    - QueryCancelAutoplay
    - WM_ACTIVATEAPP (for when we are not the active application)
    - GetKeyboardLayout (for French keyboards, international WASD support)

    Just a partial list of stuff !!
*/


////////////////////////////////////////////////
// Config

// RenderDimension := v2i{1280, 720}
RenderDimension := v2i{1920, 1080}
// RenderDimension := v2i{2560, 1440}

MonitorRefreshHz :: 90

HighPriorityThreads :: 9
LowPriorityThreads  :: 2

////////////////////////////////////////////////
//  Globals

GlobalPlatformState := PlatformState {
    window_position = { length = size_of(win.WINDOWPLACEMENT) },
}

// Debug Variables

GlobalPause:               b32
GlobalDebugShowCursor:     b32 = INTERNAL
GlobalDebugRenderSingleThreaded: b32 = false
GlobalUseSoftwareRenderer: b32 = false
// :BackendSwitching:
GlobalUseVulkanRenderer:   b32 = true

GlobalDebugTable := &DebugTable{}

////////////////////////////////////////////////
// Types

SoundOutput :: struct {
    samples_per_second:   u32,
    num_channels:         u32,
    bytes_per_sample:     u32,
    buffer_size:          u32,
    running_sample_index: u32,
    safety_bytes:         u32,
}

PlatformState :: struct {
    exe_path: string,
    performance_counter_frequency: f64,
    window_position: win.WINDOWPLACEMENT,
    
    // @note to touch the memory ring you need to take the memory mutex.
    block_mutex:    TicketMutex,
    block_sentinel: Memory_Block,
    
    recording_handle: win.HANDLE,
    replaying_handle: win.HANDLE,
    recording_index:  i32,
    replaying_index:  i32,
    
    file_arena: Arena,
}

Memory_Block :: struct #align(64) {
    using _data: _Memory_Block,
    _pad: [64 - size_of(_Memory_Block)] u8,
}

_Memory_Block :: struct {
    // @note this needs to be the first member so that a ^Platform_Memory_Block can be cast to a ^Memory_Block
    block: Platform_Memory_Block,
    
    prev, next: ^Memory_Block,
    loop_flags: Memory_Block_Flags,
}

Memory_Block_Flags :: bit_set [Memory_Block_Flag]
Memory_Block_Flag :: enum {
    allocated_during_loop,
    freed_during_loop,
}
Saved_Memory_Block :: struct {
    base: u64,
    size: u64,
}

////////////////////////////////////////////////

main :: proc () {
    unused(verify_memory_block_integrity)
    
    list_init_sentinel(&GlobalPlatformState.block_sentinel)
    
    // @hack
    set_platform_api_in_the_statically_linked_game_code(Platform)
    _platform_arena: Arena
    platform_allocator := arena_allocator(&_platform_arena)
    back_buffer := Bitmap { dimension = RenderDimension }
    {
        frequency: win.LARGE_INTEGER
        win.QueryPerformanceFrequency(&frequency)
        GlobalPlatformState.performance_counter_frequency = cast(f64) frequency
    }
    
    ////////////////////////////////////////////////
    // Windows Setup
    
    window: win.HWND
    {
        instance := cast(win.HINSTANCE) win.GetModuleHandleW(nil)
        window_class := win.WNDCLASSW{
            hInstance = instance,
            lpszClassName = "HandmadeWindowClass",
            style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
            lpfnWndProc = main_window_callback,
            hCursor = win.LoadCursorW(nil, cast(cstring16) win.MAKEINTRESOURCEW(cast(umm) cast(pmm) win.IDC_ARROW)),
            // hIcon =,
        }
        
        {
            buffer := &back_buffer
            assert(align(16, buffer.dimension.x) == buffer.dimension.x)
            buffer.memory = make(platform_allocator, Color, buffer.dimension.x * buffer.dimension.y)
        }
        
        if win.RegisterClassW(&window_class) == 0 {
            return // @logging 
        }
        
        window = win.CreateWindowExW(
            0,
            window_class.lpszClassName,
            "Handmade",
            win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
            win.CW_USEDEFAULT,
            win.CW_USEDEFAULT,
            back_buffer.dimension.x  + 16, // added for the window frame
            back_buffer.dimension.y + 39,
            nil,
            nil,
            window_class.hInstance,
            nil,
        )
        
        if window == nil {
            // @logging
            runtime.exit(1)
        }
    }
    
    {
        exe_path_buffer: [win.MAX_PATH_WIDE] u16
        size_of_filename  := win.GetModuleFileNameW(nil, &exe_path_buffer[0], win.MAX_PATH_WIDE)
        exe_path_and_name := win.wstring_to_utf8(cast(cstring16) &exe_path_buffer[0], cast(int) size_of_filename, context.temp_allocator) or_else ""
        on_last_slash: u32
        for r, i in exe_path_and_name {
            if r == '\\' {
                on_last_slash = cast(u32) i
            }
        }
        GlobalPlatformState.exe_path = exe_path_and_name[:on_last_slash]
    }
    
    ////////////////////////////////////////////////
    // Platform Setup
    
    high_queue, low_queue: WorkQueue
    init_work_queue(&high_queue, HighPriorityThreads)
    init_work_queue(&low_queue,  LowPriorityThreads )
    
    ////////////////////////////////////////////////
    //  Video Setup
    
    render_state := make(platform_allocator, Render_State)
    // @cleanup
    render_state.game     = cast(type_of(render_state.game)) game
    render_state.platform = Platform
    
    render_dll: Dll
    render_dll.name = build_exe_path("render.dll")
    render_dll.lock = build_exe_path("render.lock")
    render_dll.temp = build_exe_path("render_temp.dll")
    
    {
        window_dc := win.GetDC(window)
        defer win.ReleaseDC(window, window_dc)
        
        write_time: u64
        render_dll.is_valid, write_time = load_render_lib(&render_dll)
        
        if render_dll.is_valid {
            render_dll.is_valid = render.attach(render_state, window, window_dc, GlobalUseVulkanRenderer ? .Vulkan : .OpenGL)
            if render_dll.is_valid {
                render_dll.write_time = write_time
            } else {
                render.reload_or_shutdown(.Shutdown)
                unload_render_api(&render_dll)
            }
        }
    }
    
    // @todo how do we reliably query this on windows?
    game_update_hz: f32
    {
        when false {
            device_context := win.GetDC(window)
            VRefresh :: 116
            refresh_rate := win.GetDeviceCaps(device_context, VRefresh)
            if refresh_rate > 1 {
                MonitorRefreshHz = cast(u32) refresh_rate
            }
            win.ReleaseDC(window, device_context)
        }
        
        game_update_hz = cast(f32) MonitorRefreshHz
    }
    
    ////////////////////////////////////////////////
    //  Sound Setup
    
    sound_output: SoundOutput
    sound_output.samples_per_second = 48000
    sound_output.num_channels       = 2
    sound_output.bytes_per_sample   = size_of(Sample)
    sound_output.buffer_size        = sound_output.samples_per_second * sound_output.bytes_per_sample
    // @todo actually compute this variance and set a reasonable value
    {
        target_seconds_per_frame := 1 / game_update_hz
        sound_output.safety_bytes = cast(u32) (target_seconds_per_frame * cast(f32) sound_output.samples_per_second * cast(f32) sound_output.bytes_per_sample)
    }
    
    direct_sound_buffer := init_dSound(window, sound_output.buffer_size, sound_output.samples_per_second)
    if direct_sound_buffer == nil {
        print("Error: Failed to initialize DSound.") // @logging 
        runtime.exit(1)
    }
    
    clear_sound_buffer(direct_sound_buffer, &sound_output)
    
    direct_sound_buffer->Play(0, 0, DSBPLAY_LOOPING)
    
    sound_is_valid: bool
    
    ////////////////////////////////////////////////
    //  Input Setup
    
    xinput := init_xInput()
    
    // @todo Monitor xbox controllers for being plugged in after the fact
    xbox_controller_present: [XUSER_MAX_COUNT] bool = true
    
    input: [2] Input
    old_input, new_input := &input[0], &input[1]
    
    ////////////////////////////////////////////////
    // Memory Setup
    
    game_dll: Dll
    game_dll.name = build_exe_path("game.dll")
    game_dll.lock = build_exe_path("game.lock")
    game_dll.temp = build_exe_path("game_temp.dll")
    load_game_lib(&game_dll)
    
    game.debug_set_event_recording(GlobalDebugTable, game_dll.is_valid)
    
    // @todo make this like sixty seconds?
    // @todo remove MaxPossibleOverlap
    MaxPossibleOverlap :: 8
    samples := make(platform_allocator, Sample, sound_output.samples_per_second + MaxPossibleOverlap)
    assert(samples != nil)
    
    _frame_arena := Arena { allocation_flags = { .not_restored } }
    frame_allocator := arena_allocator(&_frame_arena)
    
    render_commands: RenderCommands
    {
        // @todo decide what our sizes should be
        push_buffer := make(frame_allocator, u8, 32*Megabyte)
        render_commands.push_buffer        = make_byte_buffer(push_buffer)
        render_commands.vertex_buffer      = make_array_allocator(frame_allocator, Textured_Vertex, 1 << 20)
        render_commands.quad_bitmap_buffer = make_array_allocator(frame_allocator, ^Bitmap, 1 << 20)
        
        // @todo Check if the software renderer handles this correctly because of the lanewidth
        render_commands.white_bitmap.memory = make(frame_allocator, Color, 1)
        render_commands.white_bitmap.memory[0] = 255
        render_commands.white_bitmap.dimension = 1
        render_commands.white_bitmap.width_over_height = 1
        render_commands.white_bitmap.texture_handle = render.allocate_texture(render_commands.white_bitmap, true)
        
        render_commands.dimension = back_buffer.dimension
        
        render_commands.multisampling_hint    = true
        render_commands.pixelation_hint       = !false
        render_commands.depth_peel_count_hint = 4
        // render_commands.light_texture_dimension_power_of_2 = {9, 8, 1}
    }
    
    game_memory := GameMemory {
        high_priority_queue = auto_cast &high_queue,
        low_priority_queue  = auto_cast &low_queue,
        
        Platform_api = Platform,
    }
    
    { // @note initialize game_memory
        game_memory.debug_table = make(platform_allocator, DebugTable)
        
        texture_op_count := 1024
        texture_ops := make(platform_allocator, TextureOp, texture_op_count)
        for &op, index in texture_ops[:texture_op_count-1] {
            op.next = &texture_ops[index + 1]
        }
        
        freelist_init(&game_memory.platform_texture_op_queue.freelist, nil, &texture_ops[0])
    }
    texture_op_queue := &game_memory.platform_texture_op_queue
    
    ////////////////////////////////////////////////
    //  Timer Setup
    
    last_counter := get_wall_clock()
    
    ////////////////////////////////////////////////
    //  Game Loop
    
    // @note Set the windows scheduler granularity to 1ms so that out win.Sleep can be more granular
    desired_scheduler_ms :: 1
    sleep_is_granular := win.timeBeginPeriod(desired_scheduler_ms) == win.TIMERR_NOERROR
    
    running := true
    
    expected_frames_per_update: f32 = 1
    target_seconds_per_frame: f32
    for running {
        check_arena_allocator(platform_allocator)  
        check_arena_allocator(frame_allocator)  
        
        clear_render_commands(&render_commands)
        
        window_dim := get_window_dimension(window)
        draw_region := aspect_ratio_fit(render_commands.dimension, window_dim)
        
        ////////////////////////////////////////////////
        { timed_block("input processed")
            
            target_seconds_per_frame = expected_frames_per_update / game_update_hz
            {
                new_input.delta_time = target_seconds_per_frame
                
                is_down :: proc (vk: win.INT) -> bool {
                    is_down_mask :: transmute(i16) (cast(u16) 1 << 15)
                    return (win.GetKeyState(vk) & is_down_mask) != 0
                }
                
                { // Modifiers
                    new_input.shift_down   = is_down(win.VK_LSHIFT)
                    new_input.control_down = is_down(win.VK_CONTROL)
                    new_input.alt_down     = is_down(win.VK_MENU)
                }
                
                { timed_block("mouse input")
                    
                    mouse_in_window_y_down: win.POINT
                    win.GetCursorPos(&mouse_in_window_y_down)
                    win.ScreenToClient(window, &mouse_in_window_y_down)
                    
                    mouse_in_window_y_up := vec_cast(f32, mouse_in_window_y_down.x, window_dim.y - 1 - mouse_in_window_y_down.y)
                    draw_region := rec_cast(f32, draw_region)
                    mouse_in_draw_region := cast(v2) render_commands.dimension * clamp_01_map_to_range(draw_region.min, mouse_in_window_y_up, draw_region.max)
                    
                    new_input.mouse.p = mouse_in_draw_region
                    for &button, index in new_input.mouse.buttons {
                        button.ended_down = old_input.mouse.buttons[index].ended_down
                        button.half_transition_count = 0
                    }
                    
                    // @todo support mouse wheel
                    new_input.mouse.wheel = 0
                    // @todo Do we need to update the input button on every event?
                    process_win_keyboard_message(&new_input.mouse.buttons[.left],   is_down(win.VK_LBUTTON))
                    process_win_keyboard_message(&new_input.mouse.buttons[.right],  is_down(win.VK_RBUTTON))
                    process_win_keyboard_message(&new_input.mouse.buttons[.middle], is_down(win.VK_MBUTTON))
                    process_win_keyboard_message(&new_input.mouse.buttons[.extra1], is_down(win.VK_XBUTTON1))
                    process_win_keyboard_message(&new_input.mouse.buttons[.extra2], is_down(win.VK_XBUTTON2))
                }
                
                { timed_block("keyboard input")
                    
                    old_keyboard_controller := &old_input.controllers[0]
                    new_keyboard_controller := &new_input.controllers[0]
                    new_keyboard_controller ^= {}
                    new_keyboard_controller.is_connected = true
                    
                    for &button, index in new_keyboard_controller.buttons {
                        button.ended_down = old_keyboard_controller.buttons[index].ended_down
                    }
                    
                    if process_pending_messages(&GlobalPlatformState, new_keyboard_controller, render_state) {
                        running = false
                    }
                }
                
                max_controller_count: u32 = min(XUSER_MAX_COUNT, len(Input{}.controllers) - 1)
                // @todo Need to not poll disconnected controllers to avoid xinput frame rate hit
                // on older libraries.
                // Is this still relevant?
                // @todo should we poll this more frequently
                // @todo only check connected controllers, catch messages on connect / disconnect
                { timed_block("controller input")
                    
                    for controller_index in 0..<max_controller_count {
                        controller_state: XINPUT_STATE
                        
                        our_controller_index := controller_index+1
                        
                        old_controller :=  old_input.controllers[our_controller_index]
                        new_controller := &new_input.controllers[our_controller_index]
                        
                        if xbox_controller_present[controller_index] && xinput.GetState(controller_index, &controller_state) == win.ERROR_SUCCESS {
                            new_controller.is_connected = true
                            new_controller.is_analog = old_controller.is_analog
                            // @todo see if dwPacketNumber increments too rapidly
                            pad := controller_state.Gamepad
                            
                            process_Xinput_button :: proc (new_state: ^InputButton, old_state: InputButton, xInput_button_state: win.WORD, button_bit: win.WORD) {
                                new_state.ended_down = cast(bool) (xInput_button_state & button_bit)
                                new_state.half_transition_count = (old_state.ended_down == new_state.ended_down) ? 1 : 0
                            }
                            
                            xx := #partial [Controller_Button] win.WORD {
                                .button_up      = XINPUT_GAMEPAD_Y,
                                .button_down    = XINPUT_GAMEPAD_A,
                                .button_left    = XINPUT_GAMEPAD_X,
                                .button_right   = XINPUT_GAMEPAD_B,
                                
                                .start          = XINPUT_GAMEPAD_START,
                                .back           = XINPUT_GAMEPAD_BACK,
                                
                                .shoulder_left  = XINPUT_GAMEPAD_LEFT_SHOULDER,
                                .shoulder_right = XINPUT_GAMEPAD_RIGHT_SHOULDER,
                                
                                .dpad_up        = XINPUT_GAMEPAD_DPAD_UP,
                                .dpad_down      = XINPUT_GAMEPAD_DPAD_DOWN,
                                .dpad_left      = XINPUT_GAMEPAD_DPAD_LEFT,
                                .dpad_right     = XINPUT_GAMEPAD_DPAD_RIGHT,
                                
                                .thumb_left     = XINPUT_GAMEPAD_LEFT_THUMB,
                                .thumb_right    = XINPUT_GAMEPAD_RIGHT_THUMB,
                                
                                // @note stick_xx "buttons" are handled separately below
                            }
                            
                            for xinput_bit, button in xx {
                                process_Xinput_button(&new_controller.buttons[button], old_controller.buttons[button], pad.wButtons, xinput_bit)
                            }
                            
                            process_Xinput_stick :: proc (thumbstick: win.SHORT, deadzone: i16) -> f32 {
                                if thumbstick < -deadzone {
                                    return cast(f32) (thumbstick + deadzone) / (32768 - cast(f32) deadzone)
                                } else if thumbstick > deadzone {
                                    return cast(f32) (thumbstick - deadzone) / (32767 - cast(f32) deadzone)
                                }
                                return 0
                            }
                            
                            // @todo right stick, triggers
                            // @todo This is a square deadzone, check XInput to
                            // verify that the deadzone is "round" and show how to do
                            // round deadzone processing.
                            new_controller.stick_average = {
                                process_Xinput_stick(pad.sThumbLX, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE),
                                process_Xinput_stick(pad.sThumbLY, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE),
                            }
                            if new_controller.stick_average != {0,0} { new_controller.is_analog = true }
                            
                            // @todo what if we don't want to override the stick
                            if (pad.wButtons & XINPUT_GAMEPAD_DPAD_RIGHT) != 0 { new_controller.stick_average.x =  1; new_controller.is_analog = false }
                            if (pad.wButtons & XINPUT_GAMEPAD_DPAD_LEFT) != 0  { new_controller.stick_average.x = -1; new_controller.is_analog = false }
                            if (pad.wButtons & XINPUT_GAMEPAD_DPAD_UP) != 0    { new_controller.stick_average.y =  1; new_controller.is_analog = false }
                            if (pad.wButtons & XINPUT_GAMEPAD_DPAD_DOWN) != 0  { new_controller.stick_average.y = -1; new_controller.is_analog = false }
                            
                            Threshold :: 0.5
                            // @cleanup process_Xinput_button is leaking its abstraction here
                            process_Xinput_button(&new_controller.buttons[.stick_left],  old_controller.buttons[.stick_left],  1, new_controller.stick_average.x < -Threshold ? 1 : 0)
                            process_Xinput_button(&new_controller.buttons[.stick_right], old_controller.buttons[.stick_right], 1, new_controller.stick_average.x >  Threshold ? 1 : 0)
                            process_Xinput_button(&new_controller.buttons[.stick_down],  old_controller.buttons[.stick_down],  1, new_controller.stick_average.y < -Threshold ? 1 : 0)
                            process_Xinput_button(&new_controller.buttons[.stick_up],    old_controller.buttons[.stick_up],    1, new_controller.stick_average.y >  Threshold ? 1 : 0)
                            
                            // @cleanup This is probably vestigial and can safely be removed
                            if (pad.wButtons & XINPUT_GAMEPAD_BACK) != 0 { running = false }
                        } else {
                            new_controller.is_connected = false
                            xbox_controller_present[controller_index] = false
                        }
                    }
                }
            }
                        
            { debug_data_block("Platform")
                
                game.debug_record_b32(&GlobalPause)
                game.debug_record_b32(&GlobalDebugShowCursor)
                game.debug_record_f32(&expected_frames_per_update)
            }

            { debug_data_block("Renderer")
                // game.debug_record_b32(&GlobalDebugRenderSingleThreaded)
                // game.debug_record_b32(&GlobalUseSoftwareRenderer)
                game.debug_record_b32(&GlobalUseVulkanRenderer)
            }
            
            { debug_data_block("Profile")
                { debug_data_block("Memory")
                    game.debug_ui_element(ArenaOccupancy{ &_platform_arena }, "Platform Arena")
                    game.debug_ui_element(ArenaOccupancy{ &_frame_arena }, "Platform Frame Arena")
                }
            }
        }
        ////////////////////////////////////////////////
        { timed_block("game updated")
        
            if !GlobalPause {
                state := &GlobalPlatformState
                if state.recording_index != 0 {
                    record_input(state, new_input)
                }
                
                if state.replaying_index != 0 {
                    replay_input(state, new_input)
                }
                
                if game_dll.is_valid {
                    game.update_and_render(&game_memory, new_input, &render_commands)
                    if new_input.quit_requested {
                        running = false
                    }
                }
            }
        }
        ////////////////////////////////////////////////
        { timed_block("audio update")
            
            if !GlobalPause {
                sound_is_valid = true
                play_cursor, write_cursor: u32
                audio_counter := get_wall_clock()
                from_begin_to_audio := get_seconds_elapsed(last_counter, audio_counter)
                
                if result := direct_sound_buffer->GetCurrentPosition(&play_cursor, &write_cursor); win.SUCCEEDED(result) {
                    /*
                    Here is how sound output computation works.
                    
                    We define a safety value that is the number of samples we think our game update loop
                    may vary by (let's say up to 2ms)
                    
                    When we wake up to write audio, we will look and see what the play cursor position is and we
                    will forecast ahead where we think the play cursor will be on the next frame boundary.
                    
                    We will then look to see if the write cursor is before that by at least our safety value. If
                    it is, the target fill position is that frame boundary plus one frame. This gives us perfect
                    audio sync in the case of a card that has low enough latency.
                    
                    If the write cursor is _after_ that safety margin, then we assume we can never sync the
                    audio perfectly, so we will write one frame's worth of audio plus the safety margin's worth
                    of guard samples.
                    */
                    
                    if !sound_is_valid {
                        sound_output.running_sample_index = write_cursor / sound_output.bytes_per_sample
                        sound_is_valid = true
                    }
                    
                    byte_to_lock := (sound_output.running_sample_index * sound_output.bytes_per_sample) % sound_output.buffer_size
                    
                    expected_sound_bytes_per_frame := cast(u32) (cast(f32)sound_output.bytes_per_sample * cast(f32) sound_output.samples_per_second * target_seconds_per_frame)
                    
                    seconds_left_until_flip := target_seconds_per_frame-from_begin_to_audio
                    expected_sound_bytes_until_flip := cast(u32) (seconds_left_until_flip/target_seconds_per_frame * cast(f32)expected_sound_bytes_per_frame)
                    
                    expected_frame_boundary_byte := play_cursor + expected_sound_bytes_until_flip
                    
                    safe_write_cursor := write_cursor
                    if safe_write_cursor < play_cursor {
                        safe_write_cursor += sound_output.buffer_size
                    }
                    assert(safe_write_cursor >= play_cursor)
                    safe_write_cursor += sound_output.safety_bytes
                    
                    audio_card_is_low_latency := safe_write_cursor < expected_frame_boundary_byte
                    
                    target_cursor: u32
                    if audio_card_is_low_latency {
                        target_cursor = expected_frame_boundary_byte + expected_sound_bytes_per_frame
                    } else {
                        target_cursor = write_cursor + sound_output.safety_bytes + expected_sound_bytes_per_frame
                    }
                    target_cursor %= sound_output.buffer_size
                    
                    bytes_to_write: u32
                    if byte_to_lock > target_cursor {
                        bytes_to_write = target_cursor - byte_to_lock + sound_output.buffer_size
                    } else{
                        bytes_to_write = target_cursor - byte_to_lock
                    }
                    
                    sound_buffer := GameSoundBuffer {
                        samples_per_second = sound_output.samples_per_second,
                        samples            = samples[:align(8, bytes_to_write / sound_output.bytes_per_sample)],
                    }
                    bytes_to_write = auto_cast len(sound_buffer.samples) * sound_output.bytes_per_sample
                    
                    if game_dll.is_valid {
                        game.output_sound_samples(&game_memory, sound_buffer)
                    }
                    
                    fill_sound_buffer(direct_sound_buffer, &sound_output, byte_to_lock, bytes_to_write, sound_buffer)
                } else {
                    sound_is_valid = false
                }
            }
        }
        ////////////////////////////////////////////////
        when INTERNAL {
            game.begin_timed_block("debug collation")
            
            game_memory.reloaded_executable = false
            executable_needs_to_be_reloaded := needs_to_be_reloaded(game_dll)
            if executable_needs_to_be_reloaded {
                // @note clear out the queue, as they may call into unloaded game code
                complete_all_work(&high_queue)
                complete_all_work(&low_queue)
                assert(high_queue.completion_count == high_queue.completion_goal)
                assert(low_queue.completion_count  == low_queue.completion_goal)
                game.debug_set_event_recording(GlobalDebugTable, false)
            }
            
            game.debug_frame_end(&game_memory, new_input^, &render_commands)
            
            if executable_needs_to_be_reloaded {
                timed_block("game hotreload")
                
                // @todo if this is too slow the audio and the whole game will lag
                unload_game_api(&game_dll)
                for _ in 0..<100 {
                    load_game_lib(&game_dll)
                    if game_dll.is_valid { break }
                    win.Sleep(100)
                }
                
                game_memory.reloaded_executable = true
                game.debug_set_event_recording(GlobalDebugTable, game_dll.is_valid)
                
                render_state.game = cast(type_of(render_state.game)) game
            }
            
            if needs_to_be_reloaded(render_dll) {
                timed_block("render hotreload")
                
                // @note clear out the queue, as they may call into unloaded game code
                complete_all_work(&high_queue)
                complete_all_work(&low_queue)
                assert(high_queue.completion_count == high_queue.completion_goal)
                assert(low_queue.completion_count  == low_queue.completion_goal)
                
                if render_dll.is_valid {
                    render.reload_or_shutdown(.Reload)
                    render_dll.is_valid = false
                }
                unload_render_api(&render_dll)
                
                for _ in 0..<100 {
                    api_is_valid, write_time := load_render_lib(&render_dll)
                    if !api_is_valid {
                        win.Sleep(100)
                        continue
                    }
                    
                    window_dc := win.GetDC(window)
                    attached  := render.attach(render_state, window, window_dc, GlobalUseVulkanRenderer ? .Vulkan : .OpenGL)
                    win.ReleaseDC(window, window_dc)
                    
                    if attached {
                        render_dll.is_valid   = true
                        render_dll.write_time = write_time
                    } else {
                        // A state layout/backend mismatch requires a restart.
                        // Remember this build so it is not retried every frame.
                        render_dll.write_time = write_time
                        unload_render_api(&render_dll)
                    }
                    break
                }
            }
            
            game.end_timed_block()
        }
        ////////////////////////////////////////////////
        { timed_block("prepare render")
            
            swap(&new_input, &old_input)
            
            { timed_block("texture downloads")
                begin_ticket_mutex(&texture_op_queue.mutex)
                    first := texture_op_queue.ops.first
                    last  := texture_op_queue.ops.last
                    texture_op_queue.ops = {}
                end_ticket_mutex(&texture_op_queue.mutex)
                
                if last != nil {
                    assert(first != nil)
                    render.manage_textures(last)
                    
                    begin_ticket_mutex(&texture_op_queue.mutex)
                        freelist_free_list(&texture_op_queue.freelist, last, first)
                    end_ticket_mutex(&texture_op_queue.mutex)
                }
            }
        }
        ////////////////////////////////////////////////
        { timed_block("render")
            
            params := Render_Params {
                render_queue     = auto_cast &high_queue,
                frame_allocator  = frame_allocator,
                window_dimension = window_dim,
                software_target  = back_buffer,
                single_threaded  = cast(bool) GlobalDebugRenderSingleThreaded,
            }
            render.render(&render_commands, draw_region, params)
        }
        ////////////////////////////////////////////////
        { timed_block("sleep at frame end")
            
            seconds_elapsed_for_frame := get_seconds_elapsed_until_now(last_counter)
            for seconds_elapsed_for_frame < target_seconds_per_frame {
                seconds_elapsed_for_frame = get_seconds_elapsed_until_now(last_counter)
            }
            
            if seconds_elapsed_for_frame < target_seconds_per_frame {
                // @note Sleep
                if sleep_is_granular {
                    sleep_ms := (target_seconds_per_frame-0.001 - seconds_elapsed_for_frame) * 1000
                    if sleep_ms > 0 { 
                        win.Sleep(cast(u32) sleep_ms)
                    }
                }
                
                test_seconds_elapsed := get_seconds_elapsed_until_now(last_counter)
                if test_seconds_elapsed > target_seconds_per_frame {
                    if test_seconds_elapsed - (desired_scheduler_ms * 0.001) > target_seconds_per_frame {
                        print("Missed sleep - actual % target % over %\n", 
                            view_seconds(seconds_elapsed_for_frame, precision = 3),
                            view_seconds(target_seconds_per_frame, precision = 3),
                            view_seconds(test_seconds_elapsed - desired_scheduler_ms, precision = 3),
                        )
                    }
                }
                
                // @note Busy Waiting
                for seconds_elapsed_for_frame < target_seconds_per_frame {
                    seconds_elapsed_for_frame = get_seconds_elapsed_until_now(last_counter)
                }
            } else {
                // @logging Missed frame, maybe because window was moved
                if seconds_elapsed_for_frame - (desired_scheduler_ms * 0.001) > target_seconds_per_frame {
                    print("Missed frame - actual % target % over %\n",
                        view_seconds(seconds_elapsed_for_frame, precision = 3),
                        view_seconds(target_seconds_per_frame, precision = 3),
                        view_seconds(seconds_elapsed_for_frame - target_seconds_per_frame, precision = 3),
                    )
                }
            }
        }
        ////////////////////////////////////////////////
        if render_dll.is_valid && render_state.backend != .Vulkan {
            timed_block("gl frame display")
            
            device_context := win.GetDC(window)
            defer win.ReleaseDC(window, device_context)
            
            { timed_block("SwapBuffers")
                win.SwapBuffers(device_context)
            }
        }
        ////////////////////////////////////////////////
        
        end_counter := get_wall_clock()
        measured_seconds_per_frame := get_seconds_elapsed(last_counter, end_counter)
        exact_target_frames_per_update     := measured_seconds_per_frame * MonitorRefreshHz
        new_exact_target_frames_per_update := round(i32, exact_target_frames_per_update)
        unused(new_exact_target_frames_per_update)
        
        target_seconds_per_frame = measured_seconds_per_frame
        
        game.frame_marker(measured_seconds_per_frame)
        last_counter = end_counter
    }
    
    ////////////////////////////////////////////////
    // Cleanup and Shutdown
    
    if render_dll.is_valid { render.reload_or_shutdown(.Shutdown) }
    unload_render_api(&render_dll)
    unload_game_api(&game_dll)
}

////////////////////////////////////////////////
// Platform Allocator

PageSize :: 4096 // @todo you can get this from the OS, too!

@(api)
allocate_memory_block :: proc (#any_int size: umm, allocation_flags := Platform_Allocation_Flags{}) -> (result: ^Platform_Memory_Block) {
    total_size := size + size_of(Memory_Block)
    
    base_offset: umm = size_of(Memory_Block)
    protect_offset: umm
    if .check_underflow in allocation_flags {
        total_size = size + 2 * PageSize
        base_offset = 2 * PageSize
        protect_offset = PageSize
    } else if .check_overflow in allocation_flags {
        size_rounded_up := align(PageSize, size)
        total_size = size_rounded_up + 2 * PageSize
        base_offset = PageSize + size_rounded_up - size
        protect_offset = PageSize + size_rounded_up
    }
    
    memory := cast([^] u8) win.VirtualAlloc(nil, cast(uint) total_size, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
    assert(memory != nil)
    
    block := cast(^Memory_Block) memory
    
    if BoundsCheck & allocation_flags != {} {
        old_protect: u32
        protected := cast(bool) win.VirtualProtect(&memory[protect_offset], PageSize, win.PAGE_NOACCESS, &old_protect)
        assert(protected)
    }
    
    block.block.storage          = memory[base_offset:][:size]
    block.block.allocation_flags = allocation_flags
    
    if is_in_loop(&GlobalPlatformState) && .not_restored not_in allocation_flags {
        block.loop_flags += { .allocated_during_loop }
    }
    
    begin_ticket_mutex(&GlobalPlatformState.block_mutex)
    list_prepend(&GlobalPlatformState.block_sentinel, block)
    end_ticket_mutex(&GlobalPlatformState.block_mutex)
    
    result = &block.block
    return result
}

@(api)
deallocate_memory_block :: proc (memory_block: ^Platform_Memory_Block) {
    block := cast(^Memory_Block) memory_block
    
    if is_in_loop(&GlobalPlatformState) {
        block.loop_flags += { .freed_during_loop }
    } else {
        free_memory_block(block)
    }
}

free_memory_block :: proc (block: ^Memory_Block) {
    begin_ticket_mutex(&GlobalPlatformState.block_mutex)
    list_remove(block)
    end_ticket_mutex(&GlobalPlatformState.block_mutex)
    
    ok := cast(bool) win.VirtualFree(block, 0, win.MEM_RELEASE)
    assert(ok)
}

clear_blocks_by_mask :: proc (state: ^PlatformState, mask: Memory_Block_Flags) {
    begin_ticket_mutex(&state.block_mutex)
    defer end_ticket_mutex(&state.block_mutex)
    
    for it := state.block_sentinel.next; it != &state.block_sentinel; {
        block := it
        it = it.next
        
        if (mask & block.loop_flags) == mask {
            assert(mask <= block.loop_flags)
            free_memory_block(block)
        } else {
            assert(!(mask <= block.loop_flags))
            block.loop_flags = {}
        }
    }
}

// @todo only generate this when INTERNAL?
@(api)
debug_get_memory_stats :: proc () -> (result: Debug_Platform_Memory_Stats) {
    state := &GlobalPlatformState
    begin_ticket_mutex(&state.block_mutex)
    defer end_ticket_mutex(&state.block_mutex)
    
    for it := state.block_sentinel.next; it != &state.block_sentinel; it = it.next{
        result.block_count += 1
        result.total_used += it.block.used
        result.total_size += auto_cast len(it.block.storage)
    }
    
    return result
}

////////////////////////////////////////////////   
//  Record and Replay

is_in_loop :: proc (state: ^PlatformState) -> (result: bool) {
    result = state.recording_index != 0 || state.replaying_index != 0
    return result
}

get_record_replay_filepath :: proc (index: i32) -> cstring16 {
    buffer: [64] u8
    return build_exe_path(format_string(buffer[:], "editloop_%.input", index))
}

verify_memory_block_integrity :: proc (state: ^PlatformState) {
    begin_ticket_mutex(&state.block_mutex)
    for source := state.block_sentinel.next; source != &state.block_sentinel; source = source.next {
        if source.block.storage != nil {
            size := safe_truncate(u32, len(source.block.storage))
            unused(size)
        }
    }
    end_ticket_mutex(&state.block_mutex)
}

begin_recording_input :: proc (state: ^PlatformState, index: i32) {
    path := get_record_replay_filepath(index)
    state.recording_handle = win.CreateFileW(path, win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, 0, nil)
    
    if state.recording_handle != win.INVALID_HANDLE {
        state.recording_index = index
        
        begin_ticket_mutex(&state.block_mutex)
        written: u32
        for source := state.block_sentinel.next; source != &state.block_sentinel; source = source.next {
            if .not_restored in source.block.allocation_flags { continue }
            
            base := raw_data(source.block.storage)
            dest := Saved_Memory_Block {
                base = cast(u64) cast(umm) base,
                size = cast(u64) len(source.block.storage),
            }
            
            ok: bool
            ok = cast(bool) win.WriteFile(state.recording_handle, &dest, size_of(dest), &written, nil)
            assert(ok)
            ok = cast(bool) win.WriteFile(state.recording_handle, base, safe_truncate(u32, dest.size), &written, nil)
            assert(ok)
        }
        end_ticket_mutex(&state.block_mutex)
        
        final_block := Saved_Memory_Block {}
        ok := cast(bool) win.WriteFile(state.recording_handle, &final_block, size_of(final_block), &written, nil)
        assert(ok)
    }
}

record_input :: proc (state: ^PlatformState, input: ^Input) {
    bytes_written: u32
    ok := cast(bool) win.WriteFile(state.recording_handle, input, cast(u32) size_of(Input), &bytes_written, nil)
    assert(ok)
}

end_recording_input :: proc (state: ^PlatformState) {
    ok := cast(bool) win.CloseHandle(state.recording_handle)
    assert(ok)
    state.recording_index = 0
}

begin_replaying_input :: proc (state: ^PlatformState, index: i32) {
    clear_blocks_by_mask(state, { .allocated_during_loop })
    
    path := get_record_replay_filepath(index)
    state.replaying_handle = win.CreateFileW(path, win.GENERIC_READ, 0, nil, win.OPEN_EXISTING, 0, nil)
    
    if state.replaying_handle != win.INVALID_HANDLE {
        state.replaying_index = index
        
        read: u32
        for {
            block: Saved_Memory_Block
            ok: bool
            ok = cast(bool) win.ReadFile(state.replaying_handle, &block, size_of(block), &read, nil)
            assert(ok)
            if block.base == 0 { break }
            
            base_pointer := cast(pmm) cast(umm) block.base
            ok = cast(bool) win.ReadFile(state.replaying_handle, base_pointer, safe_truncate(u32, block.size), &read, nil)
            assert(ok)
        }
    }
}

replay_input :: proc (state: ^PlatformState, input: ^Input) {
    bytes_read: u32
    if win.ReadFile(state.replaying_handle, input, cast(u32) size_of(Input), &bytes_read, nil) {
        if bytes_read == 0 {
            // @note we reached the end of the stream go back to beginning
            replay_index := state.replaying_index
            end_replaying_input(state)
            begin_replaying_input(state, replay_index)
            ok := cast(bool) win.ReadFile(state.replaying_handle, input, cast(u32) size_of(Input), &bytes_read, nil)
            assert(ok)
        }
    }
}

end_replaying_input :: proc (state: ^PlatformState) {
    clear_blocks_by_mask(state, { .freed_during_loop })
    
    ok := cast(bool) win.CloseHandle(state.replaying_handle)
    assert(ok)
    state.replaying_index = 0
}

////////////////////////////////////////////////
// Performance Timers

get_wall_clock :: proc () -> i64 {
    result: win.LARGE_INTEGER
    win.QueryPerformanceCounter(&result)
    return cast(i64) result
}

get_seconds_elapsed :: proc (start, end: i64) -> f32 {
    return cast(f32) (cast(f64) (end - start) / GlobalPlatformState.performance_counter_frequency)
}
get_seconds_elapsed_until_now :: proc (start: i64) -> f32 {
    end := get_wall_clock()
    return get_seconds_elapsed(start, end)
}

////////////////////////////////////////////////   
// Sound Buffer

fill_sound_buffer :: proc (buffer: ^IDirectSoundBuffer, sound_output: ^SoundOutput, byte_to_lock, bytes_to_write: u32, source: GameSoundBuffer) {
    timed_function()
    
    samples: [2] [^] Sample
    counts:  [2] u32
    
    if result := buffer->Lock(byte_to_lock, bytes_to_write, cast(^pmm) &samples[0], &counts[0], cast(^pmm) &samples[1], &counts[1], 0); win.SUCCEEDED(result) {
        // @todo assert that region1/2_size is valid
        source_offset: u32
        for destination, index in samples {
            sample_count := counts[index] / sound_output.bytes_per_sample
            
            copy(destination[:sample_count], source.samples[source_offset:])
            source_offset += sample_count
            
            sound_output.running_sample_index += sample_count
        }
        
        buffer->Unlock(samples[0], counts[0], samples[1], counts[1])
    } else {
        // @todo @logging
    }
}

clear_sound_buffer :: proc (buffer: ^IDirectSoundBuffer, sound_output: ^SoundOutput) {
    timed_function()
    
    regions: [2] [^] Sample
    counts:  [2] u32
    
    if result := buffer->Lock(0, sound_output.buffer_size, cast(^pmm) &regions[0], &counts[0], cast(^pmm) &regions[1], &counts[1], 0); win.SUCCEEDED(result) {
        // @todo assert that region1/2_size is valid
        for destination, index in regions {
            sample_count := counts[index] / sound_output.bytes_per_sample
            
            zero(destination[:sample_count])
            sound_output.running_sample_index += sample_count
        }
        
        buffer->Unlock(regions[0], counts[0], regions[1], counts[1])
    } else {
        // @todo @logging
    }
}

////////////////////////////////////////////////   
//  Window Drawing

get_window_dimension :: proc "system" (window: win.HWND, get_window_rect := false) -> v2i {
    client_rect: win.RECT
    if get_window_rect {
        win.GetWindowRect(window, &client_rect)
    } else {
        win.GetClientRect(window, &client_rect)
    }
    dimension: v2i
    dimension.x = client_rect.right  - client_rect.left
    dimension.y = client_rect.bottom - client_rect.top
    return dimension
}

toggle_fullscreen :: proc (window: win.HWND) {
    // @note This follows Raymond Chen's prescription for fullscreen toggling, see:
    // http://blogs.msdn.com/b/oldnewthing/archive/2010/04/12/9994016.aspx
    
    style := cast(u32) win.GetWindowLongW(window, win.GWL_STYLE)
    if style & win.WS_OVERLAPPEDWINDOW != 0 {
        info := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
        if win.GetWindowPlacement(window, &GlobalPlatformState.window_position) && 
            win.GetMonitorInfoW(win.MonitorFromWindow(window, .MONITOR_DEFAULTTOPRIMARY), &info) {
            win.SetWindowLongW(window, win.GWL_STYLE, cast(i32) (style &~ win.WS_OVERLAPPEDWINDOW))
            win.SetWindowPos(window, win.HWND_TOP, 
                info.rcMonitor.left, info.rcMonitor.top,
                info.rcMonitor.right - info.rcMonitor.left,
                info.rcMonitor.bottom - info.rcMonitor.top,
                win.SWP_NOOWNERZORDER | win.SWP_FRAMECHANGED,
            )
        }
    } else {
        win.SetWindowLongW(window, win.GWL_STYLE, cast(i32) (style | win.WS_OVERLAPPEDWINDOW))
        win.SetWindowPlacement(window, &GlobalPlatformState.window_position)
        win.SetWindowPos(window, nil, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_NOOWNERZORDER | win.SWP_FRAMECHANGED)
    }
}

////////////////////////////////////////////////   
//  Windows Messages

main_window_callback :: proc "system" (window: win.HWND, message: win.UINT, w_param: win.WPARAM, l_param: win.LPARAM) -> win.LRESULT {
    result: win.LRESULT
    context = runtime.default_context()
    switch message {
      case win.WM_SYSKEYUP, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_KEYDOWN:
        assert(false, "keyboard-event came in through a non-dispatched event")
        
      case win.WM_CLOSE: // @todo Handle this with a message to the user
        win.PostQuitMessage(0)
        
      case win.WM_DESTROY: // @todo handle this as an error - recreate window?
        win.PostQuitMessage(0)
        
      case win.WM_WINDOWPOSCHANGING:
        new_pos := cast(^win.WINDOWPOS) cast(pmm) cast(umm) l_param
        
        if cast(u16) win.GetKeyState(win.VK_SHIFT) & 0x8000 != 0 {
            window_dim := get_window_dimension(window, true) 
            client_dim := get_window_dimension(window)
            
            added := window_dim - client_dim
            
            render_dim := RenderDimension
            
            new_cx := (new_pos.cy * (render_dim.x - added.x)) / render_dim.y
            new_cy := (new_pos.cx * (render_dim.y - added.y)) / render_dim.x
            
            if abs(new_pos.cx - new_cx) < abs(new_pos.cy - new_cy) {
                new_pos.cx = new_cx + added.x
            } else {
                new_pos.cy = new_cy + added.y
            }
        }
        
        result = win.DefWindowProcW(window, message, w_param, l_param)
        
      case win.WM_ACTIVATEAPP:
        LWA_ALPHA    :: 0x00000002 // Use bAlpha to determine the opacity of the layered window.
        LWA_COLORKEY :: 0x00000001 // Use crKey as the transparency color.
        
        if w_param != 0 {
            win.SetLayeredWindowAttributes(window, win.RGB(0,0,0), 255, LWA_ALPHA)
        } else {
            win.SetLayeredWindowAttributes(window, win.RGB(0,0,0),  64, LWA_ALPHA)
        }
        
      case win.WM_PAINT:
        paint: win.PAINTSTRUCT
        device_context := win.BeginPaint(window, &paint)
        unused(device_context)
        win.EndPaint(window, &paint)
        
      case win.WM_SETCURSOR: 
        if GlobalDebugShowCursor {
            win.SetCursor(win.LoadCursorW(nil, cast(cstring16) win.MAKEINTRESOURCEW(cast(umm) cast(pmm) win.IDC_ARROW)))
        } else {
            win.SetCursor(nil)
        }
        
      case:
        timed_block("win.DefWindowProcW")
        result = win.DefWindowProcW(window, message, w_param, l_param)
    }
    
    return result
}

process_win_keyboard_message :: proc (new_state: ^InputButton, is_down: bool) {
    if is_down != new_state.ended_down {
        new_state.ended_down             = is_down
        new_state.half_transition_count += 1
    }
}

process_pending_messages :: proc (state: ^PlatformState, keyboard_controller: ^InputController, render_state: ^Render_State) -> bool {
    quit_requested: bool
    message: win.MSG
    for {
        // @note We avoid asking for WM_PAINT and WM_MOUSEMOVE messages here so that Windows will not generate them (they are generated on-demand) since we don't actually care about either.
        first  :: min(win.WM_PAINT, win.WM_MOUSEMOVE)
        second :: max(win.WM_PAINT, win.WM_MOUSEMOVE)
        last   :: max(u32)
        
        game.begin_timed_block("win.PeekMessageW")
        has_message := win.PeekMessageW(&message, nil, 0, first - 1, win.PM_REMOVE)
        if !has_message {
            has_message = win.PeekMessageW(&message, nil, first + 1, second - 1, win.PM_REMOVE)
            if !has_message {
                has_message = win.PeekMessageW(&message, nil, second + 1, last, win.PM_REMOVE)
            }
        }
        game.end_timed_block()
        
        if !has_message { break }
        
        switch message.message {
          case win.WM_QUIT:
            quit_requested = true
            
          case win.WM_SYSKEYUP, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_KEYDOWN:
            timed_block("key_message")
            
            vk_code := message.wParam
            
            AltDown   :: 1 << 29
            WasDown   :: 1 << 30
            IsUp      :: 1 << 31
            ShiftDown :: 1 << 15
            alt_down   := (message.lParam & AltDown) != 0
            was_down   := (message.lParam & WasDown) != 0
            is_down    := (message.lParam & IsUp)    == 0
            shift_down := (cast(u16) win.GetKeyState(win.VK_SHIFT) & ShiftDown) != 0
            
            if was_down == is_down { continue }
            
            switch vk_code {
            case win.VK_W:      process_win_keyboard_message(&keyboard_controller.buttons[.stick_up],       is_down)
            case win.VK_A:      process_win_keyboard_message(&keyboard_controller.buttons[.stick_left],     is_down)
            case win.VK_S:      process_win_keyboard_message(&keyboard_controller.buttons[.stick_down],     is_down)
            case win.VK_D:      process_win_keyboard_message(&keyboard_controller.buttons[.stick_right],    is_down)
            case win.VK_Q:      process_win_keyboard_message(&keyboard_controller.buttons[.shoulder_left],  is_down)
            case win.VK_E:      process_win_keyboard_message(&keyboard_controller.buttons[.shoulder_right], is_down)
            case win.VK_UP:     process_win_keyboard_message(&keyboard_controller.buttons[.button_up],      is_down)
            case win.VK_DOWN:   process_win_keyboard_message(&keyboard_controller.buttons[.button_down],    is_down)
            case win.VK_LEFT:   process_win_keyboard_message(&keyboard_controller.buttons[.button_left],    is_down)
            case win.VK_RIGHT:  process_win_keyboard_message(&keyboard_controller.buttons[.button_right],   is_down)
            case win.VK_SPACE:  process_win_keyboard_message(&keyboard_controller.buttons[.start],          is_down)
            case win.VK_ESCAPE: process_win_keyboard_message(&keyboard_controller.buttons[.back],           is_down)
            case win.VK_L:
            if is_down {
                if state.replaying_index != 0 {
                    end_replaying_input(state)
                } else if state.recording_index == 0 {
                    assert(state.replaying_index == 0)
                    begin_recording_input(state, 1) 
                } else {
                    end_recording_input(state)
                    begin_replaying_input(state, 1)
                }
            }
            
            // @note debug keys
            case win.VK_OEM_PLUS:
                if is_down && render_state != nil {
                    if shift_down {
                        render_state.vulkan.debug_light_buffer_index   += 1
                    } else {
                        render_state.vulkan.debug_light_buffer_texture += 1
                    }
                }
            case win.VK_OEM_MINUS: 
                if is_down && render_state != nil {
                    if shift_down {
                        render_state.vulkan.debug_light_buffer_index   -= 1
                    } else {
                        render_state.vulkan.debug_light_buffer_texture -= 1
                    }
                }
            
            case win.VK_F4:     if is_down && alt_down { quit_requested = true }
            case win.VK_RETURN: if is_down && alt_down { toggle_fullscreen(message.hwnd) }
            }
            
          case:
            timed_block("default_message_handler")
            // @todo on a resize or dragging of the window the whole app freezes, for a possible workaround see "Dangerous Threads Crew" https://www.youtube.com/watch?v=_HpGJeJowiY 
            win.TranslateMessage(&message)
            win.DispatchMessageW(&message)
        }
    }
    return quit_requested
}

build_exe_path :: proc (filename: string) -> cstring16 {
    assert(GlobalPlatformState.exe_path != "")
    
    buffer: [256] u8
    path := format_string(buffer[:], `%\%`, GlobalPlatformState.exe_path, filename)
    result := win.utf8_to_wstring(path, context.temp_allocator)
    return result
}

////////////////////////////////////////////////

clear_render_commands :: proc (commands: ^RenderCommands) {
    clear(&commands.push_buffer)
    clear(&commands.vertex_buffer)
    clear(&commands.quad_bitmap_buffer)
}

aspect_ratio_fit :: proc (render_size: v2i, window_size: v2i) -> Rectangle2i {
    result: Rectangle2i
    
    if render_size.x > 0 && render_size.y > 0 && window_size.x > 0 && window_size.y > 0 {
        optimal_window_width  := round(i32, cast(f32) window_size.y * cast(f32) render_size.x / cast(f32) render_size.y)
        optimal_window_height := round(i32, cast(f32) window_size.x * cast(f32) render_size.y / cast(f32) render_size.x)
        
        window_center := window_size / 2
        optimal_window_size: v2i
        if optimal_window_width > window_size.x {
            // Top and Bottom black bars
            optimal_window_size = {window_size.x, optimal_window_height}
        } else {
            // Left and Right black bars
            optimal_window_size = {optimal_window_width, window_size.y}
        }
        
        result = rectangle_center_dimension(window_center, optimal_window_size)
    }
    
    return result
}