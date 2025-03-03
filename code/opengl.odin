package main

import win "core:sys/windows"
import gl "vendor:OpenGL"

import "core:fmt"

////////////////////////////////////////////////
//  Globals

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

render_to_window :: proc(commands: ^RenderCommands, render_queue: ^PlatformWorkQueue, device_context: win.HDC, window_width, window_height: i32) {    
    sort_render_elements(commands)
    
    /* 
    
        if all_assets_valid(&render_group) /* AllResourcesPresent :CutsceneEpisodes */ {
            render_group_to_output(tran_state.high_priority_queue, render_group, buffer, &tran_state.arena)
        }
    
    */
    
    RenderInHardware :: true
    DisplayViaSoftware :: false
    
    if RenderInHardware {
         gl_render_group_to_output(commands, window_width, window_height)
         
         win.SwapBuffers(device_context)
    } else {
        offscreen_buffer := Bitmap{
            memory = GlobalBackBuffer.memory,
            width  = GlobalBackBuffer.width,
            height = GlobalBackBuffer.height,
        }
        tiled_render_group_to_output(render_queue, commands, offscreen_buffer)
        if DisplayViaSoftware {
            // TODO(viktor): recover old strechdibits routine
        } else {
            display_via_opengl(commands.width, commands.height, GlobalBackBuffer.memory, device_context)
        }
    }
}

gl_rectangle :: proc(min, max: v2, color: v4) {
    @static vertex_array_object: u32
    
    vertices := [6]v2{
        min, { max.x, min.y}, max, // Lower triangle
        min, max, {min.x,  max.y}, // Upper triangle
    }
    @static init: b32
    if !init {
        init = true
        gl.GenVertexArrays(1, &vertex_array_object)
    }
    
    gl.BindVertexArray(vertex_array_object)
    
    gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices[0], gl.STATIC_DRAW)

    gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of(v2), 0)
    gl.EnableVertexAttribArray(0)
    
    
    gl.BindVertexArray(vertex_array_object)
    gl.DrawArrays(gl.TRIANGLES, 0, 6)
    gl.BindVertexArray(0)
}

display_via_opengl :: #force_inline proc(width, height: i32, memory: []Color, device_context: win.HDC) {
    gl.Viewport(0, 0, width, height)
    
    gl_set_screenspace(width, height)
    
    gl.ClearColor(1, 0, 1, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)
    
    gl.ActiveTexture(gl.TEXTURE0)
    
    gl.BindTexture(gl.TEXTURE_2D, 1)
    
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
    
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(memory));
    gl.Enable(gl.TEXTURE_2D)
    
    gl.BindVertexArray(BlitVertexArrayObject)
        // Bind and set the vertex buffer
        gl.BindBuffer(gl.ARRAY_BUFFER, BlitVertexBufferObject)
            gl_rectangle(v2{0,0}, vec_cast(f32, width, height), 1)
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
    
    // Draw the triangles
    gl.BindVertexArray(BlitVertexArrayObject)
    gl.DrawArrays(gl.TRIANGLES, 0, 6)
    gl.BindVertexArray(0)
    
    win.SwapBuffers(device_context)
}

gl_set_screenspace :: proc(width, height: i32) {
    a := width  == 0 ? 1 : 2 / cast(f32) width
    b := height == 0 ? 1 : 2 / cast(f32) height
    
    u_transform := m4{
        a, 0, 0, -1,
        0, b, 0, -1,
        0, 0, 1,  0,
        0, 0, 0,  1,
    }
    
    gl.UniformMatrix4fv(Uniforms["u_transform"].location, 1, false, &u_transform[0, 0])
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