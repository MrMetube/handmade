package main

import win "core:sys/windows"
import gl "vendor:OpenGL"

init_opengl :: proc(window: win.HWND) {
    dc := win.GetDC(window)
    defer win.ReleaseDC(window, dc)
    
    desired_pixel_format := win.PIXELFORMATDESCRIPTOR{
        nSize      = size_of(win.PIXELFORMATDESCRIPTOR),
        nVersion   = 1,
        dwFlags    = win.PFD_SUPPORT_OPENGL | win.PFD_DRAW_TO_WINDOW | win.PFD_DOUBLEBUFFER,
        iPixelType = win.PFD_TYPE_RGBA,
        cColorBits = 32,
        cAlphaBits = 8,
        iLayerType = win.PFD_MAIN_PLANE,
    }
    
    suggested_pixel_format_index := win.ChoosePixelFormat(dc, &desired_pixel_format)
    suggested_pixel_format: win.PIXELFORMATDESCRIPTOR
    
    win.DescribePixelFormat(dc, suggested_pixel_format_index, size_of(suggested_pixel_format), &suggested_pixel_format)
    win.SetPixelFormat(dc, suggested_pixel_format_index, &suggested_pixel_format)
    
    gl_context := win.wglCreateContext(dc)
    
    if win.wglMakeCurrent(dc, gl_context) {
        gl.load_up_to(4, 6, win.gl_set_proc_address)
    } else {
        // @Logging
        unreachable()
    }
}