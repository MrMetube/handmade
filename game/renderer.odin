package game

import "core:fmt"
import "core:simd"
import "core:simd/x86"

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

RenderGroup :: struct {
    assets:              ^Assets,
    missing_asset_count: i32,
    assets_should_be_locked: b32,
    
    push_buffer:      []u8,
    push_buffer_size: u32,
    
    transform:                       Transform,
    global_alpha:                    f32,
    monitor_half_diameter_in_meters: v2,
}

Transform :: struct {
    meters_to_pixels_for_monitor: f32,
    screen_center:                v2,
    
    focal_length:          f32, // meters the player is sitting from their monitor
    distance_above_target: f32,
    
    scale:  f32,
    offset: v3,
    
    orthographic: b32,
}

EnvironmentMap :: struct {
    pz:  f32,
    LOD: [4]Bitmap,
}

// TODO(viktor): Why always prefix rendergroup?
// NOTE(viktor): RenderGroupEntry is a "compact discriminated union"
RenderGroupEntryHeader :: struct {
    type: typeid,
}

RenderGroupEntryClear :: struct {
    color:  v4,
}

RenderGroupEntryBitmap :: struct {
    color:  v4,
    p:      v2,
    size:   v2,
    
    id:     BitmapId,
    bitmap: Bitmap,
}

RenderGroupEntryRectangle :: struct {
    color:  v4,
    p:     v2,
    size:  v2,
}

RenderGroupEntryCoordinateSystem :: struct {
    color:  v4,
    origin, x_axis, y_axis: v2,

    pixels_to_meters: f32,
    
    texture, normal:        Bitmap,
    top, middle, bottom:    EnvironmentMap,
}

make_render_group :: proc(arena: ^Arena, assets: ^Assets, max_push_buffer_size: u64, assets_should_be_locked: b32) -> (result: ^RenderGroup) {
    result = push(arena, RenderGroup)
    
    max_push_buffer_size := max_push_buffer_size
    if max_push_buffer_size == 0 {
        max_push_buffer_size = arena_remaining_size(arena)
    }
    result.push_buffer = push(arena, u8, max_push_buffer_size)

    result.push_buffer_size = 0
    result.global_alpha = 1
    result.assets = assets
    result.assets_should_be_locked = assets_should_be_locked

    result.transform.scale  = 1
    result.transform.offset = 0

    return result
}

perspective :: #force_inline proc(group: ^RenderGroup, pixel_size: [2]i32, meters_to_pixels, focal_length, distance_above_target: f32) {
    group.transform.orthographic = false
    
    group.transform.screen_center = 0.5 * vec_cast(f32, pixel_size)
    group.transform.meters_to_pixels_for_monitor = meters_to_pixels
    // TODO(viktor): need to adjust this based on buffer size
    pixels_to_meters := 1.0 / meters_to_pixels
    group.monitor_half_diameter_in_meters = 0.5 * vec_cast(f32, pixel_size) * pixels_to_meters
    
    
    group.transform.distance_above_target = distance_above_target
    group.transform.focal_length          = focal_length
}

orthographic :: #force_inline proc(group: ^RenderGroup, pixel_size: [2]i32, meters_to_pixels: f32) {
    group.transform.orthographic = true
    
    group.transform.screen_center = 0.5 * vec_cast(f32, pixel_size)
    group.transform.meters_to_pixels_for_monitor = meters_to_pixels
    // TODO(viktor): need to adjust this based on buffer size
    group.monitor_half_diameter_in_meters = 0.5 * meters_to_pixels
    
    
    group.transform.distance_above_target = 10
    group.transform.focal_length          = 10
}

push_render_element :: #force_inline proc(group: ^RenderGroup, $T: typeid) -> (result: ^T) {
    header_size := cast(u32) size_of(RenderGroupEntryHeader)
    size := cast(u32) size_of(T) + header_size
    if group.push_buffer_size + size < auto_cast len(group.push_buffer) {
        header := cast(^RenderGroupEntryHeader) &group.push_buffer[group.push_buffer_size]
        header.type = typeid_of(T)

        result = cast(^T) &group.push_buffer[group.push_buffer_size + header_size]

        group.push_buffer_size += size
    } else {
        unreachable()
    }

    return result
}

all_assets_valid :: #force_inline proc(group: ^RenderGroup) -> (result: b32) {
    result = group.missing_asset_count == 0
    return result
}

push_bitmap :: #force_inline proc(group: ^RenderGroup, id: BitmapId, height: f32, offset := v3{}, color := v4{1,1,1,1}) {
    bitmap := get_bitmap(group.assets, id, group.assets_should_be_locked)
    if bitmap != nil {
        push_bitmap_raw(group, bitmap^, height, offset, color, id)
    } else {
        load_bitmap(group.assets, id, group.assets_should_be_locked)
        group.missing_asset_count += 1
    }
}
push_bitmap_raw :: #force_inline proc(group: ^RenderGroup, bitmap: Bitmap, height: f32, offset := v3{}, color := v4{1,1,1,1}, asset_id: BitmapId = 0) {
    size  := v2{bitmap.width_over_height, 1} * height
    // TODO(viktor): recheck alignments
    align := bitmap.align_percentage * size
    p     := offset - v3{align.x, -align.y, 0}

    basis_p, scale, valid := project_with_transform(group.transform, p)

    if valid {
        element := push_render_element(group, RenderGroupEntryBitmap)
        alpha := v4{1,1,1, group.global_alpha}

        if element != nil {
            element.bitmap = bitmap
            element.id     = asset_id
            
            element.color  = color * alpha
            element.p      = basis_p
            element.size   = scale * size
        }
    }
}

