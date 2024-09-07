package main

import "core:fmt"
import win "core:sys/windows"

main :: proc() {
	window_class := win.WNDCLASSW{
		hInstance = transmute(win.HINSTANCE) win.GetModuleHandleW(nil),
		lpszClassName = win.utf8_to_wstring("HandmadeWindowClass"),
		// hIcon =,
		// TODO: check if these flag matter
		style = win.CS_OWNDC | win.CS_HREDRAW | win.CS_VREDRAW,
		lpfnWndProc = main_window_callback,
	}

	if win.RegisterClassW(&window_class) != 0 {
		// TODO Logging
	}

	// TODO why is the name not seen as wstring / 2nd byte of short is 0 so it only shows an "H"
	name := win.utf8_to_wstring("Handmade")
	window_handle := win.CreateWindowExW(
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
	if window_handle == nil {
		// TODO Logging
	}

	loop: for {
		message : win.MSG
		message_result := win.GetMessageW(&message, nil, 0, 0);
		switch {
		case message_result < 0 : 
			break loop
		case message_result == 0: 
			break loop
		case:
			win.TranslateMessage(&message)
			win.DispatchMessageW(&message)
		}
	}
}

main_window_callback :: proc "system" (
	window:  win.HWND,
	message: win.UINT,
	w_param: win.WPARAM,
	l_param: win.LPARAM
) -> (result: win.LRESULT) {
	switch message {
		case win.WM_SIZE:
			win.OutputDebugStringA("WM_SIZE\n")
		case win.WM_DESTROY:
			win.OutputDebugStringA("WM_DESTROY\n")
		case win.WM_CLOSE:
			win.PostQuitMessage(0)
		case win.WM_ACTIVATEAPP:
			win.OutputDebugStringA("WM_ACTIVATEAPP\n")
		case win.WM_PAINT:
			paint: win.PAINTSTRUCT
			device_context := win.BeginPaint(window, &paint)
			
			width  := paint.rcPaint.right - paint.rcPaint.left
			height := paint.rcPaint.bottom-paint.rcPaint.top
			x := paint.rcPaint.left
			y := paint.rcPaint.top
			win.PatBlt(device_context, x, y, width, height, win.WHITENESS)

			win.EndPaint(window, &paint)
		case:
			result = win.DefWindowProcA(window, message, w_param, l_param)
	}
	return result
}
