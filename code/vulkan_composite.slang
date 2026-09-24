struct CompositeRoot {
    uint texture_descriptors[4];
    uint peel_count;
};

[[vk::push_constant]] ConstantBuffer<CompositeRoot> root;

struct VertexOutput {
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertex_id : SV_VertexID) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    float2 uvs[3]       = { float2( 0,  0), float2(2,  0), float2( 0, 2) };

    VertexOutput output;
    output.position = float4(positions[vertex_id], 0, 1);
    output.uv = uvs[vertex_id];
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0 {
    SamplerState      sampler = SamplerDescriptorHeap[0];
    Texture2D<float4> texture = ResourceDescriptorHeap[root.texture_descriptors[root.peel_count - 1]];
    float4 result = texture.Sample(sampler, input.uv);

    for (int peel_index = int(root.peel_count) - 2; peel_index >= 0; --peel_index) {
        texture = ResourceDescriptorHeap[root.texture_descriptors[peel_index]];
        float4 peel = texture.Sample(sampler, input.uv);
        result.rgb = peel.rgb + (1.0f - peel.a) * result.rgb;
    }

    return result;
}
