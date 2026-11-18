#+vet !unused-procedures
package game

/* @note(viktor):
    1) Everywhere outside the renderer, Y _always_ goes upward, X to the right.

    2) All Bitmaps including the render target are assumed to be bottom-up
        (meaning that the first row is the bottom-most row when viewed on
        screen).

    3) It is mandatory that all inputs to the renderer are in world
        coordinate ("meters"), NOT pixels. If for some reason something
        absolutely has to be specified in pixels, that will be explicitly
        marked in the API, but this should occur exceedingly sparingly.

    4) Z is a special axis, because it is broken up into discrete slices,
        and the renderer actually understands these slices(potentially).
        Z slices are what control the _scaling_ of things, whereas Z-offsets
        inside a slice are what control y-offsetting.

    5) All color values specified to the renderer as v4s are in
        _NON-premulitplied_ alpha.
*/

@(common) Color :: [4] u8

@(common)
Bitmap :: struct {
    memory: [] Color,
    dimension: iv2,
    
    // @cleanup with the next asset pack
    align_percentage:  v2,
    width_over_height: f32,
    
    texture_handle: u32,
}

@(common)
RenderSettings :: struct {
    // @todo these should all be compilation values, i.e. the renderer recompiles the psos if these change.
    dimension:             iv2,
    depth_peel_count_hint: u32,
    multisampling_hint:    bool,
    pixelation_hint:       bool,
    lighting_disabled:     bool,
}

@(common)
RenderCommands :: struct {
    using settings: RenderSettings,
    
    clear_color: v4,
    
    entries: [dynamic] RenderEntry,
    
    vertex_buffer:      [dynamic] TexturedVertex,
    quad_bitmap_buffer: [dynamic] ^Bitmap,
    light_boxes:        [dynamic] LightingBox,
    light_points:       [dynamic] LightingPoint,
    emission_color_0:   [] v3,
    
    white_bitmap: Bitmap,
}

RenderGroup :: struct {
    assets:        ^Assets,
    generation_id: AssetGenerationId,
    
    commands: ^RenderCommands,
    
    screen_size: v2,
    
    lighting_enabled: bool,
    light_index:      u32,
    
    last_setup: RenderSetup,
    
    current_quads: ^TexturedQuads,
    
    game_cam:  RenderTransform,
    debug_cam: RenderTransform,
}

RenderTransform :: struct {
    p: v3,
    x: v3,
    y: v3,
    z: v3,
    projection: m4_inv,
}

Transform :: struct {
    is_upright: bool,
    offset: v3,  
}
    
Camera_Flags :: bit_set[ enum {
    orthographic,
    debug,
}]

////////////////////////////////////////////////

RenderEntryKind :: enum u8 {
    None,
    Textured_Quads,
    DepthClear,
    BeginPeels,
    EndPeels,
    Lighting,
}

@(common)
RenderEntry :: struct {
    kind: RenderEntryKind,
    
    textured_quads: TexturedQuads,
    lighting:       Lighting,
}

RenderSetup :: struct { // @todo(viktor): rename this to some more camera-centric
    next: ^RenderSetup,
    
    clip_rect:           Rectangle2i,
    
    projection:       m4,
    camera_p:         v3,
    fog_direction:    v3,
    fog_begin:        f32,
    fog_end:          f32,
    fog_color:        v3,
    clip_alpha_begin: f32,
    clip_alpha_end:   f32,
}

TexturedQuads :: struct {
    setup: RenderSetup,
    
    quad_count:    u32,
    bitmap_offset: u32,
}

@(common)
Lighting :: struct {
    values: [] LightingValue,
}

@(common, shader)
TexturedVertex :: struct {
    p:        v4,
    n:        PackedNormal,
    uv:       PackedUV,
    color:    Color,
    emission: f32,
    
    // @todo Doesn't need to be per-vertex - move this into a its own per-primitive buffer.
    // @todo Could be compressed to u16s.
    light_index: u32,
    light_count: u32,
}

PackedNormal :: bit_field u32 {
    x: i16 | 10,
    y: i16 | 10,
    z: i16 | 10,
    _: i16 |  2,
}

PackedUV :: distinct [2] u16

////////////////////////////////////////////////

UsedBitmapDim :: struct {
    size:  v2,
    align: v2,
    p:     v3,
    basis: v3,
}

////////////////////////////////////////////////

@(common)
light_element_limit :: 64 * 1024

LightingSolution :: struct {
    surfaces:         [dynamic; light_element_limit] LightingSurface,
    points:           [] LightingPoint,
    emission_color_0: [] v3,
    
    emission_color_1:           [light_element_limit] v3,
    average_direction_to_light: [light_element_limit] v3,
    
    last_is_valid:  bool,
    last_emission:  [light_element_limit] v3,
    last_direction: [light_element_limit] v3,
}

LightingTextures :: struct {
    values: [light_element_limit] LightingValue,
}

LightingSurface :: struct {
    p: v3,
    n: v3,
    transparency:   f32,
    width, height:  f32,
    x_axis, y_axis: v3,
    light_index: u32,
    light_count: u32,
}

