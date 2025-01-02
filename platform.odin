package main

import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import win "core:sys/windows"
/*
    TODO(viktor): THIS IS NOT A FINAL PLATFORM LAYER !!!
    - Fullscreen support

    - Saved game locations
    - Getting a handle to our own executable file
    - Asset loading path
    - Threading (launch a thread)
    - Raw Input (support for multiple keyboards)
    - ClipCursor() (for multimonitor support)
    - QueryCancelAutoplay
    - WM_ACTIVATEAPP (for when we are not the active application)
    - Blit speed improvements (BitBlt)
    - Hardware acceleration (OpenGL or Direct3D or BOTH ?? )
    - GetKeyboardLayout (for French keyboards, international WASD support)

    Just a partial list of stuff !!
*/

// ---------------------- ---------------------- ----------------------
// ---------------------- Globals
// ---------------------- ---------------------- ----------------------

INTERNAL :: #config(INTERNAL, true)
// TODO(viktor): this is a global for now
Running : b32

GLOBAL_back_buffer : OffscreenBuffer
GLOBAL_sound_buffer: ^IDirectSoundBuffer

GLOBAL_perf_counter_frequency : win.LARGE_INTEGER

GlobalPause := false

GLOBAL_debug_show_cursor: b32
GLOBAL_window_position := win.WINDOWPLACEMENT{ length = size_of(win.WINDOWPLACEMENT) }

// ---------------------- ---------------------- ----------------------
// ---------------------- Types
// ---------------------- ---------------------- ----------------------

SoundOutput :: struct {
    samples_per_second   : u32,
    num_channels         : u32,
    bytes_per_sample     : u32,
    buffer_size          : u32,
    running_sample_index : u32,
    safety_bytes         : u32,
}

WindowsColor :: struct{
    b, g, r, pad: u8,
}

Color :: [4]u8

OffscreenBuffer :: struct {
    info   : win.BITMAPINFO,
    memory : []Color,
    width, height, pitch: i32,
}

State :: struct {
    exe_path : string,

    game_memory_block : []u8,
    replay_buffers: [4]ReplayBuffer,

    input_record_handle : win.HANDLE,
    input_record_index  : i32,
    input_replay_handle : win.HANDLE,
    input_replay_index  : i32,
}

ReplayBuffer :: struct {
    filename: win.wstring,
    filehandle: win.HANDLE,
    memory_map: win.HANDLE,
    memory_block: []u8,
}

ThreadContext :: struct {
    placeholder: i32,
}

