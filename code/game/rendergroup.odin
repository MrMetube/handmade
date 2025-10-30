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
    // @todo(viktor): the length of the slice and either width or height are redundant
    memory: [] Color,
    dimension: v2i,
    
    // @cleanup with the next asset pack
    align_percentage:  v2,
    width_over_height: f32,
    
    texture_handle: u32,
}
    
@(common)
RenderSettings :: struct {
    dimension:             v2i,
    depth_peel_count_hint: u32,
    multisampling_hint:    b32,
    pixelation_hint:       b32,
}

@(common)
RenderCommands :: struct {
    using settings: RenderSettings,
    
    clear_color: v4,
    
    // @note(viktor): Packed array of disjoint elements.
    // Filled with pairs of [RenderEntryHeader + SomeRenderEntry]
    // In between the entries is a linked list of [RenderEntryHeader + RenderEntryCips]. See '.rects'.
    push_buffer: Byte_Buffer,
    
    vertex_buffer:      Array(Textured_Vertex),
    quad_bitmap_buffer: Array(^Bitmap),
    
    white_bitmap: Bitmap,
}

RenderGroup :: struct {
    assets:              ^Assets,
    generation_id:       AssetGenerationId,
    missing_asset_count: i32, // @cleanup this is only ever written to
    
    commands: ^RenderCommands,
    
    screen_size: v2,
    
    last_setup: RenderSetup,
    
    current_quads: ^Textured_Quads,
    
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
    is_upright: b32,
    offset: v3,  
    
    // @cleanup scale is never read from or writen to
    scale:  f32,
}
    
Camera_Flags :: bit_set[ enum {
    orthographic,
    debug,
}]

////////////////////////////////////////////////

RenderEntryType :: enum u8 {
    None,
    Textured_Quads,
    DepthClear,
    BeginPeels,
    EndPeels,
}

@(common)
RenderEntryHeader :: struct {
    type: RenderEntryType,
}

@(common)
RenderSetup :: struct { // @todo(viktor): rename this to some more camera-centric
    next: ^RenderSetup,
    
    clip_rect:           Rectangle2i,
    
    // @volatile shader inputs
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

@(common)
Textured_Quads :: struct {
    setup: RenderSetup,
    
    quad_count:    u32,
    bitmap_offset: u32,
}

@(common) DepthClear :: struct {}
@(common) BeginPeels :: struct {}
@(common) EndPeels   :: struct {}

@(common)
Textured_Vertex :: struct {
    p:     v4,
    n:     v3,
    uv:    v2,
    color: Color,
}

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
        
        screen_size   = vec_cast(f32, commands.dimension),
        generation_id = generation_id,
    }
    
    setup := group.last_setup
    
    setup.clip_rect = rectangle_zero_min_dimension(commands.dimension)
    setup.projection = identity()
    setup.fog_begin = 0
    setup.fog_end = 1
    setup.clip_alpha_begin = 0
    setup.clip_alpha_end = 1
    
    push_setup(group, setup)
}

////////////////////////////////////////////////

default_flat_transform    :: proc () -> Transform { return { scale = 1 } }
default_upright_transform :: proc () -> Transform { return { scale = 1, is_upright = true } }

////////////////////////////////////////////////

push_render_element :: proc (group: ^RenderGroup, $T: typeid) -> (result: ^T) {
    reset_quads := true
    type: RenderEntryType
    switch typeid_of(T) {
      case Textured_Quads:     type = .Textured_Quads; reset_quads = false
      case DepthClear:         type = .DepthClear
      case BeginPeels:         type = .BeginPeels
      case EndPeels:           type = .EndPeels
      case:                    unreachable()
    }
    assert(type != .None)
    
    header := render_group_push_size(group, RenderEntryHeader)
    header ^= { type = type }
    result = render_group_push_size(group, T)
    
    if reset_quads {
        group.current_quads = nil
    }
    
    return result
}

render_group_push_size :: proc (group: ^RenderGroup, $T: typeid) -> (result: ^T) {
    result = write_reserve(&group.commands.push_buffer, T)
    return result
}

////////////////////////////////////////////////

push_setup :: proc (group: ^RenderGroup, setup: RenderSetup) {
    group.last_setup = setup
    group.current_quads = nil
}

get_screen_point :: proc (group: ^RenderGroup, transform: Transform, world_p: v3) -> (result: v2) {
    p := multiply(group.last_setup.projection, world_p + transform.offset)
    
    p.xy = group.screen_size * 0.5 * (1 + p.xy)
    
    return p.xy
}

