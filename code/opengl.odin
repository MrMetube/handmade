package main

import win "core:sys/windows"
import gl "vendor:OpenGl"


GlDefaultTextureFormat: i32 = gl.RGBA8

GlMajorVersion :: 4
GlMinorVersion :: 6

GlAttribs := [?]i32{
    win.WGL_CONTEXT_MAJOR_VERSION_ARB, GlMajorVersion,
    win.WGL_CONTEXT_MINOR_VERSION_ARB, GlMinorVersion,
    
    win.WGL_CONTEXT_FLAGS_ARB, (win.WGL_CONTEXT_DEBUG_BIT_ARB when ODIN_DEBUG else 0),
    
    win.WGL_CONTEXT_PROFILE_MASK_ARB, win.WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB,
    0,
}

glBegin:        proc (_: u32)
glEnd:          proc ()
glMatrixMode:   proc (_: i32)
glLoadIdentity: proc ()
glLoadMatrixf:  proc (_: ^m4)
glTexCoord2f:   proc (_,_: f32)
glVertex2f:     proc (_,_: f32)
glVertex3f:     proc (_,_,_: f32)
glColor4f:      proc (_,_,_,_: f32)
glColor4fv:     proc (_: [^] f32)
glTexEnvi:      proc (_: u32, _: u32, _: u32)
glAlphaFunc:    proc (_: u32, _: f32)

OpenGlInfo :: struct {
    modern_context: b32,
    
    vendor, 
    renderer,
    version, 
    shading_language_version, 
    extensions: cstring,
    
    GL_EXT_texture_sRGB,
    GL_EXT_framebuffer_sRGB: b32,
}

FramebufferHandles  := FixedArray(256, u32) { data = { 0 = 0, }, count = 1 }
FramebufferTextures := FixedArray(256, u32) { data = { 0 = 0, }, count = 1 }

////////////////////////////////////////////////

init_opengl :: proc (dc: win.HDC) -> (gl_context: win.HGLRC) {
    framebuffer_supports_srgb := load_wgl_extensions()
    set_pixel_format(dc, framebuffer_supports_srgb)
    
    if win.wglCreateContextAttribsARB != nil {
        gl_context = win.wglCreateContextAttribsARB(dc, nil, raw_data(GlAttribs[:]))
    }
    
    context_is_modern :b32= true
    if gl_context == nil {
        context_is_modern = false
        gl_context = win.wglCreateContext(dc)
    }
    
    if gl_context != nil {
        if win.wglMakeCurrent(dc, gl_context) {
            gl.load_up_to(GlMajorVersion, GlMinorVersion, win.gl_set_proc_address)
            
            extensions := opengl_get_extensions(context_is_modern)
            
            // @note(viktor): If we believe we can do full sRGB on the texture side
            // and the framebuffer side, then we can enable it, otherwise it is
            // safer for us to pass it straight through.
            if extensions.GL_EXT_texture_sRGB && framebuffer_supports_srgb {
                GlDefaultTextureFormat = gl.SRGB8_ALPHA8
                gl.Enable(gl.FRAMEBUFFER_SRGB)
            }
            
            gl.GenTextures(1, &GlobalBlitTextureHandle)
            
            if win.wglSwapIntervalEXT != nil {
                win.wglSwapIntervalEXT(1)
            }
        }
    }
    
    glTexEnvi(gl.TEXTURE_ENV, gl.TEXTURE_ENV_MODE, gl.MODULATE)
    
    return gl_context
}

