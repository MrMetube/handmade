package main

import "base:runtime"

import win "core:sys/windows"
import gl "vendor:OpenGl"

GlMajorVersion :: 4
GlMinorVersion :: 6

GlAttribs := [?] i32 {
    win.WGL_CONTEXT_MAJOR_VERSION_ARB, GlMajorVersion,
    win.WGL_CONTEXT_MINOR_VERSION_ARB, GlMinorVersion,
    
    win.WGL_CONTEXT_FLAGS_ARB, win.WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB | (win.WGL_CONTEXT_DEBUG_BIT_ARB when ODIN_DEBUG else 0),
    
    win.WGL_CONTEXT_PROFILE_MASK_ARB, win.WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
    0,
}

////////////////////////////////////////////////

OpenGlInfo :: struct {
    modern_context: b32,
    
    vendor, 
    renderer,
    version, 
    shading_language_version: cstring,
    
    GL_EXT_texture_sRGB,
    GL_EXT_framebuffer_sRGB: b32,
}

OpenGL :: struct {
    settings: RenderSettings,
    
    multisampling:    b32,
    multisample_count: i32,
    depth_peel_count:  u32,
    
    default_texture_format: u32,
    vertex_buffer_handle: u32,
    blit_buffer: FrameBuffer, // @note(viktor): used when software rendering
    
    // @note(viktor): Dynamic resources take get recreated when settings change:
    
    resolve_buffer: FrameBuffer,
    depth_peel_buffers:         FixedArray(16, FrameBuffer),
    depth_peel_resolve_buffers: FixedArray(16, FrameBuffer),
    
    zbias_no_depth_peel: ZBiasProgram, // @note(viktor): pass 0
    zbias_depth_peel:    ZBiasProgram, // @note(viktor): passes 1 through n
    peel_composite:      PeelCompositeProgram, // @note(viktor): composite all passes
    final_stretch:       FinalStretchProgram,
    multisample_resolve: MultisampleResolve,
}

CreateFramebufferFlags :: bit_set[enum{ multisampled, filtered, has_color, has_depth }]

FrameBuffer :: struct {
    handle: u32,
    
    color_texture: u32,
    depth_texture: u32,
}

open_gl := OpenGL {
    default_texture_format = gl.RGBA8,
}

////////////////////////////////////////////////

init_opengl :: proc (dc: win.HDC) -> (gl_context: win.HGLRC) {
    framebuffer_supports_srgb := load_wgl_extensions()
    set_pixel_format(dc, framebuffer_supports_srgb)
    
    if win.wglCreateContextAttribsARB != nil {
        gl_context = win.wglCreateContextAttribsARB(dc, nil, raw_data(GlAttribs[:]))
    }
    
    context_is_modern: b32 = true
    if gl_context == nil {
        context_is_modern = false
        gl_context = win.wglCreateContext(dc)
    }
    assert(gl_context != nil)
    
    if win.wglMakeCurrent(dc, gl_context) {
        gl.load_up_to(GlMajorVersion, GlMinorVersion, win.gl_set_proc_address)
        
        extensions := opengl_get_extensions(context_is_modern)
        
        win.wglSwapIntervalEXT = auto_cast win.wglGetProcAddress("wglSwapIntervalEXT")
        if win.wglSwapIntervalEXT != nil {
            DisableVSync  ::  0
            EnableVSync   ::  1
            AdaptiveVSync :: -1
            win.wglSwapIntervalEXT(EnableVSync)
        }
        
        gl.DebugMessageCallback(gl_debug_callback, nil)
        gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS)
        
        // @note(viktor): If we believe we can do full sRGB on the texture side and the framebuffer side, then we can enable it, otherwise it is safer for us to pass it straight through.
        // @todo(viktor): Just require sRGB support and fault if it is unavailable. It should be supported nowadays
        if extensions.GL_EXT_framebuffer_sRGB && framebuffer_supports_srgb {
            open_gl.default_texture_format = gl.SRGB8_ALPHA8
            gl.Enable(gl.FRAMEBUFFER_SRGB)
        }
        
        gl.GenTextures(1, &open_gl.blit_buffer.handle)
        
        legacy_array_to_be_technically_correct_even_though_we_dont_use_it_or_need_it: u32
        gl.GenVertexArrays(1, &legacy_array_to_be_technically_correct_even_though_we_dont_use_it_or_need_it)
        gl.BindVertexArray(legacy_array_to_be_technically_correct_even_though_we_dont_use_it_or_need_it)
        
        gl.GenBuffers(1, &open_gl.vertex_buffer_handle)
        gl.BindBuffer(gl.ARRAY_BUFFER, open_gl.vertex_buffer_handle)
        
        max_sample_count: i32
        gl.GetIntegerv(gl.MAX_COLOR_TEXTURE_SAMPLES, &max_sample_count)
        max_sample_count = min(16, max_sample_count)
        open_gl.multisample_count = max_sample_count
    }
    
    return gl_context
}

