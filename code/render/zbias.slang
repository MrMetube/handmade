#include "shared.slang"

struct TexturedVertex {
    v4  p;
    u32 n;
    u32 uv;
    u32 color;
};

struct QuadRoot {
    float4x4        projection;
    TexturedVertex* vertices;
    u32*            textures;
    v3              camera_p;
    v3              light_p;
    v3              fog_direction;
    v3              fog_color;
    f32             fog_begin;
    f32             fog_end;
    f32             clip_alpha_begin;
    f32             clip_alpha_end;
    u32             vertex_base;
    u32             previous_depth_descriptor;
    f32             alpha_threshold;
    
    u32 __padding;
};

[[vk::binding(0, 0)]] ConstantBuffer<QuadRoot> root;

struct VertexOutput {
    v4  fragment_p : SV_Position;
    v3  world_p;
    v3  world_n;
    v2  uv         : TEXCOORD0;
    v4  color      : COLOR0;
    f32 fog_distance;
    nointerpolation u32 texture;
};

[shader("vertex")]
VertexOutput vertexMain(u32 vertex_id : SV_VertexID) {
    // The command stream stores quads as triangle strips, but NoGraphicsAPI's
    // current graphics PSO uses triangle lists. Flip the two triangles to
    // match the Vulkan rasterizer winding after the Y coordinate conversion.
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
    output.color = v4(
        (vertex.color >>  0u) & 0xffu,
        (vertex.color >>  8u) & 0xffu,
        (vertex.color >> 16u) & 0xffu,
        (vertex.color >> 24u) & 0xffu) / 255.0f;
    
    output.fog_distance = dot(z_vertex.xyz - root.camera_p, root.fog_direction);
    
    output.world_p = z_vertex.xyz;
    
    v3 normal = v3(int3(int(vertex.n << 22u) >> 22, int(vertex.n << 12u) >> 22, int(vertex.n << 2u) >> 22));
    output.world_n = v3(normal) / 511.0f;
    
    output.texture = root.textures[quad_index];
    
    return output;
}

[shader("fragment")]
v4 fragmentMain(VertexOutput input) : SV_Target0 {
    Texture2D<v4> texture = ResourceDescriptorHeap[input.texture];
    SamplerState  sampler = SamplerDescriptorHeap[u32(Sampler.Linear)];
    
    if (root.previous_depth_descriptor != 0) {
        Texture2D<f32> previous_depth = ResourceDescriptorHeap[root.previous_depth_descriptor];
        
        f32 frag_z = input.fragment_p.z;
        f32 clip_depth = previous_depth.Load(int3(int2(input.fragment_p.xy), 0));
        
        if (frag_z <= clip_depth) {
            discard;
        }
    }
    
    f32 fog_amount   = clamp_01_map_to_range(root.fog_begin,        root.fog_end,        input.fog_distance);
    f32 alpha_amount = clamp_01_map_to_range(root.clip_alpha_begin, root.clip_alpha_end, input.fog_distance);
    
    v4 texture_sample = texture.Sample(sampler, input.uv);
    v4 modulated = input.color * texture_sample;
    modulated *= alpha_amount;
    
    const bool LIGHTING = true;
    
    v4 result_color = 0;
    if (modulated.a > root.alpha_threshold) {
        v3 to_camera      = root.camera_p - input.world_p.xyz;
        f32 camera_distance = length(root.camera_p);
        to_camera *= 1.0/camera_distance;
        
        v3 light_total = v3(1.0, 1.0, 1.0);
        if (!LIGHTING) {
            v3 light_strength = v3(6.0, 1.0, 4.0);
            v3 to_light       = root.light_p - input.world_p.xyz;
            f32 light_distance  = length(root.light_p);
            to_light *= 1/light_distance;
            
            v3 cos_light_angle = v3(
                dot(to_light, input.world_n),
                dot(to_light, input.world_n),
                dot(to_light, input.world_n), // ?
            );
            cos_light_angle = clamp(cos_light_angle, 0.0, 1.0);
            
            v3 reflected_d = -to_camera + 2 * dot(input.world_n, to_camera) * input.world_n;
            v3 cos_reflected = v3(
                dot(to_light, reflected_d),
                dot(to_light, reflected_d),
                dot(to_light, reflected_d),
            );
            cos_reflected = clamp(cos_reflected, 0.0, 1.0);
            
            cos_reflected *= cos_reflected;
            cos_reflected *= cos_reflected;
            cos_reflected *= cos_reflected;
            cos_reflected *= cos_reflected;
            cos_reflected *= cos_reflected;
            
            v3 light_amount = light_strength / square(light_distance);
            
            f32 diffuse_c    = 0.5f;
            v3 diffuse_light = diffuse_c * cos_light_angle * light_amount;
            
            f32 spec_c    = 2.0f;
            v3 spec_light = spec_c * cos_reflected * light_amount;
            
            light_total = diffuse_light + spec_light;
        }
        
        result_color.rgb = lerp(modulated.rgb, root.fog_color, fog_amount);
        result_color.rgb *= light_total;
        
        result_color.a = modulated.a;
    } else {
        discard;
    }
    
    return result_color;
}