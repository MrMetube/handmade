package main

import "core:fmt"
import "core:os" // @todo(viktor): remove this
import win "core:sys/windows"

/*
    @todo(viktor): THIS IS NOT A FINAL PLATFORM LAYER !!!
    - Hardware acceleration (OpenGL or Direct3D or Vulkan or BOTH ?? )
    - Blit speed improvements (BitBlt)
    
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

// Resolution :: [2]i32 {2560, 1440}
Resolution :: [2]i32 {1920, 1080}
// Resolution :: [2]i32 {1280, 720}
// Resolution :: [2]i32 {640, 360}

MonitorRefreshHz :: 120

HighPriorityThreads :: 10
LowPriorityThreads  :: 0

PermanentStorageSize :: 256 * Megabyte
TransientStorageSize ::   1 * Gigabyte
DebugStorageSize     :: 256 * Megabyte when INTERNAL else 0

////////////////////////////////////////////////
//  Globals

GlobalRunning: b32

GlobalBackBuffer:  OffscreenBuffer
GlobalSoundBuffer: ^IDirectSoundBuffer

GlobalPerformanceCounterFrequency: f64

GlobalPause :b32= false

RenderType :: enum {
    RenderOpenGL_DisplayOpenGL,
    RenderSoftware_DisplayGDI,
    RenderSoftware_DisplayOpenGL,
}

GlobalRenderType: RenderType

GlobalDebugShowCursor: b32 = INTERNAL
GlobalWindowPosition := win.WINDOWPLACEMENT{ length = size_of(win.WINDOWPLACEMENT) }

GlobalBlitTextureHandle: u32
BlitVertexArrayObject: u32
BlitVertexBufferObject, BlitTextureCoordinatesVbo: u32


GlobalDebugTable: ^DebugTable = &_GlobalDebugTable
_GlobalDebugTable: DebugTable
DebugTable :: struct {} // Definition in game/debug.odin

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

OffscreenBuffer :: struct {
    info:                 win.BITMAPINFO,
    memory:               []Color,
    width, height, pitch: i32,
}

PlatformState :: struct {
    exe_path: string,
    
    game_memory_block: []u8,
    replay_buffers:    [4]ReplayBuffer,
    
    input_record_handle: win.HANDLE,
    input_record_index:  i32,
    input_replay_handle: win.HANDLE,
    input_replay_index:  i32,
}

ReplayBuffer :: struct {
    filename:     win.wstring,
    filehandle:   win.HANDLE,
    memory_map:   win.HANDLE,
    memory_block: []u8,
}

main :: proc() {
    {
        frequency: win.LARGE_INTEGER
        win.QueryPerformanceFrequency(&frequency)
        GlobalPerformanceCounterFrequency = cast(f64) frequency
    }
    
    ////////////////////////////////////////////////
    // Windows Setup
    
    window: win.HWND
    {
        instance := cast(win.HINSTANCE) win.GetModuleHandleW(nil)
        window_class := win.WNDCLASSW{
            hInstance = instance,
            lpszClassName = win.L("HandmadeWindowClass"),
            style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
            lpfnWndProc = main_window_callback,
            hCursor = win.LoadCursorW(nil, win.MAKEINTRESOURCEW(32512)),
            // hIcon =,
        }
        
        resize_DIB_section(&GlobalBackBuffer, Resolution.x, Resolution.y)
        
        if win.RegisterClassW(&window_class) == 0 {
            return // @logging 
        }

        window = win.CreateWindowExW(
            0, //win.WS_EX_TOPMOST | win.WS_EX_LAYERED,
            window_class.lpszClassName,
            win.L("Handmade"),
            win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
            win.CW_USEDEFAULT,
            win.CW_USEDEFAULT,
            GlobalBackBuffer.width  + 16, // added for the window frame
            GlobalBackBuffer.height + 39,
            nil,
            nil,
            window_class.hInstance,
            nil,
        )
        
        if window == nil {
            // @logging
            return 
        }
    }
    
    ////////////////////////////////////////////////
    // Platform Setup
    
    high_queue, low_queue: PlatformWorkQueue
    high_infos: [HighPriorityThreads]CreateThreadInfo
    low_infos:  [LowPriorityThreads]CreateThreadInfo
    window_dc := win.GetDC(window)
    gl_context := init_opengl(window_dc)
    
    for &info in low_infos {
        info.gl_context = win.wglCreateContextAttribsARB(window_dc, gl_context, &GlAttribs[0])
        assert(info.gl_context != nil)
        info.window_dc  = window_dc
    }
    
    init_work_queue(&high_queue, high_infos[:])
    init_work_queue(&low_queue,  low_infos[:])
    
    fmt.print("\033[2J") // Clear the terminal

    state: PlatformState
    {
        exe_path_buffer: [win.MAX_PATH_WIDE]u16
        size_of_filename  := win.GetModuleFileNameW(nil, &exe_path_buffer[0], win.MAX_PATH_WIDE)
        exe_path_and_name := win.wstring_to_utf8(raw_data(exe_path_buffer[:size_of_filename]), cast(int) size_of_filename) or_else ""
        one_past_last_slash: u32
        for r, i in exe_path_and_name {
            if r == '\\' {
                one_past_last_slash = cast(u32) i + 1
            }
        }
        state.exe_path = exe_path_and_name[:one_past_last_slash]
    }
    
    // @note(viktor): Set the windows scheduler granularity to 1ms so that out win.Sleep can be more granular
    desired_scheduler_ms :: 1
    sleep_is_granular: b32 = win.timeBeginPeriod(desired_scheduler_ms) == win.TIMERR_NOERROR
    
    GlobalRunning = true
    
    ////////////////////////////////////////////////
    //  Video Setup
    
    // @todo(viktor): how do we reliably query this on windows?
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
    target_seconds_per_frame := 1 / game_update_hz
    
    ////////////////////////////////////////////////
    //  Sound Setup
    
    sound_output: SoundOutput
    sound_output.samples_per_second = 48000
    sound_output.num_channels       = 2
    sound_output.bytes_per_sample   = size_of(Sample)
    sound_output.buffer_size        = sound_output.samples_per_second * sound_output.bytes_per_sample
    // @todo(viktor): actually computre this variance and set a reasonable value
    sound_output.safety_bytes = cast(u32) (target_seconds_per_frame * cast(f32)sound_output.samples_per_second * cast(f32)sound_output.bytes_per_sample)
    
    init_dSound(window, sound_output.buffer_size, sound_output.samples_per_second)
    
    clear_sound_buffer(&sound_output)
    
    GlobalSoundBuffer->Play(0, 0, DSBPLAY_LOOPING)
    
    sound_is_valid: b32
    
    ////////////////////////////////////////////////
    //  Input Setup
    
    init_xInput()
    
    // @todo(viktor): Monitor xbox controllers for being plugged in after the fact
    xbox_controller_present: [XUSER_MAX_COUNT]b32 = true
    
    input: [2]Input
    old_input, new_input := &input[0], &input[1]
    
    ////////////////////////////////////////////////
    // Memory Setup

    game_dll_name := build_exe_path(state, "game.dll")
    temp_dll_name := build_exe_path(state, "game_temp.dll")
    lock_name     := build_exe_path(state, "lock.temp")
    game_lib_is_valid, game_dll_write_time := load_game_lib(game_dll_name, temp_dll_name, lock_name)
    // @todo(viktor): make this like sixty seconds?
    // @todo(viktor): pool with bitmap alloc
    // @todo(viktor): remove MaxPossibleOverlap
    MaxPossibleOverlap :: 8 * size_of(Sample)
    samples := cast([^]Sample) win.VirtualAlloc(nil, cast(uint) sound_output.buffer_size + MaxPossibleOverlap, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
    
    // @todo(viktor): @cleanup
    current_sort_memory_size : umm = 1 * Megabyte
    current_clip_memory_size : umm = 256 * Kilobyte
    sort_memory := allocate_memory(current_sort_memory_size)
    clip_memory := allocate_memory(current_clip_memory_size)
    
    // @todo(viktor): decide what our push_buffer size is
    render_commands: RenderCommands
    push_buffer_size :: 32 * Megabyte
    push_buffer := allocate_memory(push_buffer_size)
    
    game_memory := GameMemory{
        high_priority_queue = &high_queue,
        low_priority_queue  = &low_queue,
        
        Platform_api = {
            enqueue_work      = enqueue_work,
            complete_all_work = complete_all_work,
            
            allocate_memory   = allocate_memory,
            deallocate_memory = deallocate_memory,
            
            allocate_texture   = allocate_texture,
            deallocate_texture = deallocate_texture,
            
            begin_processing_all_files_of_type = begin_processing_all_files_of_type,
            end_processing_all_files_of_type   = end_processing_all_files_of_type,
            open_next_file                     = open_next_file,
            read_data_from_file                = read_data_from_file,
            mark_file_error                    = mark_file_error,
        },
    }
    
    { // @note(viktor): initialize game_memory
        base_address := cast(pmm) cast(umm) (1 * Terabyte when INTERNAL else 0)
        
        total_size := cast(uint) (PermanentStorageSize + TransientStorageSize + DebugStorageSize)
        
        storage_ptr := cast([^]u8) win.VirtualAlloc(base_address, total_size, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
        state.game_memory_block = storage_ptr[:total_size]
        
        // @todo(viktor): TransientStorage needs to be broken up
        // into game transient and cache transient, and only
        // the former need be saved for state playback.
        for &buffer, index in state.replay_buffers {
            buffer.filename   = get_record_replay_filepath(state, cast(i32) index)
            buffer.filehandle = win.CreateFileW(buffer.filename, win.GENERIC_READ|win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, 0, nil)
            
            size_high := cast(win.DWORD)(total_size >> 32)
            size_low  := cast(win.DWORD)total_size
            buffer.memory_map = win.CreateFileMappingW(buffer.filehandle, nil, win.PAGE_READWRITE, size_high, size_low, nil)
            
            buffer_storage_ptr := cast([^]u8) win.MapViewOfFile(buffer.memory_map, win.FILE_MAP_ALL_ACCESS, 0, 0, total_size)
            if buffer_storage_ptr != nil {
                buffer.memory_block = buffer_storage_ptr[:total_size]
            } else {
                // @logging 
            }
        }
        
        // :PointerArithmetic
        game_memory.permanent_storage = storage_ptr[0 :][: PermanentStorageSize]
        game_memory.transient_storage = storage_ptr[PermanentStorageSize :][: TransientStorageSize]
        game_memory.debug_storage     = storage_ptr[TransientStorageSize :][: DebugStorageSize]
        
        game_memory.debug_table = cast(^DebugTable) allocate_memory(DebugTableSize)
        
        when INTERNAL {
            game_memory.Platform_api.debug = {
                read_entire_file       = DEBUG_read_entire_file,
                write_entire_file      = DEBUG_write_entire_file,
                free_file_memory       = DEBUG_free_file_memory,
                execute_system_command = DEBUG_execute_system_command,
                get_process_state      = DEBUG_get_process_state,
            }
        }
    }
    
    if samples == nil || game_memory.permanent_storage == nil || game_memory.transient_storage == nil {
        assert(false)
        return // @logging 
    }
    
    ////////////////////////////////////////////////
    //  Timer Setup
    
    last_counter := get_wall_clock()
    flip_counter := get_wall_clock()
    
    ////////////////////////////////////////////////
    //  Game Loop
        
    for GlobalRunning {
        { game.debug_begin_data_block("Platform"); defer game.debug_end_data_block()
            
            game.debug_record_b32(&GlobalPause)
            game.debug_record_b32(&GlobalDebugShowCursor)
            game.debug_record_b32(cast(^b32) &GlobalRenderType, "RenderType")
        }
        
        ////////////////////////////////////////////////   
        //  Input
        input_processed := game.begin_timed_block("input processed")
        
        {
            new_input.delta_time = target_seconds_per_frame
            
            is_down :: proc(vk: win.INT) -> b32 {
                is_down_mask :: min(i16) // 1 << 15
                return cast(b32) (win.GetKeyState(vk)  & is_down_mask)
            }
            
            { // Modifiers
                new_input.shift_down   = is_down(win.VK_LSHIFT)
                new_input.control_down = is_down(win.VK_CONTROL)
                new_input.alt_down     = is_down(win.VK_MENU)
            }
            
            { // Mouse Input 
                mouse_input := game.begin_timed_block("mouse_input")
                defer game.end_timed_block(mouse_input)
                
                mouse: win.POINT
                win.GetCursorPos(&mouse)
                win.ScreenToClient(window, &mouse)
                
                new_input.mouse.p = vec_cast(f32, mouse.x, GlobalBackBuffer.height - 1 - mouse.y)
                for &button, index in new_input.mouse.buttons {
                    button.ended_down = old_input.mouse.buttons[index].ended_down
                    button.half_transition_count = 0
                }
                
                // @todo(viktor): support mouse wheel
                new_input.mouse.wheel = 0
                // @todo(viktor): Do we need to update the input button on every event?
                process_win_keyboard_message(&new_input.mouse.left,   is_down(win.VK_LBUTTON))
                process_win_keyboard_message(&new_input.mouse.right,  is_down(win.VK_RBUTTON))
                process_win_keyboard_message(&new_input.mouse.middle, is_down(win.VK_MBUTTON))
                process_win_keyboard_message(&new_input.mouse.extra1, is_down(win.VK_XBUTTON1))
                process_win_keyboard_message(&new_input.mouse.extra2, is_down(win.VK_XBUTTON2))
            }
            
            { // Keyboard Input
                keyboard_input := game.begin_timed_block("keyboard_input")
                defer game.end_timed_block(keyboard_input)
                
                old_keyboard_controller := &old_input.controllers[0]
                new_keyboard_controller := &new_input.controllers[0]
                new_keyboard_controller^ = {}
                new_keyboard_controller.is_connected = true
                
                for &button, index in new_keyboard_controller.buttons {
                    button.ended_down = old_keyboard_controller.buttons[index].ended_down
                }
                
                process_pending_messages(&state, new_keyboard_controller)
            }

            max_controller_count: u32 = min(XUSER_MAX_COUNT, len(Input{}.controllers) - 1)
            // @todo(viktor): Need to not poll disconnected controllers to avoid xinput frame rate hit
            // on older libraries.
            // @todo(viktor): should we poll this more frequently
            // @todo(viktor): only check connected controllers, catch messages on connect / disconnect
            controller_input := game.begin_timed_block("controller_input")
            defer game.end_timed_block(controller_input)
            
            for controller_index in 0..<max_controller_count {
                controller_state: XINPUT_STATE
                
                our_controller_index := controller_index+1
                
                old_controller := old_input.controllers[our_controller_index]
                new_controller := &new_input.controllers[our_controller_index]
                
                if xbox_controller_present[controller_index] && XInputGetState(controller_index, &controller_state) == win.ERROR_SUCCESS {
                    new_controller.is_connected = true
                    new_controller.is_analog = old_controller.is_analog
                    // @todo(viktor): see if dwPacketNumber increments too rapidly
                    pad := controller_state.Gamepad
                    
                    process_Xinput_button :: proc(new_state: ^InputButton, old_state: InputButton, xInput_button_state: win.WORD, button_bit: win.WORD) {
                        new_state.ended_down = cast(b32) (xInput_button_state & button_bit)
                        new_state.half_transition_count = (old_state.ended_down == new_state.ended_down) ? 1 : 0
                    }
                    
                    process_Xinput_button(&new_controller.button_up    , old_controller.button_up    , pad.wButtons, XINPUT_GAMEPAD_Y)
                    process_Xinput_button(&new_controller.button_down  , old_controller.button_down  , pad.wButtons, XINPUT_GAMEPAD_A)
                    process_Xinput_button(&new_controller.button_left  , old_controller.button_left  , pad.wButtons, XINPUT_GAMEPAD_X)
                    process_Xinput_button(&new_controller.button_right , old_controller.button_right , pad.wButtons, XINPUT_GAMEPAD_B)
                    
                    process_Xinput_button(&new_controller.start, old_controller.start, pad.wButtons, XINPUT_GAMEPAD_START)
                    process_Xinput_button(&new_controller.back, old_controller.back, pad.wButtons, XINPUT_GAMEPAD_BACK)
                    
                    process_Xinput_button(&new_controller.shoulder_left , old_controller.shoulder_left , pad.wButtons, XINPUT_GAMEPAD_LEFT_SHOULDER)
                    process_Xinput_button(&new_controller.shoulder_right, old_controller.shoulder_right, pad.wButtons, XINPUT_GAMEPAD_RIGHT_SHOULDER)
                    
                    process_Xinput_button(&new_controller.dpad_up    , old_controller.dpad_up    , pad.wButtons, XINPUT_GAMEPAD_DPAD_UP)
                    process_Xinput_button(&new_controller.dpad_down  , old_controller.dpad_down  , pad.wButtons, XINPUT_GAMEPAD_DPAD_DOWN)
                    process_Xinput_button(&new_controller.dpad_left  , old_controller.dpad_left  , pad.wButtons, XINPUT_GAMEPAD_DPAD_LEFT)
                    process_Xinput_button(&new_controller.dpad_right , old_controller.dpad_right , pad.wButtons, XINPUT_GAMEPAD_DPAD_RIGHT)
                    
                    process_Xinput_button(&new_controller.thumb_left , old_controller.thumb_left , pad.wButtons, XINPUT_GAMEPAD_LEFT_THUMB)
                    process_Xinput_button(&new_controller.thumb_right, old_controller.thumb_right, pad.wButtons, XINPUT_GAMEPAD_RIGHT_THUMB)
                    
                    process_Xinput_stick :: proc(thumbstick: win.SHORT, deadzone: i16) -> f32 {
                        if thumbstick < -deadzone {
                            return cast(f32) (thumbstick + deadzone) / (32768 - cast(f32) deadzone)
                        } else if thumbstick > deadzone {
                            return cast(f32) (thumbstick - deadzone) / (32767 - cast(f32) deadzone)
                        }
                        return 0
                    }
                    
                    // @todo(viktor): right stick, triggers
                    // @todo(viktor): This is a square deadzone, check XInput to
                    // verify that the deadzone is "round" and show how to do
                    // round deadzone processing.
                    new_controller.stick_average = {
                        process_Xinput_stick(pad.sThumbLX, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE),
                        process_Xinput_stick(pad.sThumbLY, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE),
                    }
                    if new_controller.stick_average != {0,0} do new_controller.is_analog = true
                    
                    // @todo(viktor): what if we don't want to override the stick
                    if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_RIGHT) { new_controller.stick_average.x =  1; new_controller.is_analog = false }
                    if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_LEFT)  { new_controller.stick_average.x = -1; new_controller.is_analog = false }
                    if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_UP)    { new_controller.stick_average.y =  1; new_controller.is_analog = false }
                    if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_DOWN)  { new_controller.stick_average.y = -1; new_controller.is_analog = false }
                    
                    Threshold :: 0.5
                    process_Xinput_button(&new_controller.stick_left , old_controller.stick_left , 1, new_controller.stick_average.x < -Threshold ? 1 : 0)
                    process_Xinput_button(&new_controller.stick_right, old_controller.stick_right, 1, new_controller.stick_average.x >  Threshold ? 1 : 0)
                    process_Xinput_button(&new_controller.stick_down , old_controller.stick_down , 1, new_controller.stick_average.y < -Threshold ? 1 : 0)
                    process_Xinput_button(&new_controller.stick_up   , old_controller.stick_up   , 1, new_controller.stick_average.y >  Threshold ? 1 : 0)
                    
                    if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_BACK) do GlobalRunning = false
                } else {
                    new_controller.is_connected = false
                    xbox_controller_present[controller_index] = false
                }
            }
        }
        
        game.end_timed_block(input_processed)
        ////////////////////////////////////////////////
        //  Update and Render
        game_updated := game.begin_timed_block("game updated")
        
        init_render_commands(&render_commands, push_buffer_size, push_buffer, GlobalBackBuffer.width, GlobalBackBuffer.height)
        
        if !GlobalPause {
            if state.input_record_index != 0 {
                record_input(&state, new_input)
            }
            
            if state.input_replay_index != 0 {
                replay_input(&state, new_input)
            }
            
            if game_lib_is_valid {
                game.update_and_render(&game_memory, new_input^, &render_commands)
            }
        }
        
        game.end_timed_block(game_updated)
        ////////////////////////////////////////////////
        // Sound Output
        audio_update := game.begin_timed_block("audio update")
        
        if !GlobalPause {
            sound_is_valid = true
            play_cursor, write_cursor: win.DWORD
            audio_counter := get_wall_clock()
            from_begin_to_audio := get_seconds_elapsed(flip_counter, audio_counter)

            if result := GlobalSoundBuffer->GetCurrentPosition(&play_cursor, &write_cursor); win.SUCCEEDED(result) {
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
                expected_sound_bytes_until_flip := cast(win.DWORD) (seconds_left_until_flip/target_seconds_per_frame * cast(f32)expected_sound_bytes_per_frame)
                
                expected_frame_boundary_byte := play_cursor + expected_sound_bytes_until_flip
                
                safe_write_cursor := write_cursor
                if safe_write_cursor < play_cursor {
                    safe_write_cursor += sound_output.buffer_size
                }
                assert(safe_write_cursor >= play_cursor)
                safe_write_cursor += sound_output.safety_bytes
                
                audio_card_is_low_latency := safe_write_cursor < expected_frame_boundary_byte
                
                target_cursor: win.DWORD
                if audio_card_is_low_latency {
                    target_cursor = expected_frame_boundary_byte + expected_sound_bytes_per_frame
                } else {
                    target_cursor = write_cursor + sound_output.safety_bytes + expected_sound_bytes_per_frame
                }
                target_cursor %= sound_output.buffer_size
                
                bytes_to_write: win.DWORD
                if byte_to_lock > target_cursor {
                    bytes_to_write = target_cursor - byte_to_lock + sound_output.buffer_size
                } else{
                    bytes_to_write = target_cursor - byte_to_lock
                }
                
                sound_buffer := GameSoundBuffer{
                    samples_per_second = sound_output.samples_per_second,
                    samples = samples[:align8(bytes_to_write/sound_output.bytes_per_sample)],
                }
                bytes_to_write = auto_cast len(sound_buffer.samples) * sound_output.bytes_per_sample
                
                if game_lib_is_valid {
                    game.output_sound_samples(&game_memory, sound_buffer)
                }
                
                fill_sound_buffer(&sound_output, byte_to_lock, bytes_to_write, sound_buffer)
            } else {
                sound_is_valid = false
            }
        }
        
        game.end_timed_block(audio_update)
        ////////////////////////////////////////////////
        when INTERNAL {
            debug_colation := game.begin_timed_block("debug colation")
            
            game_memory.reloaded_executable = false
            executable_needs_to_be_reloaded := get_last_write_time(game_dll_name) != game_dll_write_time
            if executable_needs_to_be_reloaded {
                // @note(viktor): clear out the queue, as they may call into unloaded game code
                complete_all_work(&high_queue)
                complete_all_work(&low_queue)
                assert(high_queue.completion_count == high_queue.completion_goal)
                assert(low_queue.completion_count  == low_queue.completion_goal)
                game.debug_set_event_recording(false)
            }
            
            game.debug_frame_end(&game_memory, new_input^, &render_commands)
                        
            if executable_needs_to_be_reloaded {
                // @todo(viktor): if this is too slow the audio and the whole game will lag
                unload_game_lib()

                for attempt in 0..<100 {
                    game_lib_is_valid, game_dll_write_time = load_game_lib(game_dll_name, temp_dll_name, lock_name)
                    if game_lib_is_valid do break
                    win.Sleep(100)
                }
                
                game_memory.reloaded_executable = true
                game.debug_set_event_recording(game_lib_is_valid, GlobalDebugTable)
            }
            
            game.end_timed_block(debug_colation)
        }
        ////////////////////////////////////////////////
        frame_end_sleep := game.begin_timed_block("frame end sleep")
        {
            seconds_elapsed_for_frame := get_seconds_elapsed(last_counter, get_wall_clock())
            for seconds_elapsed_for_frame < target_seconds_per_frame && !do_next_work_queue_entry(&low_queue) {
                seconds_elapsed_for_frame = get_seconds_elapsed(last_counter, get_wall_clock())
            }
            
            if seconds_elapsed_for_frame < target_seconds_per_frame {
                if sleep_is_granular {
                    sleep_ms := (target_seconds_per_frame-0.001 - seconds_elapsed_for_frame) * 1000
                    if sleep_ms > 0 { 
                        win.Sleep(cast(u32) sleep_ms)
                    }
                }
                test_seconds_elapsed := get_seconds_elapsed(last_counter, get_wall_clock())
                
                if test_seconds_elapsed < target_seconds_per_frame {
                    // @logging sleep missed
                    fmt.println("Sleep missed")
                }
                for seconds_elapsed_for_frame < target_seconds_per_frame {
                    seconds_elapsed_for_frame = get_seconds_elapsed(last_counter, get_wall_clock())
                }
            } else {
                // @logging Missed frame, maybe because window was moved
                fmt.println("Missed frame")
            }
        }
        
        game.end_timed_block(frame_end_sleep)
        ////////////////////////////////////////////////
        frame_display := game.begin_timed_block("frame display")
        
        {
            window_width, window_height := get_window_dimension(window)
            device_context := win.GetDC(window)
            
            needed_sort_memory_size := cast(umm) (render_commands.push_buffer_element_count * size_of(SortEntry) )
            if needed_sort_memory_size > current_sort_memory_size {
                deallocate_memory(sort_memory)
                current_sort_memory_size = needed_sort_memory_size
                sort_memory = allocate_memory(needed_sort_memory_size)
            }
            // @copypasta
            needed_clip_memory_size := cast(umm) (render_commands.push_buffer_element_count * size_of(RenderEntryClip) )
            if needed_clip_memory_size > current_clip_memory_size {
                deallocate_memory(clip_memory)
                current_clip_memory_size = needed_clip_memory_size
                clip_memory = allocate_memory(needed_clip_memory_size)
            }
            
            render := game.begin_timed_block("render")
            render_to_window(&render_commands, &high_queue, device_context, window_width, window_height, sort_memory, clip_memory)
            game.end_timed_block(render)
            
            win.ReleaseDC(window, device_context)
            
            flip_counter = get_wall_clock()
        }
        
        game.end_timed_block(frame_display)
        ////////////////////////////////////////////////
        swap(&new_input, &old_input)
        
        end_counter := get_wall_clock()
        game.frame_marker(get_seconds_elapsed(last_counter, end_counter))
        last_counter = end_counter
    }
}

////////////////////////////////////////////////

render_to_window :: proc(commands: ^RenderCommands, render_queue: ^PlatformWorkQueue, device_context: win.HDC, window_width, window_height: i32, sort_memory, clip_memory: pmm) {
    sort_render_elements(commands, sort_memory)
    linearize_clip_rects(commands, clip_memory)
    /* 
        if all_assets_valid(&render_group) /* AllResourcesPresent :CutsceneEpisodes */ {
            render_group_to_output(tran_state.high_priority_queue, render_group, buffer, &tran_state.arena)
        }
    */
    
    if GlobalRenderType == .RenderOpenGL_DisplayOpenGL {
        gl_render_commands(commands, window_width, window_height)
        win.SwapBuffers(device_context)
    } else {
        offscreen_buffer := Bitmap{
            memory = GlobalBackBuffer.memory,
            width  = GlobalBackBuffer.width,
            height = GlobalBackBuffer.height,
        }
        
        software_render_commands(render_queue, commands, offscreen_buffer)
        
        if GlobalRenderType == .RenderSoftware_DisplayGDI {
            display_bitmap_gdi(&GlobalBackBuffer, device_context, window_width, window_height)
        } else {
            display_bitmap_gl(window_width, window_height, offscreen_buffer, device_context)
        }
    }
}