gl_debug_callback :: proc "c" (source: u32, type: u32, id: u32, severity: u32, length: i32, message: cstring, user_ptr: rawptr) {
    // @todo(viktor): how can we get the actual context, if we ever use the context in the platform layer
    context = runtime.default_context()
    
    if severity == gl.DEBUG_SEVERITY_NOTIFICATION {
        @static ignored: map[u32] bool
        ignored[131185] = true
        @static seen: map[cstring] bool
        if id not_in ignored && message not_in seen {
            seen[message] = true
            print("INFO(%:%): %\n", type, id, message)
        }
    } else {
        print("ERROR: %\n", message)
        assert(false)
    }
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
        }
    }
    
    return framebuffer_supports_srgb
}

opengl_get_extensions :: proc (modern_context: b32) -> (result: OpenGlInfo) {
    result.modern_context = modern_context
    
    result.vendor   = gl.GetString(gl.VENDOR)
    result.renderer = gl.GetString(gl.RENDERER)
    result.version  = gl.GetString(gl.VERSION)
    
    if modern_context {
        result.shading_language_version = gl.GetString(gl.SHADING_LANGUAGE_VERSION)
    } else {
        result.shading_language_version = "(none)"
    }
    
    extensions_count: i32
    gl.GetIntegerv(gl.NUM_EXTENSIONS, &extensions_count)
    
    for index in 0..<extensions_count {
        extension := gl.GetStringi(gl.EXTENSIONS, cast(u32) index)
        
        if      "GL_EXT_texture_sRGB"     == extension do result.GL_EXT_texture_sRGB = true
        else if "GL_EXT_framebuffer_sRGB" == extension do result.GL_EXT_framebuffer_sRGB = true
        else if "GL_ARB_framebuffer_sRGB" == extension do result.GL_EXT_framebuffer_sRGB = true
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
            // @volatile see below
            /* 5 */win.WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB, TRUE,
            0,
        }
        
        if !framebuffer_supports_srgb {
            int_attribs[10] = 0 // @volatile Coupled to the ordering of the attribs itself
        }
        
        win.wglChoosePixelFormatARB(dc, raw_data(int_attribs[:]), nil, 1, &suggested_pixel_format_index, &extended_pick)
    }
    
    if extended_pick == 0 {
        desired_pixel_format := win.PIXELFORMATDESCRIPTOR {
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
    allocs, deallocs: u32
    
    for operation := last; operation != nil; operation = operation.next {
        switch &op in operation.value {
          case: unreachable()
        
          case TextureOpAllocate:
            allocs += 1
            op.result ^= gl_allocate_texture(op.bitmap)
            
          case TextureOpDeallocate:
            deallocs += 1
            gl.DeleteTextures(1, &op.handle)
        }
    }
    
    // @todo(viktor): Display in debug system
    print("texture ops %, allocs % deallocs %\n", allocs + deallocs, allocs, deallocs)
}

gl_allocate_texture :: proc (bitmap: Bitmap) -> (result: u32) {
    handle: u32
    gl.GenTextures(1, &handle)
    
    gl.BindTexture(gl.TEXTURE_2D, handle)
    
    width := bitmap.dimension.x
    height := bitmap.dimension.y
    data := raw_data(bitmap.memory)
    gl.TexImage2D(gl.TEXTURE_2D, 0, cast(i32) open_gl.default_texture_format, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, data)
    
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    
    gl.BindTexture(gl.TEXTURE_2D, 0)
    
    result = handle
    
    return result
}

////////////////////////////////////////////////

gl_change_to_settings :: proc (settings: RenderSettings) {
    timed_function()
    
    delete_framebuffer(&open_gl.resolve_buffer)
    for &buffer in slice(&open_gl.depth_peel_buffers) {
        delete_framebuffer(&buffer)
    }
    for &buffer in slice(&open_gl.depth_peel_resolve_buffers) {
        delete_framebuffer(&buffer)
    }
    clear(&open_gl.depth_peel_buffers)
    clear(&open_gl.depth_peel_resolve_buffers)
    
    delete_program(&open_gl.zbias_no_depth_peel)
    delete_program(&open_gl.zbias_depth_peel)
    delete_program(&open_gl.peel_composite)
    delete_program(&open_gl.final_stretch)
    delete_program(&open_gl.multisample_resolve)
    
    open_gl.settings = settings
    
    open_gl.multisampling    = settings.multisampling_hint
    open_gl.depth_peel_count = min(settings.depth_peel_count_hint, len(open_gl.depth_peel_buffers.data))
    
    resolve_flags := CreateFramebufferFlags{ .has_color }
    if !settings.pixelation_hint {
        resolve_flags += { .filtered }
    }
    
    depth_peel_flags := CreateFramebufferFlags{ .has_color, .has_depth }
    if open_gl.multisampling {
        depth_peel_flags += { .multisampled }
    }
    
    open_gl.resolve_buffer = create_framebuffer(settings.dimension, resolve_flags)
    
    compile_zbias_program(&open_gl.zbias_no_depth_peel, false)
    compile_zbias_program(&open_gl.zbias_depth_peel, true)
    compile_peel_composite(&open_gl.peel_composite)
    compile_final_stretch(&open_gl.final_stretch)
    compile_multisample_resolve(&open_gl.multisample_resolve)
    
    for _ in 0..<open_gl.depth_peel_count {
        buffer := create_framebuffer(settings.dimension, depth_peel_flags)
        append(&open_gl.depth_peel_buffers, buffer)
        
        if open_gl.multisampling {
            resolve_buffer := create_framebuffer(settings.dimension, depth_peel_flags - { .multisampled })
            append(&open_gl.depth_peel_resolve_buffers, resolve_buffer)
        }
    }
}

gl_render_commands :: proc (commands: ^RenderCommands, draw_region: Rectangle2i, window_dim: v2i) {
    timed_function()
    
    render_dim := commands.dimension
    settings   := commands.settings
    
    if settings != open_gl.settings {
        gl_change_to_settings(settings)
    }
    
    gl.DepthMask(true)
    gl.ColorMask(true, true, true, true)
    gl.Enable(gl.DEPTH_TEST)
    gl.DepthFunc(gl.LEQUAL)
    gl.Enable(gl.CULL_FACE)
    gl.CullFace(gl.BACK)
    gl.FrontFace(gl.CCW)
    // gl.Enable(gl.SAMPLE_ALPHA_TO_COVERAGE)
    // gl.Enable(gl.SAMPLE_ALPHA_TO_ONE)
    gl.Enable(gl.MULTISAMPLE)
    
    gl.Enable(gl.SCISSOR_TEST)
    
    gl.Disable(gl.BLEND)
    gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    
    ////////////////////////////////////////////////
    
    assert(open_gl.depth_peel_count > 0)
    
    for buffer, index in slice(&open_gl.depth_peel_buffers) {
        gl_bind_frame_buffer(buffer, settings.dimension)
        gl.Scissor(0, 0, settings.dimension.x, settings.dimension.y)
        
        c: v4
        if cast(u32) index == open_gl.depth_peel_count-1 {
            c = commands.clear_color
            c.a = 1
        }
        
        gl.ClearColor(c.r, c.g, c.b, c.a)
        gl.ClearDepth(1)
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
    }
    
    gl_bind_frame_buffer(open_gl.depth_peel_buffers.data[0], render_dim)
    
    peeling: bool
    peel_index: u32
    peel_header_restore: int
    for begin_reading(&commands.push_buffer); can_read(&commands.push_buffer); {
        header := read(&commands.push_buffer, RenderEntryHeader)
        
        switch header.type {
          case .None: unreachable()
          case: panic("Unhandled Entry")
            
          case .DepthClear:
            gl.ClearDepth(gl.DEPTH_BUFFER_BIT)
            gl.Clear(gl.DEPTH_BUFFER_BIT)
            
          case .BeginPeels:
            peel_header_restore = commands.push_buffer.read_cursor
            
          case .EndPeels:
            if open_gl.multisampling {
                from := open_gl.depth_peel_buffers.data[peel_index]
                to   := open_gl.depth_peel_resolve_buffers.data[peel_index]
                when true {
                    resolve_multisample(from, to, render_dim)
                } else {
                    gl.BindFramebuffer(gl.READ_FRAMEBUFFER, from.handle)
                    gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, to.handle)
                    gl.Viewport(0, 0, render_dim.x, render_dim.y)
                    gl.BlitFramebuffer(0, 0, render_dim.x, render_dim.y, 0, 0, render_dim.x, render_dim.y, gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT, gl.NEAREST)
                }
            }
            
            if peel_index < open_gl.depth_peel_count-1 {
                commands.push_buffer.read_cursor = peel_header_restore
                
                peeling = peel_index > 0
                peel_index += 1
                
                gl_bind_frame_buffer(open_gl.depth_peel_buffers.data[peel_index], render_dim)
            } else {
                assert(peel_index == open_gl.depth_peel_count-1)
                
                peeling = false
                peel_index = 0
                
                buffer := get_depth_peel_read_buffer(0)
                gl_bind_frame_buffer(buffer, render_dim)
            }
            
          case .Textured_Quads:
            entry := read(&commands.push_buffer, Textured_Quads)
            
            ////////////////////////////////////////////////
            gl_bind_frame_buffer(open_gl.depth_peel_buffers.data[peel_index], render_dim)
            
            setup := entry.setup
            gl.Scissor(get_xywh(setup.clip_rect))
            
            copy := game.begin_timed_block("gl copy buffer data")
            gl.BufferData(gl.ARRAY_BUFFER, cast(int) commands.vertex_buffer.count * size_of(Textured_Vertex), raw_data(commands.vertex_buffer.data), gl.STREAM_DRAW)
            game.end_timed_block(copy)
            
            ////////////////////////////////////////////////
            
            program := open_gl.zbias_no_depth_peel
            alpha_threshold: f32 = 0.02
            if peeling {
                program = open_gl.zbias_depth_peel
                buffer := get_depth_peel_read_buffer(peel_index-1)
                
                // @metaprogram
                gl.ActiveTexture(gl.TEXTURE1)
                gl.BindTexture(gl.TEXTURE_2D, buffer.depth_texture)
                gl.ActiveTexture(gl.TEXTURE0)
                if peel_index == open_gl.depth_peel_count-1 {
                    alpha_threshold = 0.9
                }
            }
            begin_program(program, setup, alpha_threshold)
            
            loop := game.begin_timed_block("gl quad loop")
            for bitmap_index in entry.bitmap_offset ..< entry.bitmap_offset + entry.quad_count {
                bitmap := commands.quad_bitmap_buffer.data[bitmap_index]
                gl.BindTexture(gl.TEXTURE_2D, bitmap.texture_handle)
                
                vertex_index := cast(i32) bitmap_index * 4
                gl.DrawArrays(gl.TRIANGLE_STRIP, vertex_index, 4)
            }
            end_timed_block(loop)
            
            end_program(program)
            
            // @metaprogram
            gl.BindTexture(gl.TEXTURE_2D, 0)
            if peeling {
                gl.ActiveTexture(gl.TEXTURE1)
                gl.BindTexture(gl.TEXTURE_2D, 0)
                gl.ActiveTexture(gl.TEXTURE0)
            }
        }
    }
    
    ////////////////////////////////////////////////
    
    gl.Disable(gl.DEPTH_TEST)
    gl.Disable(gl.SCISSOR_TEST)
    
    gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, open_gl.resolve_buffer.handle)
    gl.Viewport(0, 0, render_dim.x, render_dim.y)
    gl.Scissor(0, 0, render_dim.x, render_dim.y)
    
    vertex_buffer := [4] Textured_Vertex {
        {{-1,  1, 0, 1}, {0, 1}, 0xff},
        {{-1, -1, 0, 1}, {0, 0}, 0xff},
        {{ 1,  1, 0, 1}, {1, 1}, 0xff},
        {{ 1, -1, 0, 1}, {1, 0}, 0xff},
    }
    gl.BufferData(gl.ARRAY_BUFFER, size_of(vertex_buffer), &vertex_buffer[0], gl.STREAM_DRAW)
    
    begin_program(open_gl.peel_composite)
    // @metaprogram
    for index in 0 ..< open_gl.depth_peel_count {
        gl.ActiveTexture(gl.TEXTURE0 + index)
        buffer := get_depth_peel_read_buffer(index)
        gl.BindTexture(gl.TEXTURE_2D, buffer.color_texture)
    }
    
    gl.DrawArrays(gl.TRIANGLE_STRIP, 0, auto_cast len(vertex_buffer))
    
    // @metaprogram
    for index in 0 ..< open_gl.depth_peel_count {
        gl.ActiveTexture(gl.TEXTURE0 + index)
        gl.BindTexture(gl.TEXTURE_2D, 0)
    }
    gl.ActiveTexture(gl.TEXTURE0)
    
    end_program(open_gl.peel_composite)
    
    gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
    
    ////////////////////////////////////////////////
    
    gl.Viewport(0, 0, window_dim.x, window_dim.y)
    gl.Scissor(0, 0, window_dim.x, window_dim.y)
    gl.ClearColor(0, 0, 0, 0)
    gl.Clear(gl.COLOR_BUFFER_BIT)
    
    gl.Viewport(get_xywh(draw_region))
    gl.Scissor(get_xywh(draw_region))
    
    begin_program(open_gl.final_stretch)
    // @metaprogram
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D, open_gl.resolve_buffer.color_texture)
    
    gl.DrawArrays(gl.TRIANGLE_STRIP, 0, auto_cast len(vertex_buffer))
    
    // @metaprogram
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D, 0)
    
    end_program(open_gl.final_stretch)
}

