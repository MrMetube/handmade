package main

import "base:intrinsics"
import "base:runtime"

import "core:fmt"

import win "core:sys/windows"


INTERNAL :: #config(INTERNAL, true)

/*
	TODO: THIS IS NOT A FINAL PLATFORM LAYER !!!
 
	- Saved game locations
	- Getting a handle to our own executable file
	- Asset loading path
	- Threading (launch a thread)
	- Raw Input (support for multiple keyboards)
	- Sleep/timeBeginPeriod
	- ClipCursor() (for multimonitor support)
	- Fullscreen support
	- WM_SETCURSOR (control cursor visibility)
	- QueryCancelAutoplay
	- WM_ACTIVATEAPP (for when we are not the active application)
	- Blit speed improvements (BitBlt)
	- Hardware acceleration (OpenGL or Direct3D or BOTH ?? )
	- GetKeyboardLayout (for French keyboards, international WASD support)

	Just a partial list of stuff !!
*/

// TODO this is a global for now
RUNNING : b32

the_back_buffer : OffscreenBuffer
the_sound_buffer: ^IDirectSoundBuffer

global_perf_counter_frequency : win.LARGE_INTEGER



SoundOutput :: struct {
	samples_per_second         : u32,
	num_channels               : u32,
	bytes_per_sample           : u32,
	sound_buffer_size_in_bytes : u32,
	running_sample_index       : u32,
	latency_sample_count       : u32,
}

OffscreenBufferColor :: struct{
	b, g, r, pad: u8
}

OffscreenBuffer :: struct {
	info   : win.BITMAPINFO,
	memory : [^]OffscreenBufferColor,
	width  : i32,
	height : i32,
}

