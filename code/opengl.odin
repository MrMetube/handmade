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
    
    resolve: FrameBuffer,
    framebuffers: FixedArray(256, FrameBuffer),
    
    blit_texture_handle: u32,
    
    zbias_no_depth_peel: ZBiasProgram, // @note(viktor): pass 0
    zbias_depth_peel:    ZBiasProgram, // @note(viktor): passes 1 through n
    peel_composite:      PeelCompositeProgram, // @note(viktor): composite all passes
    final_stretch:       FinalStretchProgram,
}

CreateFramebufferFlags :: bit_set[enum{ multisampled, filtered, has_color, has_depth }]

FrameBuffer :: struct {
    handle: u32,
    
    color_texture: u32,
    depth_texture: u32,
}

// @todo(viktor): maybe try this instead of gl_xxx
sl :: struct ($T: typeid) {
    location: i32,
    value:    T,
}

gl_m4        :: distinct i32
gl_f32       :: distinct i32
gl_v2        :: distinct i32
gl_v3        :: distinct i32
gl_v4        :: distinct i32
gl_sampler2D :: distinct i32

OpenGLProgram :: struct {
    handle: u32,
    
    using vertex_inputs: struct {
        in_p:     gl_v4,
        in_uv:    gl_v2,
        in_color: gl_v4,
    },
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
        compile_peel_composite(&open_gl.peel_composite)
        compile_final_stretch(&open_gl.final_stretch)
        
        // @todo(viktor): check that all programs where compiled
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

GlobalShaderHeaderCode :: `
#define f32 float
#define v2 vec2
#define v3 vec3
#define v4 vec4
#define V2 vec2
#define V3 vec3
#define V4 vec4
#define m4 mat4x4
#define linear_blend(a, b, t) mix(a, b, t)

#define clamp01(t) clamp(t, 0, 1)

f32 clamp_01_map_to_range(f32 min, f32 max, f32 t) {
    f32 range = max - min;
    f32 absolute = (t - min) / range;
    f32 result = clamp01(absolute);
    return result;
}
`

ZBiasProgram :: struct {
    using base: OpenGLProgram,
    
    using vertex_uniforms : struct {
        projection: gl_m4,
        camera_p:   gl_v3,
        fog_direction: gl_v3,
    },
    
    using pipeline_attributes: struct {
        frag_color: gl_v4,
        frag_uv:    gl_v2,
        fog_distance: gl_f32,
    },
    
    using fragment_uniforms: struct {
        fog_color:       gl_v3,
        texture_sampler: gl_sampler2D,
        depth_sampler:   gl_sampler2D,
        alpha_threshold: gl_f32,
        
        fog_begin:     gl_f32,
        fog_end:       gl_f32,
        
        clip_alpha_begin: gl_f32,
        clip_alpha_end:   gl_f32,
    },
}

compile_zbias_program :: proc (program: ^ZBiasProgram, depth_peeling: bool) {
    defines := ctprint(`
#version 130

#define DepthPeeling %
`, depth_peeling ? 1 : 0)
    
    buf: [2048] u8
    sb := make_string_builder(buf[:])
    
    gl_generate(&sb, type_of(program.vertex_uniforms), "uniform")
    gl_generate(&sb, type_of(program.vertex_inputs), "in")
    gl_generate(&sb, type_of(program.pipeline_attributes), "smooth out")
    
    append(&sb, `
void main (void) {
    v4 in_vertex = V4(in_p.xyz, 1);
    f32 z_bias = in_p.w;
    
    v4 z_vertex = in_vertex;
    z_vertex.z += z_bias;
    
    v4 z_min_transform = projection * in_vertex;
    v4 z_max_transform = projection * z_vertex;
    
    f32 modified_z = (z_min_transform.w / z_max_transform.w) * z_max_transform.z;
    
    gl_Position = V4(z_min_transform.xy, modified_z, z_min_transform.w);
    
    frag_uv = in_uv;
    frag_color = in_color;
    
    fog_distance = dot(z_vertex.xyz - camera_p, fog_direction);
}
`)
    vertex_code := to_cstring(&sb)
    
    buf2: [2048] u8
    sb = make_string_builder(buf2[:])
    
    gl_generate(&sb, type_of(program.fragment_uniforms), "uniform")
    gl_generate(&sb, type_of(program.pipeline_attributes), "smooth in")
    
    append(&sb, `
out v4 result_color;

void main (void) {
    f32 clip_depth = 0;
  #if DepthPeeling
    clip_depth = texelFetch(depth_sampler, ivec2(gl_FragCoord.xy), 0).r;
    f32 frag_z = gl_FragCoord.z;
    if (frag_z <= clip_depth) {
        discard;
    }
        
    f32 ClipDepth = texelFetch(depth_sampler, ivec2(gl_FragCoord.xy), 0).r;
    f32 FragZ = gl_FragCoord.z;
    if(FragZ <= ClipDepth)
    {
        discard;
    }
  #endif // DepthPeeling
    
    f32 fog_amount   = clamp_01_map_to_range(fog_begin,        fog_end,        fog_distance);
    f32 alpha_amount = clamp_01_map_to_range(clip_alpha_begin, clip_alpha_end, fog_distance);
    
    v4 texture_sample = texture(texture_sampler, frag_uv);
    v4 modulated = frag_color * texture_sample;
    modulated *= alpha_amount;
    
    if (modulated.a > alpha_threshold) {
        result_color.rgb = linear_blend(modulated.rgb, fog_color, fog_amount);
        result_color.a = modulated.a;
    } else {
        discard;
    }
}
`)
    
    fragment_code := to_cstring(&sb)
    
    program.handle = gl_create_program(defines, GlobalShaderHeaderCode, vertex_code, fragment_code)
    gl_get_locations(program.handle, &program.vertex_inputs, false)
    
    gl_get_locations(program.handle, &program.vertex_uniforms, true)
    gl_get_locations(program.handle, &program.fragment_uniforms, true)
}

PeelCompositeProgram :: struct {
    using base: OpenGLProgram,
    
    using vertex_uniforms : struct {
    },
    
    using pipeline_attributes: struct {
        frag_color: gl_v4,
        frag_uv:    gl_v2,
    },
    
    using fragment_uniforms: struct {
        // @todo(viktor): support arrays of samplers
        peel0_sampler: gl_sampler2D,
        peel1_sampler: gl_sampler2D,
        peel2_sampler: gl_sampler2D,
        peel3_sampler: gl_sampler2D,
    },
    
}

compile_peel_composite :: proc (program: ^PeelCompositeProgram) {
    defines: cstring = "#version 130"
    
    buf: [2048] u8
    sb := make_string_builder(buf[:])
    
    gl_generate(&sb, type_of(program.vertex_uniforms), "uniform")
    gl_generate(&sb, type_of(program.vertex_inputs), "in")
    gl_generate(&sb, type_of(program.pipeline_attributes), "smooth out")
    
    append(&sb, `
void main (void) {
    gl_Position = in_p;
    frag_uv = in_uv;
    frag_color = in_color;
}
`)
    vertex_code := to_cstring(&sb)
    
    buf2: [2048] u8
    sb = make_string_builder(buf2[:])
    
    gl_generate(&sb, type_of(program.fragment_uniforms), "uniform")
    gl_generate(&sb, type_of(program.pipeline_attributes), "in")
    
    append(&sb, `
out v4 result_color;

void main (void) {
    v4 peel0 = texture(peel0_sampler, frag_uv);
    v4 peel1 = texture(peel1_sampler, frag_uv);
    v4 peel2 = texture(peel2_sampler, frag_uv);
    v4 peel3 = texture(peel3_sampler, frag_uv);
    
    #if 0
    peel3.rgb *= 1.0f / peel3.a;
    #endif
    
    #if 0
    peel0.rgb = V3(0, 0, 1) * peel0.a;
    peel1.rgb = V3(0, 1, 0) * peel1.a;
    peel2.rgb = V3(1, 0, 0) * peel2.a;
    peel3.rgb = V3(1, 1, 1) * peel3.a;
    #endif
    
    result_color.rgb = peel3.rgb;
    result_color.rgb = peel2.rgb + (1 - peel2.a) * result_color.rgb;
    result_color.rgb = peel1.rgb + (1 - peel1.a) * result_color.rgb;
    result_color.rgb = peel0.rgb + (1 - peel0.a) * result_color.rgb;
}
`)
    fragment_code := to_cstring(&sb)

    program.handle = gl_create_program(defines, GlobalShaderHeaderCode, vertex_code, fragment_code)
    gl_get_locations(program.handle, &program.vertex_inputs, false)
    
    gl_get_locations(program.handle, &program.vertex_uniforms,   true)
    gl_get_locations(program.handle, &program.fragment_uniforms, true)
}

FinalStretchProgram :: struct {
    using base: OpenGLProgram,
    
    using vertex_uniforms: struct {},
    
    using pipeline_attributes: struct {
        frag_color: gl_v4,
        frag_uv:    gl_v2,
    },
    
    using fragment_uniforms: struct {
        image: gl_sampler2D,
    },
    
}

compile_final_stretch :: proc (program: ^FinalStretchProgram) {
    defines: cstring = "#version 130"
    
    buf: [2048] u8
    sb := make_string_builder(buf[:])
    
    gl_generate(&sb, type_of(program.vertex_uniforms), "uniform")
    gl_generate(&sb, type_of(program.vertex_inputs), "in")
    gl_generate(&sb, type_of(program.pipeline_attributes), "smooth out")
    
    append(&sb, `
void main (void) {
    gl_Position = in_p;
    frag_uv = in_uv;
    frag_color = in_color;
}
`)
    vertex_code := to_cstring(&sb)
    
    buf2: [2048] u8
    sb = make_string_builder(buf2[:])
    
    gl_generate(&sb, type_of(program.fragment_uniforms), "uniform")
    gl_generate(&sb, type_of(program.pipeline_attributes), "in")
    
    append(&sb, `
out v4 result_color;

void main (void) {
    v4 sample = texture(image, frag_uv);
    result_color = sample;
}
`)
    fragment_code := to_cstring(&sb)

    program.handle = gl_create_program(defines, GlobalShaderHeaderCode, vertex_code, fragment_code)
    gl_get_locations(program.handle, &program.vertex_inputs, false)
    
    gl_get_locations(program.handle, &program.vertex_uniforms,   true)
    gl_get_locations(program.handle, &program.fragment_uniforms, true)
}

////////////////////////////////////////////////

begin_program :: proc { begin_program_peel_composite, begin_program_zbias, begin_program_final_stretch }

begin_program_final_stretch :: proc (program: FinalStretchProgram) {
    begin_program_common(program)
    
    // @todo(viktor): @metaprogram here?
    gl.Uniform1i(auto_cast program.image, 0)
}
begin_program_peel_composite :: proc (program: PeelCompositeProgram) {
    begin_program_common(program)
    
    // @todo(viktor): @metaprogram here?
    gl.Uniform1i(auto_cast program.peel0_sampler, 0)
    gl.Uniform1i(auto_cast program.peel1_sampler, 1)
    gl.Uniform1i(auto_cast program.peel2_sampler, 2)
    gl.Uniform1i(auto_cast program.peel3_sampler, 3)
}

begin_program_zbias :: proc (program: ZBiasProgram, setup: RenderSetup, alpha_threshold: f32) {
    begin_program_common(program)
    
    // @todo(viktor): @metaprogram here?
    setup := setup
    gl.UniformMatrix4fv(auto_cast program.projection, 1, false, &setup.projection[0, 0])
    gl.Uniform3fv(auto_cast program.camera_p,         1, &setup.camera_p[0])
    gl.Uniform3fv(auto_cast program.fog_direction,    1, &setup.fog_direction[0])
    
    gl.Uniform3fv(auto_cast program.fog_color,        1, &setup.fog_color[0])
    gl.Uniform1i(auto_cast program.texture_sampler, 0)
    gl.Uniform1i(auto_cast program.depth_sampler,   1)
    gl.Uniform1f(auto_cast program.alpha_threshold,   alpha_threshold)
    gl.Uniform1f(auto_cast program.fog_begin,         setup.fog_begin)
    gl.Uniform1f(auto_cast program.fog_end,           setup.fog_end)
    gl.Uniform1f(auto_cast program.clip_alpha_begin,  setup.clip_alpha_begin)
    gl.Uniform1f(auto_cast program.clip_alpha_end,    setup.clip_alpha_end)
}

begin_program_common :: proc (program: OpenGLProgram) {
    gl.UseProgram(program.handle)
    
    dummy: Textured_Vertex
    stride := cast(i32) size_of(dummy)
    
    if program.in_uv != -1 {
        id := cast(u32) program.in_uv
        gl.EnableVertexAttribArray(id)
        gl.VertexAttribPointer(id, len(dummy.uv), gl.FLOAT, false, stride, offset_of(dummy.uv))
    }
    if program.in_color != -1 {
        id := cast(u32) program.in_color
        gl.EnableVertexAttribArray(id)
        gl.VertexAttribPointer(id, len(dummy.color), gl.UNSIGNED_BYTE, true, stride, offset_of(dummy.color))
    }
    if program.in_p != -1 {
        id := cast(u32) program.in_p
        gl.EnableVertexAttribArray(id)
        gl.VertexAttribPointer(id, len(dummy.p), gl.FLOAT, false, stride, offset_of(dummy.p))
    }
}

end_program :: proc { end_program_common }
end_program_common :: proc (program: OpenGLProgram) {
    if program.in_uv    != -1 do gl.DisableVertexAttribArray(cast(u32) program.in_uv)
    if program.in_color != -1 do gl.DisableVertexAttribArray(cast(u32) program.in_color)
    if program.in_p     != -1 do gl.DisableVertexAttribArray(cast(u32) program.in_p)
    
    gl.UseProgram(0)
}

gl_type_to_string :: proc (type: typeid) -> (result: string) {
    switch type {
        case: unreachable()
        case gl_m4:        result = "m4"
        case gl_f32:       result = "f32"
        case gl_v2:        result = "v2"
        case gl_v3:        result = "v3"
        case gl_v4:        result = "v4"
        case gl_sampler2D: result = "sampler2D"
    }
    
    return result
}

gl_generate :: proc (sb: ^String_Builder, type: typeid, prefix: string) {
    info := type_info_of(type).variant.(runtime.Type_Info_Struct)
    for index in 0 ..< info.field_count {
        id := info.types[index].id
        name := info.names[index]
        
        appendf(sb, "% % %;\n", prefix, gl_type_to_string(id), name)
    }
    append(sb, "\n")
}

gl_get_locations :: proc (program_handle: u32, base: ^$T, $is_uniform: bool) {
    info := type_info_of(T).variant.(runtime.Type_Info_Struct)
    bytes := to_bytes(base)
    
    for index in 0 ..< info.field_count {
        size := info.types[index].size
        name := info.names[index]
        offset := info.offsets[index]
        
        cname := ctprint("%", name)
        when is_uniform {
            value := gl.GetUniformLocation(program_handle, cname)
        } else {
            value := gl.GetAttribLocation(program_handle, cname)
        }
        
        dest := bytes[offset:][:size]    
        source := to_bytes(&value)
        copy_slice(dest, source)
    }
}
    
gl_create_program :: proc (defines, header_code, vertex_code, fragment_code: cstring) -> (result: u32) {
    shared_code := ctprint("% %", defines, header_code)
    
    lengths := [?] i32 { 0..<20 = -1 }
    
    vertex_shader_code   := [?] cstring { shared_code, vertex_code }
    fragment_shader_code := [?] cstring { shared_code, fragment_code }
    
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

create_framebuffer :: proc (dim: v2i, flags: CreateFramebufferFlags) -> (result: FrameBuffer) {
    gl.GenFramebuffers(1, &result.handle)
    if .has_color in flags {
        gl.GenTextures(1, auto_cast &result.color_texture)
    }
    if .has_depth in flags {
        gl.GenTextures(1, auto_cast &result.depth_texture)
    }
    
    gl.BindFramebuffer(gl.FRAMEBUFFER, result.handle)
    
    max_sample_count: i32
    gl.GetIntegerv(gl.MAX_COLOR_TEXTURE_SAMPLES, &max_sample_count)
    max_sample_count = min(16, max_sample_count)
    
    slot: u32 = .multisampled in flags ? gl.TEXTURE_2D_MULTISAMPLE : gl.TEXTURE_2D
    filtering: i32 = .filtered in flags ? gl.LINEAR : gl.NEAREST
    
    if .has_color in flags {
        gl.BindTexture(slot, result.color_texture)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filtering)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filtering)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
        
        if slot == gl.TEXTURE_2D_MULTISAMPLE {
            gl.TexImage2DMultisample(slot, max_sample_count, open_gl.default_texture_format, dim.x, dim.y, false)
        } else {
            gl.TexImage2D(slot, 0, cast(i32) open_gl.default_texture_format, dim.x, dim.y, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
        }
        
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, slot, result.color_texture, 0)
    }
    
    if .has_depth in flags {
        gl.BindTexture(slot, result.depth_texture)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filtering)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filtering)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
        gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
        
        // @todo(viktor): Check if going with a 16-bit depth buffer would be faster and have enough quality
        if slot == gl.TEXTURE_2D_MULTISAMPLE {
            gl.TexImage2DMultisample(slot, max_sample_count, gl.DEPTH_COMPONENT24, dim.x, dim.y, false)
        } else {
            gl.TexImage2D(slot, 0, gl.DEPTH_COMPONENT24, dim.x, dim.y, 0, gl.DEPTH_COMPONENT, gl.UNSIGNED_INT, nil)
        }
        
        gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT,  slot, result.depth_texture, 0)
    }
    gl.BindTexture(slot, 0)
    
    
    status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
    assert(status == gl.FRAMEBUFFER_COMPLETE)
    
    return result
}