load_wgl_extensions :: proc () -> (framebuffer_supports_srgb: b32) {
    window_class := win.WNDCLASSW {
        lpfnWndProc = win.DefWindowProcW,
        hInstance = auto_cast win.GetModuleHandleW(nil),
        lpszClassName = "HandmadeWGLLoader",
    }
    
    if win.RegisterClassW(&window_class) != 0 {
        window := win.CreateWindowExW(
            0,
            window_class.lpszClassName,
            "Handmade Hero",
            0,
            win.CW_USEDEFAULT,
            win.CW_USEDEFAULT,
            win.CW_USEDEFAULT,
            win.CW_USEDEFAULT,
            nil,
            nil,
            window_class.hInstance,
            nil,
        )
        defer win.DestroyWindow(window)
        
        dummy_dc := win.GetDC(window)
        defer win.ReleaseDC(window, dummy_dc)
        
        set_pixel_format(dummy_dc, false)
        
        dummy_context := win.wglCreateContext(dummy_dc)
        defer win.wglDeleteContext(dummy_context)
        
        if win.wglMakeCurrent(dummy_dc, dummy_context) {
            defer win.wglMakeCurrent(nil, nil)
            
            win.wglChoosePixelFormatARB    = auto_cast win.wglGetProcAddress("wglChoosePixelFormatARB")
            win.wglCreateContextAttribsARB = auto_cast win.wglGetProcAddress("wglCreateContextAttribsARB")
            win.wglSwapIntervalEXT         = auto_cast win.wglGetProcAddress("wglSwapIntervalEXT")
            win.wglGetExtensionsStringARB  = auto_cast win.wglGetProcAddress("wglGetExtensionsStringARB")
            
            if win.wglGetExtensionsStringARB != nil {
                len: u32
                extensions := cast(string) win.wglGetExtensionsStringARB(dummy_dc)
                for extensions != "" {
                    len += 1
                    if extensions[len] == ' ' {
                        part      := extensions[:len]
                        extensions = extensions[len+1:]
                        len = 0
                        if      part == "WGL_EXT_framebuffer_sRGB" do framebuffer_supports_srgb = true
                        else if part == "WGL_ARB_framebuffer_sRGB" do framebuffer_supports_srgb = true
                    }
                }
            }
            
            win.gl_set_proc_address(&glBegin, "glBegin")
            win.gl_set_proc_address(&glEnd, "glEnd")
            win.gl_set_proc_address(&glMatrixMode,   "glMatrixMode")
            win.gl_set_proc_address(&glLoadIdentity, "glLoadIdentity")
            win.gl_set_proc_address(&glLoadMatrixf, "glLoadMatrixf")
            win.gl_set_proc_address(&glTexCoord2f, "glTexCoord2f")
            win.gl_set_proc_address(&glTexEnvi, "glTexEnvi")
            win.gl_set_proc_address(&glVertex2f, "glVertex2f")
            win.gl_set_proc_address(&glVertex3f, "glVertex3f")
            win.gl_set_proc_address(&glColor4f, "glColor4f")
            win.gl_set_proc_address(&glColor4fv, "glColor4fv")
            win.gl_set_proc_address(&glAlphaFunc, "glAlphaFunc")
        }
    }
    
    return framebuffer_supports_srgb
}

opengl_get_extensions :: proc (modern_context: b32) -> (result: OpenGlInfo) {
    result.modern_context = modern_context
    
    result.vendor     = gl.GetString(gl.VENDOR)
    result.renderer   = gl.GetString(gl.RENDERER)
    result.version    = gl.GetString(gl.VERSION)
    result.extensions = gl.GetString(gl.EXTENSIONS)
    
    if modern_context {
        result.shading_language_version = gl.GetString(gl.SHADING_LANGUAGE_VERSION)
    } else {
        result.shading_language_version = "(none)"
    }
    
    length: int
    extensions := cast(string) result.extensions
    for len(extensions) > 0 {
        length += 1
        if length >= len(extensions) do break
        
        if extensions[length] == ' ' {
            part      := extensions[:length]
            extensions = extensions[length+1:]
            length = 0
            if      "GL_EXT_texture_sRGB"     == part do result.GL_EXT_texture_sRGB = true
            else if "GL_EXT_framebuffer_sRGB" == part do result.GL_EXT_framebuffer_sRGB = true
            else if "GL_ARB_framebuffer_sRGB" == part do result.GL_EXT_framebuffer_sRGB = true
        }
    }
    
    major: i32 = 1
    minor: i32 = 0
    gl.GetIntegerv(gl.MAJOR_VERSION, &major)
    gl.GetIntegerv(gl.MINOR_VERSION, &minor)
    
    if major > 2 || major == 2 && minor >= 1 {
        result.GL_EXT_texture_sRGB = true
    }
    
    return result
}

