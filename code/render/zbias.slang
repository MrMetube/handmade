#include "shared.slang"

[[vk::binding(0, 0)]] ConstantBuffer<RootZBias> root;

struct VertexOutput {
    v4  fragment_p : SV_Position;
    v2  uv         : TEXCOORD0;
    v4  color      : COLOR0;
    v3  world_p;
    v3  world_n;
    f32 fog_distance;
    nointerpolation u32 texture;
};

[shader("vertex")]
VertexOutput vertexMain(u32 vertex_id : SV_VertexID) {
    // The command stream stores quads as triangle strips, but NoGraphicsAPI's
    // current graphics PSO uses triangle lists. Flip the two triangles to
    // match the Vulkan rasterizer winding after the Y coordinate conversion.
    
    // :QuadWinding:
    u32 quad_vertex_indices[6] = { 0u, 2u, 1u, 2u, 3u, 1u };
    u32 quad_index             = vertex_id / 6u;
    u32 quad_vertex_index = quad_vertex_indices[vertex_id % 6u];
    TexturedVertex vertex = root.vertices[root.vertex_base + quad_index * 4u + quad_vertex_index];
    
    v4 in_vertex = v4(vertex.p.xyz, 1.0f);
    f32 z_bias = vertex.p.z;
    
    v4 z_vertex = in_vertex;
    z_vertex.z += z_bias;
    
    v4 z_min_transform = mul(root.projection, in_vertex);
    v4 z_max_transform = mul(root.projection, z_vertex);
    
    f32 modified_z = (z_min_transform.w / z_max_transform.w) * z_max_transform.z;
    
    VertexOutput output;
    output.fragment_p = v4(z_min_transform.xy, modified_z, z_min_transform.w);
    // Adapt RenderSetup's OpenGL clip space at the Vulkan shader boundary.
    output.fragment_p.y *= -1;
    output.fragment_p.z = 0.5 * (output.fragment_p.z + output.fragment_p.w);
    
    output.uv = v2(vertex.uv & 0xffffu, vertex.uv >> 16u) / 65535.0f;
    output.color = rgba_to_v4(vertex.color);
    
    output.fog_distance = dot(z_vertex.xyz - root.camera_p, root.fog_direction);
    
    output.world_p = z_vertex.xyz;
    
    v3 normal = v3(iv3(i32(vertex.n << 22u) >> 22, i32(vertex.n << 12u) >> 22, i32(vertex.n << 2u) >> 22));
    output.world_n = v3(normal) / 511.0f;
    
    output.texture = root.textures[quad_index];
    
    
    
    return output;
}


struct FragmentOutput {
    v4 surface_reflect : SV_Target0;
};

[shader("fragment")]
FragmentOutput fragmentMain(VertexOutput input) : SV_Target0 {
    SamplerState  sampler = SamplerDescriptorHeap[u32(Sampler.Linear)];
    Texture2D<v4> texture = ResourceDescriptorHeap[input.texture];
    
    if (root.previous_depth != 0) {
        Texture2D<f32> previous_depth = ResourceDescriptorHeap[root.previous_depth];
        
        f32 clip_depth = previous_depth.Load(iv3(iv2(input.fragment_p.xy), 0));
        if (input.fragment_p.z <= clip_depth) {
            discard;
        }
    }
    
    f32 fog_amount   = clamp_01_map_to_range(root.fog_begin,        root.fog_end,        input.fog_distance);
    f32 alpha_amount = clamp_01_map_to_range(root.clip_alpha_begin, root.clip_alpha_end, input.fog_distance);
    
    v4 texture_sample = texture.Sample(sampler, input.uv);
    v4 modulated = input.color * texture_sample;
    modulated *= alpha_amount;
    
    if (modulated.a < root.alpha_threshold) {
        discard;
    }
    
    v4 surface_reflect  = 0;
    surface_reflect.rgb = lerp(modulated.rgb, root.fog_color, fog_amount);
    surface_reflect.a   = modulated.a;
    
    
    if (root.lighting_lookup != nullptr) {
        v3 average_light = v3(0,0,0);
        
        v3 voxel_p = root.inverse_voxel_dimension * (input.world_p - root.voxel_min_corner) - v3(0.5, 0.5, 0.5);
        v3 voxel_floor    = floor(voxel_p);
        v3 voxel_fraction = voxel_p - voxel_floor;
        iv3 voxel_index = iv3(voxel_floor);
        
        v3 l000 = sum_voxel_light(input, voxel_index);
        v3 l001 = sum_voxel_light(input, voxel_index + iv3( 0, 0, 1));
        v3 l010 = sum_voxel_light(input, voxel_index + iv3( 0, 1, 0));
        v3 l011 = sum_voxel_light(input, voxel_index + iv3( 0, 1, 1));
        v3 l100 = sum_voxel_light(input, voxel_index + iv3( 1, 0, 0));
        v3 l101 = sum_voxel_light(input, voxel_index + iv3( 1, 0, 1));
        v3 l110 = sum_voxel_light(input, voxel_index + iv3( 1, 1, 0));
        v3 l111 = sum_voxel_light(input, voxel_index + iv3( 1, 1, 1));
        v3  l00 = lerp(l000, l001, voxel_fraction.z);
        v3  l01 = lerp(l010, l011, voxel_fraction.z);
        v3  l10 = lerp(l100, l101, voxel_fraction.z);
        v3  l11 = lerp(l110, l111, voxel_fraction.z);
        v3   l0 = lerp(l00,  l01,  voxel_fraction.y);
        v3   l1 = lerp(l10,  l11,  voxel_fraction.y);
        v3    l = lerp(l0,   l1,   voxel_fraction.x);
        
        surface_reflect.rgb *= l;
    }
    
    FragmentOutput output;
    output.surface_reflect = surface_reflect;
    
    return output;
}

v3 sum_voxel_light(VertexOutput input, iv3 voxel_index) {
    i32 vi = voxel_index.x + voxel_index.y * 8 + voxel_index.z * 8 * 8;
    if (vi < 0 || vi > 8 * 8 * 16) return 0;
    
    u16 light_index = root.lighting_lookup[vi];
    if (light_index == 0) return 0;
    
    v4 result = 0;
    
    while (light_index != 0) {
        LightingTexel *light = &root.lighting_t[light_index];
        v4 light_c = rgba_to_v4(light.c);
        
        v3 light_p  = light.p;
        v3 light_d  = light.d.xyz;
        light_index = u16(light.next);
        
        v3 delta = light_p - input.world_p;
        f32 contribution = clamp01(1 - 0.5 * length(delta));
        // contribution *= clamp01(dot(light_d, input.world_n));
        
        result.rgb += contribution * light_c.rgb;
        result.a   += contribution;
    }
    
    if (result.a > 1) {
        result.rgb *= 1 / result.a;
    }
    
    return result.rgb;
}