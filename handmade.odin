package main

import "core:fmt"
import "vendor:miniaudio" //this is a concession to cpp oop code used in wasapi/xaudio2
import win "core:sys/windows"

// TODO this is a global for now
RUNNING : b32
the_sound_buffer: ^IDirectSoundBuffer

main :: proc() {
	load_xInput()

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

	// TODO why is the name not seen as wstring / 2nd byte of short is 0 so it only shows an "H"
	window := win.CreateWindowExW(
		0,
		window_class.lpszClassName,
		win.utf8_to_wstring("Handmade"),
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

	{
		samplerate :: 48000
		num_channels :: 2
		bytes_per_sample :: size_of(i16)
		init_dSound(window, samplerate * num_channels * bytes_per_sample, samplerate)
	}


	RUNNING = true
	xOffset, yOffset: i32
	
	device_context := win.GetDC(window)

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

				if a do yOffset += 2
				if b do vibration.wLeftMotorSpeed = 0x7FFF
			} else {
				// The controller is unavailable
			}
		}

		xOffset += 1
		XInputSetState(0, &vibration)
		
		render_weird_gradient(back_buffer, xOffset, yOffset)
		window_width, window_height := get_window_dimension(window)
		display_buffer_in_window(back_buffer, device_context, window_width, window_height)
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
