static const f32 max_light_intensity = 10.0;

#define square(value) (value*value)
#define clamp01(value) (clamp(value, 0, 1))
#define length_squared(value) (dot(value, value))

typedef uint   u32;
typedef float  f32;
typedef float2 v2;
typedef float3 v3;
typedef float4 v4;

f32 clamp_01_map_to_range(f32 min, f32 max, f32 t) {
    f32 range  = max - min;
    f32 result = 0;
    if (range != 0) {
        f32 absolute = (t - min) / range;
        result = clamp(absolute, 0, 1);
    }
    return result;
}

static const v4 fullscreen_positions[3] = { v4(-1, -1, 0 ,1), v4(3, -1, 0, 1), v4(-1, 3, 0, 1) };
static const v2 fullscreen_uvs[3]       = { v2( 0,  0),       v2(2,  0),       v2( 0, 2)       };

////////////////////////////////////////////////
// @todo generate this to keep it in sync with the odin code?

// see :VulkanSamplers:
enum Sampler : u32 {
    Linear  = 0,
    Nearest = 1,
};

// @volatile see vulkan.odin
static const u32 depth_peel_and_resolve_target_stride = depth_peel.__count;
static const u32 depth_peel_and_resolve_target_count  = 4 * depth_peel_and_resolve_target_stride;
static const u32 light_buffer_stride = light_buffer.__count;
static const u32 light_buffer_count  = 10 * light_buffer_stride;

// @volatile see vulkan.odin
enum TextureDescriptor : u32 {
    nil_texture = 0,
    
    depth_peel_begin,
    depth_peel_end = depth_peel_begin + depth_peel_and_resolve_target_count,
    
    resolve_begin,
    resolve_end = resolve_begin + depth_peel_and_resolve_target_count,
    
    composite,
    
    light_buffer_begin,
    light_buffer_end = light_buffer_begin+light_buffer_count, // @cleanup
    
    first_dynamic_texture,
    // count = first_dynamic_texture + max_vulkan_textures,
}

// @volatile see vulkan.odin
enum light_buffer : u32 {
    front_emission  = 0,
    back_emission   = 1,
    surface_color   = 2,
    normal_xy_depth = 3,
    __count,
}

enum depth_peel : u32 {
    depth           = 0,
    surface_reflect = 1,
    emission        = 2,
    normal_lp       = 3,
    __count,
}

////////////////////////////////////////////////

inline Texture2D<v4> get_light_buffer(u32 index, light_buffer texture) {
    u32 descriptor = TextureDescriptor.light_buffer_begin + index * light_buffer_stride + texture;
    Texture2D<v4> result = ResourceDescriptorHeap[descriptor];
    return result;
}

inline Texture2DMS<f32> get_peel_depth_buffer(u32 index) {
    u32 descriptor = TextureDescriptor.depth_peel_begin + index * depth_peel_and_resolve_target_stride + depth_peel.depth;
    Texture2DMS<f32> result = ResourceDescriptorHeap[descriptor];
    return result;
}
inline Texture2DMS<v4> get_peel_color_buffer(u32 index, depth_peel texture) {
    u32 descriptor = TextureDescriptor.depth_peel_begin + index * depth_peel_and_resolve_target_stride + texture;
    Texture2DMS<v4> result = ResourceDescriptorHeap[descriptor];
    return result;
}

// @copypasta
inline Texture2DMS<f32> get_resolve_depth_buffer(u32 index) {
    u32 descriptor = TextureDescriptor.resolve_begin + index * depth_peel_and_resolve_target_stride + depth_peel.depth;
    Texture2DMS<f32> result = ResourceDescriptorHeap[descriptor];
    return result;
}
inline Texture2DMS<v4> get_resolve_color_buffer(u32 index, depth_peel texture) {
    u32 descriptor = TextureDescriptor.resolve_begin + index * depth_peel_and_resolve_target_stride + texture;
    Texture2DMS<v4> result = ResourceDescriptorHeap[descriptor];
    return result;
}

////////////////////////////////////////////////

v2 pack_normal2(v2 n) {
    v2 result = 0.5 + 0.5 * n;
    return result;
}
v2 unpack_normal2(v2 n) {
    v2 result = -1 + 2 * n;
    return result;
}

v3 unpack_normal3(v2 n) {
    v2  n2     = unpack_normal2(n);
    v3  result = extend_normal3(n2);
    return result;
}  

v3 extend_normal3(v2 n2) {
    f32 nz     = sqrt(1 - square(n2.x) -square(n2.y));
    v3  result = v3(n2, nz);
    return result;
}