push_rectangle :: #force_inline proc(group: ^RenderGroup, offset:v3, size: v2, color:= v4{1,1,1,1}) {
    p := V3(offset.xy + size * 0.5, 0)
    basis_p, scale, valid := project_with_transform(group.transform, p)
    
    if valid {
        element := push_render_element(group, RenderGroupEntryRectangle)
        alpha := v4{1,1,1, group.global_alpha}

        if element != nil {
            element.color     = color * alpha
            element.size      = scale * size
            element.p         = basis_p - 0.5 * element.size
        }
    }
}

push_rectangle_outline :: #force_inline proc(group: ^RenderGroup, offset:v3, size: v2, color:= v4{1,1,1,1}, thickness: f32 = 0.1) {
    // TODO(viktor): there are rounding issues with draw_rectangle
    // NOTE(viktor): Top and Bottom
    push_rectangle(group, offset - {0, size.y*0.5, 0}, {size.x+thickness, thickness}, color)
    push_rectangle(group, offset + {0, size.y*0.5, 0}, {size.x+thickness, thickness}, color)

    // NOTE(viktor): Left and Right
    push_rectangle(group, offset - {size.x*0.5, 0, 0}, {thickness, size.y-thickness}, color)
    push_rectangle(group, offset + {size.x*0.5, 0, 0}, {thickness, size.y-thickness}, color)
}

coordinate_system :: #force_inline proc(group: ^RenderGroup, color:= v4{1,1,1,1}) -> (result: ^RenderGroupEntryCoordinateSystem) {
    // p, scale, valid := get_render_entity_basis_p(group.transform, entry, screen_size)
    
    // if valid {
    //     result = push_render_element(group, RenderGroupEntryCoordinateSystem)
    //     if result != nil {
    //         result.color = color
    //     }
    // }

    return result
}

push_hitpoints :: proc(group: ^RenderGroup, entity: ^Entity, offset_y: f32) {
    if entity.hit_point_max > 1 {
        health_size: v2 = 0.1
        spacing_between: f32 = health_size.x * 1.5
        health_x := -0.5 * (cast(f32) entity.hit_point_max - 1) * spacing_between

        for index in 0..<entity.hit_point_max {
            hit_point := entity.hit_points[index]
            color := hit_point.filled_amount == 0 ? Gray : Red
            push_rectangle(group, {health_x, -offset_y, 0}, health_size, color)
            health_x += spacing_between
        }
    }

}

clear :: proc(group: ^RenderGroup, color: v4) {
    entry := push_render_element(group, RenderGroupEntryClear)
    if entry != nil {
        entry.color = color
    }
}

get_camera_rectangle_at_target :: #force_inline proc(group: ^RenderGroup) -> (result: Rectangle2) {
    result = get_camera_rectangle_at_distance(group, group.transform.distance_above_target)

    return result
}

get_camera_rectangle_at_distance :: #force_inline proc(group: ^RenderGroup, distance_from_camera: f32) -> (result: Rectangle2) {
    camera_half_diameter := unproject_with_transform(group.transform, group.monitor_half_diameter_in_meters, distance_from_camera)
    result = rectangle_center_half_diameter(v2{}, camera_half_diameter)

    return result
}

project_with_transform :: #force_inline proc(transform: Transform, base_p: v3) -> (position: v2, scale: f32, valid: b32) {
    p := V3(base_p.xy, 0) + transform.offset
    near_clip_plane :: 0.2
    distance_above_target := transform.distance_above_target
    
    if !transform.orthographic {
        base_z : f32//base_p.z
        
        //
        // Debug camera
        //
        when false {
            // TODO(viktor): how do we want to control the debug camera?
            distance_above_target *= 5
        }
        
        distance_to_p_z := distance_above_target - p.z
        // TODO(viktor): transform.scale is unused
        if distance_to_p_z > near_clip_plane {
            raw := V3(p.xy, 1)
            projected := transform.focal_length * raw / distance_to_p_z

            position = transform.screen_center + projected.xy * transform.meters_to_pixels_for_monitor + v2{0, scale * base_z}
            scale    =                           projected.z  * transform.meters_to_pixels_for_monitor
            valid    = true
        }
        
    } else{
        position = transform.screen_center + transform.meters_to_pixels_for_monitor * p.xy
        scale = transform.meters_to_pixels_for_monitor
        valid = true
    }

    return position, scale, valid
}

unproject_with_transform :: #force_inline proc(transform: Transform, projected: v2, distance_from_camera: f32) -> (result: v2) {
    result = projected * (distance_from_camera / transform.focal_length)

    return result
}

TileRenderWork :: struct {
    group:  ^RenderGroup, 
    target: Bitmap,
    
    clip_rect: Rectangle2i, 
}

