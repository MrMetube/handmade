#include "shared.slang"

struct Root {
    u32 color;
    u32 depth;
    u32 sample_count;
};

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

struct VertexOutput {
    v4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(u32 vertex_id : SV_VertexID) {
    v2 positions[3] = { v2(-1, -1), v2(3, -1), v2(-1, 3) };

    VertexOutput result;
    result.position = v4(positions[vertex_id], 0, 1);
    return result;
}

struct FragmentOutput {
    v4  color : SV_Target0;
    f32 depth : SV_Depth;
};

[shader("fragment")]
FragmentOutput fragmentMain(VertexOutput input) {
    Texture2DMS<v4>  color = ResourceDescriptorHeap[root.color];
    Texture2DMS<f32> depth = ResourceDescriptorHeap[root.depth];
    int2 pixel = int2(input.position.xy);
    
    v4 combined_color = 0;
    // Match the OpenGL resolve's zero-initialized depth minimum.
    f32 depth_min = 0;
    f32 depth_max = 0;
    for (u32 sample_index = 0; sample_index < root.sample_count; ++sample_index) {
        f32 sample_depth = depth.Load(pixel, sample_index);
        depth_min = min(depth_min, sample_depth);
        depth_max = max(depth_max, sample_depth);
        combined_color += color.Load(pixel, sample_index);
    }
    
    FragmentOutput result;
    result.color = combined_color / root.sample_count;
    result.depth = 0.5f * (depth_min + depth_max);
    return result;
}