main :: proc() {
    when INTERNAL do fmt.print("\033[2J") // NOTE: clear the terminal
    win.QueryPerformanceFrequency(&GLOBAL_perf_counter_frequency)

    // ---------------------- ---------------------- ----------------------
    // ----------------------  Platform Setup
    // ---------------------- ---------------------- ----------------------

    state: State
    {
        exe_path_buffer : [win.MAX_PATH_WIDE]u16
        size_of_filename := win.GetModuleFileNameW(nil, &exe_path_buffer[0], win.MAX_PATH_WIDE)
        exe_path_and_name := win.wstring_to_utf8(raw_data(exe_path_buffer[:size_of_filename]), cast(int) size_of_filename) or_else ""
        one_past_last_slash : u32
        for r, i in exe_path_and_name {
            if r == '\\' {
                one_past_last_slash = cast(u32) i + 1
            }
        }
        state.exe_path = exe_path_and_name[:one_past_last_slash]
    }
    
    // NOTE: Set the windows scheduler granularity to 1ms so that out win.Sleep can be more granular
    desired_scheduler_ms :: 1
    sleep_is_granular: b32 = win.timeBeginPeriod(desired_scheduler_ms) == win.TIMERR_NOERROR
    
    // NOTE: We store a thread context in the context to know which thread is calling into the platform layer
    // TODO(viktor): Once there are multiple threads each call into the threads game code needs its own thread context
    main_thread_context : ThreadContext
    main_thread_context.placeholder = 123
    context.user_ptr = &main_thread_context
    
    Running = true



    // ---------------------- ---------------------- ----------------------
    // ---------------------- Windows Setup
    // ---------------------- ---------------------- ----------------------

    window : win.HWND
    {
        instance := cast(win.HINSTANCE) win.GetModuleHandleW(nil)
        window_class := win.WNDCLASSW{
            hInstance = instance,
            lpszClassName = win.utf8_to_wstring("HandmadeWindowClass"),
            style = win.CS_HREDRAW | win.CS_VREDRAW,
            lpfnWndProc = main_window_callback,
            hCursor = win.LoadCursorW(nil, win.MAKEINTRESOURCEW(32512)),
            // hIcon =,
        }
        when INTERNAL {
            GLOBAL_debug_show_cursor = true
        }

        resize_DIB_section(&GLOBAL_back_buffer, 960, 540)

        if win.RegisterClassW(&window_class) == 0 {
            return // TODO Logging
        }


        // NOTE: lpWindowName is either a cstring or a wstring depending on if UNICODE is defined
        // Odin expects that to be the case, but here it seems to be undefined so yeah.
        _window_title := "Handmade"
        window_title := cast([^]u16) raw_data(_window_title[:])
        window = win.CreateWindowExW(
            0, //win.WS_EX_TOPMOST | win.WS_EX_LAYERED,
            window_class.lpszClassName,
            window_title,
            win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
            win.CW_USEDEFAULT,
            win.CW_USEDEFAULT,
            GLOBAL_back_buffer.width  + 50,
            GLOBAL_back_buffer.height + 50,
            nil,
            nil,
            window_class.hInstance,
            nil,
        )

        if window == nil {
            return // TODO Logging
        }
    }



    // ---------------------- ---------------------- ----------------------
    // ---------------------- Video Setup
    // ---------------------- ---------------------- ----------------------

    // TODO: how do we reliably query this on windows?
    game_update_hz: f32
    {
        monitor_refresh_hz: u32 = 60
        when false {
            device_context := win.GetDC(window)
            VRefresh :: 116
            refresh_rate := win.GetDeviceCaps(device_context, VRefresh)
            if refresh_rate > 1 {
                monitor_refresh_hz = cast(u32) refresh_rate
            }
            win.ReleaseDC(window, device_context)
        }
        // TODO why divide by 2
        game_update_hz = cast(f32) monitor_refresh_hz / 2
    }
    target_seconds_per_frame := 1 / game_update_hz



    // ---------------------- ---------------------- ----------------------
    // ---------------------- Sound Setup
    // ---------------------- ---------------------- ----------------------

    sound_output : SoundOutput
    sound_output.samples_per_second = 48000
    sound_output.num_channels = 2
    sound_output.bytes_per_sample = size_of(Sample)
    sound_output.buffer_size = sound_output.samples_per_second * sound_output.bytes_per_sample
    // TODO: actually computre this variance and set a reasonable value
    sound_output.safety_bytes = cast(u32) (target_seconds_per_frame * cast(f32)sound_output.samples_per_second * cast(f32)sound_output.bytes_per_sample)

    init_dSound(window, sound_output.buffer_size, sound_output.samples_per_second)

    clear_sound_buffer(&sound_output)

    GLOBAL_sound_buffer->Play(0, 0, DSBPLAY_LOOPING)

    sound_is_valid: b32

    when false &&  INTERNAL {
        audio_latency_bytes: u32
        audio_latency_seconds: f32
        debug_last_time_markers: [36]DebugTimeMarker
    }



    // ---------------------- ---------------------- ----------------------
    // ---------------------- Input Setup
    // ---------------------- ---------------------- ----------------------

    init_xInput()

    input : [2]GameInput
    old_input, new_input := input[0], input[1]


    // ---------------------- ---------------------- ----------------------
    // ---------------------- Memory Setup
    // ---------------------- ---------------------- ----------------------

    game_dll_name := build_exe_path(state, "game.dll")
    temp_dll_name := build_exe_path(state, "game_temp.dll")
    lock_name     := build_exe_path(state, "lock.temp")
    game_lib_is_valid, game_dll_write_time := init_game_lib(game_dll_name, temp_dll_name, lock_name)
    // TODO: make this like sixty seconds?
    // TODO: pool with bitmap alloc
    samples := cast([^][2]i16) win.VirtualAlloc(nil, cast(uint) sound_output.buffer_size, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)

    context.allocator = {}

    game_memory : GameMemory
    {
        base_address := cast(rawptr) cast(uintptr) terabytes(1) when INTERNAL else 0

        permanent_storage_size := megabytes(u64(256))
        transient_storage_size := gigabytes(u64(1))
        total_size:= cast(uint) (permanent_storage_size + transient_storage_size)

        storage_ptr := cast([^]u8) win.VirtualAlloc( base_address, total_size, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
        // TODO(viktor): why limit ourselves?
        assert(total_size < gigabytes(uint(4)))
        state.game_memory_block = storage_ptr[:total_size]

        // TODO(viktor): TransientStorage needs to be broken up
        // into game transient and cache transient, and only
        // the former need be saved for state playback.
        for &buffer, index in state.replay_buffers {
            buffer.filename = get_record_replay_filepath(state, cast(i32) index)
            buffer.filehandle = win.CreateFileW(buffer.filename, win.GENERIC_READ|win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, 0, nil)
        
            size_high:= cast(win.DWORD)(total_size >> 32)
            size_low := cast(win.DWORD)total_size
            buffer.memory_map = win.CreateFileMappingW(buffer.filehandle, nil, win.PAGE_READWRITE, size_high, size_low, nil)

            buffer_storage_ptr := cast([^]u8) win.MapViewOfFile(buffer.memory_map, win.FILE_MAP_ALL_ACCESS, 0, 0, total_size)
            if buffer_storage_ptr != nil {
                buffer.memory_block = buffer_storage_ptr[:total_size]
            } else {
                // TODO: Diagnostic
            }
        }

        game_memory.permanent_storage = storage_ptr[0:][:permanent_storage_size]
        game_memory.transient_storage = storage_ptr[permanent_storage_size:][:transient_storage_size]

        game_memory.debug.read_entire_file  = DEBUG_read_entire_file
        game_memory.debug.write_entire_file = DEBUG_write_entire_file
        game_memory.debug.free_file_memory  = DEBUG_free_file_memory
    }

    if samples == nil || game_memory.permanent_storage == nil || game_memory.transient_storage == nil {
        return // TODO: logging
    }



    // ---------------------- ---------------------- ----------------------
    // ---------------------- Timer Setup
    // ---------------------- ---------------------- ----------------------

    last_counter := get_wall_clock()
    flip_counter := get_wall_clock()
    last_cycle_count := intrinsics.read_cycle_counter()



    // ---------------------- ---------------------- ----------------------
    // ---------------------- Game Loop
    // ---------------------- ---------------------- ----------------------
    for Running {
        // TODO: if this is too slow the audio and the whole game will lag
        new_input.reloaded_executable = false
        if get_last_write_time(game_dll_name) != game_dll_write_time {
            game_lib_is_valid, game_dll_write_time = init_game_lib(game_dll_name, temp_dll_name, lock_name)
            
            new_input.reloaded_executable = true
        }

        // ---------------------- ---------------------- ----------------------
        // ---------------------- Input
        // ---------------------- ---------------------- ----------------------
        {
            new_input.delta_time = target_seconds_per_frame
            { // Mouse Input 
                mouse : win.POINT
                win.GetCursorPos(&mouse)
                win.ScreenToClient(window, &mouse)
                new_input.mouse_position = transmute([2]i32) mouse
                // TODO: support mouse wheel
                new_input.mouse_wheel = 0
                is_down_mask := transmute(win.SHORT) u16(1 << 15)
                // TODO: Do we need to update the input button on every event?
                process_win_keyboard_message(&new_input.mouse_left,   cast(b32) (win.GetKeyState(win.VK_LBUTTON)  & is_down_mask))
                process_win_keyboard_message(&new_input.mouse_right,  cast(b32) (win.GetKeyState(win.VK_RBUTTON)  & is_down_mask))
                process_win_keyboard_message(&new_input.mouse_middle, cast(b32) (win.GetKeyState(win.VK_MBUTTON)  & is_down_mask))
                process_win_keyboard_message(&new_input.mouse_extra1, cast(b32) (win.GetKeyState(win.VK_XBUTTON1) & is_down_mask))
                process_win_keyboard_message(&new_input.mouse_extra2, cast(b32) (win.GetKeyState(win.VK_XBUTTON2) & is_down_mask))
            }

            { // Keyboard Input
                old_keyboard_controller := &old_input.controllers[0]
                new_keyboard_controller := &new_input.controllers[0]
                new_keyboard_controller^ = {}
                new_keyboard_controller.is_connected = true

                for &button, index in new_keyboard_controller.buttons {
                    button.ended_down = old_keyboard_controller.buttons[index].ended_down
                }

                process_pending_messages(&state, new_keyboard_controller)
            }
            max_controller_count: u32 = min(XUSER_MAX_COUNT, len(GameInput{}.controllers) - 1)
            // TODO: Need to not poll disconnected controllers to avoid xinput frame rate hit
            // on older libraries.
            // TODO: should we poll this more frequently
            // TODO: only check connected controllers, catch messages on connect / disconnect
            for controller_index in 0..<max_controller_count {
                controller_state : XINPUT_STATE

                our_controller_index := controller_index+1

                old_controller := old_input.controllers[our_controller_index]
                new_controller := &new_input.controllers[our_controller_index]

                if XInputGetState(controller_index, &controller_state) == win.ERROR_SUCCESS {
                    new_controller.is_connected = true
                    new_controller.is_analog = old_controller.is_analog
                    // TODO: see if dwPacketNumber increments too rapidly
                    pad := controller_state.Gamepad

                    process_Xinput_button :: proc(new_state: ^GameInputButton, old_state: GameInputButton, xInput_button_state: win.WORD, button_bit: win.WORD) {
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

                    // TODO: right stick, triggers
                    // TODO: This is a square deadzone, check XInput to
                    // verify that the deadzone is "round" and show how to do
                    // round deadzone processing.
                    new_controller.stick_average = {
                        process_Xinput_stick(pad.sThumbLX, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE),
                        process_Xinput_stick(pad.sThumbLY, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE),
                    }
                    if new_controller.stick_average != {0,0} do new_controller.is_analog = true

                    // TODO: what if we don't want to override the stick
                    if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_RIGHT) { new_controller.stick_average.x =  1; new_controller.is_analog = false }
                    if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_LEFT)  { new_controller.stick_average.x = -1; new_controller.is_analog = false }
                    if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_UP)    { new_controller.stick_average.y =  1; new_controller.is_analog = false }
                    if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_DOWN)  { new_controller.stick_average.y = -1; new_controller.is_analog = false }

                    Threshold :: 0.5
                    process_Xinput_button(&new_controller.stick_left , old_controller.stick_left , 1, new_controller.stick_average.x < -Threshold ? 1 : 0)
                    process_Xinput_button(&new_controller.stick_right, old_controller.stick_right, 1, new_controller.stick_average.x >  Threshold ? 1 : 0)
                    process_Xinput_button(&new_controller.stick_down , old_controller.stick_down , 1, new_controller.stick_average.y < -Threshold ? 1 : 0)
                    process_Xinput_button(&new_controller.stick_up   , old_controller.stick_up   , 1, new_controller.stick_average.y >  Threshold ? 1 : 0)

                    if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_BACK) do Running = false
                } else {
                    new_controller.is_connected = false
                }
            }
        }

        if GlobalPause do continue


        // ---------------------- ---------------------- ----------------------
        // ---------------------- Update, Sound and Render
        // ---------------------- ---------------------- ----------------------
        {
            offscreen_buffer := GameLoadedBitmap{
                pixels = GLOBAL_back_buffer.memory,
                width  = GLOBAL_back_buffer.width,
                height = GLOBAL_back_buffer.height,
                pitch  = GLOBAL_back_buffer.width,
            }

            if state.input_record_index != 0 {
                record_input(&state, &new_input)
            }
            if state.input_replay_index != 0 {
                replay_input(&state, &new_input)
            }

            if game_lib_is_valid {
                game_update_and_render(&game_memory, offscreen_buffer, new_input)
            }

            sound_is_valid = true
            play_cursor, write_cursor : win.DWORD
            audio_counter := get_wall_clock()
            from_begin_to_audio := get_seconds_elapsed(flip_counter, audio_counter)
            if result := GLOBAL_sound_buffer->GetCurrentPosition(&play_cursor, &write_cursor); win.SUCCEEDED(result) {
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

                target_cursor : win.DWORD
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
                    samples = samples[:(bytes_to_write/sound_output.bytes_per_sample)],
                }
                if game_lib_is_valid {
                    game_output_sound_samples(&game_memory, sound_buffer)
                }

                when false &&  INTERNAL {
                    GLOBAL_sound_buffer->GetCurrentPosition(&play_cursor, &write_cursor); win.SUCCEEDED(result)
                    debug_last_time_markers[0].output_play_cursor           = play_cursor
                    debug_last_time_markers[0].output_write_cursor          = write_cursor
                    debug_last_time_markers[0].output_location              = byte_to_lock
                    debug_last_time_markers[0].output_byte_count            = bytes_to_write
                    debug_last_time_markers[0].expected_frame_boundary_byte = expected_frame_boundary_byte

                    audio_latency_bytes = ((write_cursor - play_cursor) + sound_output.buffer_size) % sound_output.buffer_size
                    audio_latency_seconds = (cast(f32)audio_latency_bytes / cast(f32)sound_output.bytes_per_sample) / cast(f32)sound_output.samples_per_second

                    // fmt.printfln("PC %v WC %v Delta %v Seconds %vs", play_cursor, write_cursor, audio_latency_bytes, audio_latency_seconds)
                }

                fill_sound_buffer(&sound_output, byte_to_lock, bytes_to_write, sound_buffer)
            } else {
                sound_is_valid = false
            }

            swap(&old_input, &new_input)
        }

        // ---------------------- ---------------------- ----------------------
        // ---------------------- Display Frame & Performance Counters
        // ---------------------- ---------------------- ----------------------
        {
            seconds_elapsed_for_frame := get_seconds_elapsed(last_counter, get_wall_clock())
            if seconds_elapsed_for_frame < target_seconds_per_frame {
                if sleep_is_granular {
                    sleep_ms := (target_seconds_per_frame-0.001 - seconds_elapsed_for_frame) * 1000
                    if sleep_ms > 0 do win.Sleep(cast(u32) sleep_ms)
                }
                test_seconds_elapsed := get_seconds_elapsed(last_counter, get_wall_clock())
                if test_seconds_elapsed < target_seconds_per_frame {
                    // TODO: Log sleep miss here
                }
                for seconds_elapsed_for_frame < target_seconds_per_frame {
                    seconds_elapsed_for_frame = get_seconds_elapsed(last_counter, get_wall_clock())
                }
            } else {
                // TODO: Missed frame, Logging, maybe because window was moved
            }

            end_counter := get_wall_clock()
            end_cycle_count := intrinsics.read_cycle_counter()

            window_width, window_height := get_window_dimension(window)
            when false && INTERNAL {
                DEBUG_sync_display(GLOBAL_back_buffer, debug_last_time_markers[:], sound_output, target_seconds_per_frame)
            }

            {
                device_context := win.GetDC(window)
                display_buffer_in_window(&GLOBAL_back_buffer, device_context, window_width, window_height)
                win.ReleaseDC(window, device_context)
            }

            flip_counter = get_wall_clock()
            when false && INTERNAL {
                play_cursor, write_cursor : win.DWORD
                GLOBAL_sound_buffer->GetCurrentPosition(&play_cursor, &write_cursor)
                debug_last_time_markers[0].flip_play_cursor = play_cursor
                debug_last_time_markers[0].flip_write_cursor = write_cursor
            }


            when INTERNAL && false {
                cycles_elapsed        := end_cycle_count - last_cycle_count
                mega_cycles_per_frame := f32(cycles_elapsed) / (1000 * 1000)
                ms_per_frame          := get_seconds_elapsed(last_counter, end_counter) * 1000
                frames_per_second     := 1000 / ms_per_frame
                fmt.printfln("ms/f: %2.02f - fps: %4.02f - Megacycles/f: %3.02f", ms_per_frame, frames_per_second, mega_cycles_per_frame)
            }

            last_cycle_count = end_cycle_count
            last_counter = end_counter
            when false && INTERNAL {
                #reverse for cursor, index in debug_last_time_markers {
                    if index < len(debug_last_time_markers)-1 do debug_last_time_markers[index+1] = cursor
                }
            }
        }
    }
}



