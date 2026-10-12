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

// see :VulkanSamplers:
enum Sampler {
    Linear  = 0,
    Nearest = 1,
};

// @todo in multiple shaders, we just want a fullscreen-rectangle vertex shader. unify that usage.
static const v4 fullscreen_positions[3] = { v4(-1, -1, 0 ,1), v4(3, -1, 0, 1), v4(-1, 3, 0, 1) };
static const v2 fullscreen_uvs[3]       = { v2( 0,  0),       v2(2,  0),       v2( 0, 2)       };