@(common)
LightingBox :: struct {
    min: v3,
    max: v3,
    transparency: f32,
    
    light_index: [7] u32,
    _padding:    [1] u32,
}

@(common)
LightingPoint :: struct {
    p:             v3,
    reflect_color: v3,
    n:             v3,
}

@(common, shader)
LightingValue :: struct {
    p: v3,
    c: v3,
    d: v2, 
    // @note z is recoverable through |d.xyz| = 1
    // => sqrt(x²+y²+z²) = 1 => x²+y²+z² = 1 => z² = 1-x²-y² => +/-z = sqrt(1-x²-y²)
    // The sign of z is stored in c.r(color values are always positive, so the sign-bit is not used).
}

////////////////////////////////////////////////

init_render_group :: proc (group: ^RenderGroup, assets: ^Assets, commands: ^RenderCommands, generation_id: AssetGenerationId) {
    group ^= {
        assets   = assets,
        commands = commands,
        
        screen_size   = cast(v2) commands.dimension,
        generation_id = generation_id,
        
        light_index = 1,
    }
    
    setup := group.last_setup
    
    setup.clip_rect        = rectangle_zero_min_dimension(commands.dimension)
    setup.projection       = identity()
    setup.fog_begin        = 0
    setup.fog_end          = 1
    setup.clip_alpha_begin = 0
    setup.clip_alpha_end   = 1
    
    push_setup(group, setup)
}

////////////////////////////////////////////////

default_flat_transform    :: proc () -> Transform { return { } }
default_upright_transform :: proc () -> Transform { return { is_upright = true } }

////////////////////////////////////////////////

push_render_entry :: proc (group: ^RenderGroup, kind: RenderEntryKind) -> ^RenderEntry {
    reset_quads := true
    
    assert(kind != .None)
    if kind == .Textured_Quads {
        reset_quads = false
    }
    
    result := append_into(&group.commands.entries)
    result.kind = kind
    
    if reset_quads {
        group.current_quads = nil
    }
    
    return result
}

render_group_push_size :: proc (group: ^RenderGroup, $T: typeid) -> ^T {
    result := write_reserve(&group.commands.push_buffer, T)
    return result
}

////////////////////////////////////////////////

enable_lighting :: proc (group: ^RenderGroup) {
    group.lighting_enabled = true
}

push_setup :: proc (group: ^RenderGroup, setup: RenderSetup) {
    group.last_setup = setup
    group.current_quads = nil
}

get_screen_point :: proc (group: ^RenderGroup, transform: Transform, world_p: v3) -> v2 {
    p := multiply(group.last_setup.projection, world_p + transform.offset)
    
    p.xy = group.screen_size * 0.5 * (1 + p.xy)
    
    return p.xy
}

get_clip_rect_with_transform :: proc (group: ^RenderGroup, rect: Rectangle2, transform: Transform) -> Rectangle2i {
    min_corner := get_screen_point(group, transform, V3(rect.min, 0))
    max_corner := get_screen_point(group, transform, V3(rect.max, 0))
    
    result := round_outer(Rectangle2{min_corner, max_corner})
    
    return result
}

@(deferred_in_out=end_transient_clip_rect)
transient_clip_rect :: proc (group: ^RenderGroup, rect: Rectangle2i) -> (previous_setup: RenderSetup) {
    previous_setup = group.last_setup
    
    setup := previous_setup
    setup.clip_rect =  rect
    push_setup(group, setup)
    
    return previous_setup
}

end_transient_clip_rect :: proc (group: ^RenderGroup, _: Rectangle2i, previous_setup: RenderSetup) {
    push_setup(group, previous_setup)
}

push_depth_clear      :: proc (group: ^RenderGroup) { push_render_entry(group, .DepthClear) }
push_begin_depth_peel :: proc (group: ^RenderGroup) { push_render_entry(group, .BeginPeels) }
push_end_depth_peel   :: proc (group: ^RenderGroup) { push_render_entry(group, .EndPeels)   }

push_lighting :: proc (group: ^RenderGroup, source: ^LightingTextures) {
    entry := push_render_entry(group, .Lighting)
    entry.lighting.values = source.values[:]
}