set_pixel_format :: proc (dc: win.HDC, framebuffer_supports_srgb: b32) {
    suggested_pixel_format_index: i32
    extended_pick: u32
    
    if win.wglChoosePixelFormatARB != nil {
        TRUE :: 1
        
        int_attribs := [?] i32 {
            /* 0 */ win.WGL_DRAW_TO_WINDOW_ARB, TRUE,
            /* 1 */ win.WGL_ACCELERATION_ARB,   win.WGL_FULL_ACCELERATION_ARB,
            /* 2 */ win.WGL_SUPPORT_OPENGL_ARB, TRUE,
            /* 3 */ win.WGL_DOUBLE_BUFFER_ARB,  TRUE,
            /* 4 */ win.WGL_PIXEL_TYPE_ARB,     win.WGL_TYPE_RGBA_ARB,
            /* 5 */ win.WGL_RED_BITS_ARB,       8,
            /* 6 */ win.WGL_GREEN_BITS_ARB,     8,
            /* 7 */ win.WGL_BLUE_BITS_ARB,      8,
            /* 8 */ win.WGL_ALPHA_BITS_ARB,     8,
            /* 9 */ win.WGL_DEPTH_BITS_ARB,     24,
            // @volatile see below
            /* 10 */win.WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB, TRUE,
            0,
        }
        
        if !framebuffer_supports_srgb {
            int_attribs[20] = 0 // @volatile Coupled to the ordering of the attribs itself
        }
        
        win.wglChoosePixelFormatARB(dc, raw_data(int_attribs[:]), nil, 1, &suggested_pixel_format_index, &extended_pick)
    }
    
    if extended_pick == 0 {
        desired_pixel_format := win.PIXELFORMATDESCRIPTOR{
            nSize      = size_of(win.PIXELFORMATDESCRIPTOR),
            nVersion   = 1,
            dwFlags    = win.PFD_SUPPORT_OPENGL | win.PFD_DRAW_TO_WINDOW | win.PFD_DOUBLEBUFFER,
            iPixelType = win.PFD_TYPE_RGBA,
            cColorBits = 32,
            cAlphaBits = 8,
            cDepthBits = 24,
            iLayerType = win.PFD_MAIN_PLANE,
        }
        
        suggested_pixel_format_index = win.ChoosePixelFormat(dc, &desired_pixel_format)
    }
    
    win.SetPixelFormat(dc, suggested_pixel_format_index, nil)
}

////////////////////////////////////////////////

gl_manage_textures :: proc (last: ^TextureOp) {
    timed_function()
    
    allocs, deallocs: u32
    
    for operation := last; operation != nil; operation = operation.next {
        switch &op in operation.value {
          case: unreachable()
        
          case TextureOpAllocate:
            allocs += 1
            op.result ^= gl_allocate_texture(op.width, op.height, op.data)
            
          case TextureOpDeallocate:
            deallocs += 1
            gl.DeleteTextures(1, &op.handle)
        }
    }
    
    // @todo(viktor): Display in debug system
    print("texture ops %, allocs % deallocs %\n", allocs + deallocs, allocs, deallocs)
}

gl_allocate_texture :: proc (width, height: i32, data: pmm) -> (result: u32) {
    timed_function()
    
    handle: u32
    gl.GenTextures(1, &handle)
    
    gl.BindTexture(gl.TEXTURE_2D, handle)
    
    gl.TexImage2D(gl.TEXTURE_2D, 0, GlDefaultTextureFormat, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, data)
    
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP)
    
    gl.BindTexture(gl.TEXTURE_2D, 0)
    
    result = handle
    
    return result
}

////////////////////////////////////////////////

gl_display_bitmap :: proc (bitmap: Bitmap, draw_region: Rectangle2i, clear_color: v4) {
    timed_function()

    gl_bind_frame_buffer(0, draw_region)
    
    gl.Disable(gl.SCISSOR_TEST)
    gl.Disable(gl.BLEND)
    defer gl.Enable(gl.BLEND)
    
    gl.BindTexture(gl.TEXTURE_2D, GlobalBlitTextureHandle)
    defer gl.BindTexture(gl.TEXTURE_2D, 0)
    
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, bitmap.width, bitmap.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(bitmap.memory))
    
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP)
    
    gl.Enable(gl.TEXTURE_2D)
    
    gl.ClearColor(clear_color.r, clear_color.g, clear_color.b, clear_color.a)
    gl.Clear(gl.COLOR_BUFFER_BIT)
    
    glMatrixMode(gl.TEXTURE)
    glLoadIdentity()
    
    glMatrixMode(gl.MODELVIEW)
    glLoadIdentity()
    
    glMatrixMode(gl.PROJECTION)
    glLoadIdentity()
    
    if true do unimplemented()
    
    // // b := safe_ratio_1(cast(f32) size.x, cast(f32) size.y)
    // // transform := m4 {
    // //     1, 0, 0, 0,
    // //     0, b, 0, 0,
    // //     0, 0, 1, 0,
    // //     0, 0, 1, 0,
    // // }
    
    // glLoadMatrixf(&transform[0,0])
    
    gl_rectangle({-1, -1, 0}, {1, 1, 0}, {1,1,1,1}, 0, 1)
}

////////////////////////////////////////////////

