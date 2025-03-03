package game

import gl "vendor:OpenGL"
import win "core:sys/windows"

// @Copypasta from code/opengl
Uniforms: gl.Uniforms

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

render_to_opengl :: proc(group: ^RenderGroup, target: Bitmap) {
    @static init: b32
    
    if !init {
        init = true
        
        // TODO(viktor): this is redundant with the platform layout, but to extract this
        // we need to find a better cut off, otherwise we need to export almost all the 
        // definitions
        gl.load_up_to(4, 6, win.gl_set_proc_address)
        program, program_ok := gl.load_shaders_source(VertexShader, PixelShader)
        if !program_ok {
            // @Logging Failed to create GLSL program
            return
        }
        gl.UseProgram(program)

        Uniforms = gl.get_uniforms_from_program(program)
    }
    
    gl.Viewport(0, 0, target.width, target.height)
    
    gl.Enable(gl.TEXTURE_2D)
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    
    // :PointerArithmetic
    sort_entries := (cast([^]TileSortEntry) &group.push_buffer[group.sort_entry_at])[:group.push_buffer_element_count]
    
    for sort_entry in sort_entries {
        header := cast(^RenderGroupEntryHeader) &group.push_buffer[sort_entry.push_buffer_offset]
        //:PointerArithmetic
        entry_data := &group.push_buffer[sort_entry.push_buffer_offset + size_of(RenderGroupEntryHeader)]
        
        switch header.type {
          case RenderGroupEntryClear:
            entry := cast(^RenderGroupEntryClear) entry_data
            
            color := entry.color
            gl.ClearColor(color.r, color.g, color.b, color.a)
            gl.Clear(gl.COLOR_BUFFER_BIT)
            
          case RenderGroupEntryRectangle:
            entry := cast(^RenderGroupEntryRectangle) entry_data
            
            gl.Disable(gl.TEXTURE_2D)
            gl_rectangle(entry.rect.min, entry.rect.max, entry.color)
            gl.Enable(gl.TEXTURE_2D)
            
          case RenderGroupEntryBitmap:
            entry := cast(^RenderGroupEntryBitmap) entry_data
            
            min := entry.p
            max := min + entry.size
            
            bitmap := &entry.bitmap
            if bitmap.handle != 0 {
                gl.BindTexture(gl.TEXTURE_2D, bitmap.handle)
            } else {
                @static texture_count: u32
                bitmap.handle = texture_count
                texture_count += 1
                gl.BindTexture(gl.TEXTURE_2D, bitmap.handle)
                
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_BASE_LEVEL, 0)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_LOD, 0)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LOD, 0)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LEVEL, 0)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP)
                gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_R, gl.CLAMP)
            }

            gl.Uniform1i(Uniforms["gameTexture"].location, 0)
            
            gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, bitmap.width, bitmap.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(bitmap.memory));

            gl_rectangle(min, max, entry.color)
            
          case RenderGroupEntryCoordinateSystem:
          case:
            panic("Unhandled Entry")
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
