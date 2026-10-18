#include "generated.slang"

static const f32 max_light_intensity = 10.0;

#define square(value) (value*value)
#define clamp01(value) (clamp(value, 0, 1))
#define length_squared(value) (dot(value, value))
#define rgba_to_v4 unpackUnorm4x8ToFloat

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

inline Texture2D<v4> get_light_buffer(u32 index, LightBufferKind texture) {
    u32 descriptor = TextureDescriptor.light_buffer_begin + index * light_buffer_stride + texture;
    Texture2D<v4> result = ResourceDescriptorHeap[descriptor];
    return result;
}

inline Texture2DMS<f32> get_peel_depth_buffer(u32 index) {
    u32 descriptor = TextureDescriptor.depth_peel_begin + index * depth_peel_and_resolve_target_stride + DepthPeelKind.depth;
    Texture2DMS<f32> result = ResourceDescriptorHeap[descriptor];
    return result;
}
inline Texture2DMS<v4> get_peel_color_buffer(u32 index, DepthPeelKind texture) {
    u32 descriptor = TextureDescriptor.depth_peel_begin + index * depth_peel_and_resolve_target_stride + texture;
    Texture2DMS<v4> result = ResourceDescriptorHeap[descriptor];
    return result;
}

// @copypasta
inline Texture2DMS<f32> get_resolve_depth_buffer(u32 index) {
    u32 descriptor = TextureDescriptor.resolve_begin + index * depth_peel_and_resolve_target_stride + DepthPeelKind.depth;
    Texture2DMS<f32> result = ResourceDescriptorHeap[descriptor];
    return result;
}
inline Texture2DMS<v4> get_resolve_color_buffer(u32 index, DepthPeelKind texture) {
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
