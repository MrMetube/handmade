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
    
    align_percentage:  [2] f32,
    width_over_height: f32,
    
    width, height: i32,
    
    texture_handle: u32,
}

@(common)
RenderCommands :: struct {
    width, height: i32,
    
    clear_color: v4,
    
    // @note(viktor): Packed array of disjoint elements.
    // Filled from the front with SortSpriteBounds and from the back with
    // pairs of [RenderEntryHeader some_render_entry]
    // In between the entries is a linked list of RenderEntryCips. See rects.
    using _data : struct #raw_union {
        push_buffer:  []u8,
        sort_entries: Array(SortSpriteBounds),
    },
    push_buffer_data_at: u32,
    render_entry_count:  u32,
    
    max_render_target_index: u32,
    
    clip_rects_count: u32,
    rects: Deque(RenderEntryClip),
    
    last_used_manual_sort_key: u16,
}

@(common)
RenderPrep :: struct {
    clip_rects:     Array(RenderEntryClip),
    sorted_offsets: []u32,
}

RenderGroup :: struct {
    assets:                ^Assets,
    missing_asset_count:   i32,
    
    screen_area: Rectangle2,
    
    camera: Camera,
    
    monitor_half_dim_in_meters: v2,
    
    commands: ^RenderCommands,
    
    generation_id: AssetGenerationId,
    
    current_clip_rect_index: u16,
    
    is_aggregating:     b32,
    aggregate_bounds:   SpriteBounds,
    first_aggregate_at: i64,
}

