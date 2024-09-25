package main

import "base:intrinsics"

import "core:fmt"
import "core:math" // TODO implement sine ourself

import win "core:sys/windows"


// TODO this is a global for now
RUNNING : b32
the_sound_buffer: ^IDirectSoundBuffer

main :: proc() {
	init_xInput()

	window_class := win.WNDCLASSW{
		hInstance = cast(win.HINSTANCE) win.GetModuleHandleW(nil),
		lpszClassName = win.utf8_to_wstring("HandmadeWindowClass"),
		// hIcon =,
		style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
		lpfnWndProc = main_window_callback,
	}

	resize_DIB_section(&back_buffer, 1280, 720)

	if win.RegisterClassW(&window_class) != 0 {
		// TODO Logging
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
		// TODO Logging
	}

	device_context := win.GetDC(window)

	// graphics test
	xOffset, yOffset: i32

	// sound test
	sound_output : SoundOutput
	sound_output.samples_per_second = 48000
	sound_output.num_channels = 2
	sound_output.bytes_per_sample = size_of(i16) * sound_output.num_channels
	sound_output.audio_buffer_size = sound_output.samples_per_second * sound_output.bytes_per_sample
	sound_output.latency_sample_count = sound_output.samples_per_second / 15

	sound_output.tone_hz = 440
	sound_output.wave_period = sound_output.samples_per_second / sound_output.tone_hz
	sound_output.tone_volumne = 1000

	init_dSound(window, sound_output.audio_buffer_size, sound_output.samples_per_second)
	
	fill_sound_buffer(&sound_output, 0, sound_output.latency_sample_count * sound_output.bytes_per_sample)
	the_sound_buffer->Play(0, 0, DSBPLAY_LOOPING)
	
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

		// TODO should we poll this more frequently
		vibration : XINPUT_VIBRATION
		// TODO only check connected controllers, catch messages on connect / disconnect
		for controller_index in u32(0)..< XUSER_MAX_COUNT {
			controller_state : XINPUT_STATE
			if XInputGetState(controller_index, &controller_state) == win.ERROR_SUCCESS {
				// The controller is plugged in
				// TODO see if dwPacketNumber increments too rapidly
				pad := &controller_state.Gamepad
				dpad_up        := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_DPAD_UP)
				dpad_down      := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_DPAD_DOWN)
				dpad_left      := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_DPAD_LEFT)
				dpad_right     := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_DPAD_RIGHT)
				start          := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_START)
				back           := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_BACK)
				left_thumb     := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_LEFT_THUMB)
				right_thumb    := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_RIGHT_THUMB)
				left_shoulder  := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_LEFT_SHOULDER)
				right_shoulder := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_RIGHT_SHOULDER)
				a              := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_A)
				b              := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_B)
				x              := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_X)
				y              := cast(b32) (pad.wButtons & XINPUT_GAMEPAD_Y)

				left_stick_x  := pad.sThumbLX
				left_stick_y  := pad.sThumbLY
				right_stick_x := pad.sThumbRX
				right_stick_y := pad.sThumbRY


				// TODO deal with the dead zones properly
				xOffset += cast(i32) (left_stick_x / 4096)
				yOffset -= cast(i32) (left_stick_y / 4096)


				if back do RUNNING = false	
				
				sound_output.tone_hz = 440 + u32(440 * f32(left_stick_y) / 60000)
				fmt.println(sound_output.tone_hz)
				sound_output.wave_period = sound_output.samples_per_second / sound_output.tone_hz
				
				if b do vibration.wLeftMotorSpeed = 0x7FFF

			} else {
				// The controller is unavailable
			}
		}

		XInputSetState(0, &vibration)
		
		render_weird_gradient(back_buffer, xOffset, yOffset)

		// Direct Sound output test
		play_cursor, write_cursor : win.DWORD
		
		if result := the_sound_buffer->GetCurrentPosition(&play_cursor, &write_cursor); win.SUCCEEDED(result){
			byte_to_lock := (sound_output.running_sample_index*sound_output.bytes_per_sample) % sound_output.audio_buffer_size
			
			target_cursor := (play_cursor + sound_output.latency_sample_count * sound_output.bytes_per_sample)  % sound_output.audio_buffer_size
			bytes_to_write: win.DWORD
			
			// TODO Change this to using a lower latency offset from the playcursor
			// when we actually start having sound effects.
			if byte_to_lock > target_cursor {
				bytes_to_write = target_cursor - byte_to_lock + sound_output.audio_buffer_size
			} else{
				bytes_to_write = target_cursor - byte_to_lock
			}

			fill_sound_buffer(&sound_output, byte_to_lock, bytes_to_write)
		} else {
			// TODO Logging
		}

		window_width, window_height := get_window_dimension(window)
		display_buffer_in_window(back_buffer, device_context, window_width, window_height)

		end_counter : win.LARGE_INTEGER
		win.QueryPerformanceCounter(&end_counter)

		end_cycle_counter := intrinsics.read_cycle_counter()

		cycles_elapsed := end_cycle_counter - last_cycle_count
		mega_cycles_elapsed := f32(cycles_elapsed) / (1000 * 1000)

		counter_elapsed   := end_counter - last_counter
		ms_per_frame      := f32(counter_elapsed) / f32(perf_counter_frequency) * 1000
		frames_per_second := f32(perf_counter_frequency) / f32(counter_elapsed)
		fmt.printfln("Milliseconds/frame: %2.02f - frames/second: %4.02f - Megacycles/frame: %3.02f", ms_per_frame, frames_per_second, mega_cycles_elapsed) 
 		
		last_counter = end_counter
		last_cycle_count = end_cycle_counter
	}
}