push_camera :: proc (group: ^RenderGroup, flags: Camera_Flags, x := v3{1,0,0}, y := v3{0,1,0}, z := v3{0,0,1}, p := v3{0,0,0}, focal_length: f32 = 1, near_clip_plane: f32 = 0.1, far_clip_plane: f32 = 100, fog := false, clip_alpha := true) {
    aspect_width_over_height := safe_ratio_1(cast(f32) group.commands.dimension.x, cast(f32) group.commands.dimension.y)
    
    setup := group.last_setup
    projection: m4_inv
    if .orthographic in flags {
        projection = orthographic_projection(aspect_width_over_height, near_clip_plane, far_clip_plane)
        
        setup.fog_direction = 0
    } else {
        projection = perspective_projection(aspect_width_over_height, focal_length, near_clip_plane, far_clip_plane)
    }
    
    fog        := fog
    clip_alpha := clip_alpha
    if .debug in flags {
        fog        = false
        clip_alpha = false
    }
    
    if fog {
        setup.fog_direction = -z
        setup.fog_begin = 8
        setup.fog_end   = 25
    } else {
        setup.fog_begin = 0
        setup.fog_end   = 1
        setup.fog_direction = {0, 0, 0}
    }
    
    if clip_alpha {
        setup.clip_alpha_begin = near_clip_plane + 2.0
        setup.clip_alpha_end   = near_clip_plane + 2.25
    } else {
        setup.clip_alpha_begin = near_clip_plane - 1000
        setup.clip_alpha_end   = near_clip_plane -  999
    }
    
    camera := camera_transform(x, y, z, p)
    
    projection.forward  = projection.forward * camera.forward
    projection.backward = camera.backward * projection.backward
    
    transform := .debug in flags ? &group.debug_cam : &group.game_cam
    
    transform.projection = projection
    transform.p = p
    transform.x = x
    transform.y = y
    transform.z = z
    
    if .debug in flags {
        group.debug_cam = group.game_cam
    }
    setup.camera_p = p
    
    setup.projection = projection.forward
    push_setup(group, setup)
}

////////////////////////////////////////////////

push_clear :: proc (group: ^RenderGroup, color: v4) {
    group.commands.clear_color = store_color(color)
    
    setup := group.last_setup
    setup.fog_color = srgb_to_linear(color.rgb)
    push_setup(group, setup)
}

////////////////////////////////////////////////

push_quad :: proc { push_quad_no_bias, push_quad_z_bias }
push_quad_no_bias :: proc (group: ^RenderGroup, bitmap: ^Bitmap, p0, p1, p2, p3: v3, t0, t1, t2, t3: v2, c0, c1, c2, c3: Color, emission: f32 = 0, light_index: u32 = 0, light_count: u32 = 0) {
    push_quad(group, bitmap, V4(p0, 0), V4(p1, 0), V4(p2, 0), V4(p3, 0), t0, t1, t2, t3, c0, c1, c2, c3, emission, light_index, light_count)
}
push_quad_z_bias  :: proc (group: ^RenderGroup, bitmap: ^Bitmap, p0, p1, p2, p3: v4, t0, t1, t2, t3: v2, c0, c1, c2, c3: Color, emission: f32 = 0, light_index: u32 = 0, light_count: u32 = 0) {
    entry := get_current_quads(group)
    entry.quad_count += 1
    
    // @todo(viktor): Just pass the normal down directly
    e10 := p1 - p0
    e30 := p3 - p0
    
    e10.z += e10.w
    e30.z += e30.w
    
    normal := cross(e30.xyz, e10.xyz)
    normal = normalize_or_zero(normal)
    
    n0, n1, n2, n3: v3 = normal, normal, normal, normal
    
    append(&group.commands.quad_bitmap_buffer,  bitmap)
    append(&group.commands.vertex_buffer,
        { p0, pack(n0), pack(t0), c0, emission, light_index, light_count },
        { p1, pack(n1), pack(t1), c1, emission, light_index, light_count },
        { p2, pack(n2), pack(t2), c2, emission, light_index, light_count },
        { p3, pack(n3), pack(t3), c3, emission, light_index, light_count },
    )
}

pack :: proc { pack_normal, pack_uv }
pack_normal :: proc (normal: v3) -> PackedNormal {
    result := PackedNormal {
        x = round(i16, clamp(normal.x, -1, 1) * 511),
        y = round(i16, clamp(normal.y, -1, 1) * 511),
        z = round(i16, clamp(normal.z, -1, 1) * 511),
    }
    return result
}
pack_uv :: proc (uv: v2) -> PackedUV {
    result := PackedUV {
        round(u16, clamp(uv.x, 0, 1) * cast(f32) max(u16)),
        round(u16, clamp(uv.y, 0, 1) * cast(f32) max(u16)),
    }
    return result
}

unpack :: proc { unpack_normal, unpack_uv }
unpack_normal :: proc (normal: PackedNormal) -> v3 {
    result := v3 {
        cast(f32) normal.x,
        cast(f32) normal.y,
        cast(f32) normal.z,
    }
    result *= 1.0 / 511.0
    return result
}
unpack_uv :: proc (uv: PackedUV) -> v2 {
    result := cast(v2) uv
    result *= 1.0 /  cast(f32) max(u16)
    return result
}

get_current_quads :: proc (group: ^RenderGroup) -> ^TexturedQuads {
    if group.current_quads == nil {
        entry := push_render_entry(group, .Textured_Quads)
        group.current_quads = &entry.textured_quads
        group.current_quads ^= {
            bitmap_offset = cast(u32) len(group.commands.quad_bitmap_buffer),
            setup         = group.last_setup,
        }        
    }
    
    result := group.current_quads
    return result
}

