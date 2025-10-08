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
    push_buffer: [] u8, // :Array or :Allocator
    push_buffer_data_at: u32,
    
    max_render_target_index: u32,
    
    clip_rects_count: u32,
    rects: Deque(RenderEntryClip),
    
    vertex_buffer: Array(Textured_Vertex),
    quad_bitmap_buffer: Array(^Bitmap),
    white_bitmap: Bitmap,
}

@(common)
RenderPrep :: struct {
    clip_rects: Array(RenderEntryClip),
}

RenderGroup :: struct {
    assets:              ^Assets,
    missing_asset_count: i32,
    
    screen_size: v2,
    
    cam_p: v3,
    cam_x: v3,
    cam_y: v3,
    cam_z: v3,
    last_projection:    m4_inv,
    last_clip_rect:     Rectangle2i,
    last_render_target: u32,
    
    commands: ^RenderCommands,
    
    generation_id: AssetGenerationId,
    
    current_clip_rect_index: u16,
    
    current_quads: ^RenderEntry_Textured_Quads,
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
    RenderEntryClip,
    RenderEntryBlendRenderTargets,
    RenderEntry_Textured_Quads,
}

@(common)
RenderEntryHeader :: struct {
    clip_rect_index: u16,
    type: RenderEntryType,
}

@(common)
RenderEntryClip :: struct { // @todo(viktor): rename this to some more camera-centric
    next: ^RenderEntryClip,
    
    clip_rect:           Rectangle2i,
    render_target_index: u32,
    projection:          m4,
}

@(common)
RenderEntryBlendRenderTargets :: struct {
    source_index: u32,
    dest_index:   u32,
    alpha:        f32,
}

@(common)
RenderEntry_Textured_Quads :: struct {
    quad_count: u32,
    bitmap_offset: u32,
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
    
    push_setup(group, rectangle_zero_dimension(commands.width, commands.height), 0, {identity(), identity()})
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
      case RenderEntryClip:               type = .RenderEntryClip
      case RenderEntry_Textured_Quads:    type = .RenderEntry_Textured_Quads; reset_quads = false
      case:                               unreachable()
    }
    assert(type != .None)
    
    header := render_group_push_size(group, RenderEntryHeader)
    header ^= {
        clip_rect_index = group.current_clip_rect_index,
        type = type,
    }
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

push_setup :: proc (group: ^RenderGroup, rect: Rectangle2i, render_target_index: u32, projection: m4_inv) -> (result: ^RenderEntryClip) {
    result = push_render_element(group, RenderEntryClip)
    
    result.clip_rect           = rect
    result.render_target_index = render_target_index
    result.projection          = projection.forward
    
    group.last_projection    = projection
    group.last_render_target = render_target_index
    group.last_clip_rect     = rect
    
    current_clip_rect_index := cast(u16) group.commands.clip_rects_count
    deque_append(&group.commands.rects, result)
    group.commands.clip_rects_count += 1
    group.current_clip_rect_index = current_clip_rect_index
    
    return result
}

push_clip_rect :: proc (group: ^RenderGroup, rect: Rectangle2) -> (result: u16) {
    clip := round_outer(rect)
    push_setup(group, clip, group.last_render_target, group.last_projection)
    result = group.current_clip_rect_index
    return result
}
push_clip_rect_with_transform :: proc (group: ^RenderGroup, rect: Rectangle2, transform: Transform) -> (result: u16) {
    rect3 := Rect3(rect, 0, 0)
    
    // @cleanup What is this even supposed to to, thats just rect3.max isnt it?
    center := get_center(rect3)
    size   := get_dimension(rect3)
    p := center + 0.5*size
    basis := project_with_transform(transform, p)
    
    dim := size.xy
    rectangle := rectangle_center_dimension(basis.xy - 0.5 * dim, dim)
    result = push_clip_rect(group, rectangle)
    
    return result
}