Transform :: struct {
    chunk_z: i32,
    
    is_upright:   b32,
    floor_z:      f32,
    
    offset:       v3,  
    scale:        f32,
    
    color:   v4,
    t_color: v4,
    manual_sort_key: ManualSortKey,
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

RenderEntryType :: enum u8 {
    None,
    RenderEntryBitmap,
    RenderEntryRectangle,
    RenderEntryClip,
    RenderEntryBlendRenderTargets,
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
    render_target_index: u32,
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
RenderEntryBlendRenderTargets :: struct {
    source_index: u32,
    dest_index:   u32,
    alpha:        f32,
}

UsedBitmapDim :: struct {
    size:  v2,
    align: v2,
    p:     v3,
    basis: ProjectedBasis,
}

ProjectedBasis :: struct {
    p:     v2,
    scale: f32,
    valid: b32,
}

////////////////////////////////////////////////

Camera_Params :: struct {
    width_of_monitor: f32,
    meters_to_pixels: f32,
    focal_length:     f32,
}

 get_standard_camera_params :: proc (width_in_pixels: f32, focal_length: f32) -> (result: Camera_Params) {
    result.width_of_monitor = 0.635
    result.meters_to_pixels = width_in_pixels / result.width_of_monitor
    result.focal_length = focal_length
    
    return result
 }

////////////////////////////////////////////////

init_render_group :: proc(group: ^RenderGroup, assets: ^Assets, commands: ^RenderCommands, generation_id: AssetGenerationId) {
    assert((cast(umm) &(cast(^RenderCommands)nil).push_buffer) == (cast(umm) &(cast(^RenderCommands)nil).sort_entries.data))
    
    pixel_size := vec_cast(f32, commands.width, commands.height)
    
    group ^= {
        assets = assets,
        screen_area = rectangle_min_dimension(v2{}, pixel_size),
        commands = commands,
        generation_id = generation_id,
    }
    
    clip := rectangle_min_dimension(v2{0,0}, pixel_size)
    group.current_clip_rect_index = push_clip_rect(group, clip, 0)
}

////////////////////////////////////////////////

default_flat_transform    :: proc() -> Transform { return { scale = 1 } }
default_upright_transform :: proc() -> Transform { return { scale = 1, is_upright = true } }

perspective :: proc(group: ^RenderGroup, meters_to_pixels, focal_length, distance_above_target: f32) {
    // @todo(viktor): need to adjust this based on buffer size
    pixels_to_meters := 1.0 / meters_to_pixels
    pixel_size := get_dimension(group.screen_area)
    group.monitor_half_dim_in_meters = 0.5 * pixel_size * pixels_to_meters
    
    group.camera = {
        mode = .Perspective,
        
        screen_center = 0.5 * pixel_size,
        meters_to_pixels_for_monitor = meters_to_pixels,
        
        focal_length          = focal_length,
        distance_above_target = distance_above_target,
    }
}

orthographic :: proc(group: ^RenderGroup, meters_to_pixels: f32) {
    // @todo(viktor): need to adjust this based on buffer size
    pixel_size := get_dimension(group.screen_area)
    group.monitor_half_dim_in_meters = 0.5 * meters_to_pixels
    
    group.camera = {
        mode = .Orthographic,
        
        screen_center = 0.5 * pixel_size,
        meters_to_pixels_for_monitor = meters_to_pixels,
        
        focal_length          = 10,
        distance_above_target = 10,
    }
}

////////////////////////////////////////////////

push_render_element :: proc(group: ^RenderGroup, $T: typeid, bounds: SpriteBounds, screen_bounds: Rectangle2) -> (result: ^T) {
    assert(group.camera.mode != .None)

    type: RenderEntryType
    switch typeid_of(T) {
      case RenderEntryBitmap:             type = .RenderEntryBitmap
      case RenderEntryRectangle:          type = .RenderEntryRectangle
      case RenderEntryBlendRenderTargets: type = .RenderEntryBlendRenderTargets
      case RenderEntryClip:               unreachable()
    }
    assert(type != .None)
    
    header_size := cast(u32) size_of(RenderEntryHeader)
    entry_size := cast(u32) size_of(T)
    total_size := entry_size + header_size
    
    // :PointerArithmetic
    assert(group.commands.push_buffer_data_at - total_size > get_next_sort_entry_at(group.commands))
    group.commands.push_buffer_data_at -= total_size
    offset := group.commands.push_buffer_data_at
    header := cast(^RenderEntryHeader) &group.commands.push_buffer[offset]
    header ^= {
        clip_rect_index = group.current_clip_rect_index,
        type = type,
    }
    
    result = cast(^T) &group.commands.push_buffer[offset + header_size]
    group.commands.render_entry_count += 1

    if group.is_aggregating {
        if group.first_aggregate_at == group.commands.sort_entries.count{
            group.aggregate_bounds = bounds
        } else if is_y_sprite(group.aggregate_bounds) {
            assert(is_y_sprite(bounds) == is_y_sprite(group.aggregate_bounds))
            group.aggregate_bounds.z_max = max(group.aggregate_bounds.z_max, bounds.z_max)
        } else {
            assert(is_y_sprite(bounds) == is_y_sprite(group.aggregate_bounds))
            group.aggregate_bounds.y_max = max(group.aggregate_bounds.y_max, bounds.y_max)
            group.aggregate_bounds.y_min = min(group.aggregate_bounds.y_min, bounds.y_min)
        }
    }
        
    sort_entry := push_sort_sprite_bounds(group.commands)
    sort_entry ^= {
        bounds = bounds,
        offset = offset,
        screen_bounds = screen_bounds,
    }
    
    return result
}

store_color :: proc(transform: Transform, color: v4) -> (result: v4) {
    result = linear_blend(color, transform.color, transform.t_color)
    result.rgb *= result.a
    return result
}

push_sort_sprite_bounds :: proc(commands: ^RenderCommands) -> (result: ^SortSpriteBounds) {
    // :PointerArithmetic
    next_sort_entry_at := get_next_sort_entry_at(commands)
    if next_sort_entry_at + size_of(SortSpriteBounds) < commands.push_buffer_data_at {
        result = append(&commands.sort_entries)
    }
    
    return result
}

push_blend_render_targets :: proc(group: ^RenderGroup, source_index: u32, alpha: f32) {
    push_sort_barrier(group)
    entry := push_render_element(group, RenderEntryBlendRenderTargets, {}, {})
    entry ^= {
        source_index = source_index,
        alpha = alpha,
    }
    push_sort_barrier(group)
}

push_clip_rect :: proc { push_clip_rect_direct, push_clip_rect_with_transform }
push_clip_rect_direct :: proc(group: ^RenderGroup, rect: Rectangle2, render_target_index: u32) -> (result: u16) {
    total_size := cast(u32) size_of(RenderEntryClip)
    
    
    // :PointerArithmetic
    assert(group.commands.push_buffer_data_at - total_size > get_next_sort_entry_at(group.commands))
    group.commands.push_buffer_data_at -= total_size
    entry := cast(^RenderEntryClip) &group.commands.push_buffer[group.commands.push_buffer_data_at]
    group.commands.render_entry_count += 1
    
    result = cast(u16) group.commands.clip_rects_count
    deque_append(&group.commands.rects, entry)
    group.commands.clip_rects_count += 1
    group.current_clip_rect_index = result
    
    entry ^= { rect = rec_cast(i32, rect) }
    entry.rect.min.y += 1 // Correction for rounding, because the y-axis is inverted
    entry.render_target_index = render_target_index
    group.commands.max_render_target_index = max(group.commands.max_render_target_index, render_target_index)
    
    return result
}
push_clip_rect_with_transform :: proc(group: ^RenderGroup, rect: Rectangle2, render_target_index: u32, transform: Transform) -> (result: u16) {
    rect3 := Rect3(rect, 0, 0)
    
    center := get_center(rect3)
    size   := get_dimension(rect3)
    p := center + 0.5*size
    basis := project_with_transform(group.camera, transform, p)
    
    if basis.valid {
        bp  := basis.p
        dim := basis.scale * size.xy
        result = push_clip_rect_direct(group, rectangle_center_dimension(bp - 0.5 * dim, dim), render_target_index)
    }
    
    return result
}

push_sort_barrier :: proc(group: ^RenderGroup, turn_of_sorting := false) {
    sort_entry := push_sort_sprite_bounds(group.commands)
    sort_entry ^= {
        offset = SpriteBarrierValue,
        flags  = turn_of_sorting ? transmute(type_of(sort_entry.flags)) cast(u16) SpriteBarrierTurnsOffSorting : {}
    }
}

push_clear :: proc(group: ^RenderGroup, color: v4) {
    group.commands.clear_color = store_color({}, color)
}

push_bitmap :: proc(
    group: ^RenderGroup, id: BitmapId, transform: Transform, height: f32, 
    offset := v3{}, color := v4{1,1,1,1}, use_alignment: b32 = true, x_axis := v2{1,0}, y_axis := v2{0,1},
) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    // @todo(viktor): the handle is filled out always at the end of the frame in manage_textures
    if bitmap != nil && bitmap.texture_handle != 0 {
        assert(bitmap.texture_handle != 0)
        push_bitmap_raw(group, bitmap, transform, height, offset, color, id, use_alignment, x_axis, y_axis)
    } else {
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
        
        bounds := get_sprite_bounds(transform, offset, height)
        bounds.manual_sort_key = transform.manual_sort_key
        
        size := used_dim.basis.scale * used_dim.size
        // @todo(viktor): more conservative bounds here
        screen_rect := rectangle_min_dimension(used_dim.basis.p, size)
        element := push_render_element(group, RenderEntryBitmap, bounds, screen_rect)
     
        element.bitmap = bitmap
        element.id     = cast(u32) asset_id
        
        element.p                   = used_dim.basis.p
        element.premultiplied_color = store_color(transform, color)
        
        element.x_axis = size.x * x_axis
        element.y_axis = size.y * y_axis
    }
}

push_rectangle :: proc { push_rectangle2, push_rectangle3 }
push_rectangle2 :: proc(group: ^RenderGroup, rect: Rectangle2, transform: Transform, color := v4{1,1,1,1}) {
    push_rectangle(group, Rect3(rect, 0, 0), transform, color)
}
push_rectangle3 :: proc(group: ^RenderGroup, rect: Rectangle3, transform: Transform, color := v4{1,1,1,1}) {
    basis := project_with_transform(group.camera, transform, rect.min)
    
    if basis.valid {
        dimension := get_dimension(rect)
        
        dim := basis.scale * dimension.xy
        screen_rect := rectangle_min_dimension(basis.p, dim)
                
        bounds := get_sprite_bounds(transform, 0, dimension.y)
        element := push_render_element(group, RenderEntryRectangle, bounds, screen_rect)

        element.premultiplied_color = store_color(transform, color)
        element.rect                = screen_rect
    }
}

push_rectangle_outline :: proc { push_rectangle_outline2, push_rectangle_outline3 }
push_rectangle_outline2 :: proc(group: ^RenderGroup, rec: Rectangle2, transform: Transform, color := v4{1,1,1,1}, thickness: v2 = 0.1) {
    push_rectangle_outline(group, Rect3(rec, 0, 0), transform, color, thickness)
}
push_rectangle_outline3 :: proc(group: ^RenderGroup, rec: Rectangle3, transform: Transform, color:= v4{1,1,1,1}, thickness: v2 = 0.1) {
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
    camera_half_dim := -unproject_with_transform(group.camera, default_flat_transform(), group.monitor_half_dim_in_meters).xy
    result = rectangle_center_half_dimension(v2{}, camera_half_dim)
    
    return result
}

project_with_transform :: proc(camera: Camera, transform: Transform, base_p: v3) -> (result: ProjectedBasis) {
    p := base_p + transform.offset
    
    near_clip_plane :: 0.2
    
    distance_above_target := camera.distance_above_target
    switch camera.mode {
      case .None: unreachable()
      case .Perspective:
        if UseDebugCamera {
            distance_above_target *= DebugCameraDistance
        }
        
        
        floor_z := transform.floor_z
        distance_to_p_z := distance_above_target - floor_z
        // @todo(viktor): transform.scale is unused
        if distance_to_p_z > near_clip_plane {
            height_off_floor: f32 = p.z - floor_z
            ortho_y_from_z: f32 = 1
            
            raw := V3(p.xy, 1)
            raw.y += height_off_floor * ortho_y_from_z
            
            projected := camera.focal_length * raw / distance_to_p_z
            
            result.scale = projected.z  * camera.meters_to_pixels_for_monitor
            
            result.p     = projected.xy * camera.meters_to_pixels_for_monitor + camera.screen_center
            result.valid = true
        }
        
      case .Orthographic:
        result.p     = camera.meters_to_pixels_for_monitor * p.xy + camera.screen_center
        result.scale = camera.meters_to_pixels_for_monitor
        result.valid = true
    }

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

////////////////////////////////////////////////

@(common) SpriteBarrierValue           :: 0xFFFFFFFF
@(common) SpriteBarrierTurnsOffSorting :: 0xFF00

@(common)
SortSpriteBounds :: struct {
    using bounds: SpriteBounds,
    offset:  u32,
    
    screen_bounds: Rectangle2,
    first_edge_with_me_as_the_front: ^SpriteEdge,
    
    generation_count: u16,
    flags: bit_set[enum u16{ Visited, Drawn,    DebugBox, Cycle }; u16],
}

SpriteBounds :: struct {
    chunk_z: i32,
    y_min, y_max, z_max: f32,
    using manual_sort_key: ManualSortKey,
}

ManualSortKey :: struct {
    always_in_front_of: u16,
    always_behind:      u16,
}

@(common)
SpriteEdge :: struct {
    front, behind: u16,
    next_edge_with_same_front: ^SpriteEdge,
}

is_y_sprite :: proc(s: SpriteBounds) -> b32 {
    return s.y_min == s.y_max
}

@(common)
sort_sprite_bounds_is_in_front_of :: proc(a, b: SpriteBounds) -> (a_in_front_of_b: b32) {
    if a.chunk_z != b.chunk_z do return a.chunk_z > b.chunk_z
    if a.always_in_front_of != 0 && a.always_in_front_of == b.always_behind do return true
    if a.always_behind      != 0 && a.always_behind == b.always_in_front_of do return false
    
    both_are_z_sprites := !is_y_sprite(a) && !is_y_sprite(b)
    
    a_includes_b := b.y_min >= a.y_min && b.y_max < a.y_max
    b_includes_a := a.y_min >= b.y_min && a.y_max < b.y_max
    
    sort_by_z := both_are_z_sprites || a_includes_b || b_includes_a
    
    a_in_front_of_b = sort_by_z ? a.z_max > b.z_max : a.y_min < b.y_min
    
    return a_in_front_of_b
}

reserve_sort_key :: proc(group: ^RenderGroup) -> u16 {
    group.commands.last_used_manual_sort_key += 1
    result := group.commands.last_used_manual_sort_key
    assert(result != 0)
    return result
}

begin_aggregate_sort_key :: proc(group: ^RenderGroup) {
    assert(!group.is_aggregating)
    group.is_aggregating = true
    
    group.aggregate_bounds = {
        y_max = -Infinity,
        y_min = +Infinity,
        z_max = -Infinity,
    }
    group.first_aggregate_at = group.commands.sort_entries.count
}

end_aggregate_sort_key :: proc(group: ^RenderGroup) {
    assert(group.is_aggregating)
    
    group.is_aggregating = false
    aggregate_count := group.commands.sort_entries.count - group.first_aggregate_at
    entries := slice(group.commands.sort_entries)[group.first_aggregate_at:][:aggregate_count]
    
    for &entry in entries {
        entry.bounds = group.aggregate_bounds
    }
}

get_next_sort_entry_at :: proc(commands: ^RenderCommands) -> u32 { return cast(u32) commands.sort_entries.count * size_of(SortSpriteBounds) }

get_sprite_bounds :: proc(transform: Transform, offset: v3, height: f32) -> (result: SpriteBounds) {
    y := transform.offset.y + offset.y
    result = SpriteBounds {
        chunk_z = transform.chunk_z,
        
        y_min = y,
        y_max = y,
        z_max = transform.offset.z + offset.z,
        manual_sort_key = transform.manual_sort_key,
    }
    
    // @todo(viktor): More accurate calculations - this doesn't handle neither alignment nor rotation nor axis shear/scale
    if transform.is_upright {
        result.z_max += .5 * height
    } else {
        result.y_min -= .5 * height
        result.y_max += .5 * height
    }
    
    return result
}