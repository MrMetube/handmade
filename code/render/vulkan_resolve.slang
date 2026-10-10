struct Root {
    uint color_descriptor;
    uint depth_descriptor;
    uint sample_count;
};

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

struct VertexOutput {
    float4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertex_id : SV_VertexID) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };

    VertexOutput result;
    result.position = float4(positions[vertex_id], 0, 1);
    return result;
}

struct FragmentOutput {
    float4 color : SV_Target0;
    float  depth : SV_Depth;
};

[shader("fragment")]
FragmentOutput fragmentMain(VertexOutput input) {
    Texture2DMS<float4> color = ResourceDescriptorHeap[root.color_descriptor];
    Texture2DMS<float>  depth = ResourceDescriptorHeap[root.depth_descriptor];
    int2 pixel = int2(input.position.xy);

    float4 combined_color = 0;
    // Match the OpenGL resolve's zero-initialized depth minimum.
    float depth_min = 0;
    float depth_max = 0;
    for (uint sample_index = 0; sample_index < root.sample_count; ++sample_index) {
        float sample_depth = depth.Load(pixel, sample_index);
        depth_min = min(depth_min, sample_depth);
        depth_max = max(depth_max, sample_depth);
        combined_color += color.Load(pixel, sample_index);
    }

    FragmentOutput result;
    result.color = combined_color / root.sample_count;
    result.depth = 0.5f * (depth_min + depth_max);
    return result;
}
