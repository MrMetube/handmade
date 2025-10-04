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
    assets:                ^Assets,
    missing_asset_count:   i32,
    
    screen_size: v2,
    
    camera: Camera,
    
    commands: ^RenderCommands,
    
    generation_id: AssetGenerationId,
    
    current_clip_rect_index: u16,
}

Transform :: struct {
    chunk_z: i32,
    
    is_upright: b32,
    floor_z:    f32,
    
    offset: v3,  
    scale:  f32,
    
    color:   v4,
    t_color: v4,
}
    
Camera :: struct {
    mode: enum { None, Orthographic, Perspective },
    focal_length: f32, // meters the player is sitting from their monitor
    p: v3,
}

////////////////////////////////////////////////

RenderEntryType :: enum u8 {
    None,
    RenderEntryBitmap,
    RenderEntryRectangle,
    RenderEntryClip,
    RenderEntryBlendRenderTargets,
}

@(common)
RenderEntryHeader :: struct {
    clip_rect_index: u16,
    type: RenderEntryType,
}

@(common)
RenderEntryClip :: struct {
    rect: Rectangle2i,
    next: ^RenderEntryClip,
    render_target_index: u32,
    projection:          m4,
}

@(common)
RenderEntryBitmap :: struct {
    premultiplied_color: v4,
    
    bitmap: Bitmap,
    id:     BitmapId,
    
    p: v3,
    // @note(viktor): X and Y axis are _already scaled_ by the full dimension.
    x_axis: v2,
    y_axis: v2,
}

@(common)
RenderEntryRectangle :: struct {
    premultiplied_color: v4,
    p:   v3,
    dim: v2,
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

Camera_Params :: struct {
    focal_length: f32,
}

////////////////////////////////////////////////

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
}

////////////////////////////////////////////////

default_flat_transform    :: proc () -> Transform { return { scale = 1 } }
default_upright_transform :: proc () -> Transform { return { scale = 1, is_upright = true } }

perspective  :: proc (group: ^RenderGroup, focal_length: f32, p: v3) { set_camera(group, false, focal_length, p) }
orthographic :: proc (group: ^RenderGroup)                           { set_camera(group, true, 1, 0)             }

set_camera :: proc (group: ^RenderGroup, orthographic: bool, focal_length: f32, p: v3) {
    group.camera = {
        mode = orthographic ? .Orthographic : .Perspective,
        focal_length = focal_length,
        p = p,
    }
    
    screen_area := rectangle_zero_dimension(group.screen_size)
    group.current_clip_rect_index = push_clip_rect(group, screen_area, 0, focal_length)
}

////////////////////////////////////////////////