gl_render_commands :: proc (commands: ^RenderCommands, draw_region: Rectangle2i, window_dim: v2i) {
    timed_function()
    
    gl_setup_render := game.begin_timed_block("gl setup render")
    render_dim := v2i{commands.width, commands.height}
    
    gl.DepthMask(true)
    gl.ColorMask(true, true, true, true)
    gl.DepthFunc(gl.LEQUAL)
    gl.Enable(gl.DEPTH_TEST)
    gl.Enable(gl.CULL_FACE)
    gl.CullFace(gl.BACK)
    gl.FrontFace(gl.CCW)
    // gl.Enable(gl.SAMPLE_ALPHA_TO_COVERAGE)
    // gl.Enable(gl.SAMPLE_ALPHA_TO_ONE)
    // gl.Enable(gl.MULTISAMPLE)
    
    gl.Enable(gl.SCISSOR_TEST)
    gl.Disable(gl.BLEND)
    gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
    
    max_render_target_index := cast(u32) 3 // commands.max_render_target_index
    count := cast(u32) open_gl.framebuffers.count
    if max_render_target_index >= count {
        if open_gl.resolve.handle == 0 {
            open_gl.resolve = create_framebuffer(render_dim, { .filtered, .has_color })
        }
        
        new_frame_buffer_count := max_render_target_index + 1
        assert(new_frame_buffer_count < len(open_gl.framebuffers.data))
        
        new_count := new_frame_buffer_count - count
        for _ in 0..<new_count {
            buffer := create_framebuffer(render_dim, { .has_color, .has_depth })
            append(&open_gl.framebuffers, buffer)
        }
    }
    
    for index in 0 ..= max_render_target_index {
        gl_bind_frame_buffer(index, render_dim)
        gl.Scissor(0, 0, render_dim.x, render_dim.y)
        
        c: v4
        if index == max_render_target_index {
            c = commands.clear_color
            c.a = 1
        }
        
        gl.ClearColor(c.r, c.g, c.b, c.a)
        gl.ClearDepth(1)
        gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
    }
    
    game.end_timed_block(gl_setup_render)
    
    gl_bind_frame_buffer(0, render_dim)
    
    current_render_target_index := max(u32)
    
    peeling: bool
    peel_index: u32
    peel_header_restore: int
    for begin_reading(&commands.push_buffer); can_read(&commands.push_buffer); {
        header := read(&commands.push_buffer, RenderEntryHeader)
        
        switch header.type {
          case .None: unreachable()
          case: panic("Unhandled Entry")
            
          case .DepthClear:
            gl.Clear(gl.DEPTH_BUFFER_BIT)
            
          case .BeginPeels:
            peel_header_restore = commands.push_buffer.read_cursor
            
          case .EndPeels:
            if peel_index < max_render_target_index {
                commands.push_buffer.read_cursor = peel_header_restore
                peel_index += 1
                gl_bind_frame_buffer(peel_index, render_dim)
                peeling = true
            } else {
                assert(peel_index == max_render_target_index)
                gl_bind_frame_buffer(0, render_dim)
                peeling = false
            }
            
          case .BlendRenderTargets:
            entry := read(&commands.push_buffer, BlendRenderTargets)
            
            // @todo(viktor): if blending works without binding the dest then we can also remove that member from the Entry
            // gl_bind_frame_buffer(entry.dest_index, draw_region)
            // defer gl_bind_frame_buffer(current_target_index, draw_region)
            
            // @todo(viktor): If the window has black bars the rectangle will be offset incorrectly. thanks global variables!
            gl.BindTexture(gl.TEXTURE_2D, open_gl.framebuffers.data[entry.source_index].color_texture)
            
            gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
            defer gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
            
            // @todo(viktor): move this to the newer version of the code
            commands_dim := vec_cast(f32, commands.width, commands.height)
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
            
          case .Textured_Quads:
            entry := read(&commands.push_buffer, Textured_Quads)
            
            ////////////////////////////////////////////////
            
            setup := entry.setup
            unused(current_render_target_index)
            when false {
                if current_render_target_index != setup.render_target_index {
                    current_render_target_index = setup.render_target_index
                    gl_bind_frame_buffer(current_render_target_index, draw_region)
                }
            }
            
            gl.Scissor(get_xywh(setup.clip_rect))
            
            copy := game.begin_timed_block("gl copy buffer data")
            gl.BufferData(gl.ARRAY_BUFFER, cast(int) commands.vertex_buffer.count * size_of(Textured_Vertex), raw_data(commands.vertex_buffer.data), gl.STREAM_DRAW)
            game.end_timed_block(copy)
            
            ////////////////////////////////////////////////
            
            program := open_gl.zbias_no_depth_peel
            alpha_threshold: f32
            if peeling {
                program = open_gl.zbias_depth_peel
                gl.ActiveTexture(gl.TEXTURE1)
                gl.BindTexture(gl.TEXTURE_2D, open_gl.framebuffers.data[peel_index-1].depth_texture)
                gl.ActiveTexture(gl.TEXTURE0)
                if peel_index == max_render_target_index {
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
            
            gl.BindTexture(gl.TEXTURE_2D, 0)
            
            end_program(program)
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
    
    gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, open_gl.resolve.handle)
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
    for index in 1 ..= max_render_target_index {
        gl.ActiveTexture(gl.TEXTURE0 + index)
        gl.BindTexture(gl.TEXTURE_2D, open_gl.framebuffers.data[index].color_texture)
    }
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D, open_gl.framebuffers.data[0].color_texture)
    
    gl.DrawArrays(gl.TRIANGLE_STRIP, 0, auto_cast len(vertex_buffer))
    
    for index in 1 ..= max_render_target_index {
        gl.ActiveTexture(gl.TEXTURE0 + index)
        gl.BindTexture(gl.TEXTURE_2D, 0)
    }
    gl.ActiveTexture(gl.TEXTURE0)
    
    end_program(open_gl.peel_composite)
    
    ////////////////////////////////////////////////
    
    gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
    
    gl.Viewport(0, 0, window_dim.x, window_dim.y)
    gl.Scissor(0, 0, window_dim.x, window_dim.y)
    gl.ClearColor(0, 0, 0, 0)
    gl.Clear(gl.COLOR_BUFFER_BIT)
    
    gl.Viewport(get_xywh(draw_region))
    gl.Scissor(get_xywh(draw_region))
    
    begin_program(open_gl.final_stretch)
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D, open_gl.resolve.color_texture)
    
    gl.DrawArrays(gl.TRIANGLE_STRIP, 0, auto_cast len(vertex_buffer))
    
    gl.ActiveTexture(gl.TEXTURE0)
    gl.BindTexture(gl.TEXTURE_2D, 0)
    
    end_program(open_gl.final_stretch)
    
    ////////////////////////////////////////////////
    
    // s := render_dim
    // d := draw_region
    // gl.BindFramebuffer(gl.READ_FRAMEBUFFER, open_gl.framebuffer_handles.data[0])
    // gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
    // gl.Viewport(draw_region.min.x, draw_region.min.y, window_dim.x, window_dim.y)
    
    // gl.BlitFramebuffer(0, 0, s.x, s.y, d.min.x, d.min.y, d.max.x, d.max.y, gl.COLOR_BUFFER_BIT, gl.LINEAR)
}

gl_display_bitmap :: proc (bitmap: Bitmap, draw_region: Rectangle2i, clear_color: v4) {
    if true do unimplemented()
    
    timed_function()
    
    gl_bind_frame_buffer(0, get_dimension(draw_region))
    
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
    
    // gl_rectangle(min = {-1, -1, 0}, max = {1, 1, 0}, color = {1,1,1,1}, minuv = 0, maxuv =1)
}

////////////////////////////////////////////////

gl_bind_frame_buffer :: proc (render_target_index: u32, render_dim: v2i) {
    render_texture := open_gl.framebuffers.data[render_target_index].handle
    gl.BindFramebuffer(gl.FRAMEBUFFER, render_texture)
    
    gl.Viewport(0, 0, render_dim.x, render_dim.y)
}

////////////////////////////////////////////////
// @cleanup the last usage is in BlendRenderTargets, which itself is no longer used

glBegin: proc (_: u32)
glEnd:   proc ()

glTexCoord2f: proc (_,_: f32)
glVertex3f:   proc (_,_,_: f32)
glColor4f:    proc (_,_,_,_: f32)