do_tile_render_work : PlatformWorkQueueCallback : proc(data: rawpointer) {
    data := cast(^TileRenderWork) data

    assert(data.group != nil)
    assert(data.target.memory != nil)
    
    scoped_timed_block(.render_to_output)

    render_to_output(data.group, data.target, data.clip_rect, true)
    render_to_output(data.group, data.target, data.clip_rect, false)
}

tiled_render_group_to_output :: proc(queue: ^PlatformWorkQueue, group: ^RenderGroup, target: Bitmap) {
    assert(cast(uintpointer) raw_data(target.memory) & (16 - 1) == 0)
    
    /* TODO(viktor):
        - Make sure the tiles are all cache-aligned
        - Can we get hyperthreads synced so they do interleaved lines?
        - How big should the tiles be for performance?
        - Actually ballpark the memory bandwidth for our DrawRectangleQuickly
        - Re-test some of our instruction choices
    */
    
    tile_count :: [2]i32{4, 4}
    work: [tile_count.x * tile_count.y]TileRenderWork
    
    tile_size  := [2]i32{target.width, target.height} / tile_count
    tile_size.x = ((tile_size.x + 3) / 4) * 4
    
    work_index: i32
    for y in 0..<tile_count.y {
        for x in 0..<tile_count.x {
            it := &work[work_index]
            
            it.group = group
            it.target = target
            
            it.clip_rect.min = tile_size * {x, y}
            it.clip_rect.max = it.clip_rect.min + tile_size
            
            if x == tile_count.x-1 {
                it.clip_rect.max.x = target.width
            }
            if y == tile_count.y-1 {
                it.clip_rect.max.y = target.height
            }
            
            when false {
                do_tile_render_work(it)
            } else {
                Platform.enqueue_work(queue, do_tile_render_work, it)
            }
            
            work_index += 1
        }
    }

    Platform.complete_all_work(queue)
}

render_group_to_output :: proc(group: ^RenderGroup, target: Bitmap) {
    assert(transmute(u64) raw_data(target.memory) & (16 - 1) == 0)
    
    work := TileRenderWork{
        group = group,
        target = target,
        clip_rect = {
            min = 0,
            max = {target.width, target.height},
        },
    }
    
    do_tile_render_work(&work)
}

render_to_output :: proc(group: ^RenderGroup, target: Bitmap, clip_rect: Rectangle2i, even: b32) {
    null_pixels_to_meters :: 1

    for base_address: u32 = 0; base_address < group.push_buffer_size; {
        header := cast(^RenderGroupEntryHeader) &group.push_buffer[base_address]
        base_address += size_of(RenderGroupEntryHeader)

        data := &group.push_buffer[base_address]

        switch header.type {
        case RenderGroupEntryClear:
            entry := cast(^RenderGroupEntryClear) data
            base_address += auto_cast size_of(entry^)

            draw_rectangle(target, group.transform.screen_center, group.transform.screen_center * 2, entry.color, clip_rect, even)

        case RenderGroupEntryRectangle:
            entry := cast(^RenderGroupEntryRectangle) data
            base_address += auto_cast size_of(entry^)

            draw_rectangle(target, entry.p, entry.size, entry.color, clip_rect, even)

        case RenderGroupEntryBitmap:
            entry := cast(^RenderGroupEntryBitmap) data
            base_address += auto_cast size_of(entry^)

            when true {
                draw_rectangle_quickly(target,
                    entry.p, {entry.size.x, 0}, {0, entry.size.y},
                    entry.bitmap, entry.color,
                    null_pixels_to_meters, clip_rect, even,
                )
            } else {
                draw_rectangle_slowly(target,
                    entry.p, {entry.size.x, 0}, {0, entry.size.y},
                    entry.bitmap, {}, entry.color,
                    {}, {}, {},
                    null_pixels_to_meters,
                )
            }

        case RenderGroupEntryCoordinateSystem:
            entry := cast(^RenderGroupEntryCoordinateSystem) data
            base_address += auto_cast size_of(entry^)
            when true {
                draw_rectangle_quickly(target,
                    entry.origin, entry.x_axis, entry.y_axis,
                    entry.texture, /* entry.normal, */ entry.color,
                    /* entry.top, entry.middle, entry.bottom, */
                    null_pixels_to_meters, clip_rect, even,
                )
            } else {
                draw_rectangle_slowly(target,
                    entry.origin, entry.x_axis, entry.y_axis,
                    entry.texture, entry.normal, entry.color,
                    entry.top, entry.middle, entry.bottom,
                    null_pixels_to_meters,
                )
            }

            p := entry.origin
            x := p + entry.x_axis
            y := p + entry.y_axis
            size := v2{10, 10}

            draw_rectangle(target, p, size, Red, clip_rect, even)
            draw_rectangle(target, x, size, Red * 0.7, clip_rect, even)
            draw_rectangle(target, y, size, Red * 0.7, clip_rect, even)

        case:
            fmt.panicf("Unhandled Entry: %v", header.type)
        }
    }
}