push_render_element :: proc (group: ^RenderGroup, $T: typeid) -> (result: ^T) {
    assert(group.camera.mode != nil)
    
    type: RenderEntryType
    switch typeid_of(T) {
      case RenderEntryBitmap:             type = .RenderEntryBitmap
      case RenderEntryRectangle:          type = .RenderEntryRectangle
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

push_clip_rect :: proc { push_clip_rect_direct, push_clip_rect_with_transform }
push_clip_rect_direct :: proc (group: ^RenderGroup, rect: Rectangle2, render_target_index: u32, focal_length: f32) -> (result: u16) {
    entry := push_render_element(group, RenderEntryClip)
    
    entry.rect = rec_cast(i32, rect)
    entry.rect.min.y += 1 // Correction for rounding, because the y-axis is inverted
    entry.render_target_index = render_target_index
    
    aspect_width_over_height := safe_ratio_1(cast(f32) group.commands.width, cast(f32) group.commands.height)
    one_over_focal_length := 1 / focal_length
    entry.projection = projection(aspect_width_over_height, one_over_focal_length)
    
    result = cast(u16) group.commands.clip_rects_count
    deque_append(&group.commands.rects, entry)
    group.commands.clip_rects_count += 1
    group.current_clip_rect_index = result
    
    group.commands.max_render_target_index = max(group.commands.max_render_target_index, render_target_index)
    
    return result
}
push_clip_rect_with_transform :: proc (group: ^RenderGroup, rect: Rectangle2, render_target_index: u32, transform: Transform) -> (result: u16) {
    rect3 := Rect3(rect, 0, 0)
    
    center := get_center(rect3)
    size   := get_dimension(rect3)
    p := center + 0.5*size
    basis := project_with_transform(group.camera, transform, p)
    
    dim := size.xy
    rectangle := rectangle_center_dimension(basis.xy - 0.5 * dim, dim)
    result = push_clip_rect_direct(group, rectangle, render_target_index, group.camera.focal_length)
    
    return result
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

push_clear :: proc (group: ^RenderGroup, color: v4) {
    group.commands.clear_color = store_color({}, color)
}

push_bitmap :: proc (
    group: ^RenderGroup, id: BitmapId, transform: Transform, height: f32, 
    offset := v3{}, color := v4{1, 1, 1, 1}, use_alignment: b32 = true, x_axis := v2{1, 0}, y_axis := v2{0, 1},
) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    // @todo(viktor): the handle is filled out always at the end of the frame in manage_textures
    if bitmap != nil && bitmap.texture_handle != 0 {
        assert(bitmap.texture_handle != 0)
        push_bitmap_raw(group, bitmap^, transform, height, offset, color, id, use_alignment, x_axis, y_axis)
    } else {
        load_bitmap(group.assets, id, false)
        group.missing_asset_count += 1
    }
}

push_bitmap_raw :: proc (
    group: ^RenderGroup, bitmap: Bitmap, transform: Transform, height: f32, 
    offset := v3{}, color := v4{1, 1, 1, 1}, asset_id: BitmapId = 0, use_alignment: b32 = true, x_axis := v2{1, 0}, y_axis := v2{0, 1},
) {
    assert(bitmap.width_over_height != 0)
    
    used_dim := get_used_bitmap_dim(group, bitmap, transform, height, offset, use_alignment, x_axis, y_axis)
    assert(bitmap.texture_handle != 0)
    
    size := used_dim.size
    
    element := push_render_element(group, RenderEntryBitmap)
    element ^= {
        premultiplied_color = store_color(transform, color),
        
        bitmap = bitmap,
        id     = asset_id,
        
        p      = used_dim.basis,
        x_axis = x_axis * size.x,
        y_axis = y_axis * size.y,
    }
}

push_rectangle :: proc { push_rectangle2, push_rectangle3 }
push_rectangle2 :: proc (group: ^RenderGroup, rect: Rectangle2, transform: Transform, color := v4{1,1,1,1}) {
    push_rectangle(group, Rect3(rect, 0, 0), transform, color)
}
push_rectangle3 :: proc (group: ^RenderGroup, rect: Rectangle3, transform: Transform, color := v4{1,1,1,1}) {
    basis := project_with_transform(group.camera, transform, rect.min)
    dimension := get_dimension(rect)
    
    element := push_render_element(group, RenderEntryRectangle)
    element ^= {
        premultiplied_color = store_color(transform, color),
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

store_color :: proc (transform: Transform, color: v4) -> (result: v4) {
    result = linear_blend(color, transform.color, transform.t_color)
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
    
    result.basis = project_with_transform(group.camera, transform, result.p)
    
    return result
}

project_with_transform :: proc (camera: Camera, transform: Transform, base_p: v3) -> (result: v3) {
    p := base_p + transform.offset
    
    switch camera.mode {
      case .None: unreachable()
      
      case .Orthographic:
        result = p
        
      case .Perspective:
        p.xy -= camera.p.xy
        distance_above_target := camera.p.z
        if UseDebugCamera {
            distance_above_target *= DebugCameraDistance
        }
        
        floor_z := transform.floor_z
        distance_to_p_z := distance_above_target - floor_z
        
        height_off_floor := p.z - floor_z
        
        raw := V3(p.xy, 1)
        raw.y += height_off_floor
        
        result = V3(raw.xy, distance_to_p_z)
    }

    return result
}

unproject_with_transform :: proc (group: ^RenderGroup, camera: Camera, transform: Transform, pixel_p: v2) -> (result: v3) {
    // @todo(viktor): make this conform with project with transform
    screen_center := group.screen_size * 0.5
    result.xy = (pixel_p - screen_center)
    
    aspect := group.screen_size.x / group.screen_size.y
    result.x *= 0.5 / group.screen_size.x
    result.y *= 0.5 / (group.screen_size.y * aspect)
    
    result.z  = transform.offset.z
    
    switch camera.mode {
      case .None: unreachable()
      
      case .Orthographic: // nothing
      
      case .Perspective:  
        result.xy *= (camera.p.z - result.z) / camera.focal_length
        result.xy += camera.p.xy
    }
    
    result -= transform.offset
    
    return result
}

get_camera_rectangle_at_target :: proc (group: ^RenderGroup) -> (result: Rectangle3) {
    result = get_camera_rectangle_at_distance(group, group.camera.p.z)
    return result
}

get_camera_rectangle_at_distance :: proc (group: ^RenderGroup, distance_from_camera: f32) -> (result: Rectangle3) {
    transform := default_flat_transform()
    transform.offset.z = -distance_from_camera
    
    min := unproject_with_transform(group, group.camera, transform, 0)
    max := unproject_with_transform(group, group.camera, transform, group.screen_size)
    
    result = rectangle_min_max(min, max)
    
    return result
}

fit_camera_distance_to_half_dim :: proc (focal_length, monitor_half_dim_in_meters: f32, half_dim_in_meters: $V) -> (result: V) {
    result = focal_length * (half_dim_in_meters / monitor_half_dim_in_meters)
    return result
}