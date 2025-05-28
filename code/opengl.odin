package main

import win "core:sys/windows"
import gl "vendor:OpenGl"


GlDefaultTextureFormat :i32= gl.RGBA8

GlMajorVersion :: 4
GlMinorVersion :: 6

GlAttribs := [?]i32{
    win.WGL_CONTEXT_MAJOR_VERSION_ARB, GlMajorVersion,
    win.WGL_CONTEXT_MINOR_VERSION_ARB, GlMinorVersion,
    
    win.WGL_CONTEXT_FLAGS_ARB, (win.WGL_CONTEXT_DEBUG_BIT_ARB when ODIN_DEBUG else 0),
    
    win.WGL_CONTEXT_PROFILE_MASK_ARB, win.WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB,
    0,
}

glBegin: proc(_: u32)
glEnd: proc()
glMatrixMode: proc(_: i32)
glLoadIdentity: proc()
glLoadMatrixf: proc(_:[^]f32)
glTexCoord2f: proc(_,_:f32)
glVertex2f: proc(_,_:f32)
glVertex2fv: proc(_:[^]f32)
glColor4f: proc(_,_,_,_:f32)
glColor4fv: proc(_:[^]f32)
glTexEnvi: proc(target: u32, pname: u32, param: u32)

OpenGlInfo :: struct {
    modern_context: b32,
    
    vendor, renderer, version, shading_language_version, extensions: cstring,
    GL_EXT_texture_sRGB: b32,
    GL_EXT_framebuffer_sRGB: b32,
}

////////////////////////////////////////////////

init_opengl :: proc(dc: win.HDC) -> (gl_context: win.HGLRC) {
    framebuffer_supports_srgb := load_wgl_extensions()
    
    if win.wglCreateContextAttribsARB != nil {
        set_pixel_format(dc, framebuffer_supports_srgb)
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
    
    return gl_context
}

load_wgl_extensions :: proc() -> (framebuffer_supports_srgb: b32) {
    window_class := win.WNDCLASSW {
        lpfnWndProc = win.DefWindowProcW,
        hInstance = auto_cast win.GetModuleHandleW(nil),
        lpszClassName = win.L("HandmadeWGLLoader"),
    }
    
    if win.RegisterClassW(&window_class) != 0 {
        window := win.CreateWindowExW(
            0,
            window_class.lpszClassName,
            win.L("Handmade Hero"),
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
            win.gl_set_proc_address(&glVertex2fv, "glVertex2fv")
            win.gl_set_proc_address(&glColor4f, "glColor4f")
            win.gl_set_proc_address(&glColor4fv, "glColor4fv")
        }
    }
    
    return framebuffer_supports_srgb
}

opengl_get_extensions :: proc(modern_context: b32) -> (result: OpenGlInfo) {
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
    
    len: u32
    extensions := cast(string) result.extensions
    for extensions != "" {
        len += 1
        if extensions[len] == ' ' {
            part      := extensions[:len]
            extensions = extensions[len+1:]
            len = 0
            if      "GL_EXT_texture_sRGB"     == part do result.GL_EXT_texture_sRGB = true
            else if "GL_EXT_framebuffer_sRGB" == part do result.GL_EXT_framebuffer_sRGB = true
            else if "GL_ARB_framebuffer_sRGB" == part do result.GL_EXT_framebuffer_sRGB = true
        }
    }
    
    return result
}

set_pixel_format :: proc(dc: win.HDC, framebuffer_supports_srgb: b32) {
    suggested_pixel_format: win.PIXELFORMATDESCRIPTOR
    suggested_pixel_format_index: i32
    extended_pick: u32
    
    if win.wglChoosePixelFormatARB != nil {
        TRUE :: 1
        
        int_attribs := [?]i32{
            win.WGL_DRAW_TO_WINDOW_ARB, TRUE,
            win.WGL_ACCELERATION_ARB, win.WGL_FULL_ACCELERATION_ARB,
            win.WGL_SUPPORT_OPENGL_ARB, TRUE,
            win.WGL_DOUBLE_BUFFER_ARB, TRUE,
            win.WGL_PIXEL_TYPE_ARB, win.WGL_TYPE_RGBA_ARB,
            win.WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB, TRUE,
            0,
        }
        
        if !framebuffer_supports_srgb {
            int_attribs[10] = 0 // @volatile Coupled to the ordering of the attribs itself
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
            iLayerType = win.PFD_MAIN_PLANE,
        }
        
        suggested_pixel_format_index = win.ChoosePixelFormat(dc, &desired_pixel_format)
    }
    
    win.DescribePixelFormat(dc, suggested_pixel_format_index, size_of(suggested_pixel_format), &suggested_pixel_format)
    win.SetPixelFormat(dc, suggested_pixel_format_index, &suggested_pixel_format)
    
}

display_bitmap_gl :: proc(width, height: i32, bitmap: Bitmap, device_context: win.HDC) {
    gl.Disable(gl.SCISSOR_TEST)
    
    gl.Viewport(0, 0, width, height)
    
    gl_set_screenspace(width, height)
    
    gl.BindTexture(gl.TEXTURE_2D, GlobalBlitTextureHandle)
    defer gl.BindTexture(gl.TEXTURE_2D, 0)
    
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, bitmap.width, bitmap.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(bitmap.memory))
    
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP)
    glTexEnvi(gl.TEXTURE_ENV, gl.TEXTURE_ENV_MODE, gl.MODULATE)
    
    gl.Enable(gl.TEXTURE_2D)

    gl.ClearColor(1, 0, 1, 0)
    gl.Clear(gl.COLOR_BUFFER_BIT)

    glMatrixMode(gl.TEXTURE)
    glLoadIdentity()

    glMatrixMode(gl.MODELVIEW)
    glLoadIdentity()

    glMatrixMode(gl.PROJECTION)
    glLoadIdentity()

    glBegin(gl.TRIANGLES)
    
    P :f32= 1
    
    // @note(viktor): Lower triangle
    glTexCoord2f(0.0, 0.0)
    glVertex2f(-P, -P)
    
    glTexCoord2f(1.0, 0.0)
    glVertex2f(P, -P)
    
    glTexCoord2f(1.0, 1.0)
    glVertex2f(P, P)
    
    // @note(viktor): Upper triangle
    glTexCoord2f(0.0, 0.0)
    glVertex2f(-P, -P)
    
    glTexCoord2f(1.0, 1.0)
    glVertex2f(P, P)
    
    glTexCoord2f(0.0, 1.0)
    glVertex2f(-P, P)
    
    glEnd()
    
    win.SwapBuffers(device_context)
}