draw_bitmap :: proc(buffer: Bitmap, bitmap: Bitmap, center: v2, color: v4) {
    rounded_center := round(center, i32)

    left   := rounded_center.x - bitmap.width  / 2
    top	   := rounded_center.y - bitmap.height / 2
    right  := left + bitmap.width
    bottom := top  + bitmap.height

    src_left, src_top: i32
    if left < 0 {
        src_left = -left
        left = 0
    }
    if top < 0 {
        src_top = -top
        top = 0
    }
    bottom = min(bottom, buffer.height)
    right  = min(right,  buffer.width)

    src_row :=  bitmap.width *  src_top +  src_left
    dst_row :=  left +  top *  buffer.width
    for _ in top..< bottom  {
        src_index := src_row
        dst_index := dst_row
        defer dst_row +=  buffer.width
        defer src_row +=  bitmap.width

        for _ in left..< right  {
            src := bitmap.memory[src_index]
            dst := &buffer.memory[dst_index]
            defer src_index += 1
            defer dst_index += 1

            texel := vec_cast(f32, src)
            texel = srgb_255_to_linear_1(texel)
            texel *= color.a

            pixel := vec_cast(f32, dst^)
            pixel = srgb_255_to_linear_1(pixel)

            result := (1 - texel.a) * pixel + texel
            result = linear_1_to_srgb_255(result)

            dst^ = vec_cast(u8, result + 0.5)
        }
    }
}

 @( enable_target_feature="sse,sse2",
    optimization_mode="favor_size",
)
draw_rectangle_quickly :: proc(buffer: Bitmap, origin, x_axis, y_axis: v2, texture: Bitmap, color: v4, pixels_to_meters: f32, clip_rect: Rectangle2i, even: b32) {
    scoped_timed_block(.draw_rectangle_quickly)
    assert(texture.memory != nil)
    assert(texture.width  >= 0)
    assert(texture.height >= 0)
    assert(texture.width  >  0)

    // NOTE(viktor): premultiply color
    color := color
    color.rgb *= color.a
/* 
    length_x_axis := length(x_axis)
    length_y_axis := length(y_axis)
    normal_x_axis := (length_y_axis / length_x_axis) * x_axis
    normal_y_axis := (length_x_axis / length_y_axis) * y_axis
    // NOTE(viktor): normal_z_scale could be a parameter if we want people
    // to have control over the amount of scaling in the z direction that
    // the normals appear to have
    normal_z_scale := lerp(length_x_axis, length_y_axis, 0.5)
 */
    inverted_infinity_rectangle :: #force_inline proc() -> (result: Rectangle2i) {
        result.min = max(i32)
        result.max = min(i32)
        
        return result
    }
    
    fill_rect := inverted_infinity_rectangle()
    for testp in ([?]v2{origin, (origin+x_axis), (origin + y_axis), (origin + x_axis + y_axis)}) {
        floorp := floor(testp, i32)
        ceilp  := ceil(testp, i32)
        if fill_rect.min.x > floorp.x do fill_rect.min.x = floorp.x
        if fill_rect.min.y > floorp.y do fill_rect.min.y = floorp.y
        if fill_rect.max.x < ceilp.x  do fill_rect.max.x = ceilp.x
        if fill_rect.max.y < ceilp.y  do fill_rect.max.y = ceilp.y
    }
    clip_rect := clip_rect
    fill_rect = rectangle_intersection(fill_rect, clip_rect)

    if !even == (fill_rect.min.y & 1 != 0) {
        fill_rect.min.y += 1
    }

    if rectangle_has_area(fill_rect) {
        // TODO(viktor): properly go to 8 wide
        maskFF       := cast(i32x4) 0xff
        maskFFFFFFFF := cast(u32x4) 0xffffffff
        
        clip_mask       := maskFFFFFFFF
        start_clip_mask := clip_mask
        end_clip_mask   := clip_mask
        
        start_clip_masks := [?]u32x4 {
            transmute(u32x4) x86._mm_slli_si128(transmute(simd.i64x2) start_clip_mask, 0*4),
            transmute(u32x4) x86._mm_slli_si128(transmute(simd.i64x2) start_clip_mask, 1*4),
            transmute(u32x4) x86._mm_slli_si128(transmute(simd.i64x2) start_clip_mask, 2*4),
            transmute(u32x4) x86._mm_slli_si128(transmute(simd.i64x2) start_clip_mask, 3*4),
        }  
              
        end_clip_masks := [?]u32x4 {
            transmute(u32x4) x86._mm_srli_si128(transmute(simd.i64x2) end_clip_mask, 0*4),
            transmute(u32x4) x86._mm_srli_si128(transmute(simd.i64x2) end_clip_mask, 3*4),
            transmute(u32x4) x86._mm_srli_si128(transmute(simd.i64x2) end_clip_mask, 2*4),
            transmute(u32x4) x86._mm_srli_si128(transmute(simd.i64x2) end_clip_mask, 1*4),
        }
        
        // TODO(viktor): IMPORTANT(viktor): fix this clipping
        if fill_rect.min.x & 3 != 0 {
            start_clip_mask = start_clip_masks[fill_rect.min.x & 3]
            fill_rect.min.x = fill_rect.min.x & (~i32(3))
        }

        if fill_rect.max.x & 3 != 0 {
            end_clip_mask = end_clip_masks[fill_rect.max.x & 3]
            fill_rect.max.x = (fill_rect.max.x & (~i32(3))) + 4
        }
        
        normal_x_axis := x_axis * 1 / length_squared(x_axis)
        normal_y_axis := y_axis * 1 / length_squared(y_axis)
        
        texture_width_x4  := cast(f32x4) (texture.width  - 2)
        texture_height_x4 := cast(f32x4) (texture.height - 2)

        inv_255         := cast(f32x4) (1.0 / 255.0)
        max_color_value := cast(f32x4) (255 * 255)
        
        zero_i := cast(i32x4) 0

        shift8  := cast(u32x4)  8
        shift16 := cast(u32x4) 16
        shift24 := cast(u32x4) 24

        color_r := cast(f32x4) color.r
        color_g := cast(f32x4) color.g
        color_b := cast(f32x4) color.b
        color_a := cast(f32x4) color.a

        normal_x_axis_x := cast(f32x4) normal_x_axis.x
        normal_x_axis_y := cast(f32x4) normal_x_axis.y
        normal_y_axis_x := cast(f32x4) normal_y_axis.x
        normal_y_axis_y := cast(f32x4) normal_y_axis.y
        
        texture_width := cast(i32x4) texture.width

        delta_x := cast(f32x4) fill_rect.min.x - cast(f32x4) origin.x + f32x4{ 0, 1, 2, 3}
        delta_y := cast(f32x4) fill_rect.min.y - cast(f32x4) origin.y
        
        delta_y_n_x_axis_y := delta_y * normal_x_axis_y
        delta_y_n_y_axis_y := delta_y * normal_y_axis_y
        
        scoped_timed_block_counted(.test_pixel, cast(i64) rectangle_clamped_area(fill_rect) / 2)
        for y := fill_rect.min.y; y < fill_rect.max.y; y += 2 {
            // u := dot(delta, n_x_axis)
            // v := dot(delta, n_y_axis)
            u := delta_x * normal_x_axis_x + delta_y_n_x_axis_y
            v := delta_x * normal_y_axis_x + delta_y_n_y_axis_y
            defer {
                delta_y_n_x_axis_y += normal_x_axis_y * 2
                delta_y_n_y_axis_y += normal_y_axis_y * 2
            }

            clip_mask = start_clip_mask
            
            for x := fill_rect.min.x; x < fill_rect.max.x; x += 4 {
                defer {
                    u += normal_x_axis_x * 4
                    v += normal_y_axis_x * 4
                    
                    if x + 4 >= fill_rect.max.x {
                        clip_mask = end_clip_mask
                    } else {
                        clip_mask = maskFFFFFFFF
                    }
                }
                
                // u >= 0 && u <= 1 && v >= 0 && v <= 1
                write_mask := transmute(i32x4) (clip_mask & simd.lanes_ge(u, 0) & simd.lanes_le(u, 1) & simd.lanes_ge(v, 0) & simd.lanes_le(v, 1))

                // TODO(viktor): recheck later if this helps
                // if x86._mm_movemask_epi8((cast([^]simd.i64x2) &write_mask)[0]) != 0 && x86._mm_movemask_epi8((cast([^]simd.i64x2) &write_mask)[1]) != 0 
                #no_bounds_check {
                    pixel := cast(^[4]ByteColor) &buffer.memory[y * buffer.width + x]
                    original_pixel := simd.masked_load(pixel, zero_i, write_mask)
                    
                    u = clamp_01(u)
                    v = clamp_01(v)

                    // NOTE(viktor): Bias texture coordinates to start on the 
                    // boundary between the 0,0 and 1,1 pixels
                    tx := u * texture_width_x4  + 0.5
                    ty := v * texture_height_x4 + 0.5

                    sx := cast(i32x4) tx
                    sy := cast(i32x4) ty

                    fx := tx - cast(f32x4) sx
                    fy := ty - cast(f32x4) sy

                    // NOTE(viktor): bilinear sample
                    fetch := sy * texture_width + sx
                    
                    fetch_0 := (cast([^]i32)&fetch)[0]
                    fetch_1 := (cast([^]i32)&fetch)[1]
                    fetch_2 := (cast([^]i32)&fetch)[2]
                    fetch_3 := (cast([^]i32)&fetch)[3]
                    
                    texel_0 := cast([^]i32) &texture.memory[fetch_0]
                    texel_1 := cast([^]i32) &texture.memory[fetch_1]
                    texel_2 := cast([^]i32) &texture.memory[fetch_2]
                    texel_3 := cast([^]i32) &texture.memory[fetch_3]
                    
                    sample_a := i32x4{ texel_0[0],                 texel_1[0],                 texel_2[0],                 texel_3[0],                }
                    sample_b := i32x4{ texel_0[1],                 texel_1[1],                 texel_2[1],                 texel_3[1],                }
                    sample_c := i32x4{ texel_0[texture.width],     texel_1[texture.width],     texel_2[texture.width],     texel_3[texture.width],    }
                    sample_d := i32x4{ texel_0[texture.width + 1], texel_1[texture.width + 1], texel_2[texture.width + 1], texel_3[texture.width + 1] }

                    ta_r := cast(f32x4) (maskFF &          sample_a           )
                    ta_g := cast(f32x4) (maskFF & simd.shr(sample_a,  shift8) )
                    ta_b := cast(f32x4) (maskFF & simd.shr(sample_a,  shift16))
                    ta_a := cast(f32x4) (maskFF & simd.shr(sample_a,  shift24))

                    tb_r := cast(f32x4) (maskFF &          sample_b           )
                    tb_g := cast(f32x4) (maskFF & simd.shr(sample_b,  shift8) )
                    tb_b := cast(f32x4) (maskFF & simd.shr(sample_b,  shift16))
                    tb_a := cast(f32x4) (maskFF & simd.shr(sample_b,  shift24))

                    tc_r := cast(f32x4) (maskFF &          sample_c           )
                    tc_g := cast(f32x4) (maskFF & simd.shr(sample_c,  shift8) )
                    tc_b := cast(f32x4) (maskFF & simd.shr(sample_c,  shift16))
                    tc_a := cast(f32x4) (maskFF & simd.shr(sample_c,  shift24))

                    td_r := cast(f32x4) (maskFF &          sample_d           )
                    td_g := cast(f32x4) (maskFF & simd.shr(sample_d,  shift8) )
                    td_b := cast(f32x4) (maskFF & simd.shr(sample_d,  shift16))
                    td_a := cast(f32x4) (maskFF & simd.shr(sample_d,  shift24))

                    pixel_r := cast(f32x4) (maskFF &          original_pixel           )
                    pixel_g := cast(f32x4) (maskFF & simd.shr(original_pixel,  shift8) )
                    pixel_b := cast(f32x4) (maskFF & simd.shr(original_pixel,  shift16))
                    pixel_a := cast(f32x4) (maskFF & simd.shr(original_pixel,  shift24))

                    // NOTE(viktor): srgb to linear
                    ta_r = square(ta_r)
                    ta_g = square(ta_g)
                    ta_b = square(ta_b)

                    tb_r = square(tb_r)
                    tb_g = square(tb_g)
                    tb_b = square(tb_b)

                    tc_r = square(tc_r)
                    tc_g = square(tc_g)
                    tc_b = square(tc_b)

                    td_r = square(td_r)
                    td_g = square(td_g)
                    td_b = square(td_b)

                    pixel_r = square(pixel_r)
                    pixel_g = square(pixel_g)
                    pixel_b = square(pixel_b)

                    // NOTE(viktor): bilinear blend
                    ifx := 1 - fx
                    ify := 1 - fy
                    l0  := ify * ifx
                    l1  := ify * fx
                    l2  :=  fy * ifx
                    l3  :=  fy * fx

                    texel_r := l0 * ta_r + l1 * tb_r + l2 * tc_r + l3 * td_r
                    texel_g := l0 * ta_g + l1 * tb_g + l2 * tc_g + l3 * td_g
                    texel_b := l0 * ta_b + l1 * tb_b + l2 * tc_b + l3 * td_b
                    texel_a := l0 * ta_a + l1 * tb_a + l2 * tc_a + l3 * td_a

                    texel_r *= color_r 
                    texel_g *= color_g 
                    texel_b *= color_b 
                    texel_a *= color_a 

                    texel_r = clamp(texel_r, 0, max_color_value)
                    texel_g = clamp(texel_g, 0, max_color_value)
                    texel_b = clamp(texel_b, 0, max_color_value)

                    // NOTE(viktor): blend with target pixel
                    inv_texel_a := (1 - (inv_255 * texel_a))
                    blended_r := inv_texel_a * pixel_r + texel_r
                    blended_g := inv_texel_a * pixel_g + texel_g
                    blended_b := inv_texel_a * pixel_b + texel_b
                    blended_a := inv_texel_a * pixel_a + texel_a

                    // NOTE(viktor): linear to srgb
                    blended_r  = square_root(blended_r)
                    blended_g  = square_root(blended_g)
                    blended_b  = square_root(blended_b)

                    intr := cast(i32x4) blended_r
                    intg := cast(i32x4) blended_g
                    intb := cast(i32x4) blended_b
                    inta := cast(i32x4) blended_a
                    
                    mixed := intr | simd.shl(intg, shift8) | simd.shl(intb, shift16) | simd.shl(inta, shift24)

                    simd.masked_store(pixel, mixed, write_mask)
                }
            }
        }
    }
}

