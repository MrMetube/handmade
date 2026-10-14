#include "shared.slang"

struct TexturedVertex {
    v4  p;
    u32 n;
    u32 uv;
    u32 color;
    f32 emission;
};

struct Root {
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
    u32             previous_depth;
    f32             alpha_threshold;
    
    u32 __padding;
};

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

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


struct FragmentOutput {
    v4 surface_reflect : SV_Target0;
    v4 emission        : SV_Target1;
    v4 normal          : SV_Target2;
};


[shader("fragment")]
FragmentOutput fragmentMain(VertexOutput input) : SV_Target0 {
    Texture2D<v4> texture = ResourceDescriptorHeap[input.texture];
    SamplerState  sampler = SamplerDescriptorHeap[u32(Sampler.Linear)];
    
    if (root.previous_depth != 0) {
        Texture2D<f32> previous_depth = ResourceDescriptorHeap[root.previous_depth];
        
        f32 clip_depth = previous_depth.Load(int3(int2(input.fragment_p.xy), 0));
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
    
    FragmentOutput output;
    v4 surface_reflect  = 0;
    surface_reflect.rgb = lerp(modulated.rgb, root.fog_color, fog_amount);
    surface_reflect.a   = modulated.a;
    
    v3 world_n = normalize(input.world_n);
    v2 n       = pack_normal2(world_n.xy);
    
    v3 emission = v3(0);
    if (length(root.light_p - input.world_p) < 3) {
        emission = v3(1, 1, 1);
    }
    // @todo Some way of specifying the emission spread.
    f32 emission_spread = 1.0;
    
    output.surface_reflect = surface_reflect;
    output.emission        = v4(emission, emission_spread);
    output.normal          = v4(n, 0, 0);
    
    return output;
}
