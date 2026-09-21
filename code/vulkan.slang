struct TexturedVertex
{
    float4 p;
    float3 n;
    float2 uv;
    uint color;
};

struct QuadRoot
{
    float4x4 projection;
    TexturedVertex* vertices;
    float4 camera_p;
    float4 fog_direction;
    float4 fog_color;
    float4 fog_and_clip;
    uint* texture_descriptors;
    uint vertex_base;
    uint previous_depth_descriptor;
    uint peeling;
    float alpha_threshold;
};

[[vk::push_constant]] ConstantBuffer<QuadRoot> root;

struct VertexOutput
{
    float4 position : SV_Position;
    float2 uv       : TEXCOORD0;
    float4 color    : COLOR0;
    nointerpolation uint texture_descriptor : TEXCOORD1;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertex_id : SV_VertexID)
{
    // The command stream stores quads as triangle strips, but NoGraphicsAPI's
    // current graphics PSO uses triangle lists. Reuse the four stored vertices
    // as the two triangles (0,1,2) and (2,1,3).
    uint quad_vertex_indices[6] = { 0u, 1u, 2u, 2u, 1u, 3u };
    uint quad_index = vertex_id / 6u;
    uint quad_vertex_index = quad_vertex_indices[vertex_id % 6u];
    TexturedVertex vertex = root.vertices[root.vertex_base + quad_index * 4u + quad_vertex_index];

    VertexOutput output;
    // Match the OpenGL Z-bias vertex path. p.w is not a homogeneous coordinate;
    // it is the per-vertex depth bias used to keep Handmade's render slices apart.
    float4 vertex_position = float4(vertex.p.xyz, 1.0f);
    float4 biased_position = vertex_position;
    biased_position.z += vertex.p.w;

    float4 minimum_depth_position = mul(root.projection, vertex_position);
    float4 maximum_depth_position = mul(root.projection, biased_position);
    float modified_depth = (minimum_depth_position.w / maximum_depth_position.w) * maximum_depth_position.z;

    output.position = float4(minimum_depth_position.xy, modified_depth, minimum_depth_position.w);
    // RenderSetup was written for OpenGL clip space. Keep it unchanged while
    // this backend is brought up, and adapt only at the Vulkan shader boundary.
    output.position.y = -output.position.y;
    output.position.z = 0.5f * (output.position.z + output.position.w);
    output.uv = vertex.uv;
    output.texture_descriptor = root.texture_descriptors[quad_index];
    output.color = float4(
        (vertex.color >>  0u) & 0xffu,
        (vertex.color >>  8u) & 0xffu,
        (vertex.color >> 16u) & 0xffu,
        (vertex.color >> 24u) & 0xffu) / 255.0f;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target0
{
    Texture2D<float4> texture = ResourceDescriptorHeap[input.texture_descriptor];
    SamplerState sampler = SamplerDescriptorHeap[0];
    float4 modulated = input.color * texture.Sample(sampler, input.uv);

    if (root.peeling != 0)
    {
        Texture2D<float> previous_depth = ResourceDescriptorHeap[root.previous_depth_descriptor];
        if (input.position.z <= previous_depth.Load(int3(input.position.xy, 0)))
            discard;
    }

    if (modulated.a <= root.alpha_threshold)
        discard;

    return modulated;
}