get_thread_context :: proc() -> ThreadContext {
    return (cast(^ThreadContext)context.user_ptr)^
}



get_wall_clock :: #force_inline proc() -> i64 {
    result : win.LARGE_INTEGER
    win.QueryPerformanceCounter(&result)
    return cast(i64) result
}

get_seconds_elapsed :: #force_inline proc(start, end: i64) -> f32 {
    return f32(end - start) / f32(GLOBAL_perf_counter_frequency)
}

get_last_write_time :: proc(filename: win.wstring) -> (last_write_time: u64) {
    FILE_ATTRIBUTE_DATA :: struct {
        dwFileAttributes : win.DWORD,
        ftCreationTime : win.FILETIME,
        ftLastAccessTime : win.FILETIME,
        ftLastWriteTime : win.FILETIME,
        nFileSizeHigh : win.DWORD,
        nFileSizeLow : win.DWORD,
    }

    file_information : FILE_ATTRIBUTE_DATA
    if win.GetFileAttributesExW(filename, win.GetFileExInfoStandard, &file_information) {
        last_write_time = (cast(u64) (file_information.ftLastWriteTime.dwHighDateTime) << 32) | cast(u64) (file_information.ftLastWriteTime.dwLowDateTime)
    }
    return last_write_time
}

build_exe_path :: proc(state: State, filename: string) -> win.wstring {
    return win.utf8_to_wstring(fmt.tprint(state.exe_path, filename, sep=""))
}



