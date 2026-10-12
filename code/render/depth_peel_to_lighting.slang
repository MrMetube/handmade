#include "shared.slang"

static const f32 max_light_power = 10.0;

struct Root {
    u32 source_resolve_buffer;
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
    v3 front_emission : SV_Target0;
    v3 back_emission  : SV_Target1;
    v3 surface_color  : SV_Target2;
    v3 normal_depth   : SV_Target3;
};

[shader("fragment")]
FragmentOutput fragmentMain(VertexOutput input) {
    Texture2DMS<f32> depth_texture           = get_resolve_depth_buffer(root.source_resolve_buffer);
    Texture2DMS<v4>  surface_reflect_texture = get_resolve_color_buffer(root.source_resolve_buffer, depth_peel.surface_reflect);
    Texture2DMS<v4>  emission_texture        = get_resolve_color_buffer(root.source_resolve_buffer, depth_peel.emission);
    Texture2DMS<v4>  normal_lp_texture       = get_resolve_color_buffer(root.source_resolve_buffer, depth_peel.normal_lp);
    
    int2 texel = int2(input.position.xy);
    
    f32 depth = depth_texture.Load(texel, 0);
    
    v4  surface_reflect     = surface_reflect_texture.Load(texel, 0);
    v3  surface_reflect_rgb = surface_reflect.rgb;
    f32 coverage            = surface_reflect.a;
    
    v4  emission        = emission_texture.Load(texel, 0);
    v3  emission_rgb    = emission.rgb;
    f32 emission_spread = emission.a; // @todo Use this to seed back emitters?
    
    v4  normal_lp = normal_lp_texture.Load(texel, 0);
    f32 nx  = -1 + 2.0 * normal_lp.x;
    f32 ny  = -1 + 2.0 * normal_lp.y;
    f32 lp0 = normal_lp.z;
    f32 lp1 = normal_lp.w;
    
    FragmentOutput result;
    result.front_emission = max_light_power * emission_rgb;
    result.back_emission  = v3(0);
    result.surface_color  = surface_reflect_rgb;
    result.normal_depth   = v3(nx, ny, depth);
    
    return result;
}