display_bitmap_gdi :: proc(buffer: ^OffscreenBuffer, device_context: win.HDC, window_width, window_height: i32) {
    #no_bounds_check if true {
        for y in 0..<buffer.height {
            row := buffer.memory[y * buffer.width:][:buffer.width]
            for &useful_color in row {
                // @note(viktor): Windows expects the color to be ordered like this:
                // struct{ b, g, r, pad: u8 }
                useful_color.r, useful_color.b = useful_color.b, useful_color.r
            }
        }
    }
    
    offset := [2]i32{window_width - buffer.width, window_height - buffer.height} / 2

    win.PatBlt(device_context, 0, 0, buffer.width+offset.x*2, offset.y,         win.BLACKNESS )
    win.PatBlt(device_context, 0, offset.y, offset.x, buffer.height+offset.y*2, win.BLACKNESS )
    
    win.PatBlt(device_context, buffer.width+offset.x, 0, window_width, window_height,             win.BLACKNESS )
    win.PatBlt(device_context, 0, buffer.height+offset.y, buffer.width+offset.x*2, window_height, win.BLACKNESS )
    
    // @todo(viktor): aspect ratio correction
    // @todo(viktor): stretch to fill window once we are fine with our renderer
    win.StretchDIBits(
        device_context,
        offset.x, offset.y, buffer.width, buffer.height,
        0, 0, buffer.width, buffer.height,
        raw_data(buffer.memory),
        &buffer.info,
        win.DIB_RGB_COLORS,
        win.SRCCOPY,
    )
}