resolve_multisample :: proc (from, to: FrameBuffer, dim: v2i) {
    gl.DepthFunc(gl.ALWAYS)
    defer gl.DepthFunc(gl.LEQUAL)
    
    gl.BindFramebuffer(gl.FRAMEBUFFER, to.handle)
    defer gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
    
    gl.Viewport(0, 0, dim.x, dim.y)
    gl.Scissor(0, 0, dim.x, dim.y)
    
    vertex_buffer := [4] Textured_Vertex {
        {{-1,  1, 0, 1}, {0, 1}, 0xff},
        {{-1, -1, 0, 1}, {0, 0}, 0xff},
        {{ 1,  1, 0, 1}, {1, 1}, 0xff},
        {{ 1, -1, 0, 1}, {1, 0}, 0xff},
    }
    gl.BufferData(gl.ARRAY_BUFFER, size_of(vertex_buffer), &vertex_buffer[0], gl.STREAM_DRAW)
    
    open_gl.multisample_resolve.sample_count.value = open_gl.multisample_count
    begin_program(open_gl.multisample_resolve)
    
    // @metaprogram
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, from.color_texture)
    gl.ActiveTexture(gl.TEXTURE1)
    gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, from.depth_texture)
    
    gl.DrawArrays(gl.TRIANGLE_STRIP, 0, auto_cast len(vertex_buffer))
    
    // @metaprogram
    gl.ActiveTexture(gl.TEXTURE1)
    gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, 0)
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D_MULTISAMPLE, 0)
    
    end_program(open_gl.multisample_resolve)
}

