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

    @todo(viktor): :ZHandling
*/

@(common) 
Color :: [4]u8

@(common) 
Bitmap :: struct {
    // @todo(viktor): the length of the slice and either width or height are redundant
    memory: []Color,
    
    align_percentage:  [2]f32,
    width_over_height: f32,
    
    width, height: i32,
    
    texture_handle: u32,
}

@(common)
RenderCommands :: struct {
    width, height: i32,
    
    // @note(viktor): Packed array of disjoint elements.
    push_buffer:      []u8, // :DisjointArray
    push_buffer_size: u32,
    
    sort_entry_at:             u32,
    push_buffer_element_count: u32,
    
    clip_rects: Array(RenderEntryClip),
    
    rects: Deque(RenderEntryClip),
}

RenderGroup :: struct {
    assets:                ^Assets,
    missing_asset_count:   i32,
    renders_in_background: b32,
    
    camera:                          Camera,
    monitor_half_diameter_in_meters: v2,
    
    commands: ^RenderCommands,
    
    generation_id: AssetGenerationId,
    
    current_clip_rect_index: u16,
}

Transform :: struct {
    offset:    v3,  
    scale:     f32,
    sort_bias: f32,
}

Camera :: struct {
    mode: TransformMode,
    
    screen_center:                v2,
    meters_to_pixels_for_monitor: f32,
    
    focal_length:          f32, // meters the player is sitting from their monitor
    distance_above_target: f32,
}

TransformMode :: enum {
    None, Perspective, Orthographic,
}

@(common)
EnvironmentMap :: struct {
    pz:  f32,
    LOD: [4]Bitmap,
}

@(common)
RenderEntryType :: enum u8 {
    None,
    RenderEntryClear,
    RenderEntryBitmap,
    RenderEntryRectangle,
    RenderEntryClip,
}

@(common)
RenderEntryHeader :: struct { // @todo(viktor): Don't store type here, store in sort index?
    clip_rect_index: u16,
    type: RenderEntryType,
}

@(common)
RenderEntryClip :: struct {
    rect: Rectangle2i,
    next: ^RenderEntryClip,
    
    fx: ClipRectFX,
}

@(common)
RenderEntryClear :: struct {
    premultiplied_color:  v4,
}

@(common)
RenderEntryBitmap :: struct {
    bitmap: ^Bitmap,
    id:     u32, // BitmapId @cleanup
    
    premultiplied_color:  v4,
    p:      v2,
    // @note(viktor): X and Y axis are _already scaled_ by the full dimension.
    x_axis: v2,
    y_axis: v2,
}

@(common)
RenderEntryRectangle :: struct {
    premultiplied_color: v4,
    rect:  Rectangle2,
}

@(common)
ClipRectFX :: struct {
    t_color: v4,
    color:   v4,
}
        
UsedBitmapDim :: struct {
    size:  v2,
    align: v2,
    p:     v3,
    basis: ProjectedBasis,
}

ProjectedBasis :: struct {
    p:        v2,
    scale:    f32,
    valid:    b32,
    sort_key: f32,
}

init_render_group :: proc(group: ^RenderGroup, assets: ^Assets, commands: ^RenderCommands, renders_in_background: b32, generation_id: AssetGenerationId) {
    group^ = {
        assets = assets,
        renders_in_background = renders_in_background,
        commands = commands,
        
        generation_id = generation_id,
    }
}


// @cleanup
default_flat_transform    :: proc() -> Transform { return { scale = 1 } }
default_upright_transform :: proc() -> Transform { return { scale = 1 } }

perspective :: proc(group: ^RenderGroup, pixel_count: [2]i32, meters_to_pixels, focal_length, distance_above_target: f32) {
    // @todo(viktor): need to adjust this based on buffer size
    pixels_to_meters := 1.0 / meters_to_pixels
    pixel_size := vec_cast(f32, pixel_count)
    group.monitor_half_diameter_in_meters = 0.5 * pixel_size * pixels_to_meters
        
    group.camera = {
        mode = .Perspective,
        
        screen_center = 0.5 * pixel_size,
        meters_to_pixels_for_monitor = meters_to_pixels,
        
        focal_length          = focal_length,
        distance_above_target = distance_above_target,
    }
    
    clip := rectangle_min_dimension(v2{0,0}, pixel_size)
    group.current_clip_rect_index = push_clip_rect(group, clip)
}

orthographic :: proc(group: ^RenderGroup, pixel_count: [2]i32, meters_to_pixels: f32) {
    // @todo(viktor): need to adjust this based on buffer size
    pixel_size := vec_cast(f32, pixel_count)
    group.monitor_half_diameter_in_meters = 0.5 * meters_to_pixels
    
    group.camera = {
        mode = .Orthographic,
        
        screen_center = 0.5 * pixel_size,
        meters_to_pixels_for_monitor = meters_to_pixels,
        
        focal_length          = 10,
        distance_above_target = 10,
    }
    
    clip := rectangle_min_dimension(v2{0,0}, pixel_size)
    group.current_clip_rect_index = push_clip_rect(group, clip)
}