push_line_segment :: proc { push_line_segment_default, push_line_segment_direct }
push_line_segment_default :: proc (group: ^RenderGroup, bitmap: ^Bitmap, transform: Transform, from_p, to_p: v3, c0, c1: v4, thickness: f32) {
    zbias :: 0.01
    from_p := V4(project_with_transform(transform, from_p), zbias)
    to_p   := V4(project_with_transform(transform, to_p),   zbias)
    c0 := v4_to_rgba(store_color(c0))
    c1 := v4_to_rgba(store_color(c1))
    push_line_segment(group, bitmap, from_p, to_p, c0, c1, thickness)
}
push_line_segment_direct :: proc (group: ^RenderGroup, bitmap: ^Bitmap, from_p, to_p: v4, c0, c1: Color, thickness: f32) {
    perp := cross(group.debug_cam.z, to_p.xyz - from_p.xyz)
    perp = normalize_or_zero(perp)
    
    d := V4(perp, 0) * thickness
    
    p0 := from_p - d
    p1 := from_p + d
    p2 :=   to_p + d
    p3 :=   to_p - d
    
    t0, t1, t2, t3: v2 = {0,0}, {1,0}, {1,1}, {0,1}
    c0, c1, c2, c3 := c0, c1, c1, c0
    
    push_quad(group, bitmap, p0, p1, p2, p3, t0, t1, t2, t3, c0, c1, c2, c3)
}

////////////////////////////////////////////////

push_bitmap :: proc (group: ^RenderGroup, id: BitmapId, transform: Transform, height: f32, offset := v3{}, color := v4{1, 1, 1, 1}, use_alignment := true, x_axis := v2{1, 0}, y_axis := v2{0, 1}) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    // @todo(viktor): the handle is filled out always at the end of the frame in manage_textures
    if bitmap != nil && bitmap.texture_handle != 0 {
        push_bitmap_raw(group, bitmap, transform, height, offset, color, use_alignment, x_axis, y_axis)
    } else {
        load_bitmap(group.assets, id, false)
    }
}

push_bitmap_raw :: proc (group: ^RenderGroup, bitmap: ^Bitmap, transform: Transform, height: f32, offset := v3{}, color := v4{1, 1, 1, 1}, use_alignment := true, x_axis2 := v2{1, 0}, y_axis2 := v2{0, 1}) {
    assert(bitmap.width_over_height != 0)
    assert(bitmap.texture_handle != 0)
    
    used_dim := get_used_bitmap_dim(group, bitmap^, transform, height, offset, use_alignment, x_axis2, y_axis2)
    size := used_dim.size
    
    min    := V4(used_dim.basis, 0)
    x_axis := V3(x_axis2, 0) * size.x
    y_axis := V3(y_axis2, 0) * size.y
    
    z_bias: f32
    if transform.is_upright {
        z_bias = 0.25 * height
        
        // x_axis0 := size.x * v3{x_axis2.x, 0, x_axis2.y}
        y_axis0 := size.y * v3{y_axis2.x, 0, y_axis2.y}
        x_axis1 := size.x * (x_axis2.x * group.game_cam.x + x_axis2.y * group.game_cam.y)
        y_axis1 := size.y * (y_axis2.x * group.game_cam.x + y_axis2.y * group.game_cam.y)
        
        x_axis = x_axis1
        y_axis = y_axis1
        y_axis.z = linear_blend(y_axis0.z, y_axis1.z, 0.5)
    }
    
    // @note(viktor): step in one texel because the bitmaps are padded on all sides with a blank strip of pixels
    d_texel := 1 / cast(v2) bitmap.dimension
    min_uv := 0 + d_texel
    max_uv := 1 - d_texel
    
    max := min + V4(x_axis + y_axis, z_bias)
    
    premultiplied_color := store_color(color)
    c := v4_to_rgba(premultiplied_color)
    
    ////////////////////////////////////////////////
    
    p0 := min
    p1 := v4{min.x, max.y, max.z, max.w}
    p2 := max
    p3 := v4{max.x, min.y, min.z, min.w}
    
    t0 := min_uv
    t1 := v2{min_uv.x, max_uv.y}
    t2 := max_uv
    t3 := v2{max_uv.x, min_uv.y}
    
    push_quad(group, bitmap, p0, p1, p2, p3, t0, t1, t2, t3, c, c, c, c)
}

push_light :: proc (group: ^RenderGroup, p: v3, radius: f32, color := v3{1, 1, 1}, emission: f32, light_index_store: ^u32) {
    push_cube_raw(group, &group.commands.white_bitmap, p + {0, 0, 0.5*radius}, radius, radius, V4(color, 1), emission, light_index_store) 
}

push_cube :: proc (group: ^RenderGroup, id: BitmapId, p: v3, radius, height: f32, color := v4{1, 1, 1, 1}, light_index_store: ^u32) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    
    // @note(viktor): the handle is filled out always at the end of the frame in manage_textures
    if bitmap == nil || bitmap.texture_handle == 0 {
        load_bitmap(group.assets, id, false)
    } else {
        push_cube_raw(group, bitmap, p, radius, height, color, light_index_store = light_index_store)
    }
}

