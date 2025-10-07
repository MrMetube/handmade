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
    // In between the entries is a linked list of RenderEntryCips. See '.rects'.
    push_buffer: [] u8, // :Array or :Allocator
    push_buffer_data_at: u32,
    
    max_render_target_index: u32,
    
    clip_rects_count: u32,
    rects: Deque(RenderEntryClip),
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
    last_projection:    m4,
    last_clip_rect:     Rectangle2i,
    last_render_target: u32,
    
    commands: ^RenderCommands,
    
    generation_id: AssetGenerationId,
    
    current_clip_rect_index: u16,
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
    RenderEntryBitmap,
    RenderEntryRectangle,
    RenderEntryCube,
    RenderEntryClip,
    RenderEntryBlendRenderTargets,
}

@(common)
RenderEntryHeader :: struct {
    clip_rect_index: u16,
    type: RenderEntryType,
}

@(common)
RenderEntryBitmap :: struct {
    bitmap: Bitmap,
    premultiplied_color: v4,
    
    p: v3,
    // @note(viktor): X and Y axis are _already scaled_ by the full dimension.
    x_axis: v3,
    y_axis: v3,
    z_bias: f32,
}

@(common)
RenderEntryRectangle :: struct {
    bitmap: Bitmap,
    premultiplied_color: v4,
    
    p:   v3,
    dim: v2,
}