store_color :: proc(group: ^RenderGroup, color: v4) -> (result: v4) {
    // @todo(viktor): This should now happen per layer
    // result = lerp(color, group.global_color, group.t_global_color)
    result = color
    result.rgb *= result.a
    return result
}

////////////////////////////////////////////////

push_render_element :: proc(group: ^RenderGroup, $T: typeid, sort_key: f32) -> (result: ^T) {
    assert(group.camera.mode != .None)
    
    header_size := cast(u32) size_of(RenderEntryHeader)
    size := cast(u32) size_of(T) + header_size
    
    commands := group.commands
    // :PointerArithmetic
    if commands.push_buffer_size + size < commands.sort_entry_at - size_of(SortEntry) {
        offset := commands.push_buffer_size
        header := cast(^RenderEntryHeader) &commands.push_buffer[offset]
        header.clip_rect_index = group.current_clip_rect_index
        
        switch typeid_of(T) {
          case RenderEntryClear:            header.type = .RenderEntryClear
          case RenderEntryBitmap:           header.type = .RenderEntryBitmap
          case RenderEntryRectangle:        header.type = .RenderEntryRectangle
          case RenderEntryClip:             header.type = .RenderEntryClip
        }
        assert(header.type != .None)

        result = cast(^T) &commands.push_buffer[offset + header_size]

        commands.sort_entry_at -= size_of(SortEntry)
        entry := cast(^SortEntry) &commands.push_buffer[commands.sort_entry_at]
        entry^ = {
            sort_key = sort_key,
            index    = offset,
        }
        
        commands.push_buffer_size += size
        commands.push_buffer_element_count += 1
    } else {
        unreachable()
    }

    return result
}

clear :: proc(group: ^RenderGroup, color: v4) {
    entry := push_render_element(group, RenderEntryClear, NegativeInfinity)
    if entry != nil {
        entry.premultiplied_color = store_color(group, color)
    }
}

push_clip_rect :: proc { push_clip_rect_direct, push_clip_rect_with_transform }
push_clip_rect_direct :: proc(group: ^RenderGroup, rect: Rectangle2, fx := ClipRectFX{}) -> (result: u16) {
    assert(group.camera.mode != .None)
    
    size := cast(u32) size_of(RenderEntryClip)
    
    commands := group.commands
    // :PointerArithmetic
    if commands.push_buffer_size + size < commands.sort_entry_at - size_of(SortEntry) {
        entry := cast(^RenderEntryClip) &commands.push_buffer[commands.push_buffer_size]
        commands.push_buffer_size += size
    
        result = cast(u16) group.commands.clip_rects.count
        deque_append(&commands.rects, entry)
        group.commands.clip_rects.count += 1
        group.current_clip_rect_index = result
        
        clip := RenderEntryClip { rect = rec_cast(i32, rect) }
        clip.rect.min.y += 1 // Correction for rounding, because the y-axis is inverted
        clip.fx = fx
        
        entry^ = clip
    }
    return result
}
push_clip_rect_with_transform :: proc(group: ^RenderGroup, rect: Rectangle2, transform: Transform) -> (result: u16) {
    rect3 := Rect3(rect, 0, 0)
    
    center := rectangle_get_center(rect3)
    size   := rectangle_get_dimension(rect3)
    p := center + 0.5*size
    basis := project_with_transform(group.camera, transform, p)
    
    if basis.valid {
        bp  := basis.p
        dim := basis.scale * size.xy
        result = push_clip_rect_direct(group, rectangle_center_dimension(bp - 0.5 * dim, dim))
    }
    
    return result
}

push_bitmap :: proc(
    group: ^RenderGroup, id: BitmapId, transform: Transform, height: f32, 
    offset := v3{}, color := v4{1,1,1,1}, use_alignment: b32 =true, x_axis := v2{1,0}, y_axis := v2{0,1},
) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    if group.renders_in_background && bitmap == nil {
        load_bitmap(group.assets, id, true)
        bitmap = get_bitmap(group.assets, id, group.generation_id)
        assert(bitmap != nil)
    }
    
    if bitmap != nil {
        assert(bitmap.texture_handle != 0)
        push_bitmap_raw(group, bitmap, transform, height, offset, color, id, use_alignment, x_axis, y_axis)
    } else {
        assert(!group.renders_in_background)
        load_bitmap(group.assets, id, false)
        group.missing_asset_count += 1
    }
}

