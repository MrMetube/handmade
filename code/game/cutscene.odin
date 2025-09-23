package game

Titlescreen_Mode :: struct {
    t: f32,
}

Cutscene_Mode :: struct {
    id: Cutscene_Id,
    t: f32,
}

Cutscene_Id :: enum { Intro }

Cutscene :: distinct [] Layered_Scene

Layered_Scene :: struct {
    type: AssetTypeId,
    shot_index: u32,
    layers: [] Scene_Layer,
    
    duration: f32,
    camera_start: v3,
    camera_end: v3,
    
    t_fade_in: f32,
}

Scene_Layer :: struct {
    p: v3,
    height: f32,
    flags: Scene_Layer_Flags,
    param: v2,
}

Scene_Layer_Flags :: bit_set[Scene_Layer_Flag]
Scene_Layer_Flag :: enum {
    at_infinity,
    counter_camera_x,
    counter_camera_y,
    transient,
    floaty,
}

////////////////////////////////////////////////

CutsceneWarmUpSeconds :: 2

Cutscenes := [?] Cutscene { IntroCutscene }

IntroCutscene := Cutscene {
    {.None,             0, intro_layers[ 0],  CutsceneWarmUpSeconds, 0, 0, 0},
    {.OpeningCutscene,  1, intro_layers[ 1],                   20.0, {0, 0,   10}, {-4,    -2,     5  }, 0.5},
    {.OpeningCutscene,  2, intro_layers[ 2],                   20.0, {0, 0,    0}, { 2,    -2,    -4  }, 0  },
    {.OpeningCutscene,  3, intro_layers[ 3],                   20.0, {0, 0.5,  0}, { 0,     6.5,  -1.5}, 0  },
    {.OpeningCutscene,  4, intro_layers[ 4],                   20.0, {0, 0,    0}, { 0,     0,    -0.5}, 0  },
    {.OpeningCutscene,  5, intro_layers[ 5],                   20.0, {0, 0,    0}, { 0,     0.5,  -1  }, 0  },
    {.OpeningCutscene,  6, intro_layers[ 6],                   20.0, {0, 0,    0}, {-0.5,   0.5,  -1  }, 0  },
    {.OpeningCutscene,  7, intro_layers[ 7],                   20.0, {0, 0,    0}, { 2,     0,     0  }, 0  },
    {.OpeningCutscene,  8, intro_layers[ 8],                   20.0, {0, 0,    0}, { 0,    -0.5,  -1  }, 0  },
    {.OpeningCutscene,  9, intro_layers[ 9],                   20.0, {0, 0,    0}, {-0.75, -0.5,  -1  }, 0  },
    {.OpeningCutscene, 10, intro_layers[10],                   20.0, {0, 0,    0}, {-0.1,   0.05, -0.5}, 0  },
    {.OpeningCutscene, 11, intro_layers[11],                   20.0, {0, 0,    0}, { 0.6,   0.5,  -2  }, 0  },
}

