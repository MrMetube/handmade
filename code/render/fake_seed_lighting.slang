#include "shared.slang"

struct Root {
    v3 light_p;
};

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

struct VertexOutput {
    v4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertex_id : SV_VertexID) {
    const v2 positions[4] = { v2(-1, -1), v2(1, -1), v2(-1, 1), v2(1, 1) };
    const uint indices[6] = { 0, 1, 3, 0, 3, 2 };
    
    VertexOutput result;
    result.position = v4(positions[indices[vertex_id]], 0, 1);
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
    
    v3 front_emission      = v3(0, 0, 0);
    v3 back_emission       = v3(0, 0, 0);
    v3 surface_color       = v3(0.7, 0.7, 0.7);
    v3 normal_xz_and_depth = v3(0, 1, 10);
    
    f32 artificial_range = 10.0;
    v2 this_p = input.position.xy;
    v2 light_p = root.light_p.xy * 0.025 * v2(1920, 1080) + 0.25*v2(1920, 1080);
    
    v2 delta_to_light     = this_p - light_p;
    f32 distance_to_light = length(delta_to_light);
    f32 light_radius      = 10;
    
    if (distance_to_light < light_radius) {
        front_emission      = v3(1, 0, 0);
        back_emission       = v3(0, 1, 0);
        surface_color       = v3(0, 0, 0);
        normal_xz_and_depth = v3(1, 0, 0);
    }
    
    FragmentOutput output;
    
    output.front_emission      = front_emission;
    output.back_emission       = back_emission;
    output.surface_color       = surface_color;
    output.normal_xz_and_depth = normal_xz_and_depth;
    
    return output;
}