// ---------------------- ---------------------- ----------------------
// ---------------------- Record and Replay
// ---------------------- ---------------------- ----------------------

get_record_replay_filepath :: proc(state: State, index:i32) -> win.wstring {
    return build_exe_path(state, fmt.tprintf("editloop_%d.input", index))
}

begin_recording_input :: proc(state: ^State, input_recording_index: i32) {
    replay_buffer := state.replay_buffers[input_recording_index]

    if replay_buffer.memory_block != nil {
        state.input_record_index = input_recording_index
        state.input_record_handle = replay_buffer.filehandle
        // TODO: this is slow on the first start
        file_position := cast(win.LARGE_INTEGER) len(state.game_memory_block)
        win.SetFilePointerEx(state.input_record_handle, file_position, nil, win.FILE_BEGIN)
        
        copy_slice(replay_buffer.memory_block, state.game_memory_block)
    }
}

record_input :: proc(state: ^State, input: ^GameInput) {
    bytes_written: u32
    win.WriteFile(state.input_record_handle, input, cast(u32) size_of(GameInput), &bytes_written, nil)
}

end_recording_input :: proc(state: ^State) {
    state.input_record_index = 0
}

begin_replaying_input :: proc(state: ^State, input_replaying_index: i32) {
    replay_buffer := state.replay_buffers[input_replaying_index]

    if replay_buffer.memory_block != nil {
        state.input_replay_index = input_replaying_index
        state.input_replay_handle = replay_buffer.filehandle
        
        file_position := cast(win.LARGE_INTEGER) len(state.game_memory_block)
        win.SetFilePointerEx(state.input_replay_handle, file_position, nil, win.FILE_BEGIN)

        copy(state.game_memory_block, replay_buffer.memory_block)
    }
}

