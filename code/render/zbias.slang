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
    
    // @todo Let the fragment stage read these values directly out of the vertices buffer.
    nointerpolation u32 light_index;
    nointerpolation u32 light_count;
};

[shader("mesh")]
[outputtopology("triangle")]
[numthreads(1,1,1)]
void meshMain(out vertices VertexOutput output_vertices[4], out indices uv3 triangles[2], u32 quad_index : SV_GroupID) {
    
    SetMeshOutputCounts(4, 2);
    for (u32 vertex_index = 0; vertex_index < 4; vertex_index += 1) {
        TexturedVertex vertex = root.vertices[root.vertex_base + quad_index * 4 + vertex_index];
        
        v4 in_vertex = v4(vertex.p.xyz, 1.0);
        f32 z_bias = vertex.p.w;
        
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
        
        output.uv = unpack_vertex_uv(vertex.uv);
        output.color = rgba_to_v4(vertex.color);
        
        output.fog_distance = dot(z_vertex.xyz - root.camera_p, root.fog_direction);
        
        output.world_p = z_vertex.xyz;
        
        output.world_n = unpack_vertex_normal(vertex.n);
        
        output.texture = root.textures[quad_index];
        
        output.light_index = vertex.light_index;
        output.light_count = vertex.light_count;
        
        output_vertices[vertex_index] = output;
    }
    
    triangles[0] = {0, 1, 2};
    triangles[1] = {0, 2, 3};
}

v3 unpack_vertex_normal(PackedNormal n) {
    v3 result = v3(iv3(
        i32(n << 22u) >> 22, 
        i32(n << 12u) >> 22, 
        i32(n <<  2u) >> 22)
    );
    result *= 1.0 / 511.0;
    return result;
}

v2 unpack_vertex_uv(PackedUV uv) {
    v2 result = v2(uv & 0xffffu, uv >> 16);
    result *= 1.0 / 65535.0;
    return result;
}

[shader("fragment")]
v4 fragmentMain(VertexOutput input) : SV_Target0 {
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
    
    if (!root.lighting_disabled && root.lighting_lookup != nullptr) {
        v3 average_light = v3(0,0,0);
        
        v3 voxel_p = root.inverse_voxel_dimension * (input.world_p - root.voxel_min_corner) - v3(0.5, 0.5, 0.5);
        v3 voxel_floor    = floor(voxel_p);
        v3 voxel_fraction = voxel_p - voxel_floor;
        iv3 voxel_index = iv3(voxel_floor);
        
        if (input.light_index != 0) {
            v3 l = sum_light(input);
            
            surface_reflect.rgb *= l;
        }
    }
    
    v4 result = surface_reflect;
    return result;
}

// @volatile see rendergroup.odin
static const iv3 lookup_dimension = iv3(32, 32, 32);
static const f32 max_light_power  = 10.0;

v3 sum_light(VertexOutput input) {
    u32 light_index = input.light_index;
    u32 light_count = input.light_count;
    v4 result = 0;
    
    while (light_count > 0) {
        LightingTexel *light = &root.lighting_texels[light_index];
        
        v3 light_p = light.p;
        v3 light_d = light.d;
        v4 light_c = rgba_to_v4(light.c);
        
        v3 delta                = light_p - input.world_p;
        f32 contribution        = 1 / (1 + length_squared(root.inverse_voxel_dimension * delta));
        f32 directional_falloff = clamp01(dot(light_d, input.world_n));
        
        result.rgb += contribution * directional_falloff * light_c.rgb * light_c.a * max_light_power;
        result.a   += contribution;
        
        light_index += 1;
        light_count -= 1;
    }
    
    if (result.a > 0) {
        result.rgb *= 1 / result.a;
    }
    
    return result.rgb;
}