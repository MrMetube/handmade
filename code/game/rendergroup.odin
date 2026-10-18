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
    voxel_min_corner:             v3,
    voxel_inverse_cell_dimension: v3,
    
    pnext:  ^type_of(LightingTextures{}.pnext),
    c:      ^type_of(LightingTextures{}.c),
    lookup: ^type_of(LightingTextures{}.lookup),
}

@(common, shader)
TexturedVertex :: struct {
    p:     v4,
    n:     PackedNormal `shader:"u32"`,
    uv:    PackedUV     `shader:"u32"`,
    color: Color        `shader:"u32"`,
    emission: f32,
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

push_lighting :: proc (group: ^RenderGroup, source: ^LightingTextures, voxel_min_corner: v3, voxel_inverse_cell_dimension: v3) {
    entry := push_render_entry(group, .Lighting)
    
    entry.lighting.pnext  = &source.pnext
    entry.lighting.c      = &source.c
    entry.lighting.lookup = &source.lookup
    
    entry.lighting.voxel_min_corner             = voxel_min_corner
    entry.lighting.voxel_inverse_cell_dimension = voxel_inverse_cell_dimension
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
    
    append(&group.commands.quad_bitmap_buffer,  bitmap)
    // @note(viktor): reorder from quad ordering to triangle strip ordering
    // :QuadWinding:
    append(&group.commands.vertex_buffer, 
        TexturedVertex {p3, pack(n3), pack(t3), c3, emission},
        TexturedVertex {p0, pack(n0), pack(t0), c0, emission},
        TexturedVertex {p2, pack(n2), pack(t2), c2, emission},
        TexturedVertex {p1, pack(n1), pack(t1), c1, emission},
    )
}

@(common)
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
@(common)
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

LightingElement :: struct {
    // @note Static information.
    p: v3,
    n: v3,
    r: f32,
    reflect_c:    v3,
    transparency: f32,
    
    // @note Ambient occlusion.
    visibility: f32,
    shadow:     f32, // @note transient
    
    // @note Lighting
    front_emission_c: v3,
    back_emission_c:  v3,
    accumulated_c:    v3, // @note transient
    
    bitmap: ^Bitmap,
    ps: [4] v4,
    ts: [4] v2,
    cs: [4] Color,
}

LightingSolution :: struct {
    elements: [dynamic; 8192] LightingElement,
    textures: LightingTextures,
}

LightingTextures :: struct {
    pnext:  [8192] LightingTexel,                                                  /// p = 8192 * (3 * 4 + 4)
    c:      [8192] Color, // a is unsed                                            /// c = 8192 * 4
    lookup: [lookup_dimensions.z] [lookup_dimensions.y] [lookup_dimensions.x] u16, /// l = 32 * 32 * 32 * 2
    // @volatile see zbias.slang
    
    /// p
    /// c
    /// l
    /// (p + c + l) / 1024
    min_corner:          v3,
    voxel_dimension:     v3,
    inv_voxel_dimension: v3,
}

@(common)
lookup_dimensions :: uv3 { 32, 32, 32 }

@(common, shader)
LightingTexel :: struct {
    p:    v3,
    next: u32,
}

lighting_test :: proc (group: ^RenderGroup, solution: ^LightingSolution) {
    timed_function()
    
    elements := &solution.elements
    clear(elements)
    
    extract_reflectors_from_verts(group, solution)
    
    camera_p := group.last_setup.camera_p
        
    LightingIterationCount = clamp(LightingIterationCount, 1, 16)
    
    // @note Compute lighting
    rays: [8] v3
    for _ in 0..<LightingIterationCount {
        for &destination in elements {
            to_camera := camera_p - destination.p
            to_camera = normalize_or_zero(to_camera)
            
            accumulated: v3
            series := seed_random_series(1234)
            for &ray in rays {
                ray = normalize_or_zero(destination.n + random_bilateral(&series, v3))
            }
            closest_hit: [len(rays)] f32 = +Infinity
            
            for &source in elements {
                light_c  := source.reflect_c * source.front_emission_c
                
                to_light := source.p - destination.p 
                light_distance := length(to_light)
                if light_distance > 0 {
                    to_light *= 1.0 / light_distance
                    
                    ref_n := destination.n
                    diffuse_c  := cast(f32) 1
                    specular_c := 1.0 - diffuse_c
                    // specular_power := 1 + (15 * cast(f32) 1)
                    distance_falloff := 1 / (1 + square(light_distance))
                    
                    cos_angle            := clamp_01(dot(to_light, ref_n)) 
                    diffuse_contribution := distance_falloff * diffuse_c * cos_angle
                    
                    reflected             := -to_camera + 2 * dot(to_camera, ref_n) * ref_n
                    cos_reflected_angle   := clamp_01(dot(to_light, reflected))
                    // cos_reflected_angle   = power(cos_reflected_angle, specular_power)
                    specular_contribution := specular_c * cos_reflected_angle
                    
                    diffuse_light  := diffuse_contribution  * light_c
                    specular_light := specular_contribution * light_c
                    
                    total_light := diffuse_light + specular_light
                    result      := total_light
                    
                    for ray, ray_index in rays {
                        ray_source_n := dot(ray, source.n)
                        if ray_source_n < -0.001 {
                            point_on_plane_from_destination := source.p - destination.p
                            d     := -dot(source.n, point_on_plane_from_destination)
                            t_ray := -d / ray_source_n
                            
                            if t_ray > 0 && closest_hit[ray_index] > t_ray {
                                ray_point_on_plane := t_ray * ray
                                distance_squared   := length_squared(ray_point_on_plane - point_on_plane_from_destination)
                                
                                cone_r := 0.25 * t_ray
                                
                                if distance_squared < square(source.r + cone_r) {
                                    closest_hit[ray_index] = t_ray
                                    accumulated += result
                                }
                            }
                        }
                    }
                }
            }
            
            destination.accumulated_c = destination.visibility * accumulated
        }
        
        correction := 1 / cast(f32) (LightingIterationCount * len(rays))
        
        for &destination in elements {
            destination.front_emission_c += correction * destination.accumulated_c
        }
    }
}

// @placement
max_emission_value :: 10

extract_reflectors_from_quads :: proc (group: ^RenderGroup, solution: ^LightingSolution) {
    commands := group.commands
    quads    := group.current_quads
    
    elements := &solution.elements
    
    bitmaps  := commands.quad_bitmap_buffer[quads.bitmap_offset:][:quads.quad_count]
    vertices := commands.vertex_buffer[quads.bitmap_offset*4:][:quads.quad_count*4]
    
    for bitmap, quad_index in bitmaps {
        // :QuadWinding:
        ve0 := &vertices[quad_index*4 + 0]
        ve1 := &vertices[quad_index*4 + 1]
        ve2 := &vertices[quad_index*4 + 3]
        ve3 := &vertices[quad_index*4 + 2]
        
        ve0p := ve0.p.xyz + {0, 0, ve0.p.w}
        ve1p := ve1.p.xyz + {0, 0, ve1.p.w}
        ve2p := ve2.p.xyz + {0, 0, ve2.p.w}
        ve3p := ve3.p.xyz + {0, 0, ve3.p.w}
        
        span10 := ve1p - ve0p
        span20 := ve2p - ve0p
        span30 := ve3p - ve0p
        
        element := append_into(elements)
        element^ = {}
        
        element.p = ve0p + 0.5 * span20
        element.r = 0.75 * min(length(span30), length(span10))
        
        element.n = unpack_normal(ve0.n)
        color := rgba_to_v4(ve0.color)
        element.reflect_c        = 0.95 * color.rgb
        element.transparency     = color.a
        element.front_emission_c = max_emission_value * ve0.emission
        element.visibility       = 1
        
        element.bitmap = bitmap
        element.ps = { ve0.p, ve1.p, ve2.p, ve3.p }
        element.ts = { unpack_uv(ve0.uv), unpack_uv(ve1.uv), unpack_uv(ve2.uv), unpack_uv(ve3.uv) }
        element.cs = { ve0.color, ve1.color, ve2.color, ve3.color }
    }
}

extract_reflectors_from_verts :: proc (group: ^RenderGroup, solution: ^LightingSolution) {
    commands := group.commands
    quads    := group.current_quads
    
    elements := &solution.elements
    
    bitmaps  := commands.quad_bitmap_buffer[quads.bitmap_offset:][:quads.quad_count]
    vertices := commands.vertex_buffer[quads.bitmap_offset*4:][:quads.quad_count*4]
    
    for bitmap, quad_index in bitmaps {
        // :QuadWinding:
        vs := [4] TexturedVertex {
            vertices[quad_index*4 + 0],
            vertices[quad_index*4 + 1],
            vertices[quad_index*4 + 3],
            vertices[quad_index*4 + 2],
        }
        
        ps := [4] v3 {
            vs[0].p.xyz + {0, 0, vs[0].p.w},
            vs[1].p.xyz + {0, 0, vs[1].p.w},
            vs[2].p.xyz + {0, 0, vs[2].p.w},
            vs[3].p.xyz + {0, 0, vs[3].p.w},
        }
        
        span01 := ps[1] - ps[0]
        span03 := ps[3] - ps[0]
        
        r := 0.3 * min(length(span03), length(span01))
        
        for vertex_index in 0..<4 {
            element := append_into(elements)
            element^ = {}
            
            v := vs[vertex_index]
            
            switch vertex_index {
            case 0: element.p = ps[0] + 0.25 * span01 + 0.25 * span03
            case 1: element.p = ps[1] - 0.25 * span01 + 0.25 * span03
            case 2: element.p = ps[2] - 0.25 * span01 - 0.25 * span03
            case 3: element.p = ps[3] + 0.25 * span01 - 0.25 * span03
            }
            
            element.r = r
            
            element.n = unpack_normal(v.n)
            color := rgba_to_v4(v.color)
            element.reflect_c        = 0.95 * color.rgb
            element.transparency     = color.a
            element.front_emission_c = max_emission_value * v.emission
            element.visibility       = 1
            
            element.bitmap = bitmap
            element.ps = { vs[0].p, vs[1].p, vs[2].p, vs[3].p }
            element.ts = { unpack_uv(vs[0].uv), unpack_uv(vs[1].uv), unpack_uv(vs[2].uv), unpack_uv(vs[3].uv) }
            element.cs = { vs[0].color, vs[1].color, vs[2].color, vs[3].color }
        }
    }
}

render_lighting :: proc (group: ^RenderGroup, solution: ^LightingSolution, textures: ^LightingTextures) {
    if textures != nil {
        render_texture_debug(group, solution, textures)
        // output_lighting_textures(group, solution, textures)
    } else {
        if ShowReflectors {
            render_lighting_quads(group, solution)
        } else {
            render_lighting_verts(group, solution)
        }
    }
}

render_lighting_quads :: proc (group: ^RenderGroup, solution: ^LightingSolution) {
    timed_function()
    
    elements := &solution.elements
    
    for element in elements {
        ps := element.ps
        cs := element.cs
        bitmap := element.bitmap
        
        front_emission := clamp_01(element.front_emission_c)
        
        if ShowVisibility {
            front_emission = element.visibility
        }
        
        if ShowReflectors {
            bitmap = &group.commands.white_bitmap
            
            min: u32
            abs_n := abs_per_lane(element.n)
            if abs_n.x < abs_n.y {
                min = abs_n.x < abs_n.z ? 0 : 2
            } else {
                min = abs_n.y < abs_n.z ? 1 : 2
            }
            
            axis: v3
            axis[min] = 1
            
            ex := cross(axis, element.n)
            ey := -cross(ex, element.n)
            
            ex = normalize_or_zero(ex) * element.r
            ey = normalize_or_zero(ey) * element.r
            
            // :QuadWinding:
            ps[0].xyz = element.p + ex
            ps[1].xyz = element.p + ey
            ps[2].xyz = element.p - ex
            ps[3].xyz = element.p - ey
            ps[0].w = 0
            ps[1].w = 0
            ps[2].w = 0
            ps[3].w = 0
            
            c := v4_to_rgba(V4(front_emission, element.transparency))
            cs = c
        } else {
            cs[0] = v4_to_rgba(V4(front_emission * rgba_to_v4(cs[0]).rgb, rgba_to_v4(cs[0]).a))
            cs[1] = v4_to_rgba(V4(front_emission * rgba_to_v4(cs[1]).rgb, rgba_to_v4(cs[1]).a))
            cs[2] = v4_to_rgba(V4(front_emission * rgba_to_v4(cs[2]).rgb, rgba_to_v4(cs[2]).a))
            cs[3] = v4_to_rgba(V4(front_emission * rgba_to_v4(cs[3]).rgb, rgba_to_v4(cs[3]).a))
        }
        
        push_quad(group, bitmap, **ps, **element.ts,**cs)
    }
}

render_texture_debug :: proc (group: ^RenderGroup, solution: ^LightingSolution, textures: ^LightingTextures) {
    timed_function()
    
    for z in 0..<lookup_dimensions.z {
        for y in 0..<lookup_dimensions.y {
            for x in 0..<lookup_dimensions.x {
                index := textures.lookup[z][y][x]
                
                if false {
                    for index != 0 {
                        pnext := textures.pnext[index]
                        defer index = cast(u16) pnext.next
                        
                        p := pnext.p
                        c := rgba_to_v4(textures.c[index])
                        
                        push_cube_raw(group, &group.commands.white_bitmap, p, .1, .1, c)
                    }
                } else {
                    if index != 0 {
                        c: v4
                        count: f32
                        for index != 0 {
                                pnext := textures.pnext[index]
                                defer index = cast(u16) pnext.next
                                
                                c += rgba_to_v4(textures.c[index])
                                count += 1
                        }
                        
                        c *= 1 / count
                        p := textures.min_corner + textures.voxel_dimension * (cast(v3) uv3{x, y, z} + 0.5)
                        
                        push_cube_raw(group, &group.commands.white_bitmap, p, .1, .1, c)
                    }
                }
            }
        }
    }
}

render_lighting_verts :: proc (group: ^RenderGroup, solution: ^LightingSolution) {
    timed_function()
    
    elements := &solution.elements
    
    for element_index: int; element_index < len(elements); element_index += 4 {
        es := [4] LightingElement {
            elements[element_index+0],
            elements[element_index+1],
            elements[element_index+2],
            elements[element_index+3],
        }
        
        ps := es[0].ps
        cs := es[0].cs
        bitmap := es[0].bitmap
        
        front_emissions := [4] v3 {
            clamp_01(es[0].front_emission_c),
            clamp_01(es[1].front_emission_c),
            clamp_01(es[2].front_emission_c),
            clamp_01(es[3].front_emission_c),
        }
        
        cs[0] = v4_to_rgba(V4(front_emissions[0] * rgba_to_v4(cs[0]).rgb, rgba_to_v4(cs[0]).a))
        cs[1] = v4_to_rgba(V4(front_emissions[1] * rgba_to_v4(cs[1]).rgb, rgba_to_v4(cs[1]).a))
        cs[2] = v4_to_rgba(V4(front_emissions[2] * rgba_to_v4(cs[2]).rgb, rgba_to_v4(cs[2]).a))
        cs[3] = v4_to_rgba(V4(front_emissions[3] * rgba_to_v4(cs[3]).rgb, rgba_to_v4(cs[3]).a))
        
        push_quad(group, bitmap, **ps, **es[0].ts, **cs)
    }
}

output_lighting_textures :: proc (group: ^RenderGroup, solution: ^LightingSolution, textures: ^LightingTextures) {
    timed_function()
    
    textures.lookup = 0
    
    bounds := rectangle_inverted_infinity(Rectangle3)
    for element in solution.elements {
        bounds.min = min_per_lane(bounds.min, element.p.xyz)
        bounds.max = max_per_lane(bounds.max, element.p.xyz)
    }
    
    bounds     = add_radius(bounds, 0.1)
    dimension := get_dimension(bounds)
    
    inv_voxel_dimension := cast(v3) lookup_dimensions / dimension
    
    pack_index: u32
    for element in solution.elements {
        voxel_p     := (element.p - bounds.min) * inv_voxel_dimension
        voxel_index := truncate(u32, voxel_p)
        
        lookup_at := &textures.lookup[voxel_index.z][voxel_index.y][voxel_index.x]
        
        front_emission := clamp_01(element.front_emission_c)
        c := v4_to_rgba(V4(front_emission, 1))
        
        pack_index += 1
        
        pnext := &textures.pnext[pack_index]
        pnext.p    = element.p
        pnext.next = cast(u32) lookup_at^
        lookup_at^ = cast(u16) pack_index
        textures.c[pack_index] = c
    }
    
    textures.min_corner          = bounds.min
    textures.voxel_dimension     = dimension / cast(v3) lookup_dimensions
    textures.inv_voxel_dimension = inv_voxel_dimension
    
    push_lighting(group, textures, textures.min_corner, textures.inv_voxel_dimension)
}