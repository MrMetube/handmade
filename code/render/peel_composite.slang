#include "shared.slang"

struct CompositeRoot {
    u32 textures[4];
    u32 peel_count;
};

[[vk::binding(0, 0)]] ConstantBuffer<CompositeRoot> root;

struct VertexOutput {
    v4 position : SV_Position;
    v2 uv       : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(u32 vertex_id : SV_VertexID) {
    v2 positions[3] = { v2(-1, -1), v2(3, -1), v2(-1, 3) };
    v2 uvs[3]       = { v2( 0,  0), v2(2,  0), v2( 0, 2) };
    
    VertexOutput output;
    output.position = v4(positions[vertex_id], 0, 1);
    output.uv = uvs[vertex_id];
    return output;
}

[shader("fragment")]
v4 fragmentMain(VertexOutput input) : SV_Target0 {
    SamplerState  sampler = SamplerDescriptorHeap[u32(Sampler.Nearest)];
    Texture2D<v4> texture = ResourceDescriptorHeap[root.textures[root.peel_count - 1]];
    v4 result = texture.Sample(sampler, input.uv);
    
    for (int peel_index = int(root.peel_count) - 2; peel_index >= 0; --peel_index) {
        texture = ResourceDescriptorHeap[root.textures[peel_index]];
        v4 peel = texture.Sample(sampler, input.uv);
        
        result.rgb = peel.rgb + (1.0f - peel.a) * result.rgb;
    }
    
    return result;
}
