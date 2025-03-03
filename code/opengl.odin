package main

import win "core:sys/windows"
import gl "vendor:OpenGL"

// TODO(viktor): REMOVE THIS
import glm "core:math/linalg/glsl" 
import "core:fmt"

////////////////////////////////////////////////
//  Globals

BlitTextureHandle: u32

BlitVertexArrayObject: u32
BlitVertexBufferObject, BlitTextureCoordinatesVbo: u32

Uniforms: gl.Uniforms

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
        gl.GenVertexArrays(1, &BlitVertexArrayObject)
        gl.GenBuffers(1, &BlitVertexBufferObject)
        gl.GenBuffers(1, &BlitTextureCoordinatesVbo)
        
        gl.GenTextures(1, &BlitTextureHandle)
        
        // useful utility procedures that are part of vendor:OpenGl
        program, program_ok := gl.load_shaders_source(VertexShader, PixelShader)
        if !program_ok {
            // @Logging Failed to create GLSL program
            fmt.println(gl.get_last_error_message())
            return
        }
        gl.UseProgram(program)

        Uniforms = gl.get_uniforms_from_program(program)
        
    } else {
        // @Logging
        unreachable()
    }
}

display_buffer_in_window :: proc "system" (buffer: ^OffscreenBuffer, device_context: win.HDC, window_width, window_height: i32) {    
    when false {
    gl.Viewport(0, 0, window_width, window_height)
    
    gl.ClearColor(1, 0, 1, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
    
    gl.ActiveTexture(gl.TEXTURE0)
    
    gl.BindTexture(gl.TEXTURE_2D, BlitTextureHandle)
    
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_BASE_LEVEL, 0)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_LOD, 0)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LOD, 0)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LEVEL, 0)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_R, gl.CLAMP)
    
    gl.Uniform1i(Uniforms["gameTexture"].location, 0)
    
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, buffer.width, buffer.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(buffer.memory));
    gl.Enable(gl.TEXTURE_2D)
    
    gl.BindVertexArray(BlitVertexArrayObject)
            // Bind and set the vertex buffer
            gl.BindBuffer(gl.ARRAY_BUFFER, BlitVertexBufferObject)
                vertices := [6]v2{
                    {0, 0}, { cast(f32) buffer.width, 0}, { cast(f32) buffer.width, cast(f32) buffer.height}, // Lower triangle
                    {0, 0}, { cast(f32) buffer.width, cast(f32) buffer.height}, {0, cast(f32) buffer.height}, // Upper triangle
                }
                
                gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices[0], gl.STATIC_DRAW)

                gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of(v2), 0)
                gl.EnableVertexAttribArray(0)
                
            // Bind and set the vertex buffer
            gl.BindBuffer(gl.ARRAY_BUFFER, BlitTextureCoordinatesVbo)
                texture_coordinates := [6]v2{
                    {0,0}, {1, 0}, {1, 1},
                    {0,0}, {1, 1}, {0, 1},
                }
                
                gl.BufferData(gl.ARRAY_BUFFER, size_of(texture_coordinates), &texture_coordinates[0], gl.STATIC_DRAW)
                
                gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(v2), 0)
                gl.EnableVertexAttribArray(1)
                    
            gl.BindBuffer(gl.ARRAY_BUFFER, 0)
        gl.BindVertexArray(0)
    
    width  := buffer.width  == 0 ? 1 : cast(f32) buffer.width
    height := buffer.height == 0 ? 1 : cast(f32) buffer.height
    
    u_transform := m4{
        2 / width, 0         , 0, -1,
        0        , 2 / height, 0, -1,
        0        , 0         , 1,  0,
        0        , 0         , 0,  1,
    }
    
    gl.UniformMatrix4fv(Uniforms["u_transform"].location, 1, false, &u_transform[0, 0])

    // Draw the triangles
    gl.BindVertexArray(BlitVertexArrayObject)
    gl.DrawArrays(gl.TRIANGLES, 0, 6)
    gl.BindVertexArray(0)
    }
    
    win.SwapBuffers(device_context)
}

VertexShader := `#version 330 core

layout(location=0) in vec3 a_position;
layout(location=1) in vec2 a_tex_coords;

out vec2 v_tex_coords;

uniform mat4 u_transform;

void main() {
	gl_Position = u_transform * vec4(a_position, 1.0);
    v_tex_coords = a_tex_coords;
}
`

PixelShader := `#version 330 core

uniform sampler2D gameTexture;

in vec2 v_tex_coords;

out vec4 o_color;

void main() {
	o_color = texture(gameTexture, v_tex_coords);
}
`