main :: proc() {
	win.QueryPerformanceFrequency(&global_perf_counter_frequency)

	
	// NOTE: Set the windows scheduler granularity to 1ms so that out win.Sleep can be more granular
	desired_scheduler_ms :: 1
	sleep_is_granular: b32 = win.timeBeginPeriod(desired_scheduler_ms) == win.TIMERR_NOERROR

	window : win.HWND
	{ // ---------------------- Window Setup

		window_class := win.WNDCLASSW{
			hInstance = cast(win.HINSTANCE) win.GetModuleHandleW(nil),
			lpszClassName = win.utf8_to_wstring("HandmadeWindowClass"),
			// hIcon =,
			style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
			lpfnWndProc = main_window_callback,
		}

		resize_DIB_section(&the_back_buffer, 1280, 720)

		if win.RegisterClassW(&window_class) == 0 {
			return // TODO Logging
		}


		// NOTE: lpWindowName is either a cstring or a wstring depending on if UNICODE is defined
		// Odin expects that to be the case, but here it seems to be undefined so yeah.
		_window_title := "Handmade"
		window_title := cast([^]u16) raw_data(_window_title[:])
		window = win.CreateWindowExW(
			0,
			window_class.lpszClassName,
			window_title,
			win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
			win.CW_USEDEFAULT,
			win.CW_USEDEFAULT,
			win.CW_USEDEFAULT,
			win.CW_USEDEFAULT,
			nil,
			nil,
			window_class.hInstance,
			nil,
		)

		if window == nil {
			return // TODO Logging
		}
	}
	device_context := win.GetDC(window)


	// ---------------------- Video Setup
	// TODO: how do we reliably query this on windows?
	monitor_refresh_hz :: 144
	game_update_hz: u32 = monitor_refresh_hz / 2
	target_seconds_per_frame: f32 = 1 / cast(f32) game_update_hz

	frames_of_audio_latency :: 1 when monitor_refresh_hz == 144 else 3

	// ---------------------- Sound Setup
	sound_output : SoundOutput
	sound_output.samples_per_second = 48000
	sound_output.num_channels = 2
	sound_output.bytes_per_sample = size_of(Sample)
	sound_output.sound_buffer_size_in_bytes = sound_output.samples_per_second * sound_output.bytes_per_sample
	sound_output.latency_sample_count = frames_of_audio_latency * (sound_output.samples_per_second / game_update_hz)

	init_dSound(window, sound_output.sound_buffer_size_in_bytes, sound_output.samples_per_second)

	clear_sound_buffer(&sound_output)

	the_sound_buffer->Play(0, 0, DSBPLAY_LOOPING)
	
	sound_is_valid: b32
	last_play_cursor: win.DWORD

	when INTERNAL {
		debug_last_time_markers: [72]DebugTimeMarker
	}



	// ---------------------- Input Setup
	init_xInput()

	input : [2]GameInput
	old_input, new_input := input[0], input[1]


    
	// ---------------------- Memory Setup
	// TODO make this like sixty seconds?
	// TODO pool with bitmap alloc
	samples := cast([^][2]i16) win.VirtualAlloc(nil, cast(uint) sound_output.sound_buffer_size_in_bytes, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)

	context.allocator = {}

	game_memory : GameMemory
	{
		base_address := cast(rawptr) cast(uintptr) terabytes(1) when INTERNAL else 0

		permanent_storage_size := megabytes(64)
		transient_storage_size := gigabytes(4)
		total_size := permanent_storage_size + transient_storage_size

		storage_ptr := cast([^]u8) win.VirtualAlloc( base_address, cast(uint) total_size, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
		game_memory.permanent_storage = storage_ptr[0:][:permanent_storage_size]
		game_memory.transient_storage = storage_ptr[permanent_storage_size:][:transient_storage_size] 
	}

	if samples == nil || game_memory.permanent_storage == nil || game_memory.transient_storage == nil {
		return // TODO logging
	}

	RUNNING = true

	// ---------------------- Timer Setup
	last_counter := get_wall_clock()
	last_cycle_count := intrinsics.read_cycle_counter()
	
	for RUNNING {
		{ // ---------------------- Input
			old_keyboard_controller := &old_input.controllers[0]
			new_keyboard_controller := &new_input.controllers[0]
			new_keyboard_controller^ = {}
			new_keyboard_controller.is_connected = true

			for &button, index in new_keyboard_controller.buttons {
				button.ended_down = old_keyboard_controller.buttons[index].ended_down
			}
			
			process_pending_messages(new_keyboard_controller)

			max_controller_count: u32 = min(XUSER_MAX_COUNT, len(GameInput{}.controllers) - 1)
			// TODO Need to not poll disconnected controllers to avoid xinput frame rate hit
			// on older libraries.
			// TODO should we poll this more frequently
			// TODO only check connected controllers, catch messages on connect / disconnect
			for controller_index in 0..<max_controller_count {
				controller_state : XINPUT_STATE

				our_controller_index := controller_index+1

				old_controller := old_input.controllers[our_controller_index]
				new_controller := &new_input.controllers[our_controller_index]

				if XInputGetState(controller_index, &controller_state) == win.ERROR_SUCCESS {
					new_controller.is_connected = true
					// TODO see if dwPacketNumber increments too rapidly
					pad := controller_state.Gamepad
					
					// TODO all buttons
					left_thumb     := cast(b16) (pad.wButtons & XINPUT_GAMEPAD_LEFT_THUMB)
					right_thumb    := cast(b16) (pad.wButtons & XINPUT_GAMEPAD_RIGHT_THUMB)
					
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

					// TODO what if we dont want to override the stick
					if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_RIGHT) { new_controller.stick_average.x =  1; new_controller.is_analog = false }
					if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_LEFT)  { new_controller.stick_average.x = -1; new_controller.is_analog = false }
					if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_UP)    { new_controller.stick_average.y =  1; new_controller.is_analog = false }
					if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_DOWN)  { new_controller.stick_average.y = -1; new_controller.is_analog = false }

					THRESHOLD :: 0.5
					process_Xinput_button(&new_controller.stick_left , old_controller.stick_left , 1, new_controller.stick_average.x < -THRESHOLD ? 1 : 0)
					process_Xinput_button(&new_controller.stick_right, old_controller.stick_right, 1, new_controller.stick_average.x >  THRESHOLD ? 1 : 0)
					process_Xinput_button(&new_controller.stick_down , old_controller.stick_down , 1, new_controller.stick_average.y < -THRESHOLD ? 1 : 0)
					process_Xinput_button(&new_controller.stick_up   , old_controller.stick_up   , 1, new_controller.stick_average.y >  THRESHOLD ? 1 : 0)
		
					if cast(b16) (pad.wButtons & XINPUT_GAMEPAD_BACK) do RUNNING = false
				} else {
					new_controller.is_connected = false
				}
			}
		}

		{ // ---------------------- Update, Sound and Render
			byte_to_lock  : u32
			bytes_to_write: win.DWORD
			{
				if sound_is_valid {
					byte_to_lock = (sound_output.running_sample_index*sound_output.bytes_per_sample) % sound_output.sound_buffer_size_in_bytes

					target_cursor := (last_play_cursor + sound_output.latency_sample_count * sound_output.bytes_per_sample)  % sound_output.sound_buffer_size_in_bytes

					if byte_to_lock > target_cursor {
						bytes_to_write = target_cursor - byte_to_lock + sound_output.sound_buffer_size_in_bytes
					} else{
						bytes_to_write = target_cursor - byte_to_lock
					}
				} else {
					// TODO Logging
				}
			}

			sound_buffer := GameSoundBuffer{
				samples_per_second = sound_output.samples_per_second,
				samples = samples[:(bytes_to_write/sound_output.bytes_per_sample)],
			}

			offscreen_buffer := GameOffscreenBuffer{
				memory = the_back_buffer.memory,
				width  = the_back_buffer.width,
				height = the_back_buffer.height,
			}

			when INTERNAL {
				for &c in the_back_buffer.memory[:the_back_buffer.width*the_back_buffer.height] {
					c.r = u8(f32(c.r) * 0.98)
					c.g = u8(f32(c.g) * 0.98)
					c.b = u8(f32(c.b) * 0.98)
				}
			}

			game_update_and_render(&game_memory, offscreen_buffer, sound_buffer, new_input)

			if sound_is_valid {
				when INTERNAL {
					play_cursor, write_cursor : win.DWORD
					the_sound_buffer->GetCurrentPosition(&play_cursor, &write_cursor)
					fmt.printfln("LPC %v - PC %v WC %v", last_play_cursor, play_cursor, write_cursor)
				}
				
				fill_sound_buffer(&sound_output, byte_to_lock, bytes_to_write, sound_buffer)
			}

			swap(&old_input, &new_input)
		}

		
		{ // ---------------------- Display Frame & Performance Counters
			seconds_elapsed_for_frame := get_seconds_elapsed(last_counter, get_wall_clock())
			if seconds_elapsed_for_frame < target_seconds_per_frame {
				if sleep_is_granular {
					sleep_ms := (target_seconds_per_frame - seconds_elapsed_for_frame) * 1000
					if sleep_ms > 0 do win.Sleep(cast(u32) sleep_ms)
				}
				for seconds_elapsed_for_frame < target_seconds_per_frame {
					seconds_elapsed_for_frame = get_seconds_elapsed(last_counter, get_wall_clock())
				} 
			} else {
				// TODO: Missed frame, Logging
			}

			end_counter := get_wall_clock()
			end_cycle_count := intrinsics.read_cycle_counter()

			window_width, window_height := get_window_dimension(window)
			when INTERNAL {
				DEBUG_sync_display(the_back_buffer, debug_last_time_markers[:], sound_output, target_seconds_per_frame)
			}
			display_buffer_in_window(the_back_buffer, device_context, window_width, window_height)

			
			play_cursor, write_cursor : win.DWORD
			if result := the_sound_buffer->GetCurrentPosition(&play_cursor, &write_cursor); win.SUCCEEDED(result) {
				last_play_cursor = play_cursor
				if !sound_is_valid {
					sound_output.running_sample_index = write_cursor / sound_output.bytes_per_sample
					sound_is_valid = true
				}
			} else {
				sound_is_valid = false
			}

			when INTERNAL {
				#reverse for cursor, index in debug_last_time_markers {
					if index < len(debug_last_time_markers)-1 do debug_last_time_markers[index+1] = cursor
				}

				debug_last_time_markers[0] = {play_cursor, write_cursor}
			}


			when INTERNAL {
				cycles_elapsed        := end_cycle_count - last_cycle_count
				mega_cycles_per_frame := f32(cycles_elapsed) / (1000 * 1000)
				ms_per_frame          := get_seconds_elapsed(last_counter, end_counter) * 1000
				frames_per_second     := 1000 / ms_per_frame
				// fmt.printfln("Milliseconds/frame: %2.02f - frames/second: %4.02f - Megacycles/frame: %3.02f", ms_per_frame, frames_per_second, mega_cycles_per_frame)
			}

			last_cycle_count = end_cycle_count
			last_counter = end_counter
		}
	}
}

