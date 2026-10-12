#include "shared.slang"

struct Root {
    u32 front_emission;
    u32 back_emission;
    u32 surface_color;
    u32 normal_xy_depth;
};

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

struct VertexOutput {
    v4 position : SV_Position;
    v2 uv       : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(u32 vertex_id : SV_VertexID) {
    VertexOutput result;
    result.position = fullscreen_positions[vertex_id];
    result.uv       = fullscreen_uvs[vertex_id]; 
    return result;
}

struct FragmentOutput {
    v3 front_emission  : SV_Target0;
    v3 back_emission   : SV_Target1;
    v3 surface_color   : SV_Target2;
    v3 normal_xy_depth : SV_Target3;
};

[shader("fragment")]
FragmentOutput fragmentMain(VertexOutput input) {
    SamplerState sampler = SamplerDescriptorHeap[u32(Sampler.Linear)];
    
    Texture2D<v4> front_emission_texture  = ResourceDescriptorHeap[root.front_emission];
    Texture2D<v4> back_emission_texture   = ResourceDescriptorHeap[root.back_emission];
    Texture2D<v4> surface_color_texture   = ResourceDescriptorHeap[root.surface_color];
    Texture2D<v4> normal_xy_depth_texture = ResourceDescriptorHeap[root.normal_xy_depth];
    
    v3 source_front_emission  = manual_sample(front_emission_texture,  sampler, input.uv);
    v3 source_back_emission   = manual_sample(back_emission_texture,   sampler, input.uv);
    v3 source_surface_color   = manual_sample(surface_color_texture,   sampler, input.uv);
    v3 source_normal_xy_depth = manual_sample(normal_xy_depth_texture, sampler, input.uv);
    
    FragmentOutput output;
    
    output.front_emission  = source_front_emission;
    output.back_emission   = source_back_emission;
    output.surface_color   = source_surface_color;
    output.normal_xy_depth = source_normal_xy_depth;
    
    return output;
}

v3 manual_sample(Texture2D<v4> texture, SamplerState sampler, v2 uv) {
    v3 result = texture.Sample(sampler, uv).rgb;
    return result;
}