push_render_target :: proc (group: ^RenderGroup, render_target_index: u32) {
    push_setup(group, group.last_clip_rect, render_target_index, group.last_projection)
    
    group.commands.max_render_target_index = max(group.commands.max_render_target_index, render_target_index)
}

push_camera :: proc (group: ^RenderGroup, flags: Camera_Flags, x := v3{1,0,0}, y := v3{0,1,0}, z := v3{0,0,1}, p := v3{0,0,0}, focal_length: f32 = 1) {
    aspect_width_over_height := safe_ratio_1(cast(f32) group.commands.width, cast(f32) group.commands.height)
    
    projection: m4_inv
    if .orthographic in flags {
        projection = orthographic_projection(aspect_width_over_height)
    } else { 
        projection = perspective_projection(aspect_width_over_height, focal_length)
    }
    
    if .debug not_in flags {
        group.cam_p = p
        group.cam_x = x
        group.cam_y = y
        group.cam_z = z
    }
    camera := camera_transform(x, y, z, p)
    
    projection.forward  = projection.forward * camera.forward
    projection.backward = camera.backward * projection.backward
    
    push_setup(group, group.last_clip_rect, group.last_render_target, projection)
}

////////////////////////////////////////////////

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

push_clear :: proc (group: ^RenderGroup, color: v4) {
    group.commands.clear_color = store_color(color)
}

////////////////////////////////////////////////

push_quad :: proc (group: ^RenderGroup, bitmap: ^Bitmap, p0, p1, p2, p3: v4, t0, t1, t2, t3: v2, c0, c1, c2, c3: Color) {
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
    }
    
    result = group.current_quads
    return result
}

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
    
    premultiplied_color := store_color(color)
    
    min    := V4(used_dim.basis, 0)
    x_axis := V3(x_axis2, 0) * size.x
    y_axis := V3(y_axis2, 0) * size.y
    z_bias := height
    
    if transform.is_upright {
        x_axis = size.x * (x_axis2.x * group.cam_x + x_axis2.y * group.cam_y)
        y_axis = size.y * (y_axis2.x * group.cam_x + y_axis2.y * group.cam_y)
    }
    
    // @note(viktor): step in one texel because the bitmaps are padded on all sides with a blank strip of pixels
    d_texel := 1 / vec_cast(f32, bitmap.width, bitmap.height)
    min_uv := 0 + d_texel
    max_uv := 1 - d_texel
    
    max := min + V4(x_axis + y_axis, z_bias)
    
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

unproject_with_transform :: proc (group: ^RenderGroup, transform: Transform, pixel_p: v2, world_z: f32) -> (result: v3) {
    probe := v4{0, 0, world_z, 1}
    probe = multiply(group.last_projection.forward, probe)
    clip_z := probe.z / probe.w
    
    screen_center := group.screen_size * 0.5
    
    clip_p := V3(pixel_p - screen_center, 0)
    clip_p.xy *= 2 / group.screen_size
    clip_p.z = clip_z
    
    world_p := multiply(group.last_projection.backward, clip_p)
    result = world_p - transform.offset
    
    return result
}

get_camera_rectangle_at_target :: proc (group: ^RenderGroup) -> (result: Rectangle3) {
    z: f32 = 8
    result = get_camera_rectangle_at_distance(group, z)
    return result
}

get_camera_rectangle_at_distance :: proc (group: ^RenderGroup, distance_from_camera: f32) -> (result: Rectangle3) {
    transform := default_flat_transform()
    
    min := unproject_with_transform(group, transform, 0, distance_from_camera)
    max := unproject_with_transform(group, transform, group.screen_size, distance_from_camera)
    
    result = rectangle_min_max(min, max)
    
    return result
}

fit_camera_distance_to_half_dim :: proc (focal_length, monitor_half_dim_in_meters: f32, half_dim_in_meters: $V) -> (result: V) {
    result = focal_length * (half_dim_in_meters / monitor_half_dim_in_meters)
    return result
}