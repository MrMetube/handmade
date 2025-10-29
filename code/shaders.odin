package main

import "base:runtime"
import gl "vendor:OpenGl"

// @todo(viktor): maybe try this instead of gl_xxx
sl :: struct ($T: typeid) {
    location: i32,
    value:    T,
}

sl_m4  :: sl(^m4)
sl_u32 :: sl(u32)
sl_i32 :: sl(i32)
sl_f32 :: sl(f32)
sl_v2  :: sl(v2)
sl_v3  :: sl(v3)
sl_v4  :: sl(v4)
sl_sampler2D :: sl(i32)
sl_sampler2DMS :: sl(i32)

gl_m4          :: distinct i32
gl_i32         :: distinct i32
gl_u32         :: distinct i32
gl_f32         :: distinct i32
gl_v2          :: distinct i32
gl_v3          :: distinct i32
gl_v4          :: distinct i32
gl_sampler2D   :: distinct i32
gl_sampler2DMS :: distinct i32

OpenGLProgram :: struct {
    handle: u32,
    
    using vertex_inputs: struct {
        in_p:     gl_v4,
        in_n:     gl_v3,
        in_uv:    gl_v2,
        in_color: gl_v4,
    },
}

////////////////////////////////////////////////

GlobalShaderHeaderCode :: `
#define u32 unsigned int
#define i32 int
#define f32 float
#define v2 vec2
#define v3 vec3
#define v4 vec4
#define V2 vec2
#define V3 vec3
#define V4 vec4
#define m4 mat4x4
#define linear_blend(a, b, t) mix(a, b, t)

#define clamp01(t) clamp((t), 0, 1)

#define square(t) ((t) * (t))

f32 clamp_01_map_to_range(f32 min, f32 max, f32 t) {
    f32 range = max - min;
    f32 absolute = (t - min) / range;
    f32 result = clamp01(absolute);
    return result;
}
`

////////////////////////////////////////////////

ZBiasProgram :: struct {
    using base: OpenGLProgram,
    
    using shared_uniforms : struct {
        camera_p: gl_v3,
    },
    
    using vertex_uniforms : struct {
        projection: gl_m4,
        fog_direction: gl_v3,
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
        
        light_p: gl_v3,
    },
}

////////////////////////////////////////////////

compile_zbias_program :: proc (program: ^ZBiasProgram, depth_peeling: bool) {
    common := tprint(`
#define DepthPeeling %
    
smooth INOUT v4 frag_color;
smooth INOUT v2 frag_uv;
smooth INOUT f32 fog_distance;
smooth INOUT v3 world_p;
smooth INOUT v3 world_n;

#ifdef VERTEX
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
    
    world_p = z_vertex.xyz;
    world_n = in_n;
}
#endif // VERTEX


#ifdef FRAGMENT
out v4 result_color;

void main (void) {
    v3  light_p = light_p;
    v3 light_strength = V3(6, 1, 4);

    f32 frag_z = gl_FragCoord.z;
    
    f32 clip_depth = 0;
  #if DepthPeeling
    clip_depth = texelFetch(depth_sampler, ivec2(gl_FragCoord.xy), 0).r;
    if (frag_z <= clip_depth) {
        discard;
    }
  #endif // DepthPeeling
    
    f32 fog_amount   = clamp_01_map_to_range(fog_begin,        fog_end,        fog_distance);
    f32 alpha_amount = clamp_01_map_to_range(clip_alpha_begin, clip_alpha_end, fog_distance);
    
    v4 texture_sample = texture(texture_sampler, frag_uv);
    v4 modulated = frag_color * texture_sample;
    modulated *= alpha_amount;
    
    if (modulated.a > alpha_threshold) {
        v3 to_camera = camera_p - world_p;
        f32 camera_distance = length(to_camera);
        to_camera *= (1.0f / camera_distance);
        
        v3 to_light = light_p - world_p;
        f32 light_distance = length(to_light);
        to_light *= (1.0f / light_distance);
        v3 cos_light_angle = V3(
            dot(to_light, world_n),
            dot(to_light, world_n),
            dot(to_light, world_n)
        );
        cos_light_angle = clamp(cos_light_angle, 0, 1);
        
        
        v3 reflected_d = -to_camera + 2 * dot(world_n, to_camera) * world_n;
        v3 cos_reflected = V3(
            dot(to_light, reflected_d),
            dot(to_light, reflected_d),
            dot(to_light, reflected_d)
        );
        cos_reflected = clamp(cos_reflected, 0, 1);
        
        cos_reflected *= cos_reflected;
        cos_reflected *= cos_reflected;
        cos_reflected *= cos_reflected;
        cos_reflected *= cos_reflected;
        cos_reflected *= cos_reflected;
        
        v3 light_amount = light_strength / square(light_distance);
        
        f32 diffuse_c = 0.5f;
        v3 diffuse_light = diffuse_c * cos_light_angle * light_amount;
        
        f32 spec_c = 2.0f;
        v3 spec_light = spec_c * cos_reflected * light_amount;
        
        v3 light_total = diffuse_light + spec_light;
        
        result_color.rgb = linear_blend(modulated.rgb, fog_color, fog_amount);
        result_color.rgb *= light_total;
        
        result_color.a = modulated.a;
    } else {
        discard;
    }
}
#endif // FRAGMENT
`, depth_peeling ? 1 : 0)
    
    compile_program_common(program, common)
}

