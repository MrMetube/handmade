#include "shared.slang"

struct FinalRoot {
    u32 texture;
    u32 sampler;
};

[[vk::binding(0, 0)]] ConstantBuffer<FinalRoot> root;

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

[shader("fragment")]
v4 fragmentMain(VertexOutput input) : SV_Target0 {
    Texture2D<v4> texture = ResourceDescriptorHeap[root.texture];
    SamplerState  sampler = SamplerDescriptorHeap[ root.sampler];
    
    v4 result = texture.Sample(sampler, input.uv);
    return result;
}
