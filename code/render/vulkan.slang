#include "vulkan_shared.slang"

struct TexturedVertex {
    float4 p;
    uint   n;
    uint   uv;
    uint   color;
};

struct QuadRoot {
    float4x4        projection;
    TexturedVertex* vertices;
    uint*           texture_descriptors;
    float3          camera_p;
    float3          light_p;
    float3          fog_direction;
    float3          fog_color;
    float           fog_begin;
    float           fog_end;
    float           clip_alpha_begin;
    float           clip_alpha_end;
    uint            vertex_base;
    uint            previous_depth_descriptor;
    float           alpha_threshold;
    
    uint __padding;
};

[[vk::binding(0, 0)]] ConstantBuffer<QuadRoot> root;

struct VertexOutput {
    float4 fragment_p : SV_Position;
    float3 world_p;
    float3 world_n;
    float2 uv         : TEXCOORD0;
    float4 color      : COLOR0;
    nointerpolation uint texture_descriptor;
    float fog_distance;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertex_id : SV_VertexID) {
    // The command stream stores quads as triangle strips, but NoGraphicsAPI's
    // current graphics PSO uses triangle lists. Flip the two triangles to
    // match the Vulkan rasterizer winding after the Y coordinate conversion.
    uint quad_vertex_indices[6] = { 0u, 2u, 1u, 2u, 3u, 1u };
    uint quad_index = vertex_id / 6u;
    uint quad_vertex_index = quad_vertex_indices[vertex_id % 6u];
    TexturedVertex vertex = root.vertices[root.vertex_base + quad_index * 4u + quad_vertex_index];
    
    float4 in_vertex = float4(vertex.p.xyz, 1.0f);
    float z_bias = vertex.p.z;
    
    float4 z_vertex = in_vertex;
    z_vertex.z += z_bias;
    
    float4 z_min_transform = mul(root.projection, in_vertex);
    float4 z_max_transform = mul(root.projection, z_vertex);
    
    float modified_z = (z_min_transform.w / z_max_transform.w) * z_max_transform.z;
    
    VertexOutput output;
    output.fragment_p = float4(z_min_transform.xy, modified_z, z_min_transform.w);
    // Adapt RenderSetup's OpenGL clip space at the Vulkan shader boundary.
    output.fragment_p.y *= -1;
    output.fragment_p.z = 0.5 * (output.fragment_p.z + output.fragment_p.w);
    
    output.uv = float2(vertex.uv & 0xffffu, vertex.uv >> 16u) / 65535.0f;
    output.color = float4(
        (vertex.color >>  0u) & 0xffu,
        (vertex.color >>  8u) & 0xffu,
        (vertex.color >> 16u) & 0xffu,
        (vertex.color >> 24u) & 0xffu) / 255.0f;
    
    output.fog_distance = dot(z_vertex.xyz - root.camera_p, root.fog_direction);
    
    output.world_p = z_vertex.xyz;
    
    float3 normal = float3(int3(int(vertex.n << 22u) >> 22, int(vertex.n << 12u) >> 22, int(vertex.n << 2u) >> 22));
    output.world_n = float3(normal) / 511.0f;
    
    output.texture_descriptor = root.texture_descriptors[quad_index];
    
    return output;
    ////////////////////////////////////////////////
    /*
    
    VertexOutput output;
    output.world_p = float4(minimum_depth_position.xy, modified_depth, minimum_depth_position.w);
    // Adapt RenderSetup's OpenGL clip space at the Vulkan shader boundary.
    output.world_p.y = -output.world_p.y;
    output.world_p.z = 0.5f * (output.world_p.z + output.world_p.w);
    
    
    output.fog_distance = dot(biased_position.xyz - root.camera_p, root.fog_direction);
    output.texture_descriptor = root.texture_descriptors[quad_index];
    
    
    return output;
    */
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    Texture2D<float4> texture = ResourceDescriptorHeap[input.texture_descriptor];
    SamplerState      sampler = SamplerDescriptorHeap[uint(Sampler.Linear)];
    
    if (root.previous_depth_descriptor != 0) {
        Texture2D<float4> previous_depth = ResourceDescriptorHeap[root.previous_depth_descriptor];
        
        float frag_z = input.fragment_p.z;
        float clip_depth = previous_depth.Load(int3(int2(input.fragment_p.xy), 0)).r;
        
        if (frag_z <= clip_depth) {
            discard;
        }
    }
    
    float fog_amount   = clamp_01_map_to_range(root.fog_begin,        root.fog_end,        input.fog_distance);
    float alpha_amount = clamp_01_map_to_range(root.clip_alpha_begin, root.clip_alpha_end, input.fog_distance);
    
    float4 texture_sample = texture.Sample(sampler, input.uv);
    float4 modulated = input.color * texture_sample;
    modulated *= alpha_amount;
    
    const bool LIGHTING = true;
    
    float4 result_color = 0;
    if (modulated.a > root.alpha_threshold) {
        float3 to_camera      = root.camera_p - input.world_p.xyz;
        float camera_distance = length(root.camera_p);
        to_camera *= 1.0/camera_distance;
        
        float3 light_total = float3(1.0,1.0,1.0);
        if (LIGHTING) {
            float3 light_strength = float3(6.0,1.0,4.0);
            float3 to_light      = root.light_p - input.world_p.xyz;
            float light_distance = length(root.light_p);
            to_light *= 1/light_distance;
            
            float3 cos_light_angle = float3(
                dot(to_light, input.world_n),
                dot(to_light, input.world_n),
                dot(to_light, input.world_n), // ?
            );
            cos_light_angle = clamp(cos_light_angle, 0., 1.);
            
            float3 reflected_d = -to_camera + 2 * dot(input.world_n, to_camera) * input.world_n;
            float3 cos_reflected = float3(
                dot(to_light, reflected_d),
                dot(to_light, reflected_d),
                dot(to_light, reflected_d),
            );
            cos_reflected = clamp(cos_reflected, 0., 1.);
            
            cos_reflected *= cos_reflected;
            cos_reflected *= cos_reflected;
            cos_reflected *= cos_reflected;
            cos_reflected *= cos_reflected;
            cos_reflected *= cos_reflected;
            
            float3 light_amount = light_strength / square(light_distance);
            
            float diffuse_c = 0.5f;
            float3 diffuse_light = diffuse_c * cos_light_angle * light_amount;
            
            float spec_c = 2.0f;
            float3 spec_light = spec_c * cos_reflected * light_amount;
            
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