push_cube_raw :: proc (group: ^RenderGroup, bitmap: ^Bitmap, p: v3, radius, height: f32, color := v4{1, 1, 1, 1}, emission: f32 = 0, light_index_store: ^u32) {
    assert(bitmap.width_over_height != 0)
    assert(bitmap.texture_handle    != 0)
    
    light_index_store := light_index_store
    if !group.lighting_enabled {
        light_index_store = nil
    }
    
    p := p
    p.xy -= radius
    p.z  -= height
    
    x := 2*radius * v3{1,0,0}
    y := 2*radius * v3{0,1,0}
    z :=   height * v3{0,0,1} // @todo This is stupid. It should be uniform.
    
    t0 := v2{0, 0}
    t1 := v2{1, 0}
    t2 := v2{1, 1}
    t3 := v2{0, 1}
    
    c := v4_to_rgba(store_color(color))
    
    light_index: u32
    light_count: u32
    if light_index_store != nil {
        light_count = 4
        if light_index_store^ != 0 {
            light_index = light_index_store^
        } else {
            // @todo "used" vs. "free"
            light_index = group.light_index
            light_index_store^ = light_index
        }
        
        group.light_index += light_count * 6
        
        box := LightingBox {
            min = p,
            max = p + x + y + z,
            transparency = 0,
            light_index = {
                (light_index + 0*light_count),
                (light_index + 1*light_count),
                (light_index + 2*light_count),
                (light_index + 3*light_count),
                (light_index + 4*light_count),
                (light_index + 5*light_count),
                (light_index + 6*light_count),
            },
        }
        append(&group.commands.light_boxes, box)
        
        if len(group.commands.light_points) == 0 {
            // @note Point 0 is never used.
            append_nothing(&group.commands.light_points) 
        }
        
        for surface_index in cast(u32) 0..<6 {
            surface := get_box_surface(box.min, box.max, surface_index)
            
            x_sub_count :: 2
            y_sub_count :: 2
            
            assert(x_sub_count * y_sub_count == light_count)
            for y_sub in 0..<y_sub_count {
                y_sub_ratio := -0.5 + cast(f32) y_sub
                for x_sub in 0..<x_sub_count {
                    x_sub_ratio := -0.5 + cast(f32) x_sub
                    
                    point_index := len(group.commands.light_points)
                    point := append_into(&group.commands.light_points)
                    
                    point.p = surface.p + x_sub_ratio * surface.half_width * surface.x_axis + y_sub_ratio * surface.half_height * surface.y_axis
                    
                    point.n = surface.n
                    point.reflect_color = 0.95 * color.rgb
                    
                    max_emission_value :: 10
                    
                    group.commands.emission_color_0[point_index] = max_emission_value * emission
                }
            }
        }
    }
    
    push_quad(group, bitmap, p   , p   +y,   p   +y+z, p     +z, t0, t1, t2, t3, c, c, c, c, emission, light_index + 0*light_count, light_count) // -x
    push_quad(group, bitmap, p +x, p +x  +z, p +x+y+z, p +x+y,   t0, t1, t2, t3, c, c, c, c, emission, light_index + 1*light_count, light_count) // +x
    push_quad(group, bitmap, p   , p     +z, p +x  +z, p +x,     t0, t1, t2, t3, c, c, c, c, emission, light_index + 2*light_count, light_count) // -y
    push_quad(group, bitmap, p +y, p +x+y,   p +x+y+z, p +  y+z, t0, t1, t2, t3, c, c, c, c, emission, light_index + 3*light_count, light_count) // +y
    push_quad(group, bitmap, p   , p +x,     p +x+y  , p   +y,   t0, t1, t2, t3, c, c, c, c, emission, light_index + 4*light_count, light_count) // -z
    push_quad(group, bitmap, p +z, p   +y+z, p +x+y+z, p +x  +z, t0, t1, t2, t3, c, c, c, c, emission, light_index + 5*light_count, light_count) // +z
}

push_rectangle :: proc { push_rectangle2, push_rectangle3 }
push_rectangle2 :: proc (group: ^RenderGroup, rect: Rectangle2, transform: Transform, color := v4{1,1,1,1}) {
    push_rectangle(group, Rect3(rect, 0, 0), transform, color)
}
push_rectangle3 :: proc (group: ^RenderGroup, rect: Rectangle3, transform: Transform, color := v4{1,1,1,1}) {
    p := project_with_transform(transform, rect.min)
    dimension := get_dimension(rect)
    
    x := dimension.x * v3{1,0,0}
    y := dimension.y * v3{0,1,0}
    
    t: v2 = 0.5
    
    color := color
    color = srgb_to_linear(color)
    color = store_color(color)
    c := v4_to_rgba(color)
    
    push_quad(group, &group.commands.white_bitmap, p, p+y, p+x+y, p+x, t, t, t, t, c, c, c, c)
}