draw_rectangle_slowly :: proc(buffer: Bitmap, origin, x_axis, y_axis: v2, texture, normal_map: Bitmap, color: v4, top, middle, bottom: EnvironmentMap, pixels_to_meters: f32) {
    scoped_timed_block(.draw_rectangle_slowly)
    assert(texture.memory != nil)

    // NOTE(viktor): premultiply color
    color := color
    color.rgb *= color.a

    length_x_axis := length(x_axis)
    length_y_axis := length(y_axis)
    normal_x_axis := (length_y_axis / length_x_axis) * x_axis
    normal_y_axis := (length_x_axis / length_y_axis) * y_axis
    // NOTE(viktor): normal_z_scale could be a parameter if we want people
    // to have control over the amount of scaling in the z direction that
    // the normals appear to have
    normal_z_scale := lerp(length_x_axis, length_y_axis, 0.5)

    inv_x_len_squared := 1 / length_squared(x_axis)
    inv_y_len_squared := 1 / length_squared(y_axis)

    minimum := [2]i32{
        floor(min(origin.x, (origin+x_axis).x, (origin + y_axis).x, (origin + x_axis + y_axis).x), i32),
        floor(min(origin.y, (origin+x_axis).y, (origin + y_axis).y, (origin + x_axis + y_axis).y), i32),
    }

    maximum := [2]i32{
        ceil( max(origin.x, (origin+x_axis).x, (origin + y_axis).x, (origin + x_axis + y_axis).x), i32),
        ceil( max(origin.y, (origin+x_axis).y, (origin + y_axis).y, (origin + x_axis + y_axis).y), i32),
    }

    width_max      := buffer.width-1
    height_max     := buffer.height-1
    inv_width_max  := 1 / cast(f32) width_max
    inv_height_max := 1 / cast(f32) height_max

    // TODO(viktor): this will need to be specified separately
    origin_z: f32 = 0.5
    origin_y     := (origin + 0.5*x_axis + 0.5*y_axis).y
    fixed_cast_y := inv_height_max * origin_y

    maximum = clamp(maximum, [2]i32{0,0}, [2]i32{width_max, height_max})
    minimum = clamp(minimum, [2]i32{0,0}, [2]i32{width_max, height_max})

    for y in minimum.y..=maximum.y {
        for x in minimum.x..=maximum.x {
            pixel_p := vec_cast(f32, x, y)
            delta := pixel_p - origin
            edge0 := dot(delta                  , -perpendicular(x_axis))
            edge1 := dot(delta - x_axis         , -perpendicular(y_axis))
            edge2 := dot(delta - x_axis - y_axis,  perpendicular(x_axis))
            edge3 := dot(delta - y_axis         ,  perpendicular(y_axis))

            if edge0 < 0 && edge1 < 0 && edge2 < 0 && edge3 < 0 {
                Card :: true
                when Card {
                    screen_space_uv := v2{cast(f32) x, fixed_cast_y} * {inv_width_max, inv_height_max}
                    z_difference    := pixels_to_meters * (cast(f32) y - origin_y)
                } else {
                    screen_space_uv := vec_cast(f32, x, y) * {inv_width_max, inv_height_max}
                    z_difference: f32
                }

                u := dot(delta, x_axis) * inv_x_len_squared
                v := dot(delta, y_axis) * inv_y_len_squared

                // TODO(viktor): this epsilon should not exists
                EPSILON :: 0.000001
                assert(u + EPSILON >= 0 && u - EPSILON <= 1)
                assert(v + EPSILON >= 0 && v - EPSILON <= 1)

                // TODO(viktor): formalize texture boundaries
                t := v2{u,v} * vec_cast(f32, texture.width-2, texture.height-2)
                s := floor(t, i32)
                f := t - vec_cast(f32, s)

                assert(s.x >= 0 && s.x < texture.width)
                assert(s.y >= 0 && s.y < texture.height)

                t00, t01, t10, t11 := sample_bilinear(texture, s)

                t00 = srgb_255_to_linear_1(t00)
                t01 = srgb_255_to_linear_1(t01)
                t10 = srgb_255_to_linear_1(t10)
                t11 = srgb_255_to_linear_1(t11)

                texel := blend_bilinear(t00, t01, t10, t11, f)

                if normal_map.memory != nil {
                    normal := blend_bilinear(sample_bilinear(normal_map, s), f)
                    normal = unscale_and_bias(normal)
                    normal.xy = normal.x * normal_x_axis + normal.y * normal_y_axis
                    normal.z *= normal_z_scale
                    normal = normalize(normal)

                    // NOTE(viktor): the eye-vector is always assumed to be [0, 0, 1]
                    // This is just a simplified version of the reflection -e + 2 * dot(e, n) * n
                    bounce_direction := 2 * normal.z * normal.xyz
                    bounce_direction.z -= 2
                    // TODO(viktor): eventually we need to support two mappings
                    // one for top-down view(which we do not do now) and one
                    // for sideways, which is happening here.
                    bounce_direction.z = -bounce_direction.z

                    far_map: EnvironmentMap
                    t_environment := bounce_direction.y
                    t_far_map: f32
                    pz := origin_z + z_difference
                    if  t_environment < -0.5 {
                        far_map = bottom
                        t_far_map = -1 - 2 * t_environment
                    } else if t_environment > 0.5 {
                        far_map = top
                        t_far_map = (t_environment - 0.5) * 2
                    }
                    t_far_map = square(t_far_map)

                    light_color := v3{} // TODO(viktor): how do we sample from the middle environment m?ap
                    if t_far_map > 0 {
                        distance_from_map_in_z := far_map.pz - pz
                        far_map_color := sample_environment_map(screen_space_uv, bounce_direction, normal.w, far_map, distance_from_map_in_z)
                        light_color = lerp(light_color, far_map_color, t_far_map)
                    }

                    texel.rgb += texel.a * light_color.rgb
                    when false {
                        // NOTE(viktor): draws the bounce direction
                        texel.rgb = 0.5 + 0.5 * bounce_direction
                        texel.rgb *= texel.a
                    }
                }

                texel *= color
                texel.rgb = clamp_01(texel.rgb)

                dst := &buffer.memory[y * buffer.width + x]
                pixel := srgb_255_to_linear_1(vec_cast(f32, dst^))


                blended := (1 - texel.a) * pixel + texel
                blended = linear_1_to_srgb_255(blended)

                dst^ = vec_cast(u8, blended)
            }
        }
    }
}

