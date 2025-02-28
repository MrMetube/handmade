package main

import win "core:sys/windows"
import gl "vendor:OpenGL"

////////////////////////////////////////////////
//  Globals

BlitTextureHandle: u32

BlitVao: u32
BlitVbo, BlitTextureCoordinatesVbo: u32

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
        
        // Set up vertex data
        gl.GenVertexArrays(1, &BlitVao)
        gl.GenBuffers(1, &BlitVbo)
        gl.GenBuffers(1, &BlitTextureCoordinatesVbo)
        
        gl.GenTextures(1, &BlitTextureHandle)
        
        // Define the vertices for the triangles
        vertices := [6]v2{
            {-1, -1}, { 1, -1}, { 1,  1}, // Lower triangle
            {-1, -1}, { 1,  1}, {-1,  1}, // Upper triangle
        }
        
        texture_coordinates := [6]v2{
            {0,0}, {1, 0}, {1, 1},
            {0,0}, {1, 1}, {0, 1},
        }
    
        gl.BindVertexArray(BlitVao)
            // Bind and set the vertex buffer
            gl.BindBuffer(gl.ARRAY_BUFFER, BlitVbo)
        
                gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices[0], gl.STATIC_DRAW)

                gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 2 * size_of(f32), 0)
                gl.EnableVertexAttribArray(0)
                
            // Bind and set the vertex buffer
            gl.BindBuffer(gl.ARRAY_BUFFER, BlitTextureCoordinatesVbo)
                gl.BufferData(gl.ARRAY_BUFFER, size_of(texture_coordinates), &texture_coordinates[0], gl.STATIC_DRAW)
                
                gl.VertexAttribPointer(1, 2, gl.FLOAT, false, 2 * size_of(f32), 0)
                gl.EnableVertexAttribArray(1)
                    
            gl.BindBuffer(gl.ARRAY_BUFFER, 0)
        gl.BindVertexArray(0)
    } else {
        // @Logging
        unreachable()
    }
}