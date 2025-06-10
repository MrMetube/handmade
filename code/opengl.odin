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

glBegin:        proc(_: u32)
glEnd:          proc()
glMatrixMode:   proc(_: i32)
glLoadIdentity: proc()
glLoadMatrixf:  proc(_:[^]f32)
glTexCoord2f:   proc(_,_:f32)
glVertex2f:     proc(_,_:f32)
glVertex2fv:    proc(_:[^]f32)
glColor4f:      proc(_,_,_,_:f32)
glColor4fv:     proc(_:[^]f32)
glTexEnvi:      proc(_: u32, _: u32, _: u32)

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

////////////////////////////////////////////////

init_opengl :: proc(dc: win.HDC) -> (gl_context: win.HGLRC) {
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
    
    major: i32 = 1
    minor: i32 = 0
    gl.GetIntegerv(gl.MAJOR_VERSION, &major)
    gl.GetIntegerv(gl.MINOR_VERSION, &minor)
    
    if major > 2 || major == 2 && minor >= 1 {
        result.GL_EXT_texture_sRGB = true
    }
    
    return result
}

set_pixel_format :: proc(dc: win.HDC, framebuffer_supports_srgb: b32) {
    suggested_pixel_format_index: i32
    extended_pick: u32
    
    if win.wglChoosePixelFormatARB != nil {
        TRUE :: 1
        
        int_attribs := [?]i32{
            win.WGL_DRAW_TO_WINDOW_ARB,           TRUE,
            win.WGL_ACCELERATION_ARB,             win.WGL_FULL_ACCELERATION_ARB,
            win.WGL_SUPPORT_OPENGL_ARB,           TRUE,
            win.WGL_DOUBLE_BUFFER_ARB,            TRUE,
            win.WGL_PIXEL_TYPE_ARB,               win.WGL_TYPE_RGBA_ARB,
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
    
    win.SetPixelFormat(dc, suggested_pixel_format_index, nil)
}

////////////////////////////////////////////////

gl_manage_textures :: proc(first: ^TextureOp) -> (last: ^TextureOp) {
    for operation := first; operation != nil; operation = operation.next {
        last = operation
        
        switch &op in operation.value {
          case: unreachable()
        
          case TextureOpAllocate:
            op.result ^= gl_allocate_texture(op.width, op.height, op.data)
            
          case TextureOpDeallocate:
            gl.DeleteTextures(1, &op.handle)
        }
    }
    
    return last
}

gl_allocate_texture :: proc(width, height: i32, data: pmm) -> (result: u32) {
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

////////////////////////////////////////////////

gl_display_bitmap :: proc(bitmap: Bitmap, draw_region: Rectangle2i, clear_color: v4) {
    gl.Disable(gl.SCISSOR_TEST)
    gl.Disable(gl.BLEND)
    defer gl.Enable(gl.BLEND)
    
    gl_bind_frame_buffer(0, draw_region)
    
    gl.BindTexture(gl.TEXTURE_2D, GlobalBlitTextureHandle)
    defer gl.BindTexture(gl.TEXTURE_2D, 0)
    
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, bitmap.width, bitmap.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(bitmap.memory))
    
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP)
    glTexEnvi(gl.TEXTURE_ENV, gl.TEXTURE_ENV_MODE, gl.MODULATE)
    
    gl.Enable(gl.TEXTURE_2D)

    gl.ClearColor(clear_color.r, clear_color.g, clear_color.b, clear_color.a)
    gl.Clear(gl.COLOR_BUFFER_BIT)

    glMatrixMode(gl.TEXTURE)
    glLoadIdentity()

    glMatrixMode(gl.MODELVIEW)
    glLoadIdentity()

    glMatrixMode(gl.PROJECTION)
    glLoadIdentity()

    gl_rectangle(-1, 1, {1,1,1,1}, 0, 1)
}
    
FramebufferHandles  := FixedArray(256, u32) { data = { 0 = 0, }, count = 1 }
FramebufferTextures := FixedArray(256, u32) { data = { 0 = 0, }, count = 1 }

gl_render_commands :: proc(commands: ^RenderCommands, prep: RenderPrep, draw_region: Rectangle2i, window_dim: [2]i32, clear_color: v4) {
    timed_function()
    
    draw_dim := get_dimension(draw_region)
    gl_bind_frame_buffer(0, draw_region)
    defer gl_bind_frame_buffer(0, draw_region)
    
    gl.Enable(gl.SCISSOR_TEST)
    gl.Enable(gl.TEXTURE_2D)
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    
    // @note(viktor): FrameBuffer 0 is the default frame buffer, which we got on initialization
    max_render_target_count := cast(i64) commands.max_render_target_index+1
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
            
            assert(gl.FRAMEBUFFER_COMPLETE == gl.CheckFramebufferStatus(gl.FRAMEBUFFER))
        }
    }
    
    for index in 0..< FramebufferHandles.count {
        gl_bind_frame_buffer(cast(u32) index, draw_region)
        if index == 0 {
            gl.Scissor(0, 0, window_dim.x, window_dim.y)
        } else {
            gl.Scissor(0, 0, draw_dim.x, draw_dim.y)
        }
        
        gl.ClearColor(clear_color.r, clear_color.g, clear_color.b, clear_color.a)
        gl.Clear(gl.COLOR_BUFFER_BIT)
    }
    
    gl_set_screenspace({commands.width, commands.height})
    
    clip_rect_index      := max(u16)
    current_target_index := max(u32)
    for sort_entry_offset in prep.sorted_offsets {
        offset := sort_entry_offset
        
        //:PointerArithmetic
        header := cast(^RenderEntryHeader) &commands.push_buffer[offset]
        entry_data := &commands.push_buffer[offset + size_of(RenderEntryHeader)]
        
        if clip_rect_index != header.clip_rect_index {
            clip_rect_index = header.clip_rect_index
            clip := prep.clip_rects.data[clip_rect_index]
            
            if current_target_index != clip.render_target_index {
                current_target_index = clip.render_target_index
                gl_bind_frame_buffer(current_target_index, draw_region)
            }
            
            rect := current_target_index == 0 ? add_offset(clip.rect, draw_region.min) : clip.rect
            gl.Scissor(rect.min.x, rect.min.y, rect.max.x - rect.min.x, rect.max.y - rect.min.y)
        }
        
        switch header.type {
          case .None: unreachable()
          case .RenderEntryClip: // @note(viktor): clip rects are handled before rendering
          
          case .RenderEntryBlendRenderTargets:
            entry := cast(^RenderEntryBlendRenderTargets) entry_data
            
            gl_bind_frame_buffer(entry.dest_index, draw_region)
            defer gl_bind_frame_buffer(current_target_index, draw_region)
            
            gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
            defer gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
            
            gl.BindTexture(gl.TEXTURE_2D, FramebufferTextures.data[entry.source_index])
            gl_rectangle(0, vec_cast(f32, commands.width, commands.height), v4{1,1,1, entry.alpha}, 0, 1)
            // gl.BindTexture(gl.TEXTURE_2D, 0)
            // gl_rectangle(0, vec_cast(f32, commands.width, commands.height), v4{current_target_index == 2 ? 1 : 0,0,current_target_index == 1 ? 1 : 0, 0.2}, 0, 1)
            
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
                
                min := entry.p
                max := entry.p + entry.x_axis + entry.y_axis
                
                gl_rectangle(min, max, entry.premultiplied_color, min_uv, max_uv)
            }
            
          case:
            panic("Unhandled Entry")
        }
    }

    if GlobalDebugShowRenderSortGroups {
        timed_block("show render sort groups")
        
        // @todo(viktor): this broke since the separation of the layers with sort barriers
        if commands.render_entry_count != 0 {
            bounds := slice(commands.sort_entries)
            
            color_wheel := color_wheel
            color_index: u32
            for bound, index in bounds {
                if bound.offset == SpriteBarrierValue do continue
                if .DebugBox in bound.flags do continue
            
                if .Cycle in bound.flags {
                    color := color_wheel[color_index]
                    color_index += 1
                    if color_index >= len(color_wheel) {
                        color_index = 0
                    }
                    
                    gl.Disable(gl.TEXTURE_2D)
                    
                    glBegin(gl.LINES)
                    glColor4fv(&color[0])
                    draw_bounds_recursive(bounds, auto_cast index)
                    glEnd()
                        
                    gl.Enable(gl.TEXTURE_2D)
                }
            }
        }
    }
}