gl_render_commands :: proc (commands: ^RenderCommands, prep: RenderPrep, draw_region: Rectangle2i, window_dim: v2i) {
    timed_function()
    
    draw_dim := get_dimension(draw_region)
    gl_bind_frame_buffer(0, draw_region)
    defer gl_bind_frame_buffer(0, draw_region)
    
    gl.DepthMask(true)
    gl.ColorMask(true, true, true, true)
    gl.DepthFunc(gl.LEQUAL)
    gl.Enable(gl.DEPTH_TEST)
    glAlphaFunc(gl.GEQUAL, 0.1)
    gl.Enable(gl.ALPHA_TEST)
    
    gl.Enable(gl.TEXTURE_2D)
    gl.Enable(gl.SCISSOR_TEST)
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    
    glMatrixMode(gl.TEXTURE)
    glLoadIdentity()
    
    glMatrixMode(gl.MODELVIEW)
    glLoadIdentity()
    
    // @note(viktor): FrameBuffer 0 is the default frame buffer, which we got on initialization
    max_render_target_count := cast(i64) commands.max_render_target_index + 1
    assert(max_render_target_count < len(FramebufferHandles.data))
    if max_render_target_count >= FramebufferHandles.count {
        count := FramebufferHandles.count
        new_count := max_render_target_count - count
        
        FramebufferHandles.count  += new_count
        gl.GenFramebuffers(cast(i32) new_count, &FramebufferHandles.data[count])
        
        for render_target in slice(&FramebufferHandles)[count:] {
            texture := append(&FramebufferTextures, gl_allocate_texture(draw_dim.x, draw_dim.y, nil))
            
            gl.BindFramebuffer(gl.FRAMEBUFFER, render_target)
            gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture^, 0)
            // @todo(viktor): Create a depth buffer for this framebuffer
            // gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, texture^, 0)
            
            assert(gl.FRAMEBUFFER_COMPLETE == gl.CheckFramebufferStatus(gl.FRAMEBUFFER))
        }
    }
    
    for index in 0..< max_render_target_count {
        gl_bind_frame_buffer(cast(u32) index, draw_region)
        clear_color: v4
        if index == 0 {
            gl.Scissor(0, 0, window_dim.x, window_dim.y)
            clear_color = commands.clear_color
        } else {
            gl.Scissor(0, 0, draw_dim.x, draw_dim.y)
        }
        
        gl.ClearColor(clear_color.r, clear_color.g, clear_color.b, clear_color.a)
        gl.ClearDepth(1)
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
    }
    
    commands_dim := vec_cast(f32, commands.width, commands.height)
    dim := get_dimension(draw_region)
    clip_scale_x := safe_ratio_0(cast(f32) dim.x, commands_dim.x)
    clip_scale_y := safe_ratio_0(cast(f32) dim.y, commands_dim.y)
    
    clip_rect_index      := max(u16)
    current_target_index := max(u32)
    
    for header_offset: u32; header_offset < commands.push_buffer_data_at; {
        // :PointerArithmetic
        header := cast(^RenderEntryHeader) &commands.push_buffer[header_offset]
        header_offset += size_of(RenderEntryHeader)
        entry_data := &commands.push_buffer[header_offset]
        
        if header.type != .RenderEntryClip && clip_rect_index != header.clip_rect_index {
            clip_rect_index = header.clip_rect_index
            clip := prep.clip_rects.data[clip_rect_index]
            
            glMatrixMode(gl.PROJECTION)
            projection := clip.projection
            glLoadMatrixf(&projection)
            
            if current_target_index != clip.render_target_index {
                current_target_index = clip.render_target_index
                gl_bind_frame_buffer(current_target_index, draw_region)
            }
            
            rect := clip.clip_rect
            rect.min.x = round(i32, cast(f32) rect.min.x * clip_scale_x)
            rect.min.y = round(i32, cast(f32) rect.min.y * clip_scale_y)
            rect.max.x = round(i32, cast(f32) rect.max.x * clip_scale_x)
            rect.max.y = round(i32, cast(f32) rect.max.y * clip_scale_y)
            
            if current_target_index == 0 do rect = add_offset(rect, draw_region.min)
            
            gl.Scissor(rect.min.x, rect.min.y, rect.max.x - rect.min.x, rect.max.y - rect.min.y)
        }
        
        switch header.type {
          case .None: unreachable()
          case .RenderEntryClip: 
            // @note(viktor): clip rects are handled before rendering
            header_offset += size_of(RenderEntryClip)
            
          case .RenderEntryBlendRenderTargets:
            entry := cast(^RenderEntryBlendRenderTargets) entry_data
            header_offset += size_of(RenderEntryBlendRenderTargets)
            
            // @todo(viktor): if blending works without binding the dest then we can also remove that member from the Entry
            // gl_bind_frame_buffer(entry.dest_index, draw_region)
            // defer gl_bind_frame_buffer(current_target_index, draw_region)
            
            // @todo(viktor): If the window has black bars the rectangle will be offset incorrectly. thanks global variables!
            gl.BindTexture(gl.TEXTURE_2D, FramebufferTextures.data[entry.source_index])
            
            gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
            defer gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
            
            gl_rectangle(v3{0, 0, 0}, V3(commands_dim, 0), v4{1, 1, 1, entry.alpha})
            
          case .RenderEntryRectangle:
            entry := cast(^RenderEntryRectangle) entry_data
            header_offset += size_of(RenderEntryRectangle)
            
            color := entry.premultiplied_color
            color.r = square(color.r)
            color.g = square(color.g)
            color.b = square(color.b)
            
            gl.Disable(gl.TEXTURE_2D)
            defer gl.Enable(gl.TEXTURE_2D)
            
            gl_rectangle(entry.p, entry.p + V3(entry.dim, 0), color)
                
            when !false {
                min := entry.p
                max := entry.p + V3(entry.dim, 0)
                z := max.z
                
                glBegin(gl.LINES)
                    color.rgb = 0
                    glColor4fv(&color[0])
                    glVertex3f(min.x, min.y, z)
                    glVertex3f(max.x, min.y, z)
                    
                    glVertex3f(max.x, min.y, z)
                    glVertex3f(max.x, max.y, z)
                    
                    glVertex3f(max.x, max.y, z)
                    glVertex3f(min.x, max.y, z)
                    
                    glVertex3f(min.x, max.y, z)
                    glVertex3f(min.x, min.y, z)
                    
                glEnd()
            }
            
          case .RenderEntryBitmap:
            entry := cast(^RenderEntryBitmap) entry_data
            header_offset += size_of(RenderEntryBitmap)
            
            bitmap := entry.bitmap
            assert(bitmap.texture_handle != 0)
            
            if bitmap.width != 0 && bitmap.height != 0 {
                gl.BindTexture(gl.TEXTURE_2D, bitmap.texture_handle)
                
                // @todo(viktor): skewing with x_axis and y_axis is missing
                texel_x := 1 / cast(f32) bitmap.width
                texel_y := 1 / cast(f32) bitmap.height
                
                min_uv := v2{0+texel_x, 0+texel_y}
                max_uv := v2{1-texel_x, 1-texel_y}
                
                min := entry.p
                max := entry.p + entry.x_axis + entry.y_axis
                
                gl_rectangle(min, max, entry.premultiplied_color, min_uv, max_uv)
            }
            
          case:
            panic("Unhandled Entry")
        }
    }
}

