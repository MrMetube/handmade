#include "shared.slang"

struct Root {
    u32 peels[4];
    u32 npls[4];
    u32 light_normal_xy_depth;
    u32 light_emission;
    u32 peel_count;
};

[[vk::binding(0, 0)]] ConstantBuffer<Root> root;

struct VertexOutput {
    v4 position : SV_Position;
    v2 uv       : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(u32 vertex_id : SV_VertexID) {
    VertexOutput output;
    output.position = fullscreen_positions[vertex_id];
    output.uv       = fullscreen_uvs[vertex_id];
    return output;
}

[shader("fragment")]
v4 fragmentMain(VertexOutput input) : SV_Target0 {
    SamplerState  sampler = SamplerDescriptorHeap[u32(Sampler.Nearest)];
    
    v3 result = v3(0);
    if (root.peel_count == 1) {
        Texture2D<v4> texture = ResourceDescriptorHeap[root.peels[0]];
        v4 peel0 = texture.Sample(sampler, input.uv);
        result = peel0.rgb;
    } else {
        // assert that peel_count == 4
        Texture2D<v4> peel_surface_reflect0 = ResourceDescriptorHeap[root.peels[0]];
        Texture2D<v4> peel_surface_reflect1 = ResourceDescriptorHeap[root.peels[1]];
        Texture2D<v4> peel_surface_reflect2 = ResourceDescriptorHeap[root.peels[2]];
        Texture2D<v4> peel_surface_reflect3 = ResourceDescriptorHeap[root.peels[3]];
        
        Texture2D<v4> peel_normal_pl0 = ResourceDescriptorHeap[root.npls[0]];
        Texture2D<v4> peel_normal_pl1 = ResourceDescriptorHeap[root.npls[1]];
        Texture2D<v4> peel_normal_pl2 = ResourceDescriptorHeap[root.npls[2]];
        Texture2D<v4> peel_normal_pl3 = ResourceDescriptorHeap[root.npls[3]];
        
        Texture2D<v4> light_normal_xy_depth_texture = ResourceDescriptorHeap[root.light_normal_xy_depth];
        Texture2D<v4> light_emission_texture        = ResourceDescriptorHeap[root.light_emission];
        
        
        v4 peel0 = peel_surface_reflect0.Sample(sampler, input.uv);
        v4 peel1 = peel_surface_reflect1.Sample(sampler, input.uv);
        v4 peel2 = peel_surface_reflect2.Sample(sampler, input.uv);
        v4 peel3 = peel_surface_reflect3.Sample(sampler, input.uv);
        
        v4 normal_lp0 = peel_normal_pl0.Sample(sampler, input.uv);
        v4 normal_lp1 = peel_normal_pl1.Sample(sampler, input.uv);
        v4 normal_lp2 = peel_normal_pl2.Sample(sampler, input.uv);
        v4 normal_lp3 = peel_normal_pl3.Sample(sampler, input.uv);
        
        v4 light_np = light_normal_xy_depth_texture.Sample(sampler, input.uv);
        v3 light_c  = light_emission_texture.Sample(sampler, input.uv).rgb;
        
        v3 light_n = extend_normal3(light_np.xy);
        
        light_c = clamp01(light_c / max_light_intensity);
        light_c = sqrt(sqrt(light_c));
        
        v3 to_camera = v3(0, 0, 1); // @todo actually compute this!
        
        // peel0.rgb = light_peel(peel0.rgb, normal_lp0, light_n, light_c, to_camera);
        // peel1.rgb = light_peel(peel1.rgb, normal_lp1, light_n, light_c, to_camera);
        // peel2.rgb = light_peel(peel2.rgb, normal_lp2, light_n, light_c, to_camera);
        // peel3.rgb = light_peel(peel3.rgb, normal_lp3, light_n, light_c, to_camera);
        
        result = peel3.rgb;
        result = peel2.rgb + (1 - peel2.a) * result;
        result = peel1.rgb + (1 - peel1.a) * result;
        result = peel0.rgb + (1 - peel0.a) * result;
    }
    
    return v4(result, 1);
}

v3 light_peel(v3 surface_reflect, v4 normal_lp, v3 light_n, v3 light_c, v3 to_camera) {
    light_n = v3(0, 0, -1);
    
    v3 to_light = -light_n;
    
    v3  ref_n          = unpack_normal3(normal_lp.xy);
    f32 diffuse_c      = normal_lp.z;
    f32 specular_c     = 1.0 - diffuse_c; // @todo how should this really be encoded?
    f32 specular_power = 1 + 15 * normal_lp.w;
    
    f32 diffuse_dot = clamp01(dot(to_light, ref_n));
    v3 cos_angle    = v3(diffuse_dot);
    
    v3 reflected     = -to_camera + 2 * dot(ref_n, to_camera) * ref_n;
    f32 specular_dot = clamp01(dot(to_light, reflected));
    specular_dot     = pow(specular_dot, specular_power);
    
    v3 cos_ref_angle = v3(specular_dot);
    
    
    v3 diffuse_light  = diffuse_c  * cos_angle     * light_c;
    v3 specular_light = specular_c * cos_ref_angle * light_c;
    
    v3 total_light = diffuse_light + specular_light;
    
    v3 result = surface_reflect * total_light;
    return result;
}