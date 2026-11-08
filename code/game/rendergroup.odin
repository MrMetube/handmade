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
    
    white_bitmap: Bitmap,
}

RenderGroup :: struct {
    assets:        ^Assets,
    generation_id: AssetGenerationId,
    
    commands: ^RenderCommands,
    
    screen_size: v2,
    
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
    
    debug_light_p: v3,
}

TexturedQuads :: struct {
    setup: RenderSetup,
    
    quad_count:    u32,
    bitmap_offset: u32,
}

@(common)
Lighting :: struct {
    voxel_min_corner:        v3,
    inverse_voxel_dimension: v3,
    
    t:      ^type_of(LightingTextures{}.t),
    lookup: ^type_of(LightingTextures{}.lookup),
}

@(common, shader)
TexturedVertex :: struct {
    p:        v4,
    n:        PackedNormal,
    uv:       PackedUV,
    color:    Color,
    emission: f32,
    
    // @todo Doesn't need to be per-vertex - move this into a its own per-primitive buffer.
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

init_render_group :: proc (group: ^RenderGroup, assets: ^Assets, commands: ^RenderCommands, generation_id: AssetGenerationId) {
    group ^= {
        assets   = assets,
        commands = commands,
        
        screen_size   = cast(v2) commands.dimension,
        generation_id = generation_id,
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

push_lighting :: proc (group: ^RenderGroup, source: ^LightingTextures, voxel_min_corner: v3, inverse_voxel_dimension: v3) {
    entry := push_render_entry(group, .Lighting)
    
    entry.lighting.t      = &source.t
    entry.lighting.lookup = &source.lookup
    
    entry.lighting.voxel_min_corner        = source.voxel_min_corner
    entry.lighting.inverse_voxel_dimension = source.inverse_voxel_dimension
}

push_camera :: proc (group: ^RenderGroup, flags: Camera_Flags, x := v3{1,0,0}, y := v3{0,1,0}, z := v3{0,0,1}, p := v3{0,0,0}, focal_length: f32 = 1, near_clip_plane: f32 = 0.1, far_clip_plane: f32 = 100, fog := false, clip_alpha := true, debug_light_p: v3 = 0) {
    aspect_width_over_height := safe_ratio_1(cast(f32) group.commands.dimension.x, cast(f32) group.commands.dimension.y)
    
    setup := group.last_setup
    projection: m4_inv
    if .orthographic in flags {
        projection = orthographic_projection(aspect_width_over_height, near_clip_plane, far_clip_plane)
        
        setup.fog_direction = 0
    } else {
        projection = perspective_projection(aspect_width_over_height, focal_length, near_clip_plane, far_clip_plane)
    }
    
    fog := fog
    if .debug in flags { fog = false }
    
    if fog {
        setup.fog_direction = -z
        setup.fog_begin = 8
        setup.fog_end   = 25
    }
    
    setup.debug_light_p = debug_light_p
    
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
    
    if .debug not_in flags {
        setup.camera_p = p
    } else {
        group.debug_cam = group.game_cam
        setup.camera_p = p
    }
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

push_quad :: proc (group: ^RenderGroup, bitmap: ^Bitmap, p0, p1, p2, p3: v4, t0, t1, t2, t3: v2, c0, c1, c2, c3: Color, emission: f32 = 0) {
    entry := get_current_quads(group)
    entry.quad_count += 1
    
    // @todo(viktor): Just pass the normal down directly
    e10 := p1 - p0
    e20 := p2 - p0
    
    e10.z += e10.w
    e20.z += e20.w
    
    normal := cross(e10.xyz, e20.xyz)
    normal = normalize_or_zero(normal)
    
    n0, n1, n2, n3: v3 = normal, normal, normal, normal
    
    light_index: u32 = cast(u32) len(group.commands.vertex_buffer)
    light_count: u32 = 4
    
    append(&group.commands.quad_bitmap_buffer,  bitmap)
    // @note(viktor): reorder from quad ordering to triangle strip ordering
    // :QuadWinding:
    append(&group.commands.vertex_buffer, 
        { p3, pack(n3), pack(t3), c3, emission, light_index, light_count },
        { p0, pack(n0), pack(t0), c0, emission, light_index, light_count },
        { p2, pack(n2), pack(t2), c2, emission, light_index, light_count },
        { p1, pack(n1), pack(t1), c1, emission, light_index, light_count },
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
        cast(f32) normal.x / 511.0,
        cast(f32) normal.y / 511.0,
        cast(f32) normal.z / 511.0,
    }
    return result
}
unpack_uv :: proc (uv: PackedUV) -> v2 {
    result := v2 {
        cast(f32) uv.x / cast(f32) max(u16),
        cast(f32) uv.y / cast(f32) max(u16),
    }
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
    p1 :=   to_p - d 
    p2 :=   to_p + d 
    p3 := from_p + d 
    
    t0, t1, t2, t3: v2 = {0,0}, {1,0}, {1,1}, {0,1}
    c0, c1, c2, c3: Color = c0, c1, c1, c0
    
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
    
    // :QuadWinding:
    p0 := min
    p1 := v4{max.x, min.y, min.z, min.w}
    p2 := max
    p3 := v4{min.x, max.y, max.z, max.w}
    
    t0 := min_uv
    t1 := v2{max_uv.x, min_uv.y}
    t2 := max_uv
    t3 := v2{min_uv.x, max_uv.y}
    
    push_quad(group, bitmap, p0, p1, p2, p3, t0, t1, t2, t3, c, c, c, c)
}

push_light :: proc (group: ^RenderGroup, p: v3, radius: f32, color := v3{1, 1, 1}, emission: f32) {
    push_cube_raw(group, &group.commands.white_bitmap, p + {0, 0, 0.5*radius}, radius, radius, V4(color, 1), emission) 
}

push_cube :: proc (group: ^RenderGroup, id: BitmapId, p: v3, radius, height: f32, color := v4{1, 1, 1, 1}) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    
    // @note(viktor): the handle is filled out always at the end of the frame in manage_textures
    if bitmap == nil || bitmap.texture_handle == 0 {
        load_bitmap(group.assets, id, false)
    } else {
        push_cube_raw(group, bitmap, p, radius, height, color)
    }
}

push_cube_raw :: proc (group: ^RenderGroup, bitmap: ^Bitmap, p: v3, radius, height: f32, color := v4{1, 1, 1, 1}, emission: f32 = 0) {
    assert(bitmap.width_over_height != 0)
    assert(bitmap.texture_handle != 0)
    
    p := p
    n := p
    
    p.xy += radius
    n.xy -= radius
    n.z  -= height
    
    p0 := v4{n.x, n.y, n.z, 0}
    p2 := v4{n.x, p.y, n.z, 0}
    p4 := v4{p.x, n.y, n.z, 0}
    p6 := v4{p.x, p.y, n.z, 0}
    p1 := v4{n.x, n.y, p.z, 0}
    p3 := v4{n.x, p.y, p.z, 0}
    p5 := v4{p.x, n.y, p.z, 0}
    p7 := v4{p.x, p.y, p.z, 0}
    
    top_color := store_color(color)
    bot_color := v4{0, 0, 0, 1}
    
    ct := v4_to_rgba(V4(top_color.rgb * .75, top_color.a))
    cb := v4_to_rgba(V4(bot_color.rgb * .75, bot_color.a))
    
    bo := v4_to_rgba(bot_color)
    op := v4_to_rgba(top_color)
    
    ct = v4_to_rgba(store_color(color))
    cb = ct
    bo = ct
    op = ct 
    
    t0 := v2{0, 0}
    t1 := v2{1, 0}
    t2 := v2{1, 1}
    t3 := v2{0, 1}
    
    // :QuadWinding:
    push_quad(group, bitmap, p0, p1, p3, p2, t0, t1, t2, t3, cb, ct, ct, cb, emission)
    push_quad(group, bitmap, p0, p2, p6, p4, t0, t1, t2, t3, bo, bo, bo, bo, emission)
    push_quad(group, bitmap, p0, p4, p5, p1, t0, t1, t2, t3, cb, cb, ct, ct, emission)
    push_quad(group, bitmap, p7, p5, p4, p6, t0, t1, t2, t3, ct, ct, cb, cb, emission)
    push_quad(group, bitmap, p7, p6, p2, p3, t0, t1, t2, t3, ct, cb, cb, ct, emission)
    push_quad(group, bitmap, p7, p3, p1, p5, t0, t1, t2, t3, op, op, op, op, emission)
}

push_rectangle :: proc { push_rectangle2, push_rectangle3 }
push_rectangle2 :: proc (group: ^RenderGroup, rect: Rectangle2, transform: Transform, color := v4{1,1,1,1}) {
    push_rectangle(group, Rect3(rect, 0, 0), transform, color)
}
push_rectangle3 :: proc (group: ^RenderGroup, rect: Rectangle3, transform: Transform, color := v4{1,1,1,1}) {
    p := project_with_transform(transform, rect.min)
    dimension := get_dimension(rect)
    
    color := color
    color = srgb_to_linear(color)
    color = store_color(color)
    c := v4_to_rgba(color)
    
    p0 := V4(p, 0)
    p1 := V4(p + {dimension.x, 0, 0}, 0)
    p2 := V4(p + {dimension.x, dimension.y, 0}, 0)
    p3 := V4(p + {0, dimension.y, 0}, 0)
    
    t: v2 = 0.5
    push_quad(group, &group.commands.white_bitmap, p0, p1, p2, p3, t, t, t, t, c, c, c, c)
}

push_rectangle_outline :: proc { push_rectangle_outline2, push_rectangle_outline3 }
push_rectangle_outline2 :: proc (group: ^RenderGroup, rec: Rectangle2, transform: Transform, color := v4{1,1,1,1}, thickness: v2 = 0.1) {
    push_rectangle_outline(group, Rect3(rec, 0, 0), transform, color, thickness)
}
push_rectangle_outline3 :: proc (group: ^RenderGroup, rec: Rectangle3, transform: Transform, color:= v4{1,1,1,1}, thickness: v2 = 0.1) {
    center         := get_center(rec)
    half_dimension := get_dimension(rec) * 0.5
    
    center_top    := center + {0, half_dimension.y, 0}
    center_bottom := center - {0, half_dimension.y, 0}
    center_left   := center - {half_dimension.x, 0, 0}
    center_right  := center + {half_dimension.x, 0, 0}
    
    half_thickness := thickness * 0.5
    
    half_dim_horizontal := v3{half_dimension.x+half_thickness.x, half_thickness.y, half_dimension.z}
    half_dim_vertical   := v3{half_thickness.x, half_dimension.y-half_thickness.y, half_dimension.z}
    
    // Top and Bottom
    push_rectangle(group, rectangle_center_half_dimension(center_top,    half_dim_horizontal), transform, color)
    push_rectangle(group, rectangle_center_half_dimension(center_bottom, half_dim_horizontal), transform, color)
    
    // Left and Right
    push_rectangle(group, rectangle_center_half_dimension(center_left,  half_dim_vertical), transform, color)
    push_rectangle(group, rectangle_center_half_dimension(center_right, half_dim_vertical), transform, color)
}

push_volume_outline :: proc (group: ^RenderGroup, rec: Rectangle3, transform: Transform, color:= v4{1,1,1,1}, thickness: f32 = 0.1) {
    p := project_with_transform(transform, rec.max)
    n := project_with_transform(transform, rec.min)
    
    p0 := v4{n.x, n.y, n.z, 0}
    p1 := v4{n.x, n.y, p.z, 0}
    p2 := v4{n.x, p.y, n.z, 0}
    p3 := v4{n.x, p.y, p.z, 0}
    p4 := v4{p.x, n.y, n.z, 0}
    p5 := v4{p.x, n.y, p.z, 0}
    p6 := v4{p.x, p.y, n.z, 0}
    p7 := v4{p.x, p.y, p.z, 0}
    
    color := color
    color = store_color(color)
    c := v4_to_rgba(color)
    
    bitmap := &group.commands.white_bitmap
    
    push_line_segment(group, bitmap, p0, p1, c, c, thickness)
    push_line_segment(group, bitmap, p0, p2, c, c, thickness)
    push_line_segment(group, bitmap, p0, p4, c, c, thickness)
    
    push_line_segment(group, bitmap, p3, p1, c, c, thickness)
    push_line_segment(group, bitmap, p3, p2, c, c, thickness)
    push_line_segment(group, bitmap, p3, p7, c, c, thickness)
    
    push_line_segment(group, bitmap, p5, p1, c, c, thickness)
    push_line_segment(group, bitmap, p5, p4, c, c, thickness)
    push_line_segment(group, bitmap, p5, p7, c, c, thickness)
    
    push_line_segment(group, bitmap, p6, p2, c, c, thickness)
    push_line_segment(group, bitmap, p6, p4, c, c, thickness)
    push_line_segment(group, bitmap, p6, p7, c, c, thickness)
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

light_element_limit :: 16 * 1024

// @volatile see zbias.slang
@(common)
lookup_dimensions :: uv3 { 32, 32, 32 }
max_light_power :: 10.0

LightingElement :: struct {
    // @note Static information.
    p: v3,
    n: v3,
    width, height:  f32,
    x_axis, y_axis: v3,
    reflect_color:    v3,
    transparency: f32,
    
    // @note Propagation
    emission_color:       v3,
    next_emission_color:  v3,
    
    // @note Gather
    average_direction_to_light: v3,
    
    pack_index: u32,
}

LightingSolution :: struct {
    elements: [dynamic; light_element_limit] LightingElement,
    textures: LightingTextures,
}

LightingTextures :: struct {
    t:      [light_element_limit] LightingTexel,
    lookup: [lookup_dimensions.z] [lookup_dimensions.y] [lookup_dimensions.x] u16,
    // @volatile see zbias.slang
    voxel_min_corner:        v3,
    voxel_dimension:         v3,
    inverse_voxel_dimension: v3,
}

@(common, shader)
LightingTexel :: struct {
    p:    v3,    // this could be a smaller, relative position/offset in a voxel than a v4
    next: u32,
    d:    v3,
    c:    Color, // a is unused
}

lighting_test :: proc (group: ^RenderGroup, solution: ^LightingSolution) {
    timed_function()
    
    extract_reflectors_from_quads(group, solution)
    compute_light_propagation(solution)
    gather_final_lighting(solution)
}

extract_reflectors_from_quads :: proc (group: ^RenderGroup, solution: ^LightingSolution) {
    max_emission_value :: 10
    
    commands := group.commands
    quads    := group.current_quads
    
    elements := &solution.elements
    clear(elements)
    
    x_sub_count :: 2
    y_sub_count :: 2
    assert(x_sub_count * y_sub_count * cast(int) quads.quad_count <= cap(solution.elements))
    
    bitmaps  := commands.quad_bitmap_buffer[quads.bitmap_offset:][:quads.quad_count]
    vertices := commands.vertex_buffer[quads.bitmap_offset*4:][:quads.quad_count*4]
    
    for _, quad_index in bitmaps {
        // :QuadWinding:
        ve0 := &vertices[quad_index*4 + 0]
        ve1 := &vertices[quad_index*4 + 1]
        ve2 := &vertices[quad_index*4 + 3]
        ve3 := &vertices[quad_index*4 + 2]
        
        ve0p := ve0.p.xyz + {0, 0, ve0.p.w}
        ve1p := ve1.p.xyz + {0, 0, ve1.p.w}
        ve2p := ve2.p.xyz + {0, 0, ve2.p.w}
        ve3p := ve3.p.xyz + {0, 0, ve3.p.w}
        
        span01 := ve1p - ve0p
        span03 := ve3p - ve0p
        
        x_axis := span01
        y_axis := span03
        
        width  := length(x_axis)
        height := length(y_axis)
        
        x_axis = safe_ratio_0(x_axis, width)
        y_axis = safe_ratio_0(y_axis, height) 
        
        sub_width  := width  / x_sub_count
        sub_height := height / y_sub_count
        
        ve0.light_count = x_sub_count * y_sub_count
        ve1.light_count = x_sub_count * y_sub_count
        ve2.light_count = x_sub_count * y_sub_count
        ve3.light_count = x_sub_count * y_sub_count
        
        pack_index := ve0.light_index
        for y_sub in 0..<y_sub_count {
            for x_sub in 0..<x_sub_count {
                element := append_into(elements)
                element^ = {}
                
                element.p = ve0p + 
                    (cast(f32) x_sub + 0.5) * sub_width  * x_axis + 
                    (cast(f32) y_sub + 0.5) * sub_height * y_axis
                
                element.width  = sub_width
                element.height = sub_height
                element.x_axis = x_axis
                element.y_axis = y_axis
                
                element.n = unpack_normal(ve0.n)
                
                color := rgba_to_v4(ve0.color)
                element.reflect_color  = 0.95 * color.rgb
                element.transparency   = color.a
                element.emission_color = max_emission_value * ve0.emission
                
                element.pack_index = pack_index
                pack_index += 1
            }
        }
    }
}

compute_light_propagation :: proc (solution: ^LightingSolution) {
    LightingIterationCount = clamp(LightingIterationCount, 1, 16)
    ray_count := 64
    light_power := 1.0 / cast(f32) ray_count
    
    min_emission: f32 = 0 // @todo Tune this to something higher than 0?
    
    for _ in 0..<LightingIterationCount {
        for &emitter, emitter_index in solution.elements {
            if (emitter.emission_color.r + emitter.emission_color.g + emitter.emission_color.b) > min_emission {
                emission_color := emitter.emission_color * emitter.reflect_color
                
                series := seed_random_series(1234)
                for _ in 0..<ray_count {
                    emission_direction := sample_hemisphere(&series, emitter.n)
                    
                    _, hit_index := cast_ray(solution.elements[:], emitter_index, emitter.p, emission_direction)
                    
                    if hit_index != len(solution.elements) {
                        hit := &solution.elements[hit_index]
                        accumulate_sample(hit, emission_color, light_power, -emission_direction)
                    }
                }
            }
        }
        
        sky_ray_count :: 32
        sky_color := v4 { .79, .95, 1.0,  1.0 / cast(f32) (sky_ray_count * LightingIterationCount) }
        sun_color := v4 { 1.0, .99, .73, 10.0 / cast(f32) LightingIterationCount }
        sun_direction := normalize_or_zero(v3 {1,1,1})
        
        for &reflector, element_index in solution.elements {
            series := seed_random_series(1234)
            for _ in 0..<sky_ray_count {
                ray_direction := sample_hemisphere(&series, reflector.n)
                
                _, hit_index := cast_ray(solution.elements[:], element_index, reflector.p, ray_direction)
                
                if hit_index == len(solution.elements) {
                    // @note Add some skylight here.
                    accumulate_sample(&reflector, sky_color.rgb, sky_color.a, ray_direction)
                }
            }
            
            {
                _, hit_index := cast_ray(solution.elements[:], element_index, reflector.p, sun_direction)
                
                if hit_index == len(solution.elements) {
                    // @note Add some sunlight here.
                    accumulate_sample(&reflector, sun_color.rgb, sun_color.a, sun_direction)
                }
            }
            
            reflector.emission_color += reflector.next_emission_color
            reflector.next_emission_color = 0
        }
        
        ray_count /= 2
    }
}

accumulate_sample :: proc (element: ^LightingElement, light_color: v3, light_power: f32, normal_to_light: v3) {
    angular_falloff := clamp01(dot(element.n, normal_to_light))
    
    power  := light_power * angular_falloff
    weight := power * length(light_color)
    
    element.next_emission_color        += power  * light_color
    element.average_direction_to_light += weight * normal_to_light
}

gather_final_lighting :: proc (solution: ^LightingSolution) {
    for &element in solution.elements {
        element.average_direction_to_light = normalize_or_zero(element.average_direction_to_light)
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

cast_ray :: proc (elements: [] LightingElement, skip_index: int, ray_origin, ray_direction: v3) -> (v3, int) {
    result_color := cast(v3) 0 // @todo Need a skylight method that works with our propagation.
    result_index := len(elements)
    
    closest_hit := +Infinity
    for &element, element_index in elements {
        if element_index != skip_index {
            ray_element_n := dot(ray_direction, element.n)
            
            if ray_element_n < -0.001 {
                plane_to_origin := ray_origin - element.p
                
                d := dot(element.n, plane_to_origin)
                t := -d / ray_element_n
                
                if t > 0 && closest_hit > t {
                    ray_point := plane_to_origin + t * ray_direction
                    
                    x_check := 2 * dot(ray_point, element.x_axis)
                    y_check := 2 * dot(ray_point, element.y_axis)
                    
                    if x_check >= -element.width  && x_check <= element.width &&
                       y_check >= -element.height && y_check <= element.height {
                        closest_hit  = t
                        result_color = element.emission_color
                        result_index = element_index
                    }
                }
            }
        }
    }
    
    return result_color, result_index
}

////////////////////////////////////////////////

render_lighting :: proc (group: ^RenderGroup, solution: ^LightingSolution, textures: ^LightingTextures) {
    if false && textures != nil {
        render_texture_debug(group, solution, textures)
        // output_lighting_textures(group, solution, textures)
    } else {
        render_lighting_quads(group, solution)
    }
}

render_lighting_quads :: proc (group: ^RenderGroup, solution: ^LightingSolution) {
    timed_function()
    
    for element in solution.elements {
        ex := (0.5 * element.width  - 0.03) * element.x_axis
        ey := (0.5 * element.height - 0.03) * element.y_axis
        
        // :QuadWinding:
        ps: [4] v4
        ps[0].xyz = element.p - ex - ey
        ps[1].xyz = element.p + ex - ey
        ps[2].xyz = element.p + ex + ey
        ps[3].xyz = element.p - ex + ey
        
        emission := clamp01(element.emission_color)
        c := v4_to_rgba(V4(emission, element.transparency))
        
        bitmap := &group.commands.white_bitmap
        
        push_quad(group, bitmap, **ps, 0,0,0,0, c,c,c,c)
    }
}

render_texture_debug :: proc (group: ^RenderGroup, solution: ^LightingSolution, textures: ^LightingTextures) {
    timed_function()
    
    for z in 0..<lookup_dimensions.z {
        for y in 0..<lookup_dimensions.y {
            for x in 0..<lookup_dimensions.x {
                index := textures.lookup[z][y][x]
                
                if index != 0 {
                    c := v4 {0,0,0, 1}
                    count: f32
                    for index != 0 {
                        t := textures.t[index]
                        defer index = cast(u16) t.next
                        
                        unpacked := rgba_to_v4(t.c)
                        unpacked = decode_light_with_power(unpacked)
                        c += unpacked
                        count += 1
                    }
                    
                    c.rgb *= 1 / count
                    p := textures.voxel_min_corner + textures.voxel_dimension * (cast(v3) uv3{x, y, z} + 0.5)
                    
                    push_cube_raw(group, &group.commands.white_bitmap, p, .1, .1, c)
                }
            }
        }
    }
}

decode_light_with_power :: proc (encoded: v4) -> v4 {
    result: v4
    result.rgb = encoded.rgb * max_light_power * encoded.a
    result.a   = 1
    return result
}

output_lighting_textures :: proc (group: ^RenderGroup, solution: ^LightingSolution, textures: ^LightingTextures) {
    timed_function()
    
    textures.lookup = 0
    
    bounds: Rectangle3
    dimension: v3
    inv_voxel_dimension: v3
    if false {
        bounds = rectangle_inverted_infinity(Rectangle3)
        for element in solution.elements {
            bounds = get_union_with_point(bounds, element.p)
        }
        
        bounds    = add_radius(bounds, 0.1)
        dimension = get_dimension(bounds)
        
        inv_voxel_dimension = cast(v3) lookup_dimensions / dimension
        
        pack_index: u32
        for element in solution.elements {
            voxel_p     := (element.p - bounds.min) * inv_voxel_dimension
            voxel_index := truncate(u32, voxel_p)
            
            lookup_at := &textures.lookup[voxel_index.z][voxel_index.y][voxel_index.x]
            
            light_power := length(element.emission_color.rgb)
            emission_color: v4
            if light_power > 0 {
                light_color := element.emission_color.rgb / light_power
                emission_color = V4(light_color, clamp01(light_power / max_light_power))
            }
            c := v4_to_rgba(emission_color)
            
            pack_index += 1
            
            t := &textures.t[pack_index]
            t.p = element.p
            t.c = c
            t.d.xyz = element.average_direction_to_light
            
            t.next     = cast(u32) lookup_at^
            lookup_at^ = cast(u16) pack_index
        }
    } else {
        for element, element_index in solution.elements {
            light_power := length(element.emission_color.rgb)
            emission_color: v4
            if light_power > 0 {
                light_color := element.emission_color.rgb / light_power
                emission_color = V4(light_color, clamp01(light_power / max_light_power))
            }
            c := v4_to_rgba(emission_color)
            
            
            pack_index := element.pack_index
            t := &textures.t[pack_index]
            t.p = element.p
            t.c = c
            t.d.xyz = element.average_direction_to_light
        }
    }
    
    {
        lookup_range := rectangle_min_dimension(iv3{0,0,0}, cast(iv3) lookup_dimensions-1)
        for z in 0..<cast(i32) lookup_dimensions.z {
            for y in 0..<cast(i32) lookup_dimensions.y {
                for x in 0..<cast(i32) lookup_dimensions.x {
                    index := &textures.lookup[z][y][x]
                    
                    if index^ == 0 {
                        neighbour_range := rectangle_min_max(iv3{-1,-1,-1}, iv3{1,1,1})
                        
                        // @todo clamp?
                        neighbour_range = get_intersection(add_offset(lookup_range, -iv3{x,y,z}), neighbour_range)
                        
                        neighbour: u16
                        fill: for dz in neighbour_range.min.z ..= neighbour_range.max.z {
                            for dy in neighbour_range.min.y ..= neighbour_range.max.y {
                                for dx in neighbour_range.min.x ..= neighbour_range.max.x {
                                    neighbour = textures.lookup[z+dz][y+dy][x+dx]
                                    if neighbour != 0 { break fill }
                                }
                            }
                        }
                        
                        index^ = neighbour
                    }
                }
            }
        }
    }
    
    textures.voxel_min_corner        = bounds.min
    textures.voxel_dimension         = dimension / cast(v3) lookup_dimensions
    textures.inverse_voxel_dimension = inv_voxel_dimension
    
    push_lighting(group, textures, textures.voxel_min_corner, textures.inverse_voxel_dimension)
}