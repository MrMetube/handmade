package shared_render

// @note These are shared with the build script, which creates the packed shader spirv file.
ShaderPackHeader :: struct #packed {
    magic:   [4] u8,
    version: u32,
    infos:   [Shaders] struct #packed { 
        first_stage_offset: u64, 
        first_stage_count:  u64,
        fragment_offset:    u64, 
        fragment_count:     u64,
        is_mesh_shader:     b32,
    },
}

Shaders :: enum u8 {
    zbias,
    peel_composite,
    multisample_resolve,
    final_stretch,
    multigrid_light_up,
    multigrid_light_down,
    depth_peel_to_lighting,
}