////////////////////////////////////////////////

PeelCompositeProgram :: struct {
    using base: OpenGLProgram,
    
    using shared_uniforms : struct {},
    using vertex_uniforms : struct {},
    
    using fragment_uniforms: struct {
        // @todo(viktor): support arrays of samplers
        peel0_sampler: gl_sampler2D,
        peel1_sampler: gl_sampler2D,
        peel2_sampler: gl_sampler2D,
        peel3_sampler: gl_sampler2D,
    },
}

compile_peel_composite :: proc (program: ^PeelCompositeProgram) {
    common := `
smooth INOUT v2 frag_uv;

#ifdef VERTEX
void main (void) {
    gl_Position = in_p;
    frag_uv = in_uv;
}
#endif // VERTEX

#ifdef FRAGMENT
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
#endif // FRAGMENT
`
    
    compile_program_common(program, common)
}

////////////////////////////////////////////////

MultisampleResolve :: struct {
    using base: OpenGLProgram,
    
    using shared_uniforms : struct {},
    using vertex_uniforms: struct {},
    using fragment_uniforms: struct {
        sample_count:  sl_i32,
        color_sampler: gl_sampler2DMS,
        depth_sampler: gl_sampler2DMS,
    },
}

compile_multisample_resolve :: proc (program: ^MultisampleResolve) {
    common := `
// @todo(viktor): depth is non-linear - can we do something here that is based on ratio?
#define DepthThreshold 0.001f

#ifdef VERTEX
void main (void) {
    gl_Position = in_p;
}
#endif // VERTEX

#ifdef FRAGMENT
out v4 result_color;

void main (void) {
#if 1
    f32 depth_max = 0;
    f32 depth_min = 0;
    
    for (i32 sample_index = 0; sample_index < sample_count; ++sample_index) {
        f32 depth = texelFetch(depth_sampler, ivec2(gl_FragCoord.xy), sample_index).r;
        depth_min = min(depth_min, depth);
        depth_max = max(depth_max, depth);
    }
        
    gl_FragDepth = 0.5f * (depth_min + depth_max);
    
    v4 combined_color = V4(0, 0, 0, 0);
    for (i32 sample_index = 0; sample_index < sample_count; ++sample_index) {
        f32 depth = texelFetch(depth_sampler, ivec2(gl_FragCoord.xy), sample_index).r;
        // if (depth == depth_min) 
        {
            v4 color = texelFetch(color_sampler, ivec2(gl_FragCoord.xy), sample_index);
            combined_color += color;
        }
    }
    
    
    f32 inv_sample_count = 1.0f / sample_count;
    result_color = inv_sample_count * combined_color;
#else
    i32 unique_count = 1;
    for (i32 index_a = 1; index_a < sample_count; ++index_a) {
        f32 depth_a = texelFetch(depth_sampler, ivec2(gl_FragCoord.xy), index_a).r;
        bool unique = true;
        for (i32 index_b = 0; index_b < index_a; ++index_b) {
            f32 depth_b = texelFetch(depth_sampler, ivec2(gl_FragCoord.xy), index_b).r;
            if (depth_a == depth_b) {
                unique = false;
                break;
            }
        }
        if (unique) {
            unique_count += 1;
        }
    }
    
    result_color.a = 1;
    if (unique_count == 1) result_color.rgb = V3(0,0,0);
    if (unique_count == 2) result_color.rgb = V3(1,0,0);
    if (unique_count == 3) result_color.rgb = V3(0,1,0);
    if (unique_count == 4) result_color.rgb = V3(1,1,0);
    if (unique_count == 5) result_color.rgb = V3(0,0,1);
    if (unique_count == 6) result_color.rgb = V3(1,0,1);
    if (unique_count == 7) result_color.rgb = V3(0,1,1);
    if (unique_count == 8) result_color.rgb = V3(1,1,1);

#endif
}
#endif // FRAGMENT
`
    
    compile_program_common(program, common)
}

////////////////////////////////////////////////

FinalStretchProgram :: struct {
    using base: OpenGLProgram,
    
    using shared_uniforms : struct {},
    using vertex_uniforms: struct {},
    
    using fragment_uniforms: struct {
        image: gl_sampler2D,
    },
}

compile_final_stretch :: proc (program: ^FinalStretchProgram) {
    common := `
smooth INOUT v2 frag_uv;

#ifdef VERTEX
void main (void) {
    gl_Position = in_p;
    frag_uv = in_uv;
}
#endif // VERTEX

#ifdef FRAGMENT
out v4 result_color;

void main (void) {
    v4 sample = texture(image, frag_uv);
    result_color = sample;
}
#endif // FRAGMENT
`

    compile_program_common(program, common)
}

////////////////////////////////////////////////

begin_program :: proc { begin_program_peel_composite, begin_program_zbias, begin_program_final_stretch, begin_program_multisample_resolve }