gl_render_commands :: proc(commands: ^RenderCommands, window_width, window_height: i32) {
    timed_function()
    
    gl.Viewport(0, 0, commands.width, commands.height)
    gl_set_screenspace(window_width, window_height)
    
    gl.Enable(gl.SCISSOR_TEST)
    gl.Enable(gl.TEXTURE_2D)
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    
    count := commands.push_buffer_element_count
    // :PointerArithmetic
    if count == 0 do return
    sort_entries := (cast([^]SortEntry) &commands.push_buffer[commands.sort_entry_at])[:count]
    
    clip_rect_index := max(u16)
    for sort_entry, i in sort_entries {
        header := cast(^RenderEntryHeader) &commands.push_buffer[sort_entry.index]
        //:PointerArithmetic
        entry_data := &commands.push_buffer[sort_entry.index + size_of(RenderEntryHeader)]
        
        if clip_rect_index != header.clip_rect_index {
            clip_rect_index = header.clip_rect_index
            assert(clip_rect_index < commands.clip_rect_count)
            
            rect := commands.clip_rects[clip_rect_index].rect
            gl.Scissor(rect.min.x, rect.min.y, rect.max.x - rect.min.x, rect.max.y - rect.min.y)
        }
        
        switch header.type {
          case .RenderEntryClear:
            entry := cast(^RenderEntryClear) entry_data
            
            color := entry.premultiplied_color
            color.r = square(color.r)
            color.g = square(color.g)
            color.b = square(color.b)
            
            gl.ClearColor(color.r, color.g, color.b, color.a)
            gl.Clear(gl.COLOR_BUFFER_BIT)
            
          case .RenderEntryRectangle:
            entry := cast(^RenderEntryRectangle) entry_data
            
            color := entry.premultiplied_color
            color.r = square(color.r)
            color.g = square(color.g)
            color.b = square(color.b)
            
            gl.Disable(gl.TEXTURE_2D)
            gl_rectangle(entry.rect.min, entry.rect.max, color)
            gl.Enable(gl.TEXTURE_2D)
            
          case .RenderEntryBitmap:
            entry := cast(^RenderEntryBitmap) entry_data
            
            bitmap := entry.bitmap
            assert(bitmap.texture_handle != 0)
            
            if bitmap.width != 0 && bitmap.height != 0 {
                gl.BindTexture(gl.TEXTURE_2D, bitmap.texture_handle)
                
                texel_x := 1 / cast(f32) bitmap.width
                texel_y := 1 / cast(f32) bitmap.height
                
                min_uv := v2{0+texel_x, 0+texel_y}
                max_uv := v2{1-texel_x, 1-texel_y}
                
                min_x_min_y := entry.p
                max_x_min_y := entry.p + entry.x_axis
                min_x_max_y := entry.p + entry.y_axis
                max_x_max_y := entry.p + entry.x_axis + entry.y_axis
                
                glBegin(gl.TRIANGLES)
                    
                    glColor4fv(&entry.premultiplied_color[0])
                    // @note(viktor): Lower triangle
                    glTexCoord2f(min_uv.x, min_uv.y)
                    glVertex2fv(&min_x_min_y[0])

                    glTexCoord2f(max_uv.x, min_uv.y)
                    glVertex2fv(&max_x_min_y[0])

                    glTexCoord2f(max_uv.x, max_uv.y)
                    glVertex2fv(&max_x_max_y[0])

                    // @note(viktor): Upper triangle
                    glTexCoord2f(min_uv.x, min_uv.y)
                    glVertex2fv(&min_x_min_y[0])

                    glTexCoord2f(max_uv.x, max_uv.y)
                    glVertex2fv(&max_x_max_y[0])

                    glTexCoord2f(min_uv.x, max_uv.y)
                    glVertex2fv(&min_x_max_y[0])
                    
                glEnd()
            }
            
          case .RenderEntryClip:
            entry := cast(^RenderEntryBitmap) entry_data

          case:
            panic("Unhandled Entry")
        }
    }
}

