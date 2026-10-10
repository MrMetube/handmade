#define square(value) (value*value)

float clamp_01_map_to_range(float min, float max, float t) {
    float range  = max - min;
    float result = 0;
    if (range != 0) {
        float absolute = (t - min) / range;
        result = clamp(absolute, 0, 1);
    }
    return result;
}

// see :VulkanSamplers:
enum Sampler {
    Linear  = 0,
    Nearest = 1,
};

#define f32 float
#define v2 float2
#define v3 float3
#define v4 float4