replay_input :: proc(state: ^State, input: ^GameInput) {
    bytes_read: u32
    win.ReadFile(state.input_replay_handle, input, cast(u32) size_of(GameInput), &bytes_read, nil)
    if bytes_read != 0 {
        // NOTE: there is still input
    } else {
        // NOTE: we reached the end of the stream go back to beginning
        replay_index := state.input_replay_index
        end_replaying_input(state)
        begin_replaying_input(state, replay_index)
        win.ReadFile(state.input_replay_handle, input, cast(u32) size_of(GameInput), &bytes_read, nil)
    }
}

end_replaying_input :: proc(state: ^State) {
    state.input_replay_index = 0
}

// ---------------------- ---------------------- ----------------------
// ---------------------- Sound Buffer
// ---------------------- ---------------------- ----------------------


fill_sound_buffer :: proc(sound_output: ^SoundOutput, byte_to_lock, bytes_to_write: u32, source: GameSoundBuffer) {
    region1, region2 : rawptr
    region1_size, region2_size: win.DWORD

    if result := GLOBAL_sound_buffer->Lock(byte_to_lock, bytes_to_write, &region1, &region1_size, &region2, &region2_size, 0); win.SUCCEEDED(result) {
        // TODO: assert that region1/2_size is valid
        // TODO: Collapse these two loops

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

        GLOBAL_sound_buffer->Unlock(region1, region1_size, region2, region2_size)
    } else {
        return // TODO: Logging
    }
}

