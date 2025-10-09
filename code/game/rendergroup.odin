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
    
    // @cleanup with the next asset pack
    align_percentage:  v2,
    width_over_height: f32,
    
    width, height: i32,
    
    texture_handle: u32,
}

@(common)
RenderCommands :: struct {
    width, height: i32,
    
    clear_color: v4,
    
    // @note(viktor): Packed array of disjoint elements.
    // Filled with pairs of [RenderEntryHeader + SomeRenderEntry]
    // In between the entries is a linked list of [RenderEntryHeader + RenderEntryCips]. See '.rects'.
    push_buffer:         [] u8, // :Array or :ByteArray with some write-value/read-type operations a write and read cursor
    push_buffer_data_at: u32,
    
    max_render_target_index: u32,
    
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
    
    current_quads: ^RenderEntry_Textured_Quads,
    
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
    scale:  f32,
}
    
Camera_Flags :: bit_set[ enum {
    orthographic,
    debug,
}]

////////////////////////////////////////////////

RenderEntryType :: enum u8 {
    None,
    RenderEntryBlendRenderTargets,
    RenderEntry_Textured_Quads,
}

@(common)
RenderEntryHeader :: struct {
    type: RenderEntryType,
}

@(common)
RenderSetup :: struct { // @todo(viktor): rename this to some more camera-centric
    next: ^RenderSetup,
    
    clip_rect:           Rectangle2i,
    render_target_index: u32,
    projection:          m4,
    
    // @volatile shader inputs
    camera_p:      v3,
    fog_direction: v3,
    fog_begin: f32,
    fog_end:   f32,
    fog_color: v3,
}

@(common)
RenderEntry_Textured_Quads :: struct {
    setup: RenderSetup,
    
    quad_count:    u32,
    bitmap_offset: u32,
}

@(common)
RenderEntryBlendRenderTargets :: struct {
    source_index: u32,
    dest_index:   u32,
    alpha:        f32,
}

@(common)
Textured_Vertex :: struct {
    p:     v4,
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
        
        screen_size   = vec_cast(f32, commands.width, commands.height),
        generation_id = generation_id,
    }
    
    setup := group.last_setup
    
    setup.clip_rect = rectangle_zero_dimension(commands.width, commands.height)
    setup.projection = identity()
    setup.fog_begin = 0
    setup.fog_end = 1
    
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
      case RenderEntryBlendRenderTargets: type = .RenderEntryBlendRenderTargets
      case RenderEntry_Textured_Quads:    type = .RenderEntry_Textured_Quads; reset_quads = false
      case:                               unreachable()
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
    // @note(viktor): The result is _always_ cleared to zero.
    size     := cast(u32) size_of(T)
    capacity := cast(u32) len(group.commands.push_buffer)
    assert(group.commands.push_buffer_data_at + size < capacity)
    
    // :PointerArithmetic
    result = cast(^T) &group.commands.push_buffer[group.commands.push_buffer_data_at]
    group.commands.push_buffer_data_at += size
    
    result ^= {}
    return result
}

////////////////////////////////////////////////

push_setup :: proc (group: ^RenderGroup, setup: RenderSetup) {
    group.last_setup = setup
    group.current_quads = nil
}

get_clip_rect_with_transform :: proc (group: ^RenderGroup, rect: Rectangle2, transform: Transform) -> (result: Rectangle2i) {
    dim := get_dimension(rect)
    
    // @todo(viktor): should we stick with the max for the transform or do something better here? we transform the max and then get back the rectangle we by subtracting the radius?
    p := project_with_transform(transform, V3(rect.max, 0))
    
    rectangle := rectangle_center_dimension(p.xy - 0.5 * dim, dim)
    result = round_outer(rect)
    
    return result
}

@(deferred_in_out=end_transient_clip_rect)
transient_clip_rect :: proc (group: ^RenderGroup, rect: Rectangle2i) -> (result: RenderSetup) {
    result = group.last_setup
    setup := result
    setup.clip_rect =  rect
    push_setup(group, setup)
    
    return result
}

end_transient_clip_rect :: proc (group: ^RenderGroup, _: Rectangle2i, setup: RenderSetup) {
    push_setup(group, setup)
}

push_render_target :: proc (group: ^RenderGroup, render_target_index: u32) {
    group.commands.max_render_target_index = max(group.commands.max_render_target_index, render_target_index)
    
    setup := group.last_setup
    setup.render_target_index = render_target_index
    push_setup(group, setup)
}