push_bitmap_raw :: proc(
    group: ^RenderGroup, bitmap: ^Bitmap, transform: Transform, height: f32, 
    offset := v3{}, color := v4{1,1,1,1}, asset_id: BitmapId = 0, use_alignment: b32 = true, x_axis := v2{1,0}, y_axis := v2{0,1},
) {
    assert(bitmap.width_over_height != 0)
    
    used_dim := get_used_bitmap_dim(group, bitmap^, transform, height, offset, use_alignment, x_axis, y_axis)
    if used_dim.basis.valid {
        assert(bitmap.texture_handle != 0)
        element := push_render_element(group, RenderEntryBitmap, used_dim.basis.sort_key)
        
        if element != nil {
            element.bitmap = bitmap
            element.id     = cast(u32) asset_id
            
            element.p      = used_dim.basis.p
            element.premultiplied_color = store_color(group, color)
            
            size := used_dim.basis.scale * used_dim.size
            element.x_axis = size.x * x_axis
            element.y_axis = size.y * y_axis
        }
    }
}

push_rectangle :: proc { push_rectangle2, push_rectangle3 }
push_rectangle2 :: proc(group: ^RenderGroup, rect: Rectangle2, transform: Transform, color := v4{1,1,1,1}) {
    push_rectangle(group, Rect3(rect, 0, 0), transform, color)
}
push_rectangle3 :: proc(group: ^RenderGroup, rect: Rectangle3, transform: Transform, color := v4{1,1,1,1}) {
    p := rect.max
    basis := project_with_transform(group.camera, transform, p)
    
    if basis.valid {
        element := push_render_element(group, RenderEntryRectangle, basis.sort_key)
        
        dimension := rectangle_get_dimension(rect)
        bp  := basis.p
        dim := basis.scale * dimension.xy
        
        if element != nil {
            element.premultiplied_color = store_color(group, color)
            element.rect  = rectangle_center_dimension(bp - 0.5 * dim, dim)
        }
    }
}

push_rectangle_outline :: proc { push_rectangle_outline2, push_rectangle_outline3 }
push_rectangle_outline2 :: proc(group: ^RenderGroup, rec: Rectangle2, transform: Transform, color := v4{1,1,1,1}, thickness: v2 = 0.1) {
    push_rectangle_outline(group, Rect3(rec, 0, 0), transform, color, thickness)
}
push_rectangle_outline3 :: proc(group: ^RenderGroup, rec: Rectangle3, transform: Transform, color:= v4{1,1,1,1}, thickness: v2 = 0.1) {
    
    // @todo(viktor): there are rounding issues with draw_rectangle
    // ^ What did this mean? I do not see any gaps.
    
    center         := rectangle_get_center(rec)
    half_dimension := rectangle_get_dimension(rec) * 0.5
    
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

get_used_bitmap_dim :: proc(
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

get_camera_rectangle_at_target :: proc(group: ^RenderGroup) -> (result: Rectangle2) {
    result = get_camera_rectangle_at_distance(group, group.camera.distance_above_target)
    return result
}

get_camera_rectangle_at_distance :: proc(group: ^RenderGroup, distance_from_camera: f32) -> (result: Rectangle2) {
    camera_half_diameter := -unproject_with_transform(group.camera, default_flat_transform(), group.monitor_half_diameter_in_meters).xy
    result = rectangle_center_half_dimension(v2{}, camera_half_diameter)
    
    return result
}

project_with_transform :: proc(camera: Camera, transform: Transform, base_p: v3) -> (result: ProjectedBasis) {
    p  := base_p.xyz + transform.offset.xyz
    // pw := base_p.w   + transform.offset.w
    
    near_clip_plane :: 0.2
    distance_above_target := camera.distance_above_target
    
    projected: v3
    switch camera.mode {
      case .None: unreachable()
      case .Perspective:
        if UseDebugCamera {
            distance_above_target *= DebugCameraDistance
        }
        
        base_z: f32
        distance_to_p_z := distance_above_target - p.z
        // @todo(viktor): transform.scale is unused
        if distance_to_p_z > near_clip_plane {
            raw := V3(p.xy, 1)
            projected = camera.focal_length * raw / distance_to_p_z
            
            result.scale = projected.z  * camera.meters_to_pixels_for_monitor  
            result.p     = projected.xy * camera.meters_to_pixels_for_monitor + camera.screen_center  + v2{0, result.scale * base_z}
            result.valid = true
        }
        
      case .Orthographic:
        result.p     = camera.meters_to_pixels_for_monitor * p.xy + camera.screen_center
        result.scale = camera.meters_to_pixels_for_monitor
        result.valid = true
    }
    
    perspective_z  := projected.z
    displacement_z := result.scale * 0//* pw
    
    perspective_term := perspective_z
    y_term := -p.y
    z_term := displacement_z
    
    result.sort_key = 4096 * perspective_term + 1024 * y_term + z_term + transform.sort_bias
    
    return result
}

unproject_with_transform :: proc(camera: Camera, transform: Transform, pixel_p: v2) -> (result: v3) {
    result.xy = (pixel_p - camera.screen_center) / camera.meters_to_pixels_for_monitor 
    result.z  = transform.offset.z
    
    switch camera.mode {
      case .None:         unreachable()
      case .Orthographic: // nothing
      case .Perspective:  result.xy *= (camera.distance_above_target - result.z) / camera.focal_length
    }
    
    result -= transform.offset
    
    return result
}