get_depth_peel_read_buffer :: proc (index: u32) -> (result: FrameBuffer) {
    result = open_gl.depth_peel_buffers.data[index]
    if open_gl.multisampling {
        result = open_gl.depth_peel_resolve_buffers.data[index]
    }
    return result
}

gl_display_bitmap :: proc (bitmap: Bitmap, draw_region: Rectangle2i, clear_color: v4) {
    if true do unimplemented()
    
    timed_function()
    
    gl_bind_frame_buffer({}, get_dimension(draw_region))
    
    gl.Disable(gl.SCISSOR_TEST)
    gl.Disable(gl.BLEND)
    defer gl.Enable(gl.BLEND)
    
    gl.BindTexture(gl.TEXTURE_2D, open_gl.blit_buffer.handle)
    defer gl.BindTexture(gl.TEXTURE_2D, 0)
    
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, bitmap.dimension.x, bitmap.dimension.y, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(bitmap.memory))
    
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP)
    
    gl.Enable(gl.TEXTURE_2D)
    
    gl.ClearColor(clear_color.r, clear_color.g, clear_color.b, clear_color.a)
    gl.Clear(gl.COLOR_BUFFER_BIT)
    
    // gl_rectangle(min = {-1, -1, 0}, max = {1, 1, 0}, color = {1,1,1,1}, minuv = 0, maxuv =1)
}

