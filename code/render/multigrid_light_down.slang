#include "shared.slang"

struct Root {
    u32 parent_front_emission;
    u32 parent_back_emission;
    u32 parent_normal_xz_depth;
    
    u32 our_surface_color;
    u32 our_normal_xz_depth;
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
    const v2 positions[4] = { v2(-1, -1), v2(1, -1), v2(-1, 1), v2(1, 1) };
    const v2 uvs[4]       = { v2( 0,  0), v2(1,  0), v2( 0, 1), v2(1, 1) };
    const u32 indices[6] = { 0, 1, 3, 0, 3, 2 };
    
    u32 vertex_index = indices[vertex_id];
    
    VertexOutput result;
    result.position = v4(positions[vertex_index], 0, 1);
    result.uv       = uvs[vertex_index]; 
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
        get_texture(root.parent_front_emission).GetDimensions(width, height);
        uv_step = 1.0 / v2(width, height);
    }
    
    SamplerState sampler = SamplerDescriptorHeap[u32(Sampler.Linear)];
    
    LightValue left  = parent_sample(sampler, input.uv + v2(-uv_step.x,  0)); 
    LightValue right = parent_sample(sampler, input.uv + v2(+uv_step.x,  0)); 
    LightValue up    = parent_sample(sampler, input.uv + v2( 0, -uv_step.y)); 
    LightValue down  = parent_sample(sampler, input.uv + v2( 0, +uv_step.y)); 
    
    Texture2D<v4> our_surface_color_texture   = ResourceDescriptorHeap[root.our_surface_color];
    Texture2D<v4> our_normal_xz_depth_texture = ResourceDescriptorHeap[root.our_normal_xz_depth];
    
    v3 ref_color           = our_surface_color_texture.Sample(sampler,   input.uv).rgb;
    v3 our_normal_xz_depth = our_normal_xz_depth_texture.Sample(sampler, input.uv).rgb;
    
    v3 ref_n = reconstruct_normal(our_normal_xz_depth);
    v3 ref_p = reconstruct_position(our_normal_xz_depth, input.uv);
    
    FragmentOutput output;
    output.front_emission = 0.25 * (
        transfer_light(left.p,  left.n,  left.front_emission,  ref_p, ref_n, ref_color) +
        transfer_light(right.p, right.n, right.front_emission, ref_p, ref_n, ref_color) +
        transfer_light(up.p,    up.n,    up.front_emission,    ref_p, ref_n, ref_color) +
        transfer_light(down.p,  down.n,  down.front_emission,  ref_p, ref_n, ref_color)
    );
    output.back_emission = 0.25 * (
        transfer_light(left.p,  left.n,  left.back_emission,  ref_p, ref_n, ref_color) +
        transfer_light(right.p, right.n, right.back_emission, ref_p, ref_n, ref_color) +
        transfer_light(up.p,    up.n,    up.back_emission,    ref_p, ref_n, ref_color) +
        transfer_light(down.p,  down.n,  down.back_emission,  ref_p, ref_n, ref_color)
    );
    
    return output;
}

v3 reconstruct_position(v3 normal_xz_depth, v2 uv) {
   // @todo Calculate the correct world position from the fragment coordinate.
    v3 result = v3(0, 0, normal_xz_depth.z);
    return result;
}

v3 reconstruct_normal(v3 normal_xz_depth) {
    f32 nx = normal_xz_depth.x;
    f32 nz = normal_xz_depth.y;
    f32 ny = sqrt(1.0 - square(nx) - square(nz));
    
    v3 result = v3(nx, ny, nz);
    
    return result;
}

v3 transfer_light(v3 light_p, v3 light_n, v3 light_emission, v3 ref_p, v3 ref_n, v3 ref_color) {
    v3 result = light_emission;
    
    return result;
}

LightValue parent_sample(SamplerState sampler, v2 uv) {
    LightValue result;
    result.front_emission = manual_sample(get_texture(root.parent_front_emission),  sampler, uv);
    result.back_emission  = manual_sample(get_texture(root.parent_back_emission),   sampler, uv);
    v3 normal_xz_depth    = manual_sample(get_texture(root.parent_normal_xz_depth), sampler, uv);
    
    result.n = reconstruct_normal(normal_xz_depth);
    result.p = reconstruct_position(normal_xz_depth, uv);
    
    return result;
}

v3 manual_sample(Texture2D<v4> texture, SamplerState sampler, v2 uv) {
    v3 result = texture.Sample(sampler, uv).rgb;
    return result;
}

Texture2D<v4> get_texture(u32 descriptor) {
    Texture2D<v4> result = ResourceDescriptorHeap[descriptor];
    return result;
}