get_clip_rect_with_transform :: proc (group: ^RenderGroup, rect: Rectangle2, transform: Transform) -> (result: Rectangle2i) {
    min_corner := get_screen_point(group, transform, V3(rect.min, 0))
    max_corner := get_screen_point(group, transform, V3(rect.max, 0))
    
    result = round_outer(Rectangle2{min_corner, max_corner})
    
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

push_depth_clear :: proc (group: ^RenderGroup) { push_render_element(group, DepthClear) }
push_begin_depth_peel :: proc (group: ^RenderGroup) { push_render_element(group, BeginPeels) }
push_end_depth_peel   :: proc (group: ^RenderGroup) { push_render_element(group, EndPeels)   }

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
    if .debug in flags do fog = false
    
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

push_quad :: proc (group: ^RenderGroup, bitmap: ^Bitmap, p0, p1, p2, p3: v4, t0, t1, t2, t3: v2, c0, c1, c2, c3: Color) {
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
    
    append(&group.commands.quad_bitmap_buffer, bitmap)
    // @note(viktor): reorder from quad ordering to triangle strip ordering
    append(&group.commands.vertex_buffer, 
        Textured_Vertex {p3, n3, t3, c3},
        Textured_Vertex {p0, n0, t0, c0},
        Textured_Vertex {p2, n2, t2, c2},
        Textured_Vertex {p1, n1, t1, c1},
    )
}

get_current_quads :: proc (group: ^RenderGroup) -> (result: ^Textured_Quads) {
    if group.current_quads == nil {
        group.current_quads = push_render_element(group, Textured_Quads)
        group.current_quads ^= {
            bitmap_offset = cast(u32) group.commands.quad_bitmap_buffer.count,
            setup         = group.last_setup,
        }        
    }
    
    result = group.current_quads
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
    perp_length := length(perp)
    
    when false do if perp_length < thickness {
        perp = group.debug_cam.y
    } else {
    }
    perp /= perp_length
    
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

push_bitmap :: proc (group: ^RenderGroup, id: BitmapId, transform: Transform, height: f32, offset := v3{}, color := v4{1, 1, 1, 1}, use_alignment: b32 = true, x_axis := v2{1, 0}, y_axis := v2{0, 1}) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    // @todo(viktor): the handle is filled out always at the end of the frame in manage_textures
    if bitmap != nil && bitmap.texture_handle != 0 {
        push_bitmap_raw(group, bitmap, transform, height, offset, color, use_alignment, x_axis, y_axis)
    } else {
        load_bitmap(group.assets, id, false)
        group.missing_asset_count += 1
    }
}

push_bitmap_raw :: proc (group: ^RenderGroup, bitmap: ^Bitmap, transform: Transform, height: f32, offset := v3{}, color := v4{1, 1, 1, 1}, use_alignment: b32 = true, x_axis2 := v2{1, 0}, y_axis2 := v2{0, 1}) {
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
    d_texel := 1 / vec_cast(f32, bitmap.dimension)
    min_uv := 0 + d_texel
    max_uv := 1 - d_texel
    
    max := min + V4(x_axis + y_axis, z_bias)
    
    premultiplied_color := store_color(color)
    c := v4_to_rgba(premultiplied_color)
    
    ////////////////////////////////////////////////
    
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

push_cube :: proc (group: ^RenderGroup, id: BitmapId, p: v3, radius, height: f32, color := v4{1, 1, 1, 1}) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    
    // @note(viktor): the handle is filled out always at the end of the frame in manage_textures
    if bitmap == nil || bitmap.texture_handle == 0 {
        load_bitmap(group.assets, id, false)
        group.missing_asset_count += 1
    } else {
        push_cube_raw(group, bitmap, p, radius, height, color)
    }
}

push_cube_raw :: proc (group: ^RenderGroup, bitmap: ^Bitmap, p: v3, radius, height: f32, color := v4{1, 1, 1, 1}) {
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
    
    push_quad(group, bitmap, p0, p1, p3, p2, t0, t1, t2, t3, cb, ct, ct, cb)
    push_quad(group, bitmap, p0, p2, p6, p4, t0, t1, t2, t3, bo, bo, bo, bo)
    push_quad(group, bitmap, p0, p4, p5, p1, t0, t1, t2, t3, cb, cb, ct, ct)
    push_quad(group, bitmap, p7, p5, p4, p6, t0, t1, t2, t3, ct, ct, cb, cb)
    push_quad(group, bitmap, p7, p6, p2, p3, t0, t1, t2, t3, ct, cb, cb, ct)
    push_quad(group, bitmap, p7, p3, p1, p5, t0, t1, t2, t3, op, op, op, op)
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

store_color :: proc (color: v4) -> (result: v4) {
    result = color
    result.rgb *= result.a
    return result
}

////////////////////////////////////////////////

get_used_bitmap_dim :: proc (group: ^RenderGroup, bitmap: Bitmap, transform: Transform, height: f32, offset := v3{}, use_alignment: b32 = true, x_axis := v2{1,0}, y_axis := v2{0,1}) -> (result: UsedBitmapDim) {
    result.size  = v2{bitmap.width_over_height, 1} * height
    result.align = use_alignment ? bitmap.align_percentage * result.size : 0
    result.p.z   = offset.z
    result.p.xy  = offset.xy - result.align * x_axis - result.align * y_axis
    
    result.basis = project_with_transform(transform, result.p)
    
    return result
}

project_with_transform :: proc (transform: Transform, p: v3) -> (result: v3) {
    result = p + transform.offset
    return result
}

unproject_with_transform :: proc (group: ^RenderGroup, transform: RenderTransform, pixel_p: v2, world_z: f32) -> (result: v3) {
    probe := V4(transform.p - world_z * transform.z, 1)
    probe = multiply(transform.projection.forward, probe)
    clip_z := probe.z / probe.w
    
    screen_center := group.screen_size * 0.5
    
    clip_p := V3(pixel_p - screen_center, 0)
    clip_p.xy *= 2 / group.screen_size
    clip_p.z = clip_z
    
    result = multiply(transform.projection.backward, clip_p)
    
    return result
}

get_camera_rectangle_at_distance :: proc (group: ^RenderGroup, distance_from_camera: f32) -> (result: Rectangle3) {
    min := unproject_with_transform(group, group.game_cam, 0, distance_from_camera)
    max := unproject_with_transform(group, group.game_cam, group.screen_size, distance_from_camera)
    
    result = rectangle_min_max(min, max)
    
    return result
}

// @cleanup
get_camera_rectangle_at_target :: proc (group: ^RenderGroup) -> (result: Rectangle3) {
    z: f32 = 8
    result = get_camera_rectangle_at_distance(group, z)
    return result
}


fit_camera_distance_to_half_dim :: proc (focal_length, monitor_half_dim_in_meters: f32, half_dim_in_meters: $V) -> (result: V) {
    result = focal_length * (half_dim_in_meters / monitor_half_dim_in_meters)
    return result
}