push_rectangle_outline :: proc (group: ^RenderGroup, rec: Rectangle2, transform: Transform, color := v4{1,1,1,1}, thickness: v2 = 0.1) {
    rec := Rect3(rec, 0, 0)
    dimension := get_dimension(rec)
    
    p := rec.min
    x := dimension.x * v3{1, 0, 0}
    y := dimension.y * v3{0, 1, 0}
    
    half_thickness := thickness * 0.5
    
    horizontal_thickness := v3{half_thickness.x,  half_thickness.y, 0}
    vertical_thickness   := v3{half_thickness.x, -half_thickness.y, 0}
    
    // Bottom and Top
    push_rectangle3(group, add_radius(rectangle_min_dimension(p,   x), horizontal_thickness), transform, color)
    push_rectangle3(group, add_radius(rectangle_min_dimension(p+y, x), horizontal_thickness), transform, color)
    
    // Left and Right
    push_rectangle3(group, add_radius(rectangle_min_dimension(p,   y), vertical_thickness), transform, color)
    push_rectangle3(group, add_radius(rectangle_min_dimension(p+x, y), vertical_thickness), transform, color)
}

push_volume_outline :: proc (group: ^RenderGroup, rec: Rectangle3, transform: Transform, color:= v4{1,1,1,1}, thickness: f32 = 0.1) {
    max := project_with_transform(transform, rec.max)
    min := project_with_transform(transform, rec.min)
    
    p     := V4(min, 0)
    delta := V4(max, 0) - p
    
    x := delta * v4{1, 0, 0, 0}
    y := delta * v4{0, 1, 0, 0}
    z := delta * v4{0, 0, 1, 0}
    
    c := v4_to_rgba(store_color(color))
    
    bitmap := &group.commands.white_bitmap
    
    push_line_segment(group, bitmap, p,     p+x, c, c, thickness)
    push_line_segment(group, bitmap, p+x+z, p+x, c, c, thickness)
    push_line_segment(group, bitmap, p+x+y, p+x, c, c, thickness)
    
    push_line_segment(group, bitmap, p,     p+y, c, c, thickness)
    push_line_segment(group, bitmap, p+x+y, p+y, c, c, thickness)
    push_line_segment(group, bitmap, p+y+z, p+y, c, c, thickness)
    
    push_line_segment(group, bitmap, p,     p+z, c, c, thickness)
    push_line_segment(group, bitmap, p+x+z, p+z, c, c, thickness)
    push_line_segment(group, bitmap, p+y+z, p+z, c, c, thickness)
    
    push_line_segment(group, bitmap, p+y+z, p+x+y+z, c, c, thickness)
    push_line_segment(group, bitmap, p+x+z, p+x+y+z, c, c, thickness)
    push_line_segment(group, bitmap, p+x+y, p+x+y+z, c, c, thickness)
}

////////////////////////////////////////////////

store_color :: proc (color: v4) -> v4 {
    result := color
    result.rgb *= result.a
    return result
}

////////////////////////////////////////////////

get_used_bitmap_dim :: proc (group: ^RenderGroup, bitmap: Bitmap, transform: Transform, height: f32, offset := v3{}, use_alignment := true, x_axis := v2{1,0}, y_axis := v2{0,1}) -> UsedBitmapDim {
    result: UsedBitmapDim
    result.size  = v2{bitmap.width_over_height, 1} * height
    result.align = use_alignment ? bitmap.align_percentage * result.size : 0
    result.p.z   = offset.z
    result.p.xy  = offset.xy - result.align * x_axis - result.align * y_axis
    
    result.basis = project_with_transform(transform, result.p)
    
    return result
}

project_with_transform :: proc (transform: Transform, p: v3) -> v3 {
    result := p + transform.offset
    return result
}

unproject_with_transform :: proc (group: ^RenderGroup, transform: RenderTransform, pixel_p: v2, world_z: f32) -> v3 {
    probe := V4(transform.p - world_z * transform.z, 1)
    probe = multiply(transform.projection.forward, probe)
    clip_z := probe.z / probe.w
    
    screen_center := group.screen_size * 0.5
    
    clip_p := V3(pixel_p - screen_center, 0)
    clip_p.xy *= 2 / group.screen_size
    clip_p.z = clip_z
    
    result := multiply(transform.projection.backward, clip_p)
    
    return result
}

get_camera_rectangle_at_distance :: proc (group: ^RenderGroup, distance_from_camera: f32) -> Rectangle3 {
    min := unproject_with_transform(group, group.game_cam, 0, distance_from_camera)
    max := unproject_with_transform(group, group.game_cam, group.screen_size, distance_from_camera)
    
    result := rectangle_min_max(min, max)
    
    return result
}

// @cleanup
get_camera_rectangle_at_target :: proc (group: ^RenderGroup) -> Rectangle3 {
    z: f32 = 8
    result := get_camera_rectangle_at_distance(group, z)
    return result
}

