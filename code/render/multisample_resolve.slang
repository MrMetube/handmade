#include "shared.slang"

struct Root {
    u32 peel_index;
    u32 sample_count;
};

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

struct VertexOutput {
    v4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(u32 vertex_id : SV_VertexID) {
    VertexOutput result;
    result.position = fullscreen_positions[vertex_id];
    return result;
}

struct FragmentOutput {
    v4  reflect   : SV_Target0;
    v4  emission  : SV_Target1;
    v4  normal_lp : SV_Target2;
    f32 depth     : SV_Depth;
};

[shader("fragment")]
FragmentOutput fragmentMain(VertexOutput input) {
    Texture2DMS<v4>  reflect   = get_peel_color_buffer(root.peel_index, depth_peel.surface_reflect);
    Texture2DMS<v4>  emission  = get_peel_color_buffer(root.peel_index, depth_peel.emission);
    Texture2DMS<v4>  normal_lp = get_peel_color_buffer(root.peel_index, depth_peel.normal_lp);
    Texture2DMS<f32> depth     = get_peel_depth_buffer(root.peel_index);
    
    int2 pixel = int2(input.position.xy);
    
    f32 depth_min = 1;
    f32 depth_max = 0;
    for (u32 sample_index = 0; sample_index < root.sample_count; ++sample_index) {
        f32 sample_depth = depth.Load(pixel, sample_index);
        depth_min = min(depth_min, sample_depth);
        depth_max = max(depth_max, sample_depth);
    }
    
    v4 combined_reflect   = 0;
    v4 combined_emission  = 0;
    v4 combined_normal_lp = 0;
    
    for (u32 sample_index = 0; sample_index < root.sample_count; ++sample_index) {
        combined_reflect   += reflect.Load(pixel,   sample_index);
        combined_emission  += emission.Load(pixel,  sample_index);
        combined_normal_lp += normal_lp.Load(pixel, sample_index);
    }
    
    FragmentOutput result;
    result.depth = 0.5f * (depth_min + depth_max);
    
    f32 inv_sample_count = 1.0 / root.sample_count;
    result.reflect   = combined_reflect   * inv_sample_count;
    result.emission  = combined_emission  * inv_sample_count;
    result.normal_lp = combined_normal_lp * inv_sample_count;
    
    return result;
}