draw_rectangle :: proc(buffer: Bitmap, center: v2, size: v2, color: v4, clip_rect: Rectangle2i, even: b32){
    rounded_center := floor(center, i32)
    rounded_size   := floor(size, i32)

    fill_rect := Rectangle2i{
        rounded_center - rounded_size / 2, 
        rounded_center - rounded_size / 2 + rounded_size,
    }
    
    fill_rect = rectangle_intersection(fill_rect, clip_rect)
    if !even == (fill_rect.min.y & 1 != 0) {
        fill_rect.min.y += 1
    }

    for y := fill_rect.min.y; y < fill_rect.max.y; y += 2 {
        for x in fill_rect.min.x..<fill_rect.max.x {
            dst := &buffer.memory[y * buffer.width +  x]
            src := color * 255

            dst.r = cast(u8) lerp(cast(f32) dst.r, src.r, clamp_01(color.a))
            dst.g = cast(u8) lerp(cast(f32) dst.g, src.g, clamp_01(color.a))
            dst.b = cast(u8) lerp(cast(f32) dst.b, src.b, clamp_01(color.a))
            // TODO(viktor): compute this
            dst.a = cast(u8) src.a
        }
    }
}

// TODO(viktor): should sample return a pointer instead?
sample :: #force_inline proc(texture: Bitmap, p: [2]i32) -> (result: v4) {
    texel := texture.memory[ p.y * texture.width +  p.x]
    result = vec_cast(f32, texel)

    return result
}