fit_camera_distance_to_half_dim :: proc (focal_length, monitor_half_dim_in_meters: f32, half_dim_in_meters: $V) -> V {
    result := focal_length * (half_dim_in_meters / monitor_half_dim_in_meters)
    return result
}

////////////////////////////////////////////////

lighting_test :: proc (group: ^RenderGroup, solution: ^LightingSolution) {
    timed_function()
    
    commands := group.commands
    clear(&solution.surfaces)
    
    for box in commands.light_boxes {
        for box_surface_index in cast(u32) 0..<6 {
            box_surface := get_box_surface(box.min, box.max, box_surface_index)
            
            surface := LightingSurface {
                p = box_surface.p,
                n = box_surface.n,
                transparency = box.transparency,
                width  = 2 * box_surface.half_width,
                height = 2 * box_surface.half_height,
                x_axis = box_surface.x_axis,
                y_axis = box_surface.y_axis,
                light_index = box.light_index[box_surface_index],
                light_count = box.light_index[box_surface_index+1] - box.light_index[box_surface_index],
            }
            
            append(&solution.surfaces, surface)
        }
    }
    
    point_count := cast(u32) len(commands.light_points)
    solution.points           = commands.light_points[:]
    solution.emission_color_0 = commands.emission_color_0[:point_count]
    
    {
        debug_data_block("Renderer")
        debug_data_block("Lighting")
        
        box_count := cast(u32) len(commands.light_boxes)
        debug_record_value(&box_count,   "Light Boxes")
        debug_record_value(&point_count, "Light Points")
    }
    
    // @speed Just ping-pong these if we end up using it!
    copy(solution.last_direction[:point_count], solution.average_direction_to_light[:])
    zero_slice(solution.average_direction_to_light[:point_count])
    
    compute_light_propagation(solution)
    
    copy(solution.last_emission[:point_count], solution.emission_color_0[:])
}

compute_light_propagation :: proc (solution: ^LightingSolution) {
    timed_function()
    
    ////////////////////////////////////////////////
    
    // @todo Before moving on, be sure to index 
    // allocation management in the renderer!!!
    
    ////////////////////////////////////////////////
    
    LightingIterationCount = clamp(LightingIterationCount, 1, 32)
    ray_count := 64
    
    light_retention: f32 = 0.5
    min_emission: f32 = 0 // @todo Tune this to something higher than 0?
    
    source_emission_color      := solution.emission_color_0[:]
    destination_emission_color := solution.emission_color_1[:]
    
    for _ in 0..<LightingIterationCount {
        light_power := (1.0 - light_retention) / cast(f32) ray_count
        for point_index in 1..<len(solution.points) { // @note Point 0 is never used.
            point := &solution.points[point_index]
            emission_color := source_emission_color[point_index]
            
            retained_color := emission_color
            
            if (emission_color.r + emission_color.g + emission_color.b) > min_emission {
                emission_color *= point.reflect_color
                
                series := seed_random_series(1234)
                for _ in 0..<ray_count {
                    emission_direction := sample_hemisphere(&series, point.n)
                    
                    ray_p, hit_index := cast_ray(solution, point_index, point.p, emission_direction)
                    
                    if hit_index < len(solution.surfaces) {
                        hit_surface := &solution.surfaces[hit_index]
                        
                        closest_distance_squared: f32 = +Infinity
                        closest_point_index: u32
                        for test_index in hit_surface.light_index..<hit_surface.light_index+hit_surface.light_count {
                            // @todo Day 419: Moving to another room from the starting room triggers this assert, the test_index is larger than the actual point count(but not too large for the array itself).
                            test := solution.points[test_index]
                            distance_squared := length_squared(test.p - ray_p)
                            
                            if closest_distance_squared > distance_squared {
                                closest_distance_squared = distance_squared
                                closest_point_index = test_index
                            }
                        }
                        
                        if closest_point_index != 0 {
                            // @todo inline
                            accumulate_sample :: proc (point: ^LightingPoint, destination_emission_color: ^v3, average_direction_to_light: ^v3, light_color: v3, light_power: f32, normal_to_light: v3) -> v3 {
                                angular_falloff := clamp01(dot(point.n, normal_to_light))
                                
                                power  := light_power * angular_falloff
                                
                                weight := power * length(light_color)
                                result := power * light_color
                                
                                destination_emission_color^ += result
                                average_direction_to_light^ += weight * normal_to_light
                                
                                return result
                            }
                            
                            retained_color -= accumulate_sample(&solution.points[closest_point_index], &destination_emission_color[closest_point_index], &solution.average_direction_to_light[closest_point_index], emission_color, light_power, -emission_direction)
                        }
                    }
                }
            }
            
            destination_emission_color[point_index] += retained_color
        }
        
        for point_index in 1..<len(solution.points) { // @note Point 0 is never used.
            source_emission_color[point_index] = destination_emission_color[point_index]
            destination_emission_color[point_index] = 0
        }
        
        if ray_count > 8 {
            ray_count /= 2
        }
    }
    
    last_emission  := solution.last_emission[:]
    last_direction := solution.last_direction[:]
    if !solution.last_is_valid {
        solution.last_is_valid = true
        last_emission  = solution.emission_color_0[:]
        last_direction = solution.average_direction_to_light[:]
    }
    
    for point_index in 1..<len(solution.points) { // @note Point 0 is never used.
        t :: 1. / 10.
        solution.emission_color_0[point_index]           = linear_blend(last_emission[point_index],  solution.emission_color_0[point_index], t)
        solution.average_direction_to_light[point_index] = normalize_or_zero(linear_blend(last_direction[point_index], normalize_or_zero(solution.average_direction_to_light[point_index]), t))
    }
}

