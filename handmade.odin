package main

import "core:fmt"
import win "core:sys/windows"

// TODO this is a global for now
@(private="file")
RUNNING : b32

main :: proc() {
	window_class := win.WNDCLASSW{
		hInstance = transmute(win.HINSTANCE) win.GetModuleHandleW(nil),
		lpszClassName = win.utf8_to_wstring("HandmadeWindowClass"),
		// hIcon =,
		style = win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc = main_window_callback,
	}

	resize_DIB_section(&back_buffer, 1280, 720)

	if win.RegisterClassW(&window_class) != 0 {
		// TODO Logging
	}

	// TODO why is the name not seen as wstring / 2nd byte of short is 0 so it only shows an "H"
	name := win.utf8_to_wstring("Handmade")
	window := win.CreateWindowExW(
		0,
		window_class.lpszClassName,
		name,
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
	
	RUNNING = true
	xOffset, yOffset: i32
	
	for RUNNING {
		message : win.MSG
		for win.PeekMessageW(&message, nil, 0, 0, win.PM_REMOVE) {
			if message.message == win.WM_QUIT do RUNNING = false
			win.TranslateMessage(&message)
			win.DispatchMessageW(&message)
		}

		xOffset += 1
		yOffset += 2

		render_weird_gradient(back_buffer, xOffset, yOffset)
		{
			device_context := win.GetDC(window)
			defer win.ReleaseDC(window, device_context)
			window_width, window_height := get_window_dimension(window)
			display_buffer_in_window(back_buffer, device_context, window_width, window_height, 0, 0, window_width, window_height)
		}
	}
}

OffscreenBuffer :: struct {
	info   : win.BITMAPINFO,
	memory : rawptr,
	width  : i32,
	height : i32,
	bytes_per_pixel: i32,
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

	// TODO simplify it with struct
	bitmap_memory_size := buffer.width * buffer.height * buffer.bytes_per_pixel
	bytes := transmute([^]u8) buffer.memory
	row_index: i32 = 0
	for y in 0..<buffer.height {
		for x in 0..<buffer.width {
			pixel := transmute(^WindowsColor) &bytes[row_index]
			pixel.b = u8(x + xOffset)
			pixel.g = u8(y + yOffset)
			row_index += buffer.bytes_per_pixel
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
	buffer.bytes_per_pixel = 4

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

	bitmap_memory_size := buffer.width * buffer.height * buffer.bytes_per_pixel
	buffer.memory = win.VirtualAlloc(nil, uint(bitmap_memory_size), win.MEM_COMMIT, win.PAGE_READWRITE)

	// TODO probably clear this to black
}

display_buffer_in_window :: proc "system" (
	buffer: OffscreenBuffer, device_context: win.HDC, 
	window_width, window_height: i32, x, y, width, height: i32
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

main_window_callback :: proc "system" (
	window:  win.HWND,
	message: win.UINT,
	w_param: win.WPARAM,
	l_param: win.LPARAM
) -> (result: win.LRESULT) {
	switch message {
		case win.WM_SIZE:
		case win.WM_CLOSE: // TODO Handle this with a message to the user
			RUNNING = false
		case win.WM_DESTROY: // TODO handle this as an error - recreate window?
			RUNNING = false
		case win.WM_ACTIVATEAPP:
		case win.WM_PAINT:
			paint: win.PAINTSTRUCT
			device_context := win.BeginPaint(window, &paint)
			
			x := paint.rcPaint.left
			y := paint.rcPaint.top
			width  := paint.rcPaint.right  - paint.rcPaint.left
			height := paint.rcPaint.bottom - paint.rcPaint.top
			
			window_width, window_height := get_window_dimension(window)
			display_buffer_in_window(back_buffer, device_context, window_width, window_height, x, y, width, height)

			win.EndPaint(window, &paint)
		case:
			result = win.DefWindowProcA(window, message, w_param, l_param)
	}
	return result
}