get_wall_clock :: #force_inline proc() -> i64 {
	result : win.LARGE_INTEGER
	win.QueryPerformanceCounter(&result)
	return cast(i64) result
}

get_seconds_elapsed :: #force_inline proc(start, end: i64) -> f32 {
	return f32(end - start) / f32(global_perf_counter_frequency)
}

fill_sound_buffer :: proc(sound_output: ^SoundOutput, byte_to_lock, bytes_to_write: u32, source: GameSoundBuffer) {
	region1, region2 : rawptr
	region1_size, region2_size: win.DWORD

	if result := the_sound_buffer->Lock(byte_to_lock, bytes_to_write, &region1, &region1_size, &region2, &region2_size, 0); win.SUCCEEDED(result) {
		// TODO assert that region1/2_size is valid
		// TODO Collapse these two loops
		
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

		the_sound_buffer->Unlock(region1, region1_size, region2, region2_size)
	} else {
		return // TODO Logging
	}
}

clear_sound_buffer :: proc(sound_output: ^SoundOutput) {
	region1, region2 : rawptr
	region1_size, region2_size: win.DWORD

	if result := the_sound_buffer->Lock(0, sound_output.sound_buffer_size_in_bytes , &region1, &region1_size, &region2, &region2_size, 0); win.SUCCEEDED(result) {
		// TODO assert that region1/2_size is valid
		// TODO Collapse these two loops

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

		the_sound_buffer->Unlock(region1, region1_size, region2, region2_size)
	} else {
		return // TODO Logging
	}
}