clear_sound_buffer :: proc(sound_output: ^SoundOutput) {
    region1, region2 : rawptr
    region1_size, region2_size: win.DWORD

    if result := GLOBAL_sound_buffer->Lock(0, sound_output.buffer_size , &region1, &region1_size, &region2, &region2_size, 0); win.SUCCEEDED(result) {
        // TODO: assert that region1/2_size is valid
        // TODO: Collapse these two loops
        // TODO: Copy pasta of fill_sound_buffer

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

        GLOBAL_sound_buffer->Unlock(region1, region1_size, region2, region2_size)
    } else {
        return // TODO: Logging
    }
}



// ---------------------- ---------------------- ----------------------
// ---------------------- Window Drawing
// ---------------------- ---------------------- ----------------------

get_window_dimension :: proc "system" (window: win.HWND) -> (width, height: i32) {
    client_rect : win.RECT
    win.GetClientRect(window, &client_rect)
    width  = client_rect.right  - client_rect.left
    height = client_rect.bottom - client_rect.top
    return width, height
}

resize_DIB_section :: proc "system" (buffer: ^OffscreenBuffer, width, height: i32) {
    // TODO: Bulletproof this.
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
    bitmap_memory_size := buffer.width * buffer.height * bytes_per_pixel
    buffer_ptr := cast([^]Color) win.VirtualAlloc(nil, uint(bitmap_memory_size), win.MEM_COMMIT, win.PAGE_READWRITE)
    buffer.memory = buffer_ptr[:buffer.width*buffer.height]

    // TODO: probably clear this to black
}