SoundOutput :: struct {
	samples_per_second  : u32,
	num_channels        : u32,
	bytes_per_sample    : u32,
	audio_buffer_size   : u32,
	running_sample_index: u32,
	latency_sample_count: u32,

	tone_hz             : u32,
	wave_period         : u32,
	tone_volumne        : i16,
	t_sine: f32,
}

fill_sound_buffer :: proc(sound_output: ^SoundOutput, byte_to_lock, bytes_to_write: u32) {
	region1, region2 : rawptr
	region1_size, region2_size: win.DWORD

	if result := the_sound_buffer->Lock(byte_to_lock, bytes_to_write, &region1, &region1_size, &region2, &region2_size, 0); win.SUCCEEDED(result) {
		// TODO assert that region1/2_size is valid
		// TODO Collapse these two loops
		// TODO use [2]i16 for [LEFT RIGHT]
		sample_out := cast([^]i16) region1
		region1_sample_count := region1_size / sound_output.bytes_per_sample
		sample_out_index := 0
		for sample_index in 0..<region1_sample_count {
			sample_value := cast(i16) (math.sin(sound_output.t_sine) * f32(sound_output.tone_volumne))
			
			sample_out[sample_out_index + 0] = sample_value
			sample_out[sample_out_index + 1] = sample_value
			sample_out_index += 2

			sound_output.t_sine += math.TAU / f32(sound_output.wave_period)
			sound_output.running_sample_index += 1
		}

		sample_out = cast([^]i16) region2
		region2_sample_count := region2_size / sound_output.bytes_per_sample
		sample_out_index = 0
		for sample_index in 0..<region2_sample_count {
			sample_value := cast(i16) (math.sin(sound_output.t_sine) * f32(sound_output.tone_volumne))
			
			sample_out[sample_out_index + 0] = sample_value
			sample_out[sample_out_index + 1] = sample_value
			sample_out_index += 2

			sound_output.t_sine += math.TAU / f32(sound_output.wave_period)
			sound_output.running_sample_index += 1
		}
		
		the_sound_buffer->Unlock(region1, region1_size, region2, region2_size)
	} else {
		// TODO Logging
	}
}

OffscreenBuffer :: struct {
	info   : win.BITMAPINFO,
	memory : rawptr,
	width  : i32,
	height : i32,
}

back_buffer : OffscreenBuffer

get_window_dimension :: proc "system" (window: win.HWND) -> (width, height: i32) {
	client_rect : win.RECT
	win.GetClientRect(window, &client_rect)
	width  = client_rect.right  - client_rect.left
	height = client_rect.bottom - client_rect.top
	return width, height
}

render_weird_gradient :: proc "system" (buffer: OffscreenBuffer , xOffset, yOffset: i32) {
	WindowsColor :: struct {
		b, g, r, pad: u8
	}

	bitmap_memory_size := buffer.width * buffer.height * size_of(WindowsColor)
	bytes := cast([^]u8) buffer.memory
	row_index: i32 = 0

	for y in 0..<buffer.height {
		for x in 0..<buffer.width {
			pixel := cast(^WindowsColor) &bytes[row_index]
			pixel.b = u8(x + xOffset)
			pixel.g = u8(y + yOffset)
			row_index += size_of(WindowsColor)
		}
	}
}

resize_DIB_section :: proc "system" (buffer: ^OffscreenBuffer, width, height: i32) {
	// TODO Bulletproof this.
	// Maybe don't free first, free after, then free first if that fails.
	if buffer.memory != nil {
		win.VirtualFree(buffer.memory, 0, win.MEM_RELEASE)
	}

	buffer.width = width
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
	window_width, window_height: i32
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
		display_buffer_in_window(back_buffer, device_context, window_width, window_height)

		win.EndPaint(window, &paint)
	case:
		result = win.DefWindowProcA(window, message, w_param, l_param)
	}
	return result
}