get_window_dimension :: proc "system" (window: win.HWND) -> (width, height: i32) {
	client_rect : win.RECT
	win.GetClientRect(window, &client_rect)
	width  = client_rect.right  - client_rect.left
	height = client_rect.bottom - client_rect.top
	return width, height
}

resize_DIB_section :: proc "system" (buffer: ^OffscreenBuffer, width, height: i32) {
	// TODO Bulletproof this.
	// Maybe don't free first, free after, then free first if that fails.
	if buffer.memory != nil {
		win.VirtualFree(buffer.memory, 0, win.MEM_RELEASE)
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
				biHeight        = -buffer.height,
				biPlanes        = 1,
				biBitCount      = 32,
				biCompression   = win.BI_RGB,
		}
	}

	bytes_per_pixel :: 4
	bitmap_memory_size := buffer.width * buffer.height * bytes_per_pixel
	buffer.memory = cast([^]OffscreenBufferColor) win.VirtualAlloc(nil, uint(bitmap_memory_size), win.MEM_COMMIT, win.PAGE_READWRITE)

	// TODO probably clear this to black
}

display_buffer_in_window :: proc "system" (buffer: OffscreenBuffer, device_context: win.HDC, window_width, window_height: i32){
	buffer := buffer
	// TODO aspect ratio correction
	win.StretchDIBits(
		device_context,
		0, 0, window_width, window_height,
		0, 0, buffer.width, buffer.height,
		buffer.memory,
		&buffer.info,
		win.DIB_RGB_COLORS,
		win.SRCCOPY
	)
}

main_window_callback :: proc "system" (window:  win.HWND, message: win.UINT, w_param: win.WPARAM, l_param: win.LPARAM) -> (result: win.LRESULT) {
	switch message {
	case win.WM_SYSKEYUP, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_KEYDOWN:
		context = runtime.default_context()
		assert(false, "keyboard-event came in through a non-dispatched event")
	case win.WM_CLOSE: // TODO Handle this with a message to the user
		RUNNING = false
	case win.WM_DESTROY: // TODO handle this as an error - recreate window?
		RUNNING = false
	case win.WM_ACTIVATEAPP:
	case win.WM_PAINT:
		paint: win.PAINTSTRUCT
		device_context := win.BeginPaint(window, &paint)

		window_width, window_height := get_window_dimension(window)
		display_buffer_in_window(the_back_buffer, device_context, window_width, window_height)

		win.EndPaint(window, &paint)
	case:
		result = win.DefWindowProcA(window, message, w_param, l_param)
	}
	return result
}

process_pending_messages :: proc(keyboard_controller: ^GameInputController) {
	process_win_keyboard_message :: proc(new_state: ^GameInputButton, is_down: b32) {
		assert(is_down != new_state.ended_down)
		new_state.ended_down = is_down
		new_state.half_transition_count += 1
	}

	message : win.MSG
	for win.PeekMessageW(&message, nil, 0, 0, win.PM_REMOVE) {
		switch message.message {
		case win.WM_QUIT:
			RUNNING = false
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
					RUNNING = false
					process_win_keyboard_message(&keyboard_controller.back          , is_down)
				case win.VK_X:
					process_win_keyboard_message(&keyboard_controller.start         , is_down)
				case win.VK_SPACE:
				case win.VK_F4:
					if alt_down do RUNNING = false
				}
			}
		case:
			win.TranslateMessage(&message)
			win.DispatchMessageW(&message)
		}
	}
}