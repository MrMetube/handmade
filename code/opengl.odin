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
    default_texture_format: u32,
    
    vertex_buffer: u32,
    
    framebuffer_handles:  FixedArray(256, u32),
    framebuffer_textures: FixedArray(256, u32),
    
    blit_texture_handle: u32,
    
    zbias_no_depth_peel: OpenGLProgram, // @note(viktor): pass 0
    zbias_depth_peel:    OpenGLProgram, // @note(viktor): pass 1
}

OpenGLProgram :: struct {
    program_handle: u32,
    
    // uniforms
    transform: i32,
    texture_sampler: i32,
    depth_sampler: i32,
    fog_color: i32,
    camera_p: i32,
    fog_begin: i32,
    fog_end: i32,
    fog_direction: i32,
    
    // attributes
    in_p: i32,
    in_uv: i32,
    in_color: i32,
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
        
        gl.GenTextures(1, &open_gl.blit_texture_handle)
        
        legacy_array_to_be_technically_correct_even_though_we_dont_use_it_or_need_it: u32
        gl.GenVertexArrays(1, &legacy_array_to_be_technically_correct_even_though_we_dont_use_it_or_need_it)
        gl.BindVertexArray(legacy_array_to_be_technically_correct_even_though_we_dont_use_it_or_need_it)
        
        gl.GenBuffers(1, &open_gl.vertex_buffer)
        gl.BindBuffer(gl.ARRAY_BUFFER, open_gl.vertex_buffer)
        
        compile_zbias_program(&open_gl.zbias_no_depth_peel, false)
        compile_zbias_program(&open_gl.zbias_depth_peel, true)
    }
    
    return gl_context
}

////////////////////////////////////////////////

compile_zbias_program :: proc (program: ^OpenGLProgram, depth_peeling: bool) {
    header_code := ctprint(`
#version 130

#define DepthPeeling %

#define f32 float
#define v2 vec2
#define v3 vec3
#define v4 vec4
#define V2 vec2
#define V3 vec3
#define V4 vec4
#define m4 mat4x4
#define linear_blend(a, b, t) mix(a, b, t)

#define Pipeline \
    smooth Pipe v4 frag_color; \
    smooth Pipe v2 frag_uv;    \
    smooth Pipe f32 fog_amount;
    
#define clamp01(t) clamp(t, 0, 1)

f32 clamp_01_map_to_range(f32 min, f32 max, f32 t) {
    f32 range = max - min;
    f32 absolute = (t - min) / range;
    f32 result = clamp01(absolute);
    return result;
}
`, depth_peeling ? 1 : 0)

    vertex_code: cstring = `
uniform m4 transform;
uniform v3 camera_p;
uniform f32 fog_begin;
uniform f32 fog_end;
uniform v3 fog_direction;

// @volatile keep vertex ins in sync with renderloop code
in v4 in_color;
in v2 in_uv;
in v4 in_p;

#define Pipe out
Pipeline
#undef Pipe

void main (void) {
    v4 in_vertex = V4(in_p.xyz, 1);
    f32 z_bias = in_p.w;
    
    v4 z_vertex = in_vertex;
    z_vertex.z += z_bias;
    
    v4 z_min_transform = transform * in_vertex;
    v4 z_max_transform = transform * z_vertex;
    
    f32 modified_z = (z_min_transform.w / z_max_transform.w) * z_max_transform.z;
    
    gl_Position = V4(z_min_transform.xy, modified_z, z_min_transform.w);
    
    frag_uv = in_uv;
    frag_color = in_color;
    v3 delta = z_vertex.xyz - camera_p;
    f32 distance = dot(delta, fog_direction);
    fog_amount = clamp_01_map_to_range(fog_begin, fog_end, distance);
    // f32 alpha_amount = clamp_01_map_to_range(5.0f, 5.25f, distance);
    // frag_color.a *= alpha_amount;
}
`
        fragment_code: cstring = `
uniform sampler2D texture_sampler;
uniform v3 fog_color;

#if DepthPeeling
uniform sampler2D depth_sampler;
#endif // DepthPeeling

#define Pipe in
Pipeline
#undef Pipe

out v4 result_color;

void main (void) {
  #if DepthPeeling
    f32 clip_depth = texelFetch(depth_sampler, ivec2(gl_FragCoord.xy), 0).r;
    f32 frag_z = gl_FragCoord.z;
    if (frag_z <= clip_depth) {
        discard;
    }
  #endif // DepthPeeling

    v4 texture_sample = texture(texture_sampler, frag_uv);
    if (texture_sample.a > 0) {
        v4 modulated = frag_color * texture_sample;
        result_color.rgb = linear_blend(modulated.rgb, fog_color, fog_amount);
        result_color.a = modulated.a;
    } else {
        discard;
    }
}
`
    program.program_handle = gl_create_program(header_code, vertex_code, fragment_code)
    p := program.program_handle
    
    // @metaprogram
    program.transform       = gl.GetUniformLocation(p, "transform")
    program.texture_sampler = gl.GetUniformLocation(p, "texture_sampler")
    program.depth_sampler   = gl.GetUniformLocation(p, "depth_sampler")
    program.fog_color       = gl.GetUniformLocation(p, "fog_color")
    program.camera_p        = gl.GetUniformLocation(p, "camera_p")
    program.fog_begin       = gl.GetUniformLocation(p, "fog_begin")
    program.fog_end         = gl.GetUniformLocation(p, "fog_end")
    program.fog_direction   = gl.GetUniformLocation(p, "fog_direction")
    program.fog_color       = gl.GetUniformLocation(p, "fog_color")
    
    program.in_color = gl.GetAttribLocation(p, "in_color")
    program.in_p     = gl.GetAttribLocation(p, "in_p")
    program.in_uv    = gl.GetAttribLocation(p, "in_uv")
    assert(program.in_color != -1)
    assert(program.in_p     != -1)
    assert(program.in_uv    != -1)
}

