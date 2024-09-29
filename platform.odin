package main

import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import "core:math" // TODO implement sine ourself

import win "core:sys/windows"

/*
	TODO: THIS IS NOT A FINAL PLATFORM LAYER !!!

	- Saved game locations
	- Getting a handle to our own executable file
	- Asset loading path
	- Threading (launch a thread)
	- Raw Input (support for multiple keyboards
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

SoundOutput :: struct {
	samples_per_second  : u32,
	num_channels        : u32,
	bytes_per_sample    : u32,
	sound_buffer_size_in_bytes   : u32,
	running_sample_index: u32,
	latency_sample_count: u32,
}

OffscreenBuffer :: struct {
	info   : win.BITMAPINFO,
	memory : rawptr,
	width  : i32,
	height : i32,
}

main :: proc() {
	init_xInput()

	window_class := win.WNDCLASSW{
		hInstance = cast(win.HINSTANCE) win.GetModuleHandleW(nil),
		lpszClassName = win.utf8_to_wstring("HandmadeWindowClass"),
		// hIcon =,
		style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
		lpfnWndProc = main_window_callback,
	}

	resize_DIB_section(&the_back_buffer, 1280, 720)

	if win.RegisterClassW(&window_class) != 0 {
		return // TODO Logging
	}


	// NOTE: lpWindowName is either a cstring or a wstring depending on if UNICODE is defined
	// Odin expects that to be the case, but here it seems to be undefined so yeah.
	_window_title := "Handmade"
	window_title := cast([^]u16) raw_data(_window_title[:])
	window := win.CreateWindowExW(
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


	device_context := win.GetDC(window)



	sound_output : SoundOutput
	sound_output.samples_per_second = 48000
	sound_output.num_channels = 2
	sound_output.bytes_per_sample = size_of(i16) * sound_output.num_channels
	sound_output.sound_buffer_size_in_bytes = sound_output.samples_per_second * sound_output.bytes_per_sample
	sound_output.latency_sample_count = sound_output.samples_per_second / 15

	init_dSound(window, sound_output.sound_buffer_size_in_bytes, sound_output.samples_per_second)

	clear_sound_buffer(&sound_output)

	the_sound_buffer->Play(0, 0, DSBPLAY_LOOPING)
	
	// TODO make this like sixty seconds?
	// TODO pool with bitmap alloc
	samples := cast([^][2]i16) win.VirtualAlloc(nil, cast(uint) sound_output.sound_buffer_size_in_bytes, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)

	input : [2]GameInput
	old_input, new_input := input[0], input[1]



	free_all(context.temp_allocator)
	context.allocator = {}
	context.temp_allocator = {}

	game_memory : GameMemory
	{
		base_address: rawptr = cast(rawptr) terabytes(1) when #defined(INTERNAL) else nil
		
		permanent_storage_size := megabytes(64)
		transient_storage_size := gigabytes(4)
		total_size := permanent_storage_size + transient_storage_size

		storage_ptr := cast([^]u8) win.VirtualAlloc(base_address, cast(uint) total_size, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
		game_memory.permanent_storage = storage_ptr[0:][:permanent_storage_size]
		game_memory.transient_storage = storage_ptr[permanent_storage_size:][:transient_storage_size] 
	}

	if samples == nil || game_memory.permanent_storage == nil || game_memory.transient_storage == nil {
		return // TODO logging
	}

	RUNNING = true

	last_counter : win.LARGE_INTEGER
	perf_counter_frequency : win.LARGE_INTEGER
	win.QueryPerformanceCounter(&last_counter)
	win.QueryPerformanceFrequency(&perf_counter_frequency)

	last_cycle_count := intrinsics.read_cycle_counter()

	for RUNNING {
		message : win.MSG
		for win.PeekMessageW(&message, nil, 0, 0, win.PM_REMOVE) {
			if message.message == win.WM_QUIT do RUNNING = false
			win.TranslateMessage(&message)
			win.DispatchMessageW(&message)
		}

		// ---------------------- Input

		max_controller_count := XUSER_MAX_COUNT
		if max_controller_count > len(GameInput{}.controllers) {
			max_controller_count = len(GameInput{}.controllers)
		}
		// TODO should we poll this more frequently
		// TODO only check connected controllers, catch messages on connect / disconnect
		for controller_index in u32(0)..< XUSER_MAX_COUNT {
			controller_state : XINPUT_STATE

			old_controller := old_input.controllers[controller_index]
			new_controller := &new_input.controllers[controller_index]

			if XInputGetState(controller_index, &controller_state) == win.ERROR_SUCCESS {
				// The controller is plugged in
				// TODO see if dwPacketNumber increments too rapidly
				pad := controller_state.Gamepad
				
				// TODO all buttons
				dpad_up        := cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_UP)
				dpad_down      := cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_DOWN)
				dpad_left      := cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_LEFT)
				dpad_right     := cast(b16) (pad.wButtons & XINPUT_GAMEPAD_DPAD_RIGHT)
				
				start          := cast(b16) (pad.wButtons & XINPUT_GAMEPAD_START)
				back           := cast(b16) (pad.wButtons & XINPUT_GAMEPAD_BACK)

				left_thumb     := cast(b16) (pad.wButtons & XINPUT_GAMEPAD_LEFT_THUMB)
				right_thumb    := cast(b16) (pad.wButtons & XINPUT_GAMEPAD_RIGHT_THUMB)

				process_Xinput_digital_button :: proc(xInput_button_state: win.WORD, old_state: GameInputButton, new_state: ^GameInputButton, button_bit: win.WORD) {
					new_state.ended_down = cast(b32) (xInput_button_state & button_bit)
					new_state.half_transition_count = (old_state.ended_down == new_state.ended_down) ? 1 : 0
				}

				process_Xinput_digital_button(pad.wButtons, old_controller.left_shoulder,  &new_controller.left_shoulder,  XINPUT_GAMEPAD_LEFT_SHOULDER)
				process_Xinput_digital_button(pad.wButtons, old_controller.right_shoulder, &new_controller.right_shoulder, XINPUT_GAMEPAD_RIGHT_SHOULDER)
				process_Xinput_digital_button(pad.wButtons, old_controller.down,  &new_controller.down,  XINPUT_GAMEPAD_A)
				process_Xinput_digital_button(pad.wButtons, old_controller.right, &new_controller.right, XINPUT_GAMEPAD_B)
				process_Xinput_digital_button(pad.wButtons, old_controller.left,  &new_controller.left,  XINPUT_GAMEPAD_X)
				process_Xinput_digital_button(pad.wButtons, old_controller.up,    &new_controller.up,    XINPUT_GAMEPAD_Y)

				x, y : f32
				if pad.sThumbLX < 0 {
					x = (cast(f32)pad.sThumbLX) / 32768
				} else {
					x = (cast(f32)pad.sThumbLX) / 32767
				}
				if pad.sThumbLY < 0 {
					y = (cast(f32)pad.sThumbLY) / 32768
				} else {
					y = (cast(f32)pad.sThumbLY) / 32767
				}

				new_controller.is_analog = true
				new_controller.start = old_controller.end
				new_controller.min = {x,y}
				new_controller.max = {x,y}
				new_controller.end = {x,y}

				// TODO right stick

				if back do RUNNING = false


			} else {
				// The controller is unavailable
			}
		}

		// ---------------------- Update, Sound and Render

		// TODO: Tighten up sound logic so that we know where we should be
		// writing to and can anticipate the time spent in the game update.
		sound_is_valid: b32

		byte_to_lock  : u32
		bytes_to_write: win.DWORD
		{
			play_cursor, write_cursor : win.DWORD
			if result := the_sound_buffer->GetCurrentPosition(&play_cursor, &write_cursor); win.SUCCEEDED(result){
				byte_to_lock = (sound_output.running_sample_index*sound_output.bytes_per_sample) % sound_output.sound_buffer_size_in_bytes

				target_cursor := (play_cursor + sound_output.latency_sample_count * sound_output.bytes_per_sample)  % sound_output.sound_buffer_size_in_bytes

				if byte_to_lock > target_cursor {
					bytes_to_write = target_cursor - byte_to_lock + sound_output.sound_buffer_size_in_bytes
				} else{
					bytes_to_write = target_cursor - byte_to_lock
				}
				
				sound_is_valid = true
			} else {
				return // TODO Logging
			}
		}

		sound_buffer := GameSoundBuffer{
			samples_per_second = sound_output.samples_per_second,
			samples = samples[:(bytes_to_write/sound_output.bytes_per_sample)/2],
		}

		offscreen_buffer := GameOffscreenBuffer{
			memory = the_back_buffer.memory,
			width  = the_back_buffer.width,
			height = the_back_buffer.height,
		}

		game_update_and_render(&game_memory, offscreen_buffer, sound_buffer, new_input)

		// ---------------------- Output

		// Direct Sound output test
		if sound_is_valid {
			fill_sound_buffer(&sound_output, byte_to_lock, bytes_to_write, sound_buffer)
		}

		window_width, window_height := get_window_dimension(window)
		display_buffer_in_window(the_back_buffer, device_context, window_width, window_height)


		// ---------------------- Performance Counters

		end_counter : win.LARGE_INTEGER
		win.QueryPerformanceCounter(&end_counter)

		end_cycle_counter := intrinsics.read_cycle_counter()

		cycles_elapsed := end_cycle_counter - last_cycle_count
		mega_cycles_elapsed := f32(cycles_elapsed) / (1000 * 1000)

		counter_elapsed   := end_counter - last_counter
		ms_per_frame      := f32(counter_elapsed) / f32(perf_counter_frequency) * 1000
		frames_per_second := f32(perf_counter_frequency) / f32(counter_elapsed)
		// fmt.printfln("Milliseconds/frame: %2.02f - frames/second: %4.02f - Megacycles/frame: %3.02f", ms_per_frame, frames_per_second, mega_cycles_elapsed)

		last_counter = end_counter
		last_cycle_count = end_cycle_counter

		// ----------------------
		
		swap(&old_input, &new_input)
	}
}

fill_sound_buffer :: proc(sound_output: ^SoundOutput, byte_to_lock, bytes_to_write: u32, source: GameSoundBuffer) {
	region1, region2 : rawptr
	region1_size, region2_size: win.DWORD

	if result := the_sound_buffer->Lock(byte_to_lock, bytes_to_write, &region1, &region1_size, &region2, &region2_size, 0); win.SUCCEEDED(result) {
		// TODO assert that region1/2_size is valid
		// TODO Collapse these two loops
		// TODO use [2]i16 for [LEFT RIGHT]

		dest_samples := cast([^]i16) region1
		region1_sample_count := region1_size / sound_output.bytes_per_sample
		dest_sample_index := 0
		source_sample_index := 0

		for _ in 0..<region1_sample_count {
			if source_sample_index >= len(source.samples) do break
			if source_sample_index+1 >= len(source.samples) do break
			dest_samples[dest_sample_index + 0] = source.samples[source_sample_index].x
			dest_samples[dest_sample_index + 1] = source.samples[source_sample_index].y
			dest_sample_index += 2
			source_sample_index += 1

			sound_output.running_sample_index += 1
		}

		dest_samples = cast([^]i16) region2
		region2_sample_count := region2_size / sound_output.bytes_per_sample
		dest_sample_index = 0

		for _ in 0..<region2_sample_count {
			if source_sample_index >= len(source.samples) do break
			if source_sample_index+1 >= len(source.samples) do break
			dest_samples[dest_sample_index + 0] = source.samples[source_sample_index].x
			dest_samples[dest_sample_index + 1] = source.samples[source_sample_index].y
			dest_sample_index += 2
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
		// TODO use [2]i16 for [LEFT RIGHT]

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
	buffer.memory = win.VirtualAlloc(nil, uint(bitmap_memory_size), win.MEM_COMMIT, win.PAGE_READWRITE)

	// TODO probably clear this to black
}

display_buffer_in_window :: proc "system" (
	buffer: OffscreenBuffer, device_context: win.HDC,
	window_width, window_height: i32,
){
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
		vk_code := w_param

		was_down :b32= cast(b32) (l_param & (1 << 30))
		is_down  :b32= ! (cast(b32) (l_param & (1 << 31)))

		alt_down := cast(b32) (l_param & (1 << 29))

		if was_down != is_down {
			switch vk_code {
			case win.VK_W:
			case win.VK_A:
			case win.VK_S:
			case win.VK_D:
			case win.VK_Q:
			case win.VK_E:
			case win.VK_UP:
			case win.VK_DOWN:
			case win.VK_LEFT:
			case win.VK_RIGHT:
			case win.VK_ESCAPE:
				RUNNING = false
			case win.VK_SPACE:
			case win.VK_F4:
				if alt_down do RUNNING = false
			}
		}
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