display_buffer_in_window :: proc "system" (buffer: ^OffscreenBuffer, device_context: win.HDC, window_width, window_height: i32, fix_windows_colors: b32 = true){
    // TODO(viktor): can we avoid this without forcing the game to have to handle the windows color component order?
    if fix_windows_colors {
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                useful_color := &buffer.memory[y * buffer.width + x]
                windows_color:= WindowsColor{
                    r = useful_color.r,
                    g = useful_color.g,
                    b = useful_color.b,
                }
                useful_color^ = transmute(Color) windows_color
            }
        }
    }
        
    if window_width >= buffer.width*2 && window_height >= buffer.height*2 {
        offset := [2]i32{window_width - buffer.width*2, window_height - buffer.height*2} / 2
        
        win.StretchDIBits(
            device_context,
            offset.x, offset.y, buffer.width*2, buffer.height*2,
            0, 0, buffer.width, buffer.height,
            raw_data(buffer.memory),
            &buffer.info,
            win.DIB_RGB_COLORS,
            win.SRCCOPY,
        )	
    } else {
        offset := [2]i32{window_width - buffer.width, window_height - buffer.height} / 2

        win.PatBlt(device_context, 0, 0, buffer.width+offset.x*2, offset.y, win.BLACKNESS )
        win.PatBlt(device_context, 0, offset.y, offset.x, buffer.height+offset.y*2, win.BLACKNESS )
        
        win.PatBlt(device_context, buffer.width+offset.x, 0, window_width, window_height, win.BLACKNESS )
        win.PatBlt(device_context, 0, buffer.height+offset.y, buffer.width+offset.x*2, window_height, win.BLACKNESS )
        
        // TODO: aspect ratio correction
        // TODO: stretch to fill window once we are fine with our renderer
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
}

