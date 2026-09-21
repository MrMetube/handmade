struct CompositeRoot
{
    uint texture_descriptor;
};

[[vk::push_constant]] ConstantBuffer<CompositeRoot> root;

struct VertexOutput
{
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertex_id : SV_VertexID)
{
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    float2 uvs[3]       = { float2( 0,  0), float2(2,  0), float2( 0, 2) };

    VertexOutput output;
    output.position = float4(positions[vertex_id], 0, 1);
    output.uv = uvs[vertex_id];
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0
{
    Texture2D<float4> texture = ResourceDescriptorHeap[root.texture_descriptor];
    SamplerState sampler = SamplerDescriptorHeap[0];
    return texture.Sample(sampler, input.uv);
}
