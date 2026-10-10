#include "shared.slang"

struct Root {
    uint front_emission_descriptor;
    uint back_emission_descriptor;
    uint surface_color_descriptor;
    uint normal_xz_and_depth_descriptor;
};

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

struct VertexOutput {
    v4 position : SV_Position;
    v2 uv       : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertex_id : SV_VertexID) {
    const v2 positions[4] = { v2(-1, -1), v2(1, -1), v2(-1, 1), v2(1, 1) };
    const v2 uvs[4]       = { v2( 0,  0), v2(1,  0), v2( 0, 1), v2(1, 1) };
    const uint indices[6] = { 0, 1, 3, 0, 3, 2 };
    
    uint vertex_index = indices[vertex_id];
    
    VertexOutput result;
    result.position = v4(positions[vertex_index], 0, 1);
    result.uv       = uvs[vertex_index]; 
    return result;
}

struct FragmentOutput {
    v3 front_emission      : SV_Target0;
    v3 back_emission       : SV_Target1;
    v3 surface_color       : SV_Target2;
    v3 normal_xz_and_depth : SV_Target3;
};

[shader("fragment")]
FragmentOutput fragmentMain(VertexOutput input) {
    SamplerState sampler = SamplerDescriptorHeap[uint(Sampler.Linear)];
    
    Texture2D<v4> front_emission_texture      = ResourceDescriptorHeap[root.front_emission_descriptor];
    Texture2D<v4> back_emission_texture       = ResourceDescriptorHeap[root.back_emission_descriptor];
    Texture2D<v4> surface_color_texture       = ResourceDescriptorHeap[root.surface_color_descriptor];
    Texture2D<v4> normal_xz_and_depth_texture = ResourceDescriptorHeap[root.normal_xz_and_depth_descriptor];
    
    v3 source_front_emission      = front_emission_texture.Sample(sampler,      input.uv).rgb;
    v3 source_back_emission       = back_emission_texture.Sample(sampler,       input.uv).rgb;
    v3 source_surface_color       = surface_color_texture.Sample(sampler,       input.uv).rgb;
    v3 source_normal_xz_and_depth = normal_xz_and_depth_texture.Sample(sampler, input.uv).rgb;
    
    FragmentOutput output;
    
    output.front_emission      = source_front_emission;
    output.back_emission       = source_back_emission;
    output.surface_color       = source_surface_color;
    output.normal_xz_and_depth = source_normal_xz_and_depth;
    
    return output;
}