////////////////////////////////////////////////

create_framebuffer :: proc (dim: v2i, flags: CreateFramebufferFlags) -> (result: FrameBuffer) {
    gl.GenFramebuffers(1, &result.handle)
    gl.BindFramebuffer(gl.FRAMEBUFFER, result.handle)
    
    slot: u32 = .multisampled in flags ? gl.TEXTURE_2D_MULTISAMPLE : gl.TEXTURE_2D
    filter_type: i32 = .filtered in flags ? gl.LINEAR : gl.NEAREST
    
    if .has_color in flags {
        result.color_texture = create_framebuffer_texture(slot, filter_type, open_gl.default_texture_format, dim)
        
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, slot, result.color_texture, 0)
    }
    
    if .has_depth in flags {
        // @todo(viktor): Check if going with a 16-bit depth buffer would be faster and have enough quality
        result.depth_texture = create_framebuffer_texture(slot, filter_type, gl.DEPTH_COMPONENT24, dim)
        
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, slot, result.depth_texture, 0)
    }
    
    status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
    assert(status == gl.FRAMEBUFFER_COMPLETE)
    
    gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
    gl.BindTexture(slot, 0)
    
    return result
}

create_framebuffer_texture :: proc (slot: u32, filter_type: i32, format: u32, dim: v2i) -> (result: u32) {
    gl.GenTextures(1, auto_cast &result)
    
    gl.BindTexture(slot, result)
    
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter_type)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter_type)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    
    if slot == gl.TEXTURE_2D_MULTISAMPLE {
        gl.TexImage2DMultisample(slot, open_gl.multisample_count, format, dim.x, dim.y, false)
    } else {
        data_format: u32 = format == gl.DEPTH_COMPONENT24 ? gl.DEPTH_COMPONENT : gl.RGBA
        
        gl.TexImage2D(slot, 0, auto_cast format, dim.x, dim.y, 0, data_format, gl.UNSIGNED_BYTE, nil)
    }
    
    return result
}

delete_framebuffer :: proc (buffer: ^FrameBuffer) {
    if buffer.color_texture != 0 do gl.DeleteTextures(1, &buffer.color_texture)
    if buffer.depth_texture != 0 do gl.DeleteTextures(1, &buffer.depth_texture)
    if buffer.handle        != 0 do gl.DeleteFramebuffers(1, &buffer.handle)
    
    buffer ^= {}
}

gl_bind_frame_buffer :: proc (frame_buffer: FrameBuffer, render_dim: v2i) {
    gl.BindFramebuffer(gl.FRAMEBUFFER, frame_buffer.handle)
    gl.Viewport(0, 0, render_dim.x, render_dim.y)
}