////////////////////////////////////////////////
// Exports to the game

allocate_memory : PlatformAllocateMemory : proc(#any_int size: u64) -> (result: pmm) {
    result = win.VirtualAlloc(nil, cast(uint) size, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
    return result
}

deallocate_memory : PlatformDeallocateMemory : proc(memory: pmm) {
    win.VirtualFree(memory, 0, win.MEM_RELEASE)
}

////////////////////////////////////////////////
// Performance Timers

get_wall_clock :: proc() -> i64 {
    result: win.LARGE_INTEGER
    win.QueryPerformanceCounter(&result)
    return cast(i64) result
}

get_seconds_elapsed :: proc(start, end: i64) -> f32 {
    return cast(f32) (cast(f64) (end - start) / GlobalPerformanceCounterFrequency)
}

////////////////////////////////////////////////   
//  Record and Replay

get_record_replay_filepath :: proc(state: PlatformState, index:i32) -> win.wstring {
    return build_exe_path(state, fmt.tprintf("editloop_%d.input", index))
}

begin_recording_input :: proc(state: ^PlatformState, input_recording_index: i32) {
    replay_buffer := state.replay_buffers[input_recording_index]
    
    if replay_buffer.memory_block != nil {
        state.input_record_index = input_recording_index
        state.input_record_handle = replay_buffer.filehandle
        // @todo(viktor): this is slow on the first start
        file_position := cast(win.LARGE_INTEGER) len(state.game_memory_block)
        win.SetFilePointerEx(state.input_record_handle, file_position, nil, win.FILE_BEGIN)
        
        copy_slice(replay_buffer.memory_block, state.game_memory_block)
    }
}

record_input :: proc(state: ^PlatformState, input: ^Input) {
    bytes_written: u32
    win.WriteFile(state.input_record_handle, input, cast(u32) size_of(Input), &bytes_written, nil)
}

end_recording_input :: proc(state: ^PlatformState) {
    state.input_record_index = 0
}

begin_replaying_input :: proc(state: ^PlatformState, input_replaying_index: i32) {
    replay_buffer := state.replay_buffers[input_replaying_index]
    
    if replay_buffer.memory_block != nil {
        state.input_replay_index = input_replaying_index
        state.input_replay_handle = replay_buffer.filehandle
        
        file_position := cast(win.LARGE_INTEGER) len(state.game_memory_block)
        win.SetFilePointerEx(state.input_replay_handle, file_position, nil, win.FILE_BEGIN)
        
        copy(state.game_memory_block, replay_buffer.memory_block)
    }
}

replay_input :: proc(state: ^PlatformState, input: ^Input) {
    bytes_read: u32
    win.ReadFile(state.input_replay_handle, input, cast(u32) size_of(Input), &bytes_read, nil)
    if bytes_read != 0 {
        // @note(viktor): there is still input
    } else {
        // @note(viktor): we reached the end of the stream go back to beginning
        replay_index := state.input_replay_index
        end_replaying_input(state)
        begin_replaying_input(state, replay_index)
        win.ReadFile(state.input_replay_handle, input, cast(u32) size_of(Input), &bytes_read, nil)
    }
}

end_replaying_input :: proc(state: ^PlatformState) {
    state.input_replay_index = 0
}

////////////////////////////////////////////////   
//  Sound Buffer

fill_sound_buffer :: proc(sound_output: ^SoundOutput, byte_to_lock, bytes_to_write: u32, source: GameSoundBuffer) {
    region1, region2: pmm
    region1_size, region2_size: win.DWORD
    
    if result := GlobalSoundBuffer->Lock(byte_to_lock, bytes_to_write, &region1, &region1_size, &region2, &region2_size, 0); win.SUCCEEDED(result) {
        // @todo(viktor): assert that region1/2_size is valid
        // @todo(viktor): Collapse these two loops
        
        dest_samples := cast([^]Sample) region1
        region1_sample_count := region1_size / sound_output.bytes_per_sample
        
        source_sample_index := 0
        
        for dest_sample_index in 0..<region1_sample_count {
            assert(source_sample_index < len(source.samples))
            
            dest_samples[dest_sample_index] = source.samples[source_sample_index]
            
            source_sample_index += 1
            sound_output.running_sample_index += 1
        }
        
        dest_samples = cast([^]Sample) region2
        region2_sample_count := region2_size / sound_output.bytes_per_sample
        
        for dest_sample_index in 0..<region2_sample_count {
            assert(source_sample_index < len(source.samples))
            
            dest_samples[dest_sample_index] = source.samples[source_sample_index]
            
            source_sample_index += 1
            sound_output.running_sample_index += 1
        }
        
        GlobalSoundBuffer->Unlock(region1, region1_size, region2, region2_size)
    } else {
        return // @todo(viktor): Logging
    }
}

clear_sound_buffer :: proc(sound_output: ^SoundOutput) {
    region1, region2 : pmm
    region1_size, region2_size: win.DWORD
    
    if result := GlobalSoundBuffer->Lock(0, sound_output.buffer_size , &region1, &region1_size, &region2, &region2_size, 0); win.SUCCEEDED(result) {
        // @todo(viktor): assert that region1/2_size is valid
        // @todo(viktor): Collapse these two loops
        // @todo(viktor): Copy pasta of fill_sound_buffer
        
        dest_samples := cast([^]u8) region1
        for index in 0..<region1_size {
            dest_samples[index] = 0
        }
        sound_output.running_sample_index += region1_size
        
        dest_samples = cast([^]u8) region2
        for index in 0..<region2_size {
            dest_samples[index] = 0
        }
        sound_output.running_sample_index += region2_size
        
        GlobalSoundBuffer->Unlock(region1, region1_size, region2, region2_size)
    } else {
        return // @todo(viktor): @logging
    }
}

////////////////////////////////////////////////   
//  Window Drawing

get_window_dimension :: proc "system" (window: win.HWND) -> (width, height: i32) {
    client_rect: win.RECT
    win.GetClientRect(window, &client_rect)
    width  = client_rect.right  - client_rect.left
    height = client_rect.bottom - client_rect.top
    return width, height
}

resize_DIB_section :: proc "system" (buffer: ^OffscreenBuffer, width, height: i32) {
    // @todo(viktor): Bulletproof this.
    // Maybe don't free first, free after, then free first if that fails.
    if buffer.memory != nil {
        win.VirtualFree(raw_data(buffer.memory), 0, win.MEM_RELEASE)
    }
    
    buffer.width  = width
    buffer.height = height
    
    /* When the biHeight field is negative, this is the clue to
    Windows to treat this bitmap as top-down, not bottom-up, meaning that
    the first three bytes of the image are the color for the top left pixel
    in the bitmap, not the bottom left! */
    buffer.info = win.BITMAPINFO{
        bmiHeader = {
            biSize          = size_of(buffer.info.bmiHeader),
            biWidth         = buffer.width,
            biHeight        = buffer.height,
            biPlanes        = 1,
            biBitCount      = 32,
            biCompression   = win.BI_RGB,
        },
    }
    
    bytes_per_pixel :: 4
    buffer.pitch = align16(buffer.width)
    bitmap_memory_size := buffer.pitch * buffer.height * bytes_per_pixel
    buffer_ptr := cast([^]Color) win.VirtualAlloc(nil, win.SIZE_T(bitmap_memory_size), win.MEM_COMMIT, win.PAGE_READWRITE)
    buffer.memory = buffer_ptr[:buffer.width*buffer.height]
    
    // @todo(viktor): probably clear this to black
}

toggle_fullscreen :: proc(window: win.HWND) {
    // @note(viktor): This follows Raymond Chen's prescription for fullscreen toggling, see:
    // http://blogs.msdn.com/b/oldnewthing/archive/2010/04/12/9994016.aspx

    style := cast(u32) win.GetWindowLongW(window, win.GWL_STYLE)
    if style & win.WS_OVERLAPPEDWINDOW != 0 {
        info := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
        if win.GetWindowPlacement(window, &GlobalWindowPosition) && 
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
        win.SetWindowPlacement(window, &GlobalWindowPosition)
        win.SetWindowPos(window, nil, 0, 0, 0, 0, 
            win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | 
            win.SWP_NOOWNERZORDER | win.SWP_FRAMECHANGED
        )
    }
}

////////////////////////////////////////////////   
//  Windows Messages

main_window_callback :: proc "system" (window: win.HWND, message: win.UINT, w_param: win.WPARAM, l_param: win.LPARAM) -> (result: win.LRESULT) {
    switch message {
      case win.WM_SYSKEYUP, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_KEYDOWN:
        assert_contextless(false, "keyboard-event came in through a non-dispatched event")
      case win.WM_CLOSE: // @todo(viktor): Handle this with a message to the user
        GlobalRunning = false
      case win.WM_DESTROY: // @todo(viktor): handle this as an error - recreate window?
        GlobalRunning = false
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
        
        when false {
            window_width, window_height := get_window_dimension(window)
            render_to_window(&GlobalBackBuffer, device_context, window_width, window_height)
        }
        win.EndPaint(window, &paint)
      case win.WM_SETCURSOR: 
        if !GlobalDebugShowCursor {
            win.SetCursor(nil)
        }
      case:
        result = win.DefWindowProcA(window, message, w_param, l_param)
    }
    return result
}
        
process_win_keyboard_message :: proc(new_state: ^InputButton, is_down: b32) {
    if is_down != new_state.ended_down {
        new_state.ended_down = is_down
        new_state.half_transition_count += 1
    }
}

process_pending_messages :: proc(state: ^PlatformState, keyboard_controller: ^InputController) {
    message: win.MSG
    for {
        peek_message := game.begin_timed_block("peek_message")
        has_message := win.PeekMessageW(&message, nil, 0, 0, win.PM_REMOVE)
        game.end_timed_block(peek_message)
        if !has_message do break
        
        switch message.message {
          case win.WM_QUIT:
            GlobalRunning = false
          case win.WM_SYSKEYUP, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_KEYDOWN:
            key_message := game.begin_timed_block("key_message")
            defer game.end_timed_block(key_message)
            vk_code := message.wParam
            
            was_down := cast(b32) (message.lParam & (1 << 30))
            is_down: b32 = !(cast(b32) (message.lParam & (1 << 31)))
            
            alt_down := cast(b32) (message.lParam & (1 << 29))
            
            if was_down != is_down {
                switch vk_code {
                  case win.VK_W:      process_win_keyboard_message(&keyboard_controller.stick_up,       is_down)
                  case win.VK_A:      process_win_keyboard_message(&keyboard_controller.stick_left,     is_down)
                  case win.VK_S:      process_win_keyboard_message(&keyboard_controller.stick_down,     is_down)
                  case win.VK_D:      process_win_keyboard_message(&keyboard_controller.stick_right,    is_down)
                  case win.VK_Q:      process_win_keyboard_message(&keyboard_controller.shoulder_left,  is_down)
                  case win.VK_E:      process_win_keyboard_message(&keyboard_controller.shoulder_right, is_down)
                  case win.VK_UP:     process_win_keyboard_message(&keyboard_controller.button_up,      is_down)
                  case win.VK_DOWN:   process_win_keyboard_message(&keyboard_controller.button_down,    is_down)
                  case win.VK_LEFT:   process_win_keyboard_message(&keyboard_controller.button_left,    is_down)
                  case win.VK_RIGHT:  process_win_keyboard_message(&keyboard_controller.button_right,   is_down)
                  case win.VK_SPACE:  process_win_keyboard_message(&keyboard_controller.start,          is_down)
                  case win.VK_ESCAPE: process_win_keyboard_message(&keyboard_controller.back,           is_down)
                  case win.VK_L:
                    if is_down {
                        if state.input_replay_index != 0 {
                            end_replaying_input(state)
                        } else if state.input_record_index == 0 {
                            assert(state.input_replay_index == 0)
                            begin_recording_input(state, 1) 
                        } else {
                            end_recording_input(state)
                            begin_replaying_input(state, 1)
                        }
                    }
                  case win.VK_P:
                    if is_down do GlobalPause = !GlobalPause
                  case win.VK_F4:
                    if is_down && alt_down do GlobalRunning = false
                  case win.VK_RETURN:
                    if is_down && alt_down do toggle_fullscreen(message.hwnd)
                }
            }
          case:
            default_message_handler := game.begin_timed_block("default_message_handler")
            defer game.end_timed_block(default_message_handler)
            win.TranslateMessage(&message)
            win.DispatchMessageW(&message)
        }
    }
}

build_exe_path :: proc(state: PlatformState, filename: string) -> win.wstring {
    return win.utf8_to_wstring(fmt.tprint(state.exe_path, filename, sep=""))
}