////////////////////////////////////////////////

gl_bind_frame_buffer :: proc (render_target_index: u32, draw_region: Rectangle2i) {
    render_target := FramebufferHandles.data[render_target_index]
    gl.BindFramebuffer(gl.FRAMEBUFFER, render_target)
    
    window_dim := get_dimension(draw_region)
    if render_target_index == 0 {
        gl.Viewport(draw_region.min.x, draw_region.min.y, window_dim.x, window_dim.y)
    } else {
        gl.Viewport(0, 0, window_dim.x, window_dim.y)
    }
}

gl_rectangle :: proc (min, max: v3, color: v4, min_uv := v2{0,0}, max_uv := v2{1,1}) {
    glBegin(gl.TRIANGLES)
    
    glColor4f(color.r, color.g, color.b, color.a)
    
    // @note(viktor): Lower triangle
    glTexCoord2f(min_uv.x, min_uv.y)
    glVertex3f(min.x, min.y, min.z)
    
    glTexCoord2f(max_uv.x, min_uv.y)
    glVertex3f(max.x, min.y, min.z)
    
    glTexCoord2f(max_uv.x, max_uv.y)
    glVertex3f(max.x, max.y, max.z)
    
    // @note(viktor): Upper triangle
    glTexCoord2f(min_uv.x, min_uv.y)
    glVertex3f(min.x, min.y, min.z)
    
    glTexCoord2f(max_uv.x, max_uv.y)
    glVertex3f(max.x, max.y, max.z)
    
    glTexCoord2f(min_uv.x, max_uv.y)
    glVertex3f(min.x, max.y, max.z)
    
    glEnd()
}