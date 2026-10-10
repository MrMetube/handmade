// see :VulkanSamplers:

#define square(value) (value*value)

float clamp_01_map_to_range(float min, float max, float t) {
    float range    = max - min;
    float absolute = (t - min) / range;
    float result = clamp(absolute, 0, 1);
    return result;
}

enum Sampler {
    Linear  = 0,
    Nearest = 1,
};