draw_bounds_recursive :: proc(bounds: []SortSpriteBounds, index: u16) {
    bound := &bounds[index]
    if .DebugBox in bound.flags do return
    bound.flags += { .DebugBox }
    
    bound_center := get_center(bound.screen_bounds)
    for edge := bound.first_edge_with_me_as_the_front; edge != nil; edge = edge.next_edge_with_same_front {
        assert(edge.front == index)
        
        behind := bounds[edge.behind]
        behind_center := get_center(behind.screen_bounds)
        
        glVertex2fv(&bound_center[0])
        glVertex2fv(&behind_center[0])
        
        draw_bounds_recursive(bounds, edge.behind)
    }
    
    min := bound.screen_bounds.min
    max := bound.screen_bounds.max
    glVertex2f(min.x, min.y)
    glVertex2f(min.x, max.y)
    
    glVertex2f(min.x, max.y)
    glVertex2f(max.x, max.y)
    
    glVertex2f(max.x, max.y)
    glVertex2f(max.x, min.y)
    
    glVertex2f(max.x, min.y)
    glVertex2f(min.x, min.y)
}

gl_bind_frame_buffer :: proc(render_target_index: u32, draw_region: Rectangle2i) {
    render_target := FramebufferHandles.data[render_target_index]
    gl.BindFramebuffer(gl.FRAMEBUFFER, render_target)
    
    draw_dim := get_dimension(draw_region)
    if render_target_index == 0 {
        gl.Viewport(draw_region.min.x, draw_region.min.y, draw_dim.x, draw_dim.y)
    } else {
        gl.Viewport(0, 0, draw_dim.x, draw_dim.y)
    }
}

gl_set_screenspace :: proc(size: [2]i32) {
    a := safe_ratio_1(f32(2), cast(f32) size.x)
    b := safe_ratio_1(f32(2), cast(f32) size.y)
    
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