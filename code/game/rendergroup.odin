package game

/* NOTE(viktor):
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

    TODO(viktor): :ZHandling
*/

@common 
Color :: [4]u8

@common 
Bitmap :: struct {
    // TODO(viktor): the length of the slice and either width or height are redundant
    memory: []Color,
    
    align_percentage:  [2]f32,
    width_over_height: f32,
    
    width, height: i32,
    
    texture_handle: u32,
}

@common
RenderCommands :: struct {
    width, height: i32,
    
    // NOTE(viktor): Packed array of disjoint elements
    push_buffer:               []u8,
    push_buffer_size:          u32,
    
    sort_entry_at:             u32,
    push_buffer_element_count: u32,
}

RenderGroup :: struct {
    assets:                ^Assets,
    missing_asset_count:   i32,
    renders_in_background: b32,
    
    camera:                          Camera,
    global_alpha:                    f32,
    monitor_half_diameter_in_meters: v2,
    
    commands: ^RenderCommands,
    
    generation_id: AssetGenerationId,
}

Transform :: struct {
    offset:  v3,  
    scale:   f32,
    upright: b32,
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

@common
EnvironmentMap :: struct {
    pz:  f32,
    LOD: [4]Bitmap,
}

// TODO(viktor): Why always prefix rendergroup?
// NOTE(viktor): RenderGroupEntry is a "compact discriminated union"
@common
RenderGroupEntryType :: enum u8 {
    RenderGroupEntryClear,
    RenderGroupEntryBitmap,
    RenderGroupEntryRectangle,
    RenderGroupEntryCoordinateSystem,
}
@common
RenderGroupEntryHeader :: struct { // 1
    type: RenderGroupEntryType,
}

@common
RenderGroupEntryClear :: struct {
    color:  v4,
}

@common
RenderGroupEntryBitmap :: struct { // 12
    color:  v4,
    p:      v2,
    size:   v2,
    
    id:     u32, // BitmapId
    bitmap: ^Bitmap,
}

@common
RenderGroupEntryRectangle :: struct {
    color: v4,
    rect:  Rectangle2,
}

// @Cleanup
@common
RenderGroupEntryCoordinateSystem :: struct {
    color:  v4,
    origin, x_axis, y_axis: v2,

    pixels_to_meters: f32,
    
    texture, normal:        Bitmap,
    top, middle, bottom:    EnvironmentMap,
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

@common
TileSortEntry :: struct {
    sort_key:           f32,
    push_buffer_offset: u32,
}
    
init_render_group :: proc(group: ^RenderGroup, assets: ^Assets, commands: ^RenderCommands, renders_in_background: b32, generation_id: AssetGenerationId) {
    group^ = {
        assets = assets,
        renders_in_background = renders_in_background,
        commands = commands,
        global_alpha = 1,
        generation_id = generation_id,
    }
}

default_flat_transform    :: proc() -> Transform { return { scale = 1 } }
default_upright_transform :: proc() -> Transform { return { scale = 1, upright = true} }

perspective :: proc(group: ^RenderGroup, pixel_count: [2]i32, meters_to_pixels, focal_length, distance_above_target: f32) {
    // TODO(viktor): need to adjust this based on buffer size
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
}

orthographic :: proc(group: ^RenderGroup, pixel_count: [2]i32, meters_to_pixels: f32) {
    // TODO(viktor): need to adjust this based on buffer size
    pixel_size := vec_cast(f32, pixel_count)
    group.monitor_half_diameter_in_meters = 0.5 * meters_to_pixels
    
    group.camera = {
        mode = .Orthographic,
        
        screen_center = 0.5 * pixel_size,
        meters_to_pixels_for_monitor = meters_to_pixels,
        
        focal_length          = 10,
        distance_above_target = 10,
    }
}

all_assets_valid :: proc(group: ^RenderGroup) -> (result: b32) {
    result = group.missing_asset_count == 0
    return result
}

push_render_element :: proc(group: ^RenderGroup, $T: typeid, sort_key: f32) -> (result: ^T) {
    assert(group.camera.mode != .None)
    
    header_size := cast(u32) size_of(RenderGroupEntryHeader)
    size := cast(u32) size_of(T) + header_size
    
    commands := group.commands
    // :PointerArithmetic
    if commands.push_buffer_size + size < commands.sort_entry_at - size_of(TileSortEntry) {
        offset := commands.push_buffer_size
        header := cast(^RenderGroupEntryHeader) &commands.push_buffer[offset]
        
        switch typeid_of(T) {
          case RenderGroupEntryClear:            header.type = .RenderGroupEntryClear
          case RenderGroupEntryRectangle:        header.type = .RenderGroupEntryRectangle
          case RenderGroupEntryBitmap:           header.type = .RenderGroupEntryBitmap
          case RenderGroupEntryCoordinateSystem: header.type = .RenderGroupEntryCoordinateSystem
        }

        result = cast(^T) &commands.push_buffer[offset + header_size]

        commands.sort_entry_at -= size_of(TileSortEntry)
        entry := cast(^TileSortEntry) &commands.push_buffer[commands.sort_entry_at]
        entry^ = {
            sort_key           = sort_key,
            push_buffer_offset = offset,
        }
        
        commands.push_buffer_size += size
        commands.push_buffer_element_count += 1
    } else {
        unreachable()
    }

    return result
}

clear :: proc(group: ^RenderGroup, color: v4) {
    entry := push_render_element(group, RenderGroupEntryClear, NegativeInfinity)
    if entry != nil {
        entry.color = color
    }
}

push_bitmap :: proc(group: ^RenderGroup, id: BitmapId, transform: Transform, height: f32, offset := v3{}, color := v4{1,1,1,1}, use_alignment:b32=true, sort_bias:f32=0) {
    bitmap := get_bitmap(group.assets, id, group.generation_id)
    if group.renders_in_background && bitmap == nil {
        load_bitmap(group.assets, id, true)
        bitmap = get_bitmap(group.assets, id, group.generation_id)
        assert(bitmap != nil)
    }
    
    if bitmap != nil {
        assert(bitmap.texture_handle != 0)
        push_bitmap_raw(group, bitmap, transform, height, offset, color, id, use_alignment, sort_bias)
    } else {
        assert(!group.renders_in_background)
        load_bitmap(group.assets, id, false)
        group.missing_asset_count += 1
    }
}

get_used_bitmap_dim :: proc(group: ^RenderGroup, bitmap: Bitmap, transform: Transform, height: f32, offset := v3{}, use_alignment: b32 = true) -> (result: UsedBitmapDim) {
    result.size  = v2{bitmap.width_over_height, 1} * height
    result.align = use_alignment ? bitmap.align_percentage * result.size : 0
    result.p     = offset - V3(result.align, 0)

    result.basis = project_with_transform(group.camera, transform, result.p)

    return result
}

push_bitmap_raw :: proc(group: ^RenderGroup, bitmap: ^Bitmap, transform: Transform, height: f32, offset := v3{}, color := v4{1,1,1,1}, asset_id: BitmapId = 0, use_alignment: b32 = true, sort_bias: f32 = 0) {
    assert(bitmap.width_over_height != 0)
    
    used_dim := get_used_bitmap_dim(group, bitmap^, transform, height, offset, use_alignment)
    if used_dim.basis.valid {
        assert(bitmap.texture_handle != 0)
        element := push_render_element(group, RenderGroupEntryBitmap, used_dim.basis.sort_key + sort_bias)
        
        if element != nil {
            alpha := v4{1,1,1, group.global_alpha}
            
            element.bitmap = bitmap
            element.id     = cast(u32) asset_id
            
            element.color  = color * alpha
            element.p      = used_dim.basis.p
            element.size   = used_dim.basis.scale * used_dim.size
        }
    }
}

push_rectangle :: proc { push_rectangle2, push_rectangle3 }
push_rectangle2 :: proc(group: ^RenderGroup, rec: Rectangle2, transform: Transform, color := v4{1,1,1,1}, sort_bias : f32 =0) {
    push_rectangle(group, Rect3(rec, 0, 0), transform, color, sort_bias)
}
push_rectangle3 :: proc(group: ^RenderGroup, rec: Rectangle3, transform: Transform, color := v4{1,1,1,1}, sort_bias : f32 =0) {
    center := rectangle_get_center(rec)
    size   := rectangle_get_dimension(rec)
    p := center + 0.5*size
    basis := project_with_transform(group.camera, transform, p)
    
    if basis.valid {
        element := push_render_element(group, RenderGroupEntryRectangle, basis.sort_key + sort_bias)
        
        if element != nil {
            alpha := v4{1,1,1, group.global_alpha}
            element.color = color * alpha
            element.rect  = rectangle_center_dimension(basis.p - 0.5 * basis.scale * size.xy, basis.scale * size.xy)
        }
    }
}

push_rectangle_outline :: proc { push_rectangle_outline2, push_rectangle_outline3 }
push_rectangle_outline2 :: proc(group: ^RenderGroup, rec: Rectangle2, transform: Transform, color := v4{1,1,1,1}, thickness: f32 = 0.1) {
    push_rectangle_outline(group, Rect3(rec, 0, 0), transform, color, thickness)
}
push_rectangle_outline3 :: proc(group: ^RenderGroup, rec: Rectangle3, transform: Transform, color:= v4{1,1,1,1}, thickness: f32 = 0.1) {
    // TODO(viktor): there are rounding issues with draw_rectangle
    // @Cleanup offset and size
    
    offset := rectangle_get_center(rec)
    size   := rectangle_get_dimension(rec)
    
    // Top and Bottom
    push_rectangle(group, rectangle_center_dimension(offset - {0, size.y*0.5, 0}, v3{size.x+thickness, thickness, size.z}), transform, color)
    push_rectangle(group, rectangle_center_dimension(offset + {0, size.y*0.5, 0}, v3{size.x+thickness, thickness, size.z}), transform, color)

    // Left and Right
    push_rectangle(group, rectangle_center_dimension(offset - {size.x*0.5, 0, 0}, v3{thickness, size.y-thickness, size.z}), transform, color)
    push_rectangle(group, rectangle_center_dimension(offset + {size.x*0.5, 0, 0}, v3{thickness, size.y-thickness, size.z}), transform, color)
}

coordinate_system :: proc(group: ^RenderGroup, transform: Transform, color:= v4{1,1,1,1}) -> (result: ^RenderGroupEntryCoordinateSystem) {
    basis := project_with_transform(group.camera, transform, 0)
    if basis.valid {
        result = push_render_element(group, RenderGroupEntryCoordinateSystem, basis.sort_key)
        if result != nil {
            result.color = color
        }
    }

    return result
}

push_hitpoints :: proc(group: ^RenderGroup, entity: ^Entity, offset_y: f32, transform: Transform) {
    if entity.hit_point_max > 1 {
        health_size: v2 = 0.1
        spacing_between: f32 = health_size.x * 1.5
        health_x := -0.5 * (cast(f32) entity.hit_point_max - 1) * spacing_between

        for index in 0..<entity.hit_point_max {
            hit_point := entity.hit_points[index]
            color := hit_point.filled_amount == 0 ? Gray : Red
            // @Cleanup rect
            push_rectangle(group, rectangle_center_dimension(v3{health_x, -offset_y, 0}, V3(health_size, 0)), transform, color)
            health_x += spacing_between
        }
    }
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
    p := V3(base_p.xy, 0) + transform.offset
    near_clip_plane :: 0.2
    distance_above_target := camera.distance_above_target
    
    switch camera.mode {
      case .None: unreachable()
      case .Perspective:
        base_z: f32
        
        if UseDebugCamera {
            distance_above_target *= DebugCameraDistance
        }
        
        distance_to_p_z := distance_above_target - p.z
        // TODO(viktor): transform.scale is unused
        if distance_to_p_z > near_clip_plane {
            raw := V3(p.xy, 1)
            projected := camera.focal_length * raw / distance_to_p_z

            result.scale = projected.z  * camera.meters_to_pixels_for_monitor  
            result.p     = projected.xy * camera.meters_to_pixels_for_monitor + camera.screen_center  + v2{0, result.scale * base_z}
            result.valid = true
        }
        
      case .Orthographic:
        result.p     = camera.meters_to_pixels_for_monitor * p.xy + camera.screen_center
        result.scale = camera.meters_to_pixels_for_monitor
        result.valid = true
    }

    result.sort_key = 4096 * (p.z + 0.5 * (transform.upright ? 1 : 0)) - p.y
    
    return result
}

unproject_with_transform :: proc(camera: Camera, transform: Transform, pixels_xy: v2) -> (result: v3) {
    result.xy = (pixels_xy - camera.screen_center) / camera.meters_to_pixels_for_monitor 
    result.z  = transform.offset.z
    
    switch camera.mode {
      case .None:         unreachable()
      case .Orthographic: // nothing
      case .Perspective:  result.xy *= (camera.distance_above_target - result.z) / camera.focal_length
    }
    
    result -= transform.offset

    return result
}