begin_program :: proc (program: OpenGLProgram, setup: RenderSetup) {
    gl.UseProgram(program.program_handle)
    // @volatile see vertex shader
    gl.EnableVertexAttribArray(cast(u32) program.in_uv)
    gl.EnableVertexAttribArray(cast(u32) program.in_color)
    gl.EnableVertexAttribArray(cast(u32) program.in_p)
    
    // @metaprogram
    gl.VertexAttribPointer(cast(u32) program.in_uv,    len(v2),    gl.FLOAT,         false, size_of(Textured_Vertex), offset_of(Textured_Vertex, uv))
    gl.VertexAttribPointer(cast(u32) program.in_color, len(Color), gl.UNSIGNED_BYTE,  true, size_of(Textured_Vertex), offset_of(Textured_Vertex, color))
    gl.VertexAttribPointer(cast(u32) program.in_p,     len(v4),    gl.FLOAT,         false, size_of(Textured_Vertex), offset_of(Textured_Vertex, p))
    
    {
        setup := setup
        
        gl.Uniform1i(program.texture_sampler,  0)
        gl.Uniform1i(program.depth_sampler,    0)
        gl.UniformMatrix4fv(program.transform, 1, false, &setup.projection[0, 0])
        gl.Uniform3fv(program.camera_p,        1, &setup.camera_p[0])
        gl.Uniform3fv(program.fog_direction,   1, &setup.fog_direction[0])
        gl.Uniform3fv(program.fog_color,       1, &setup.fog_color[0])
        gl.Uniform1f(program.fog_begin,        setup.fog_begin)
        gl.Uniform1f(program.fog_end,          setup.fog_end)
    }
}

end_program :: proc (program: OpenGLProgram) {
    gl.DisableVertexAttribArray(cast(u32) program.in_uv)
    gl.DisableVertexAttribArray(cast(u32) program.in_color)
    gl.DisableVertexAttribArray(cast(u32) program.in_p)
    
    gl.UseProgram(0)
}

////////////////////////////////////////////////