@(common)
RenderEntryCube :: struct {
    bitmap: Bitmap,
    premultiplied_color: v4,
    
    p: v3, // @note(viktor): This is the middle of the top face of the cube
    height: f32,
    radius: f32,
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

////////////////////////////////////////////////

UsedBitmapDim :: struct {
    size:  v2,
    align: v2,
    p:     v3,
    basis: v3,
}

////////////////////////////////////////////////

// @cleanup remove both of these
Camera_Params :: struct {
    focal_length: f32,
}

get_standard_camera_params :: proc (focal_length: f32) -> (result: Camera_Params) {
    result.focal_length = focal_length
    return result
 }

////////////////////////////////////////////////

init_render_group :: proc (group: ^RenderGroup, assets: ^Assets, commands: ^RenderCommands, generation_id: AssetGenerationId) {
    group ^= {
        assets   = assets,
        commands = commands,
        
        screen_size   = vec_cast(f32, commands.width, commands.height),
        generation_id = generation_id,
    }
    
    push_setup(group, rectangle_zero_dimension(commands.width, commands.height), 0, identity())
}

////////////////////////////////////////////////

default_flat_transform    :: proc () -> Transform { return { scale = 1 } }
default_upright_transform :: proc () -> Transform { return { scale = 1, is_upright = true } }

////////////////////////////////////////////////

push_render_element :: proc (group: ^RenderGroup, $T: typeid) -> (result: ^T) {
    type: RenderEntryType
    switch typeid_of(T) {
      case RenderEntryBitmap:             type = .RenderEntryBitmap
      case RenderEntryRectangle:          type = .RenderEntryRectangle
      case RenderEntryCube:               type = .RenderEntryCube
      case RenderEntryBlendRenderTargets: type = .RenderEntryBlendRenderTargets
      case RenderEntryClip:               type = .RenderEntryClip
      case:                               unreachable()
    }
    assert(type != .None)
    
    header := render_group_push_size(group, RenderEntryHeader)
    header ^= {
        clip_rect_index = group.current_clip_rect_index,
        type = type,
    }
    result = render_group_push_size(group, T)
    
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

push_setup :: proc (group: ^RenderGroup, rect: Rectangle2i, render_target_index: u32, projection: m4) -> (result: ^RenderEntryClip) {
    result = push_render_element(group, RenderEntryClip)
    
    result.clip_rect           = rect
    result.render_target_index = render_target_index
    result.projection          = projection
    
    group.last_projection    = result.projection
    group.last_render_target = result.render_target_index
    group.last_clip_rect     = result.clip_rect
    
    current_clip_rect_index := cast(u16) group.commands.clip_rects_count
    deque_append(&group.commands.rects, result)
    group.commands.clip_rects_count += 1
    group.current_clip_rect_index = current_clip_rect_index
    
    return result
}

push_clip_rect :: proc (group: ^RenderGroup, rect: Rectangle2) -> (result: u16) {
    clip := round_outer(rect)
    entry := push_setup(group, clip, group.last_render_target, group.last_projection)
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

push_perspective :: proc (group: ^RenderGroup, focal_length: f32, x := v3{1,0,0}, y := v3{0,1,0}, z:= v3{0,0,1}, p := v3{0,0,0}, flags := Camera_Flags {}) {
    push_camera(group, focal_length, x, y, z, p, flags)
}
push_orthographic :: proc (group: ^RenderGroup, flags := Camera_Flags {}) {
    push_camera(group, 1, v3{1,0,0}, v3{0,1,0}, v3{0,0,1}, v3{0,0,0}, flags + { .orthographic })
}

push_camera :: proc (group: ^RenderGroup, focal_length: f32, x, y, z, p: v3, flags: Camera_Flags) {
    aspect_width_over_height := safe_ratio_1(cast(f32) group.commands.width, cast(f32) group.commands.height)
    
    projection: m4
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
    camera_transform := camera_transform(x, y, z, p)
    
    projection = projection * camera_transform
    
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

push_bitmap :: proc (
    group: ^RenderGroup, id: BitmapId, transform: Transform, height: f32, 
    offset := v3{}, color := v4{1, 1, 1, 1}, use_alignment: b32 = true, x_axis := v2{1, 0}, y_axis := v2{0, 1},
) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    // @todo(viktor): the handle is filled out always at the end of the frame in manage_textures
    if bitmap != nil && bitmap.texture_handle != 0 {
        push_bitmap_raw(group, bitmap^, transform, height, offset, color, use_alignment, x_axis, y_axis)
    } else {
        load_bitmap(group.assets, id, false)
        group.missing_asset_count += 1
    }
}

push_bitmap_raw :: proc (
    group: ^RenderGroup, bitmap: Bitmap, transform: Transform, height: f32, 
    offset := v3{}, color := v4{1, 1, 1, 1}, use_alignment: b32 = true, x_axis := v2{1, 0}, y_axis := v2{0, 1},
) {
    assert(bitmap.width_over_height != 0)
    assert(bitmap.texture_handle != 0)
    
    used_dim := get_used_bitmap_dim(group, bitmap, transform, height, offset, use_alignment, x_axis, y_axis)
    
    size := used_dim.size
    
    element := push_render_element(group, RenderEntryBitmap)
    element ^= {
        premultiplied_color = store_color(color),
        bitmap = bitmap,
        
        p      = used_dim.basis,
        x_axis = V3(x_axis, 0) * size.x,
        y_axis = V3(y_axis, 0) * size.y,
        z_bias = height,
    }
    
    if transform.is_upright {
        element.x_axis = size.x * (x_axis.x * group.cam_x + x_axis.y * group.cam_y)
        element.y_axis = size.y * (y_axis.x * group.cam_x + y_axis.y * group.cam_y)
    }
}

push_cube :: proc (group: ^RenderGroup, id: BitmapId, p: v3, radius, height: f32, color := v4{1, 1, 1, 1}) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    // @note(viktor): the handle is filled out always at the end of the frame in manage_textures
    if bitmap != nil && bitmap.texture_handle != 0 {
        assert(bitmap.width_over_height != 0)
        assert(bitmap.texture_handle != 0)
        
        element := push_render_element(group, RenderEntryCube)
        element ^= {
            premultiplied_color = store_color(color),
            
            bitmap = bitmap^,
            
            p      = p,
            height = height,
            radius = radius,
        }
    } else {
        load_bitmap(group.assets, id, false)
        group.missing_asset_count += 1
    }
}

push_rectangle :: proc { push_rectangle2, push_rectangle3 }
push_rectangle2 :: proc (group: ^RenderGroup, rect: Rectangle2, transform: Transform, color := v4{1,1,1,1}) {
    push_rectangle(group, Rect3(rect, 0, 0), transform, color)
}
push_rectangle3 :: proc (group: ^RenderGroup, rect: Rectangle3, transform: Transform, color := v4{1,1,1,1}) {
    basis := project_with_transform(transform, rect.min)
    dimension := get_dimension(rect)
    
    element := push_render_element(group, RenderEntryRectangle)
    element ^= {
        premultiplied_color = store_color(color),
        p   = basis,
        dim = dimension.xy,
    }
}

push_rectangle_outline :: proc { push_rectangle_outline2, push_rectangle_outline3 }
push_rectangle_outline2 :: proc (group: ^RenderGroup, rec: Rectangle2, transform: Transform, color := v4{1,1,1,1}, thickness: v2 = 0.1) {
    push_rectangle_outline(group, Rect3(rec, 0, 0), transform, color, thickness)
}
push_rectangle_outline3 :: proc (group: ^RenderGroup, rec: Rectangle3, transform: Transform, color:= v4{1,1,1,1}, thickness: v2 = 0.1) {
    center         := get_center(rec)
    half_dimension := get_dimension(rec) * 0.5
    
    // Top and Bottom
    center_top    := center + {0, half_dimension.y, 0}
    center_bottom := center - {0, half_dimension.y, 0}
    center_left   := center - {half_dimension.x, 0, 0}
    center_right  := center + {half_dimension.x, 0, 0}
    
    half_thickness := thickness * 0.5
    
    half_dim_horizontal := v3{half_dimension.x+half_thickness.x, half_thickness.y, half_dimension.z}
    half_dim_vertical   := v3{half_thickness.x, half_dimension.y-half_thickness.y, half_dimension.z}
    
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

get_used_bitmap_dim :: proc (
    group: ^RenderGroup, bitmap: Bitmap, transform: Transform, height: f32, 
    offset := v3{}, use_alignment: b32 = true, x_axis := v2{1,0}, y_axis := v2{0,1},
) -> (result: UsedBitmapDim) {
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

unproject_with_transform :: proc (group: ^RenderGroup, transform: Transform, pixel_p: v2) -> (result: v3) {
    // @todo(viktor): make this conform with project with transform
    screen_center := group.screen_size * 0.5
    result.xy = (pixel_p - screen_center)
    
    aspect := group.screen_size.x / group.screen_size.y
    result.x *= 0.5 / group.screen_size.x
    result.y *= 0.5 / (group.screen_size.y * aspect)
    
    result.z  = transform.offset.z
    
    result.xy *= (- result.z)
    
    result -= transform.offset
    
    return result
}

get_camera_rectangle_at_target :: proc (group: ^RenderGroup) -> (result: Rectangle3) {
    z: f32 = 8
    result = get_camera_rectangle_at_distance(group, z)
    return result
}

get_camera_rectangle_at_distance :: proc (group: ^RenderGroup, distance_from_camera: f32) -> (result: Rectangle3) {
    transform := default_flat_transform()
    transform.offset.z = -distance_from_camera
    
    min := unproject_with_transform(group, transform, 0)
    max := unproject_with_transform(group, transform, group.screen_size)
    
    result = rectangle_min_max(min, max)
    
    return result
}

fit_camera_distance_to_half_dim :: proc (focal_length, monitor_half_dim_in_meters: f32, half_dim_in_meters: $V) -> (result: V) {
    result = focal_length * (half_dim_in_meters / monitor_half_dim_in_meters)
    return result
}