sample_bilinear :: #force_inline proc(texture: Bitmap, p: [2]i32) -> (s00, s01, s10, s11: v4) {
    s00 = sample(texture, p + {0, 0})
    s01 = sample(texture, p + {1, 0})
    s10 = sample(texture, p + {0, 1})
    s11 = sample(texture, p + {1, 1})

    return s00, s01, s10, s11
}

/*
    NOTE(viktor):

    screen_space_uv tells us where the ray is being cast _from_ in
    normalized screen coordinates.

    sample_direction tells us what direction the cast is going
    it does not have to be normalized, but y _must be positive_.

    roughness says which LODs of Map we sample from.

    distance_from_map_in_z says how far the map is from the sample
    point in z, given in meters
*/
sample_environment_map :: #force_inline proc(screen_space_uv: v2, sample_direction: v3, roughness: f32, environment_map: EnvironmentMap, distance_from_map_in_z: f32) -> (result: v3) {
    assert(environment_map.LOD[0].memory != nil)

    // NOTE(viktor): pick which LOD to sample from
    lod_index := round(roughness * cast(f32) (len(environment_map.LOD)-1), i32)
    lod := environment_map.LOD[lod_index]
    lod_size := vec_cast(f32, lod.width, lod.height)

    // NOTE(viktor): compute the distance to the map and the
    // scaling factor for meters-to-UVs
    uvs_per_meter: f32 = 0.1 // TODO(viktor): parameterize
    c := (uvs_per_meter * distance_from_map_in_z) / sample_direction.y
    offset := c * sample_direction.xz

    // NOTE(viktor): Find the intersection point
    uv := screen_space_uv + offset
    uv = clamp_01(uv)

    // NOTE(viktor): bilinear sample
    t        := uv * (lod_size - 2)
    index    := vec_cast(i32, t)
    fraction := t - vec_cast(f32, index)

    assert(index.x >= 0 && index.x < lod.width)
    assert(index.y >= 0 && index.y < lod.height)

    l00, l01, l10, l11 := sample_bilinear(lod, index)

    l00 = srgb_255_to_linear_1(l00)
    l01 = srgb_255_to_linear_1(l01)
    l10 = srgb_255_to_linear_1(l10)
    l11 = srgb_255_to_linear_1(l11)

    result = blend_bilinear(l00, l01, l10, l11, fraction).rgb

    when false {
        // NOTE(viktor): Turn this on to see where in the map you're sampling!
        texel := &lod.memory[lod.start + index.y * lod.width + index.x]
        texel^ = 255
    }

    return result
}

blend_bilinear :: #force_inline proc(s00, s01, s10, s11: v4, t: v2) -> (result: v4) {
    result = lerp( lerp(s00, s01, t.x), lerp(s10, s11, t.x), t.y )

    return result
}

@(require_results)
unscale_and_bias :: #force_inline proc(normal: v4) -> (result: v4) {
    inv_255: f32 = 1.0 / 255.0

    result.xyz = -1 + 2 * (normal.xyz * inv_255)
    result.w = inv_255 * normal.w

    return result
}