#include "shared.slang"

struct Root {
    u32 parent_front_emission;
    u32 parent_back_emission;
    u32 parent_normal_xy_depth;
    
    u32 our_surface_color;
    u32 our_normal_xy_depth;
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
        get_texture(root.parent_front_emission).GetDimensions(width, height);
        uv_step = 1.0 / v2(width, height);
    }
    
    SamplerState sampler = SamplerDescriptorHeap[u32(Sampler.Linear)];
    
    LightValue left  = parent_sample(sampler, input.uv + v2(-uv_step.x,  0)); 
    LightValue right = parent_sample(sampler, input.uv + v2(+uv_step.x,  0)); 
    LightValue up    = parent_sample(sampler, input.uv + v2( 0, -uv_step.y)); 
    LightValue down  = parent_sample(sampler, input.uv + v2( 0, +uv_step.y)); 
    
    Texture2D<v4> our_surface_color_texture   = ResourceDescriptorHeap[root.our_surface_color];
    Texture2D<v4> our_normal_xy_depth_texture = ResourceDescriptorHeap[root.our_normal_xy_depth];
    
    v3 ref_color           = our_surface_color_texture.Sample(sampler,   input.uv).rgb;
    v3 our_normal_xy_depth = our_normal_xy_depth_texture.Sample(sampler, input.uv).rgb;
    
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
    f32 nx = normal_xy_depth.x;
    f32 ny = normal_xy_depth.y;
    f32 nz = sqrt(1.0 - square(nx) - square(ny));
    
    v3 result = v3(nx, ny, nz);
    
    return result;
}

v3 transfer_light(v3 light_p, v3 light_n, v3 light_emission, v3 ref_p, v3 ref_n, v3 ref_color) {
    /* 
    v3 to_camera        = root.camera_p - input.world_p.xyz;
    f32 camera_distance = length(root.camera_p);
    to_camera *= 1.0/camera_distance;
    
    v3 light_p = root.light_p;
    
    v3 light_strength  = v3(1, 1, 1);
    v3 to_light        = light_p - input.world_p.xyz;
    f32 light_distance = length(light_p);
    to_light *= 1.0/light_distance;
    
    v3 cos_light_angle = v3(
        dot(to_light, input.world_n),
        dot(to_light, input.world_n),
        dot(to_light, input.world_n),
    );
    cos_light_angle = clamp(cos_light_angle, 0.0, 1.0);
    
    v3 reflected_d = -to_camera + 2 * dot(input.world_n, to_camera) * input.world_n;
    v3 cos_reflected = v3(
        dot(to_light, reflected_d),
        dot(to_light, reflected_d),
        dot(to_light, reflected_d),
    );
    cos_reflected = clamp(cos_reflected, 0.0, 1.0);
    
    cos_reflected *= cos_reflected;
    cos_reflected *= cos_reflected;
    cos_reflected *= cos_reflected;
    cos_reflected *= cos_reflected;
    cos_reflected *= cos_reflected;
    cos_reflected *= cos_reflected;
    cos_reflected *= cos_reflected;
    cos_reflected *= cos_reflected;
    cos_reflected *= cos_reflected;
    
    v3 light_amount = light_strength / square(light_distance);
    
    f32 diffuse_c    = 1.0f;
    v3 diffuse_light = diffuse_c * cos_light_angle * light_amount;
    
    f32 spec_c    = 0.0f;
    v3 spec_light = spec_c * cos_reflected * light_amount;
    
    light_total = diffuse_light + spec_light;
*/
    f32 facing           = clamp01(-dot(light_n, ref_n));
    f32 distance_squared = length_squared(light_p - ref_p);
    f32 falloff = 1.0 / (1 + 100*distance_squared);
    
    v3 result = facing * falloff * ref_color * light_emission;
    return result;
}

LightValue parent_sample(SamplerState sampler, v2 uv) {
    LightValue result;
    result.front_emission = manual_sample(get_texture(root.parent_front_emission),  sampler, uv);
    result.back_emission  = manual_sample(get_texture(root.parent_back_emission),   sampler, uv);
    v3 normal_xy_depth    = manual_sample(get_texture(root.parent_normal_xy_depth), sampler, uv);
    
    result.n = reconstruct_normal(normal_xy_depth);
    result.p = reconstruct_position(normal_xy_depth, uv);
    
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