gl_debug_callback :: proc "c" (source: u32, type: u32, id: u32, severity: u32, length: i32, message: cstring, user_ptr: rawptr) {
    // @todo(viktor): how can we get the actual context, if we ever use the context in the platform layer
    context = runtime.default_context()
    if severity == gl.DEBUG_SEVERITY_NOTIFICATION {
        @static seen: map[cstring] bool
        if message not_in seen {
            seen[message] = true
            print("INFO: %\n", message)
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
            
            win.gl_set_proc_address(&glBegin, "glBegin")
            win.gl_set_proc_address(&glEnd,   "glEnd")
            
            win.gl_set_proc_address(&glTexCoord2f, "glTexCoord2f")
            win.gl_set_proc_address(&glVertex3f,   "glVertex3f")
            win.gl_set_proc_address(&glColor4f,    "glColor4f")
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
    
    length: int
    extensions_count : i32
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
    handle: u32
    gl.GenTextures(1, &handle)
    
    gl.BindTexture(gl.TEXTURE_2D, handle)
    
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

gl_create_program :: proc (header_code, vertex_code, fragment_code: cstring) -> (result: u32) {
    lengths := [?] i32 { 0..<20 = -1 }
    
    vertex_shader_code := [?] cstring {
        header_code, vertex_code,
    }
    
    fragment_shader_code := [?] cstring {
        header_code, fragment_code,
    }
    
    vertex_shader_id   := gl.CreateShader(gl.VERTEX_SHADER)
    fragment_shader_id := gl.CreateShader(gl.FRAGMENT_SHADER)
    
    gl.ShaderSource(vertex_shader_id,   len(vertex_shader_code),   raw_data(vertex_shader_code[:]),   raw_data(lengths[:]))
    gl.ShaderSource(fragment_shader_id, len(fragment_shader_code), raw_data(fragment_shader_code[:]), raw_data(lengths[:]))
    
    gl.CompileShader(vertex_shader_id)
    gl.CompileShader(fragment_shader_id)
    
    result = gl.CreateProgram()
    
    gl.AttachShader(result, vertex_shader_id)
    gl.AttachShader(result, fragment_shader_id)
    
    gl.LinkProgram(result)
    
    gl.ValidateProgram(result)
    linked: b32
    gl.GetProgramiv(result, gl.LINK_STATUS, cast(^i32) &linked)
    
    if !linked {
        vertex_error_bytes, fragment_error_bytes, program_error_bytes: [4096] u8
        vertex_length, fragment_length, program_length: i32
        
        gl.GetShaderInfoLog(vertex_shader_id,   len(vertex_error_bytes),   &vertex_length,   &vertex_error_bytes[0])
        gl.GetShaderInfoLog(fragment_shader_id, len(fragment_error_bytes), &fragment_length, &fragment_error_bytes[0])
        gl.GetProgramInfoLog(result,            len(program_error_bytes),  &program_length,  &program_error_bytes[0])
        
        vertex_error   := cast(string) vertex_error_bytes[:vertex_length]
        fragment_error := cast(string) fragment_error_bytes[:fragment_length]
        program_error  := cast(string) program_error_bytes[:program_length]
        if vertex_error   != "" do print("vertex error message:\n%\n", vertex_error)
        if fragment_error != "" do print("fragment error message:\n%\n", fragment_error)
        if program_error  != "" do print("program error message:\n%\n", program_error)
        
        assert(false)
    }
    
    return result
}


////////////////////////////////////////////////

gl_display_bitmap :: proc (bitmap: Bitmap, draw_region: Rectangle2i, clear_color: v4) {
    timed_function()

    gl_bind_frame_buffer(0, draw_region)
    
    gl.Disable(gl.SCISSOR_TEST)
    gl.Disable(gl.BLEND)
    defer gl.Enable(gl.BLEND)
    
    gl.BindTexture(gl.TEXTURE_2D, open_gl.blit_texture_handle)
    defer gl.BindTexture(gl.TEXTURE_2D, 0)
    
    gl.TexImage2D(gl.TEXTURE_2D, 0, gl.SRGB8_ALPHA8, bitmap.width, bitmap.height, 0, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(bitmap.memory))
    
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP)
    gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP)
    
    gl.Enable(gl.TEXTURE_2D)
    
    gl.ClearColor(clear_color.r, clear_color.g, clear_color.b, clear_color.a)
    gl.Clear(gl.COLOR_BUFFER_BIT)
    
    if true do unimplemented()
    
    // gl_rectangle(min = {-1, -1, 0}, max = {1, 1, 0}, color = {1,1,1,1}, minuv = 0, maxuv =1)
}

////////////////////////////////////////////////

gl_render_commands :: proc (commands: ^RenderCommands, draw_region: Rectangle2i, window_dim: v2i) {
    timed_function()
    
    gl_setup_render := game.begin_timed_block("gl setup render")
    draw_dim := get_dimension(draw_region)
    gl_bind_frame_buffer(0, draw_region)
    defer gl_bind_frame_buffer(0, draw_region)
    
    gl.DepthMask(true)
    gl.ColorMask(true, true, true, true)
    gl.DepthFunc(gl.LEQUAL)
    gl.Enable(gl.DEPTH_TEST)
    gl.Enable(gl.SAMPLE_ALPHA_TO_COVERAGE)
    gl.Enable(gl.SAMPLE_ALPHA_TO_ONE)
    gl.Enable(gl.MULTISAMPLE)
    
    gl.Enable(gl.SCISSOR_TEST)
    gl.Enable(gl.BLEND)
    gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    
    // @note(viktor): FrameBuffer 0 is the default frame buffer, which we got on initialization
    max_render_target_count := cast(i64) commands.max_render_target_index + 1
    assert(max_render_target_count < len(open_gl.framebuffer_handles.data))
    if max_render_target_count >= open_gl.framebuffer_handles.count {
        count := open_gl.framebuffer_handles.count
        new_count := max_render_target_count - count
        
        open_gl.framebuffer_handles.count  += new_count
        gl.GenFramebuffers(cast(i32) new_count, &open_gl.framebuffer_handles.data[count])
        
        for render_target in slice(&open_gl.framebuffer_handles)[count:] {
            width  := draw_dim.x 
            height := draw_dim.y
            
            max_sample_count:i32
            gl.GetIntegerv(gl.MAX_COLOR_TEXTURE_SAMPLES, &max_sample_count)
            max_sample_count = min(16, max_sample_count)
            
            slot: u32 = gl.TEXTURE_2D_MULTISAMPLE when !true else gl.TEXTURE_2D
            
            using textures: struct { texture, depth_texture: u32 }
            gl.GenTextures(2, auto_cast &textures)
            
            gl.BindTexture(slot, texture)
            if slot == gl.TEXTURE_2D_MULTISAMPLE {
                gl.TexImage2DMultisample(slot, max_sample_count, open_gl.default_texture_format, width, height, false)
            } else {
                gl.TexImage2D(slot, 0, cast(i32) open_gl.default_texture_format, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
            }
            
            gl.BindTexture(slot, depth_texture)
            // @todo(viktor): Check if going with a 16-bit depth buffer would be faster and have enough quality
            if slot == gl.TEXTURE_2D_MULTISAMPLE {
                gl.TexImage2DMultisample(slot, max_sample_count, gl.DEPTH_COMPONENT24, width, height, false)
            } else {
                gl.TexImage2D(slot, 0, gl.DEPTH_COMPONENT24, width, height, 0, gl.DEPTH_COMPONENT, gl.UNSIGNED_BYTE, nil)
            }
            gl.BindTexture(slot, 0)
            
            append(&open_gl.framebuffer_textures, texture)
            
            gl.BindFramebuffer(gl.FRAMEBUFFER, render_target)
            gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, slot, texture, 0)
            gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT,  slot, depth_texture, 0)
            
            status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
            assert(status == gl.FRAMEBUFFER_COMPLETE)
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
    
    current_render_target_index := max(u32)
    game.end_timed_block(gl_setup_render)
    
    for begin_reading(&commands.push_buffer); can_read(&commands.push_buffer); {
        header := read(&commands.push_buffer, RenderEntryHeader)
        
        switch header.type {
          case .RenderEntry_Textured_Quads:
            entry := read(&commands.push_buffer, RenderEntry_Textured_Quads)
            
            ////////////////////////////////////////////////
            
            setup := entry.setup
            if current_render_target_index != setup.render_target_index {
                current_render_target_index = setup.render_target_index
                gl_bind_frame_buffer(current_render_target_index, draw_region)
            }
            
            gl.Scissor(setup.clip_rect.min.x, setup.clip_rect.min.y, setup.clip_rect.max.x - setup.clip_rect.min.x, setup.clip_rect.max.y - setup.clip_rect.min.y)
            
            copy := game.begin_timed_block("gl copy buffer data")
            gl.BufferData(gl.ARRAY_BUFFER, cast(int) commands.vertex_buffer.count * size_of(Textured_Vertex), raw_data(commands.vertex_buffer.data), gl.STREAM_DRAW)
            game.end_timed_block(copy)
            
            ////////////////////////////////////////////////
            
            begin_program(open_gl.zbias_no_depth_peel, setup)
            defer end_program(open_gl.zbias_no_depth_peel)
            
            loop := game.begin_timed_block("gl quad loop")
            for bitmap_index in entry.bitmap_offset..<entry.bitmap_offset+entry.quad_count {
                bitmap := commands.quad_bitmap_buffer.data[bitmap_index]
                gl.BindTexture(gl.TEXTURE_2D, bitmap.texture_handle)
                
                vertex_index := cast(i32) bitmap_index * 4
                gl.DrawArrays(gl.TRIANGLE_STRIP, vertex_index, 4)
            }
            end_timed_block(loop)
            
          case .RenderEntry_DepthClear:
            entry := read(&commands.push_buffer, RenderEntry_DepthClear)
            gl.Clear(gl.DEPTH_BUFFER_BIT)
            
            
          case .RenderEntryBlendRenderTargets:
            entry := read(&commands.push_buffer, RenderEntryBlendRenderTargets)
            
            // @todo(viktor): if blending works without binding the dest then we can also remove that member from the Entry
            // gl_bind_frame_buffer(entry.dest_index, draw_region)
            // defer gl_bind_frame_buffer(current_target_index, draw_region)
            
            // @todo(viktor): If the window has black bars the rectangle will be offset incorrectly. thanks global variables!
            gl.BindTexture(gl.TEXTURE_2D, open_gl.framebuffer_textures.data[entry.source_index])
            
            gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
            defer gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
            
            // @todo(viktor): move this to the newer version of the code
            max := commands_dim
            glBegin(gl.TRIANGLES)
            
            glColor4f(1, 1, 1, entry.alpha)
            
            // @note(viktor): Lower triangle
            glTexCoord2f(0, 0)
            glVertex3f(0, 0, 0)
            
            glTexCoord2f(1, 0)
            glVertex3f(max.x, 0, 0)
            
            glTexCoord2f(1, 1)
            glVertex3f(max.x, max.y, 0)
            
            // @note(viktor): Upper triangle
            glTexCoord2f(0, 0)
            glVertex3f(0, 0, 0)
            
            glTexCoord2f(1, 1)
            glVertex3f(max.x, max.y, 0)
            
            glTexCoord2f(0, 1)
            glVertex3f(0, max.y, 0)
            
            glEnd()
            
          case .None: unreachable()
          case: panic("Unhandled Entry")
        }
    }
    
    gl.BindFramebuffer(gl.READ_FRAMEBUFFER, open_gl.framebuffer_handles.data[0])
    gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
    gl.Viewport(draw_region.min.x, draw_region.min.y, window_dim.x, window_dim.y)
    
    s := draw_dim
    d := draw_region
    gl.BlitFramebuffer(0, 0, s.x, s.y, d.min.x, d.min.y, d.max.x, d.max.y, gl.COLOR_BUFFER_BIT, gl.LINEAR)
}

////////////////////////////////////////////////

gl_bind_frame_buffer :: proc (render_target_index: u32, draw_region: Rectangle2i) {
    render_target := open_gl.framebuffer_handles.data[render_target_index]
    gl.BindFramebuffer(gl.FRAMEBUFFER, render_target)
    
    window_dim := get_dimension(draw_region)
    gl.Viewport(0, 0, window_dim.x, window_dim.y)
}

////////////////////////////////////////////////
// @cleanup get rid of as many as possible

glBegin:        proc (_: u32)
glEnd:          proc ()

glTexCoord2f:   proc (_,_: f32)
glVertex3f:     proc (_,_,_: f32)
glColor4f:      proc (_,_,_,_: f32)