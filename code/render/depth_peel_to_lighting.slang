#include "shared.slang"

struct Root {
    u32 source_resolve_buffer;
};

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

struct VertexOutput {
    v4 position : SV_Position;
    v2 uv       : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(u32 vertex_id : SV_VertexID) {
    VertexOutput result;
    result.position = fullscreen_positions[vertex_id];
    result.uv       = fullscreen_uvs[vertex_id];
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
    SamplerState sampler = SamplerDescriptorHeap[Sampler.Linear];
    
    Texture2DMS<f32> depth_texture           = get_resolve_depth_buffer(root.source_resolve_buffer);
    Texture2DMS<v4>  surface_reflect_texture = get_resolve_color_buffer(root.source_resolve_buffer, depth_peel.surface_reflect);
    Texture2DMS<v4>  emission_texture        = get_resolve_color_buffer(root.source_resolve_buffer, depth_peel.emission);
    Texture2DMS<v4>  normal_lp_texture       = get_resolve_color_buffer(root.source_resolve_buffer, depth_peel.normal_lp);

    u32 width, height, sample_count;
    depth_texture.GetDimensions(width, height, sample_count);
    
    // @todo better sampling
    int2 texel = clamp(int2(input.uv * v2(width, height)), 0, int2(width, height)-1);
    
    f32 depth           =           depth_texture.Load(texel, 0);
    v4  surface_reflect = surface_reflect_texture.Load(texel, 0);
    v4  emission        =        emission_texture.Load(texel, 0);
    v4  normal_lp       =       normal_lp_texture.Load(texel, 0);
    
    v3  surface_reflect_rgb = surface_reflect.rgb;
    f32 coverage            = surface_reflect.a;
    
    v3  emission_rgb    = emission.rgb;
    f32 emission_spread = emission.a; // @todo Use this to seed back emitters?
    
    v2  n   = unpack_normal2(normal_lp.xy);
    f32 lp0 = normal_lp.z;
    f32 lp1 = normal_lp.w;
    
    FragmentOutput result;
    result.front_emission = max_light_intensity * emission_rgb;
    result.back_emission  = v3(0);
    result.surface_color  = surface_reflect_rgb;
    result.normal_depth   = v3(n, depth);
    
    return result;
}