intro_layers :: [?] [] Scene_Layer {
    0 = {},
    
    1 = {
        {{ 0,  0, -200}, 300, {.at_infinity}, 0}, // NOTE(casey): Sky background
        {{ 0,  0, -170}, 300, {            }, 0}, // NOTE(casey): Weird sky light
        {{ 0,  0, -100},  40, {            }, 0}, // NOTE(casey): Backmost row of trees
        {{ 0, 10,  -70},  80, {            }, 0}, // NOTE(casey): Middle hills and trees
        {{ 0,  0,  -50},  70, {            }, 0}, // NOTE(casey): Front hills and trees
        {{30, 0,   -30},  50, {            }, 0}, // NOTE(casey): Right side tree and fence
        {{ 0, -2,  -20},  40, {            }, 0}, // NOTE(casey): 7
        {{ 2, -1,   -5},  25, {            }, 0}, // NOTE(casey): 8
    },

    2 = {
        {{3, -4, -62}, 102, {}, 0}, // NOTE(casey): Hero and tree
        {{0,  0, -14},  22, {}, 0}, // NOTE(casey): Wall and window
        {{0,  2,  -8},  10, {}, 0}, // NOTE(casey): Icicles
    },

    3 = {
        {{0,  0,    -30  }, 100, {.at_infinity     }, 0}, // NOTE(casey): Sky
        {{0,  0,    -20  },  45, {.counter_camera_y}, 0}, // NOTE(casey): Wall and window
        {{0, -2,     -4  },  15, {.counter_camera_y}, 0}, // NOTE(casey): Icicles
        {{0,  0.35,  -0.5},   1, {                 }, 0}, // NOTE(casey): Icicles
    },

    4 = {
        {{ 0,     0,    -4.1}, 6, {          }, 0         },
        {{-1.2,  -0.2,  -4  }, 4, {.transient}, {0.0, 0.5}},
        {{-1.2,  -0.2,  -4  }, 4, {.transient}, {0.5, 1.0}},
        {{ 2.25, -1.5,  -3  }, 2, {          }, 0         },
        {{ 0,     0.35, -1  }, 1, {          }, 0         },
    },

    5 = {
        {{0, 0, -20}, 30, {          }, 0         },
        {{0, 0,  -5},  8, {.transient}, {0.0, 0.5}},
        {{0, 0,  -5},  8, {.transient}, {0.5, 1.0}},
        {{0, 0,  -3},  4, {.transient}, {0.5, 1.0}},
        {{0, 0,  -2},  3, {.transient}, {0.5, 1.0}},
    },

    6 = {
        {{ 0,     0,    -8  }, 12,   {}, 0},
        {{ 0,     0,    -5  },  8,   {}, 0},
        {{ 1,    -1,    -3  },  3,   {}, 0},
        {{ 0.85, -0.95, -3  },  0.5, {}, 0},
        {{-2.0,  -1,    -2.5},  2,   {}, 0},
        {{ 0.2,   0.5,  -1  },  1,   {}, 0},
    },

    7 = {
        {{-0.5, 0, -8}, 12, {.counter_camera_x}, 0},
        {{-1,   0, -4},  6, {                 }, 0},
    },

    8 = {
        {{0,  0,   -8  }, 12,   {       }, 0           },
        {{0, -1,   -5  },  4,   {.floaty}, {0.05, 15.0}},
        {{3, -1.5, -3  },  2,   {       }, 0           },
        {{0,  0,   -1.5},  2.5, {       }, 0           },
    },

    9 = {
        {{0, 0,    -8}, 12, {}, 0},
        {{0, 0.25, -3},  4, {}, 0},
        {{1, 0,    -2},  3, {}, 0},
        {{1, 0.1,  -1},  2, {}, 0},
    },

    10 = {
        {{-15,   25,    -100  }, 130,   {.at_infinity}, 0},
        {{  0,    0,     -10  },  22,   {            }, 0},
        {{ -0.8, -0.2,    -3  },   4.5, {            }, 0},
        {{  0,    0,      -2  },   4.5, {            }, 0},
        {{  0,   -0.25,   -1  },   1.5, {            }, 0},
        {{  0.2,  0.2,    -0.5},   1,   {            }, 0},
    },

    11 = {
        {{ 0,     0,     -100},   150,   {.at_infinity}, 0},
        {{ 0,    10,      -40},    40,   {            }, 0},
        {{ 0,     3.2,    -20},    23,   {            }, 0},
        {{ 0.25,  0.9,    -10},    13.5, {            }, 0},
        {{-0.5,   0.625,   -5},     7,   {            }, 0},
        {{ 0,     0.1,     -2.5},   3.9, {            }, 0},
        {{-0.3,  -0.15,    -1},     1.2, {            }, 0},
    },

}

////////////////////////////////////////////////

play_title_screen :: proc (state: ^State, tran_state: ^TransientState) {
    mode := set_game_mode(state, tran_state, Titlescreen_Mode)
    mode.t = 0
}
play_intro_cutscene :: proc (state: ^State, tran_state: ^TransientState) {
    mode := set_game_mode(state, tran_state, Cutscene_Mode)
    mode.t = 0
    mode.id = .Intro
}

////////////////////////////////////////////////

update_and_render_title_screen :: proc(state: ^State, tran_state: ^TransientState, render_group: ^RenderGroup, input: ^Input, mode: ^Titlescreen_Mode) -> (rerun: bool) {
    rerun = check_for_meta_input(state, tran_state, input)
    
    if !rerun {
        push_clear(render_group, {1, 0.25, 0.25, 1})
        
        if mode.t > 10 {
            play_intro_cutscene(state, tran_state)
        } else {
            mode.t += input.delta_time
        }
    }
    return rerun
}