begin_program_final_stretch :: proc (program: FinalStretchProgram) {
    begin_program_common(program)
    
    // @todo(viktor): @metaprogram here?
    gl.Uniform1i(auto_cast program.image, 0)
}
begin_program_multisample_resolve :: proc (program: MultisampleResolve) {
    begin_program_common(program)
    
    // @todo(viktor): @metaprogram here?
    gl.Uniform1i(auto_cast program.sample_count.location,  program.sample_count.value)
    gl.Uniform1i(auto_cast program.color_sampler, 0)
    gl.Uniform1i(auto_cast program.depth_sampler, 1)
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
    
    gl.Uniform3fv(auto_cast program.light_p,   1, &setup.debug_light_p[0])
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
    if program.in_n != -1 {
        id := cast(u32) program.in_n
        gl.EnableVertexAttribArray(id)
        gl.VertexAttribPointer(id, len(dummy.n), gl.FLOAT, false, stride, offset_of(dummy.n))
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
    program := program
    base := cast(umm) cast(pmm) &program.vertex_inputs
    
    struct_type :: type_of(program.vertex_inputs)
    info := type_info_of(struct_type).variant.(runtime.Type_Info_Struct)
    for index in 0 ..< info.field_count {
        offset := info.offsets[index]
        type   := info.types[index]
        
        // @todo(viktor): make a proc for this reflection read from member of struct
        assert(size_of(i32) == type.size)
        value := (cast(^i32) (base + offset))^
        
        if value != -1 do gl.DisableVertexAttribArray(cast(u32) value)
    }
    
    gl.UseProgram(0)
}

////////////////////////////////////////////////

compile_program_common :: proc (program: ^$Program, common: string) {
    defines: cstring = "#version 330\n"
    
    vertex_buffer, fragment_buffer: [4096] u8
    vb := make_string_builder(vertex_buffer[:])
    fb := make_string_builder(fragment_buffer[:])
    
    append(&vb, `
#define INOUT out
#define VERTEX
`)
    
    append(&fb, `
#define INOUT in
#define FRAGMENT
`)
    
    gl_generate(&vb, type_of(program.shared_uniforms), "uniform")
    gl_generate(&vb, type_of(program.vertex_uniforms), "uniform")
    gl_generate(&vb, type_of(program.vertex_inputs), "in")
    
    gl_generate(&fb, type_of(program.shared_uniforms), "uniform")
    gl_generate(&fb, type_of(program.fragment_uniforms), "uniform")
    
    append(&vb, common)
    append(&fb, common)
    
    vertex_code := to_cstring(&vb)
    fragment_code := to_cstring(&fb)
    
    program.handle = create_program(defines, GlobalShaderHeaderCode, vertex_code, fragment_code)
    gl_get_locations(program.handle, &program.vertex_inputs, false)
    
    gl_get_locations(program.handle, &program.shared_uniforms,   true)
    gl_get_locations(program.handle, &program.vertex_uniforms,   true)
    gl_get_locations(program.handle, &program.fragment_uniforms, true)
}

create_program :: proc (defines, header_code, vertex_code, fragment_code: cstring) -> (result: u32) {
    vertex_shader_code   := [?] cstring { defines, header_code, vertex_code }
    fragment_shader_code := [?] cstring { defines, header_code, fragment_code }
    
    vertex_shader_id   := gl.CreateShader(gl.VERTEX_SHADER)
    fragment_shader_id := gl.CreateShader(gl.FRAGMENT_SHADER)
    defer {
        gl.DeleteShader(vertex_shader_id)
        gl.DeleteShader(fragment_shader_id)
    }
    
    gl.ShaderSource(vertex_shader_id,   len(vertex_shader_code),   raw_data(vertex_shader_code[:]),   nil)
    gl.ShaderSource(fragment_shader_id, len(fragment_shader_code), raw_data(fragment_shader_code[:]), nil)
    
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

delete_program :: proc (program: ^$Program) {
    gl.DeleteProgram(program.handle)
    program ^= {}
}

////////////////////////////////////////////////

gl_type_to_string :: proc (type: typeid) -> (result: string) {
    switch type {
        case: unreachable()
        case gl_i32:         result = "i32"
        case gl_u32:         result = "u32"
        case gl_m4:          result = "m4"
        case gl_f32:         result = "f32"
        case gl_v2:          result = "v2"
        case gl_v3:          result = "v3"
        case gl_v4:          result = "v4"
        case gl_sampler2D:   result = "sampler2D"
        case gl_sampler2DMS: result = "sampler2DMS"
        
        case sl_i32:         result = "i32"
        case sl_u32:         result = "u32"
        case sl_m4:          result = "m4"
        case sl_f32:         result = "f32"
        case sl_v2:          result = "v2"
        case sl_v3:          result = "v3"
        case sl_v4:          result = "v4"
        case sl_sampler2D:   result = "sampler2D"
        case sl_sampler2DMS: result = "sampler2DMS"
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
        
        // @todo(viktor): make a proc for this reflection copy into a member of struct
        dest := bytes[offset:][:size]    
        source := to_bytes(&value)
        copy_slice(dest, source)
    }
}