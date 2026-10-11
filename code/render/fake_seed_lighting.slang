#include "shared.slang"

struct Root {
    v3 light_p;
};

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

struct VertexOutput {
    v4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(u32 vertex_id : SV_VertexID) {
    const v2  positions[4] = { v2(-1, -1), v2(1, -1), v2(-1, 1), v2(1, 1) };
    const u32 indices[6]   = { 0, 1, 3, 0, 3, 2 };
    
    VertexOutput result;
    result.position = v4(positions[indices[vertex_id]], 0, 1);
    return result;
}

struct FragmentOutput {
    v3 front_emission      : SV_Target0;
    v3 back_emission       : SV_Target1;
    v3 surface_color       : SV_Target2;
    v3 normal_xy_and_depth : SV_Target3;
};

[shader("fragment")]
FragmentOutput fragmentMain(VertexOutput input) {
    v3 front_emission      = v3(0, 0, 0);
    v3 back_emission       = v3(0, 0, 0);
    v3 surface_color       = v3(0.7, 0.7, 0.7);
    v3 normal_xy_and_depth = v3(0, 1, -10);
    
    f32 artificial_range = 10.0;
    v2 this_p = input.position.xy;
    
    light(this_p, root.light_p.xy,             25, v3(100,  0, 0), v3(0, 100,  0), v3(1, 0, 0), front_emission, back_emission, surface_color, normal_xy_and_depth);
    light(this_p, root.light_p.xy + v2(.5, 0), 25, v3(  0, 10, 0), v3(0,   0, 10), v3(0, 1, 1), front_emission, back_emission, surface_color, normal_xy_and_depth);
    
    FragmentOutput output;
    
    output.front_emission      = front_emission;
    output.back_emission       = back_emission;
    output.surface_color       = surface_color;
    output.normal_xy_and_depth = normal_xy_and_depth;
    
    return output;
}

void light(v2 this_p, v2 light_p, f32 light_radius, v3 light_front_emission, v3 light_back_emission, v3 light_normal_xy_depth, inout v3 front_emission, inout v3 back_emission, inout v3 surface_color, inout v3 normal_xy_depth) {
    v2 light_p = light_p * 0.025 * v2(1920, 1080) + 0.25*v2(1920, 1080);
    
    v2  delta_to_light    = this_p - light_p;
    f32 distance_to_light = length(delta_to_light);
    
    if (distance_to_light < light_radius) {
        front_emission  = light_front_emission;
        back_emission   = light_back_emission;
        surface_color   = v3(0, 0, 0);
        normal_xy_depth = light_normal_xy_depth;
    }
}