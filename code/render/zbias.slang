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
    v3              fog_direction;
    v3              fog_color;
    f32             fog_begin;
    f32             fog_end;
    f32             clip_alpha_begin;
    f32             clip_alpha_end;
    u32             vertex_base;
    u32             previous_depth;
    f32             alpha_threshold;
    
    v3 voxel_min_corner;
    v3 voxel_inverse_cell_dimension;
    
    u32 __padding2[5];
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
    
    Texture1D<v4>  texture_pnext  = ResourceDescriptorHeap[TextureDescriptor.lighting_pnext];
    Texture1D<v4>  texture_c      = ResourceDescriptorHeap[TextureDescriptor.lighting_c];
    Texture3D<u16> texture_lookup = ResourceDescriptorHeap[TextureDescriptor.lighting_lookup];
    
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
    
    v3 voxel_p = root.voxel_inverse_cell_dimension * (input.world_p - root.voxel_min_corner);
    iv3 voxel_index = iv3(floor(voxel_p));
    voxel_index = iv3(190, 154, 3);
    
    u16 light_index = texture_lookup.Load(iv4(voxel_index, 0));
    v3 average_light = v3(0,0,0);
    f32 light_count = 0;
    while (light_index != 0) {
        v4  pnext = texture_pnext.Load(iv2(light_index, 0));
        v4 color  = texture_c.Load(iv2(light_index, 0));
        
        v3 p = pnext.xyz;
        
        average_light += color.rgb;
        light_count   += 1;
        average_light = v3(0, 1, 0);
        
        light_index = u16(pnext.a);
        break;
    }
    if (light_count != 0) {
        average_light *= 1.0 / light_count;
    }
    
    FragmentOutput output;
    v4 surface_reflect  = 0;
    surface_reflect.rgb = lerp(modulated.rgb, root.fog_color, fog_amount);
    surface_reflect.a   = modulated.a;
    
    surface_reflect.rgb *= average_light;
    
    output.surface_reflect = surface_reflect;
    
    return output;
}