sample_hemisphere :: proc (series: ^RandomSeries, n: v3) -> v3 {
    // @todo Better hemisphere sampling, probably!
    result := normalize_or_zero(random_bilateral(series, v3))
    
    if dot(result, n) < 0 {
        result = -result
    }
    
    return result
}

cast_ray :: proc (solution: ^LightingSolution, skip_index: int, ray_origin, ray_direction: v3) -> (v3, int) {
    result_index := len(solution.surfaces)
    result_p: v3
    
    closest_hit := +Infinity
    for &surface, surface_index in solution.surfaces {
        if surface_index != skip_index {
            ray_surface_n := dot(ray_direction, surface.n)
            
            if ray_surface_n < -0.001 {
                plane_to_origin := ray_origin - surface.p
                
                d := dot(surface.n, plane_to_origin)
                t := -d / ray_surface_n
                
                if t > 0 && closest_hit > t {
                    ray_point := plane_to_origin + t * ray_direction
                    
                    x_check := 2 * dot(ray_point, surface.x_axis)
                    y_check := 2 * dot(ray_point, surface.y_axis)
                    
                    if x_check >= -surface.width  && x_check <= surface.width &&
                       y_check >= -surface.height && y_check <= surface.height {
                        closest_hit = t
                        result_index = surface_index
                    }
                }
            }
        }
    }
    
    result_p = ray_origin + closest_hit * ray_direction
    return result_p, result_index
}

////////////////////////////////////////////////

render_lighting_points :: proc (group: ^RenderGroup, solution: ^LightingSolution, textures: ^LightingTextures) {
    timed_function()
    
    bitmap := &group.commands.white_bitmap
    
    element_width  := cast(f32) 0.25
    element_height := cast(f32) 0.25
    
    for surface in solution.surfaces {
        for point_index in surface.light_index..<surface.light_index + surface.light_count {
            point := &solution.points[point_index]
            
            p              := point.p
            x_axis         := surface.x_axis
            y_axis         := surface.y_axis
            emission_color := solution.emission_color_0[point_index]
            
            x := 0.5 * element_width  * x_axis
            y := 0.5 * element_height * y_axis
            
            emission := clamp01(emission_color)
            c := v4_to_rgba(V4(emission, surface.transparency))
            
            push_quad(group, bitmap, p-x-y, p+x-y, p+x+y, p-x+y, 0,0,0,0, c,c,c,c)
        }
    }
}

push_lighting_values :: proc (group: ^RenderGroup, solution: ^LightingSolution, textures: ^LightingTextures) {
    timed_function()
    
    for point_index in 0..<len(solution.points) {
        p := solution.points[point_index].p
        c := solution.emission_color_0[point_index]
        d := solution.average_direction_to_light[point_index]
        
        c.r *= sign(d.z)
        d.z *= sign(d.z)
        
        textures.values[point_index] = { p, c, d.xy }
    }
    
    push_lighting(group, textures)
}

LightBoxSurface :: struct {
    p: v3,
    n: v3,
    x_axis: v3,
    y_axis: v3,
    half_width:  f32,
    half_height: f32,
}

get_box_surface :: proc (min, max: v3, surface_index: u32) -> LightBoxSurface {
    result: LightBoxSurface
    
    axis     := surface_index >> 1
    positive := cast(bool) (surface_index & 1)
    
    /* @note:
    A P     x axis     y axis
    0 0    0,-1, 0    0, 0, 1
    0 1    0, 1, 0    0, 0, 1
    
    1 0    0, 0,-1    1, 0, 0
    1 1    0, 0, 1    1, 0, 0
    
    2 0   -1, 0, 0    0, 1, 0
    2 1    1, 0, 0    0, 1, 0
    */
    
    min_corner := min
    max_corner := max
    
    if positive {
        result.n[axis] = 1
        min_corner[axis] = max_corner[axis]
    } else {
        result.n[axis] = -1
        max_corner[axis] = min_corner[axis]
    }
    
    result.x_axis[(axis+1) % 3] = positive ? 1 : -1
    result.y_axis[(axis+2) % 3] = 1
    
    span := max_corner - min_corner
    width  := abs(dot(result.x_axis, span))
    height := abs(dot(result.y_axis, span))
    
    result.p = linear_blend(min_corner, max_corner, .5)
    result.half_width  = .5 * width
    result.half_height = .5 * height
    
    return result
}