gl_rectangle :: proc(min, max: v2, color: v4, min_uv := v2{0,0}, max_uv := v2{1,1}) {
    glBegin(gl.TRIANGLES)
    
    glColor4f(color.r, color.g, color.b, color.a)
    
    // @note(viktor): Lower triangle
    glTexCoord2f(min_uv.x, min_uv.y)
    glVertex2f(min.x, min.y)

    glTexCoord2f(max_uv.x, min_uv.y)
    glVertex2f(max.x, min.y)

    glTexCoord2f(max_uv.x, max_uv.y)
    glVertex2f(max.x, max.y)

    // @note(viktor): Upper triangle
    glTexCoord2f(min_uv.x, min_uv.y)
    glVertex2f(min.x, min.y)

    glTexCoord2f(max_uv.x, max_uv.y)
    glVertex2f(max.x, max.y)

    glTexCoord2f(min_uv.x, max_uv.y)
    glVertex2f(min.x, max.y)
    glEnd()
}

gl_set_screenspace :: proc(width, height: i32) {
    a := safe_ratio_1(2, cast(f32) width)
    b := safe_ratio_1(2, cast(f32) height)
    
    glMatrixMode(gl.TEXTURE)
    glLoadIdentity()
    
    glMatrixMode(gl.MODELVIEW)
    glLoadIdentity()
    
    transform := m4 {
        a, 0, 0, -1,
        0, b, 0, -1,
        0, 0, 1,  0,
        0, 0, 0,  1,
    }
    
    glMatrixMode(gl.PROJECTION)
    glLoadMatrixf(&transform[0,0])
}

////////////////////////////////////////////////
// Exports to the game

allocate_texture : PlatformAllocateTexture = proc(width, height: i32, data: pmm) -> (result: u32) {
    handle: u32
    gl.GenTextures(1, &handle)
    
    gl.BindTexture(gl.TEXTURE_2D, handle)
    
    gl.TexImage2D(gl.TEXTURE_2D, 0, GlDefaultTextureFormat, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, data)
    
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP)
    glTexEnvi(gl.TEXTURE_ENV, gl.TEXTURE_ENV_MODE, gl.MODULATE)
    
    gl.BindTexture(gl.TEXTURE_2D, 0)
    
    result = handle
    return result
}

deallocate_texture : PlatformDeallocateTexture : proc(texture: u32) {
    handle := texture
    gl.DeleteTextures(1, &handle)
}