toggle_fullscreen :: proc(window: win.HWND) {
    // NOTE(viktor): This follows Raymond Chen's prescription for fullscreen toggling, see:
    // http://blogs.msdn.com/b/oldnewthing/archive/2010/04/12/9994016.aspx

    style := cast(u32) win.GetWindowLongW(window, win.GWL_STYLE)
    if style & win.WS_OVERLAPPEDWINDOW != 0 {
        info := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
        if win.GetWindowPlacement(window, &GLOBAL_window_position) && 
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
        win.SetWindowPlacement(window, &GLOBAL_window_position)
        win.SetWindowPos(window, nil, 0, 0, 0, 0, 
            win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | 
            win.SWP_NOOWNERZORDER | win.SWP_FRAMECHANGED)
    }
}


// ---------------------- ---------------------- ----------------------
// ---------------------- Windows Messages
// ---------------------- ---------------------- ----------------------

main_window_callback :: proc "system" (window: win.HWND, message: win.UINT, w_param: win.WPARAM, l_param: win.LPARAM) -> (result: win.LRESULT) {
    switch message {
    case win.WM_SYSKEYUP, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_KEYDOWN:
        context = runtime.default_context()
        assert(false, "keyboard-event came in through a non-dispatched event")
    case win.WM_CLOSE: // TODO: Handle this with a message to the user
        Running = false
    case win.WM_DESTROY: // TODO: handle this as an error - recreate window?
        Running = false
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

        window_width, window_height := get_window_dimension(window)
        display_buffer_in_window(&GLOBAL_back_buffer, device_context, window_width, window_height, false)

        win.EndPaint(window, &paint)
    case win.WM_SETCURSOR: 
        if GLOBAL_debug_show_cursor {

        } else {
            win.SetCursor(nil)
        }
    case:
        result = win.DefWindowProcA(window, message, w_param, l_param)
    }
    return result
}

process_win_keyboard_message :: proc(new_state: ^GameInputButton, is_down: b32) {
    if is_down != new_state.ended_down {
        new_state.ended_down = is_down
        new_state.half_transition_count += 1
    }
}

process_pending_messages :: proc(state: ^State, keyboard_controller: ^GameInputController) {
    message : win.MSG
    for win.PeekMessageW(&message, nil, 0, 0, win.PM_REMOVE) {
        switch message.message {
        case win.WM_QUIT:
            Running = false
        case win.WM_SYSKEYUP, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_KEYDOWN:
            vk_code := message.wParam

            was_down := cast(b32) (message.lParam & (1 << 30))
            is_down: b32 = !(cast(b32) (message.lParam & (1 << 31)))

            alt_down := cast(b32) (message.lParam & (1 << 29))

            if was_down != is_down {
                switch vk_code {
                case win.VK_W:
                    process_win_keyboard_message(&keyboard_controller.stick_up      , is_down)
                case win.VK_A:
                    process_win_keyboard_message(&keyboard_controller.stick_left    , is_down)
                case win.VK_S:
                    process_win_keyboard_message(&keyboard_controller.stick_down    , is_down)
                case win.VK_D:
                    process_win_keyboard_message(&keyboard_controller.stick_right   , is_down)
                case win.VK_Q:
                    process_win_keyboard_message(&keyboard_controller.shoulder_left , is_down)
                case win.VK_E:
                    process_win_keyboard_message(&keyboard_controller.shoulder_right, is_down)
                case win.VK_UP:
                    process_win_keyboard_message(&keyboard_controller.button_up     , is_down)
                case win.VK_DOWN:
                    process_win_keyboard_message(&keyboard_controller.button_down   , is_down)
                case win.VK_LEFT:
                    process_win_keyboard_message(&keyboard_controller.button_left   , is_down)
                case win.VK_RIGHT:
                    process_win_keyboard_message(&keyboard_controller.button_right  , is_down)
                case win.VK_ESCAPE:
                    Running = false
                    process_win_keyboard_message(&keyboard_controller.back          , is_down)
                case win.VK_SPACE:
                    process_win_keyboard_message(&keyboard_controller.start         , is_down)
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
                    if is_down && alt_down do Running = false
                case win.VK_RETURN:
                    if is_down && alt_down do toggle_fullscreen(message.hwnd)
                    
                }
            }
        case:
            win.TranslateMessage(&message)
            win.DispatchMessageW(&message)
        }
    }
}
