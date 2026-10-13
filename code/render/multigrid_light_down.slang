#include "shared.slang"

struct Root {
    u32 parent_index;
    u32 our_index;
};

struct LightValue {
    v3 front_emission;
    v3 back_emission;
    v3 surface_color;
    v3 n;
    v3 p;
}

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

struct VertexOutput {
    v4 position : SV_Position;
    v2 uv       : TEXCOORD0;
};

// @copypasta multiple times a simple fullscreen rectangle
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
};

[shader("fragment")]
FragmentOutput fragmentMain(VertexOutput input) {
    v2 uv_step;
    {
        // @note All textures are of the same size
        u32 width, height;
        get_light_buffer(root.parent_index, light_buffer.front_emission).GetDimensions(width, height);
        uv_step = 1.0 / v2(width, height);
    }
    
    SamplerState sampler = SamplerDescriptorHeap[u32(Sampler.Linear)];
    
    LightValue left  = parent_sample(sampler, input.uv + v2(-uv_step.x,  0)); 
    LightValue right = parent_sample(sampler, input.uv + v2(+uv_step.x,  0)); 
    LightValue up    = parent_sample(sampler, input.uv + v2( 0, -uv_step.y)); 
    LightValue down  = parent_sample(sampler, input.uv + v2( 0, +uv_step.y)); 
    
    v3 ref_color           = get_light_buffer(root.our_index, light_buffer.surface_color).Sample(sampler,   input.uv).rgb;
    v3 our_normal_xy_depth = get_light_buffer(root.our_index, light_buffer.normal_xy_depth).Sample(sampler, input.uv).rgb;
    
    v3 ref_n = reconstruct_normal(our_normal_xy_depth);
    v3 ref_p = reconstruct_position(our_normal_xy_depth, input.uv);
    
    FragmentOutput output;
    output.front_emission = (
        transfer_light(left.p,  left.n,  left.front_emission,  ref_p, ref_n, ref_color) +
        transfer_light(right.p, right.n, right.front_emission, ref_p, ref_n, ref_color) +
        transfer_light(up.p,    up.n,    up.front_emission,    ref_p, ref_n, ref_color) +
        transfer_light(down.p,  down.n,  down.front_emission,  ref_p, ref_n, ref_color)
    );
    output.back_emission = (
        transfer_light(left.p,  left.n,  left.back_emission,  ref_p, ref_n, ref_color) +
        transfer_light(right.p, right.n, right.back_emission, ref_p, ref_n, ref_color) +
        transfer_light(up.p,    up.n,    up.back_emission,    ref_p, ref_n, ref_color) +
        transfer_light(down.p,  down.n,  down.back_emission,  ref_p, ref_n, ref_color)
    );
    
    return output;
}

v3 reconstruct_position(v3 normal_xy_depth, v2 uv) {
   // @todo Calculate the correct world position from the fragment coordinate.
    v3 result = v3(uv.x, uv.y, normal_xy_depth.z);
    return result;
}

v3 reconstruct_normal(v3 normal_xy_depth) {
    v3 result = extend_normal3(normal_xy_depth.xy);
    return result;
}

v3 transfer_light(v3 light_p, v3 light_n, v3 light_emission, v3 ref_p, v3 ref_n, v3 ref_color) {
    f32 facing           = clamp01(-dot(light_n, ref_n));
    f32 distance_squared = length_squared(light_p - ref_p);
    f32 falloff = 1.0 / (1 + 100*distance_squared);
    facing = 1;
    v3 result = facing * falloff * ref_color * light_emission;
    return result;
}

LightValue parent_sample(SamplerState sampler, v2 uv) {
    LightValue result;
    result.front_emission = manual_sample(get_light_buffer(root.parent_index, light_buffer.front_emission),  sampler, uv);
    result.back_emission  = manual_sample(get_light_buffer(root.parent_index, light_buffer.back_emission),   sampler, uv);
    v3 normal_xy_depth    = manual_sample(get_light_buffer(root.parent_index, light_buffer.normal_xy_depth), sampler, uv);
    
    result.n = reconstruct_normal(normal_xy_depth);
    result.p = reconstruct_position(normal_xy_depth, uv);
    
    return result;
}

v3 manual_sample(Texture2D<v4> texture, SamplerState sampler, v2 uv) {
    v3 result = texture.Sample(sampler, uv).rgb;
    return result;
}