update_and_render_cutscene :: proc(state: ^State, tran_state: ^TransientState, render_group: ^RenderGroup, input: ^Input, mode: ^Cutscene_Mode) -> (rerun: bool) {
    assets := tran_state.assets
    rerun = check_for_meta_input(state, tran_state, input)
    
    if !rerun {
        // @note(viktor): prefetch assets for upcoming scenes
        render_cutscene_at_time(assets, nil, mode, mode.t + CutsceneWarmUpSeconds)
        still_running := render_cutscene_at_time(assets, render_group, mode, mode.t)
        if !still_running {
            play_title_screen(state, tran_state)
        } else {
            mode.t += input.delta_time
        }
    }
    return rerun
}

////////////////////////////////////////////////

check_for_meta_input :: proc (state: ^State, tran_state: ^TransientState, input: ^Input) -> (result: bool) {
    for controller in input.controllers {
        if was_pressed(controller.back) {
            input.quit_requested = true
            break
        } else if was_pressed(controller.start) {
            play_world(state, tran_state)
            result = true
            break
        }
    }
    
    return result
}

render_cutscene_at_time :: proc (assets: ^Assets, render_group: ^RenderGroup, mode: ^Cutscene_Mode, t: f32) -> (result: bool) {
    scenes := Cutscenes[mode.id]
    t_base: f32
    for scene in scenes {
        t_start := t_base
        t_end := t_start + scene.duration
        
        if t >= t_start && t < t_end {
            t_normal := clamp_01_map_to_range(t_start, t, t_end)
            render_layered_scene(assets, render_group, scene, t_normal)
            result = true
            break
        }
        
        t_base = t_end
    }
    
    return result
}

render_layered_scene :: proc (assets: ^Assets, render_group: ^RenderGroup, scene: Layered_Scene, t_normal: f32) {
    width := render_group == nil ? 0 : get_dimension(render_group.screen_area).x
    camera_params := get_standard_camera_params(width, 0.25)
    
    scene_fade_value: f32 = 1
    if t_normal < scene.t_fade_in {
        scene_fade_value = clamp_01_map_to_range(cast(f32) 0, t_normal, scene.t_fade_in)
    }
    
    match_vector  := #partial AssetVector { .ShotIndex = cast(f32) scene.shot_index }
    weight_vector := #partial AssetVector { .ShotIndex = 1, .LayerIndex = 1 }
    
    // @todo(viktor): Why does this fade seem to be wrong?  It appears nonlinear, but if it is in linear brightness, shouldn't it _appear_ linear?
    color := v4{scene_fade_value, scene_fade_value, scene_fade_value, 1}
    
    camera_offset := linear_blend(scene.camera_start, scene.camera_end, t_normal)
    if render_group != nil {
        perspective(render_group, camera_params.meters_to_pixels, camera_params.focal_length, 0)
        
        if len(scene.layers) == 0 {
            push_clear(render_group, 0)
        }
    }
    
    for layer, layer_index in scene.layers {
        active := true
        if .transient in layer.flags {
            active = t_normal >= layer.param.x && t_normal < layer.param.y
        }
        
        if !active do continue
        
        match_vector[.LayerIndex] = cast(f32) layer_index + 1
        layer_image := best_match_bitmap_from(assets, scene.type, match_vector, weight_vector)
        
        if render_group != nil {
            transform := default_flat_transform()
            
            p := layer.p
            if .at_infinity in layer.flags {
                p.z += camera_offset.z
            }
            
            if .floaty in layer.flags {
                p.y += layer.param.x + sin(layer.param.y * t_normal)
            }
            
            if .counter_camera_x in layer.flags {
                transform.offset.x = p.x + camera_offset.x
            } else {
                transform.offset.x = p.x - camera_offset.x
            }
            
            
            if .counter_camera_y in layer.flags {
                transform.offset.y = p.y + camera_offset.y
            } else {
                transform.offset.y = p.y - camera_offset.y
            }
            
            // transform.offset.z = p.z - camera_offset.z
            transform.floor_z = p.z - camera_offset.z
            transform.offset.z = p.z - camera_offset.z
            
            push_bitmap(render_group, layer_image, transform, layer.height, 0, color)
        } else {
            prefetch_bitmap(assets, layer_image)
        }
    }
}