push_camera :: proc (group: ^RenderGroup, flags: Camera_Flags, x := v3{1,0,0}, y := v3{0,1,0}, z := v3{0,0,1}, p := v3{0,0,0}, focal_length: f32 = 1) {
    aspect_width_over_height := safe_ratio_1(cast(f32) group.commands.width, cast(f32) group.commands.height)
    
    setup := group.last_setup
    projection: m4_inv
    if .orthographic in flags {
        projection = orthographic_projection(aspect_width_over_height)
        
        setup.fog_direction = 0
    } else {
        projection = perspective_projection(aspect_width_over_height, focal_length)
        
        if .debug not_in flags {
            setup.fog_direction = -z
            setup.fog_begin = 8
            setup.fog_end = 25
        }
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

push_blend_render_targets :: proc (group: ^RenderGroup, source_index: u32, alpha: f32) {
    push_sort_barrier(group)
    entry := push_render_element(group, RenderEntryBlendRenderTargets)
    entry ^= {
        source_index = source_index,
        alpha = alpha,
    }
    push_sort_barrier(group)
}

push_sort_barrier :: proc (group: ^RenderGroup, turn_of_sorting := false) {
    // @todo(viktor): Do we want the sort barrier again?
}

////////////////////////////////////////////////

push_quad :: proc (group: ^RenderGroup, bitmap: ^Bitmap, p0, p1, p2, p3: v4, t0, t1, t2, t3: v2, c0, c1, c2, c3: Color) {
    timed_function()
    
    entry := get_current_quads(group)
    entry.quad_count += 1
    
    append(&group.commands.quad_bitmap_buffer, bitmap)
    // @note(viktor): reorder from quad ordering to triangle strip ordering
    append(&group.commands.vertex_buffer, 
        Textured_Vertex {p0, t0, c0}, 
        Textured_Vertex {p3, t3, c3},
        Textured_Vertex {p1, t1, c1}, 
        Textured_Vertex {p2, t2, c2}, 
    )
}

get_current_quads :: proc (group: ^RenderGroup) -> (result: ^RenderEntry_Textured_Quads) {
    if group.current_quads == nil {
        group.current_quads = push_render_element(group, RenderEntry_Textured_Quads)
        group.current_quads.bitmap_offset = cast(u32) group.commands.quad_bitmap_buffer.count
        group.current_quads.setup = group.last_setup
    }
    
    result = group.current_quads
    return result
}

push_line_segment :: proc (group: ^RenderGroup, bitmap: ^Bitmap, from_p, to_p: v4, c0, c1: Color, thickness: f32) {
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
    z_bias := 0.5 * height
    
    if transform.is_upright {
        x_axis0 := size.x * v3{x_axis2.x, 0, x_axis2.y}
        y_axis0 := size.y * v3{y_axis2.x, 0, y_axis2.y}
        x_axis1 := size.x * (x_axis2.x * group.game_cam.x + x_axis2.y * group.game_cam.y)
        y_axis1 := size.y * (y_axis2.x * group.game_cam.x + y_axis2.y * group.game_cam.y)
        
        x_axis = x_axis1
        y_axis = y_axis1
        y_axis.z = linear_blend(y_axis0.z, y_axis1.z, 0.5)
    }
    
    // @note(viktor): step in one texel because the bitmaps are padded on all sides with a blank strip of pixels
    d_texel := 1 / vec_cast(f32, bitmap.width, bitmap.height)
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
    
    t0 := v2{0, 0}
    t1 := v2{1, 0}
    t2 := v2{1, 1}
    t3 := v2{0, 1}
    
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
    probe := V4(transform.p + -world_z * transform.z, 1)
    probe = multiply(transform.projection.forward, probe)
    clip_z := probe.z / probe.w
    
    screen_center := group.screen_size * 0.5
    
    clip_p := V3(pixel_p - screen_center, 0)
    clip_p.xy *= 2 / group.screen_size
    clip_p.z = clip_z
    
    result = multiply(transform.projection.backward, clip_p)
    
    return result
}

get_camera_rectangle_at_target :: proc (group: ^RenderGroup) -> (result: Rectangle3) {
    z: f32 = 8
    result = get_camera_rectangle_at_distance(group, z)
    return result
}

get_camera_rectangle_at_distance :: proc (group: ^RenderGroup, distance_from_camera: f32) -> (result: Rectangle3) {
    min := unproject_with_transform(group, group.game_cam, 0, distance_from_camera)
    max := unproject_with_transform(group, group.game_cam, group.screen_size, distance_from_camera)
    
    result = rectangle_min_max(min, max)
    
    return result
}

fit_camera_distance_to_half_dim :: proc (focal_length, monitor_half_dim_in_meters: f32, half_dim_in_meters: $V) -> (result: V) {
    result = focal_length * (half_dim_in_meters / monitor_half_dim_in_meters)
    return result
}