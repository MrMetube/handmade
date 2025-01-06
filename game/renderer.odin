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
    push_buffer:      []u8,
    push_buffer_size: u32,
    default_basis:    ^RenderBasis,
    global_alpha:     f32,
    
    meters_to_pixels_for_monitor:    f32,
    monitor_half_diameter_in_meters: v2,
    
    game_camera:   Camera,
    render_camera: Camera,
}

Camera :: struct {
    focal_length:          f32, // meters the player is sitting from their monitor
    distance_above_target: f32,
}

EnvironmentMap :: struct {
    pz:  f32,
    LOD: [4]LoadedBitmap,
}

RenderBasis :: struct {
    p: v3,
}

// TODO(viktor): Why always prefix rendergroup?
// NOTE(viktor): RenderGroupEntry is a "compact discriminated union"
RenderGroupEntryHeader :: struct {
    type: typeid,
}

RenderGroupEntryBasis :: struct {
    basis:  ^RenderBasis,
    offset: v3,
}

RenderGroupEntryClear :: struct {
    color: v4,
}

RenderGroupEntryBitmap :: struct {
    using rendering_basis: RenderGroupEntryBasis,
    
    size:   v2,
    color:  v4,
    bitmap: LoadedBitmap,
}

RenderGroupEntryRectangle :: struct {
    using rendering_basis: RenderGroupEntryBasis,
    
    color: v4,
    size:  v2,
}

RenderGroupEntryCoordinateSystem :: struct {
    origin, x_axis, y_axis: v2,
    color:                  v4,
    texture, normal:        LoadedBitmap,
    
    top, middle, bottom:    EnvironmentMap,
}

make_render_group :: proc(arena: ^Arena, max_push_buffer_size: u32, resolution_pixels: [2]i32) -> (result: ^RenderGroup) {
    result = push(arena, RenderGroup)
    result.push_buffer = push(arena, u8, max_push_buffer_size)
    
    result.push_buffer_size = 0
    
    result.default_basis = push(arena, RenderBasis)
    result.default_basis.p = {0,0,0}
    
    result.global_alpha = 1
    
    monitor_width_in_meters                 :: 0.635
    result.game_camera.focal_length          = 0.6
    result.game_camera.distance_above_target = 8.0
        
    result.render_camera = result.game_camera
    // result.render_camera.distance_above_target = 38
    
    result.meters_to_pixels_for_monitor = cast(f32) resolution_pixels.x * monitor_width_in_meters
    
    pixels_to_meters := 1 / result.meters_to_pixels_for_monitor
    result.monitor_half_diameter_in_meters = 0.5 * pixels_to_meters * vec_cast(f32, resolution_pixels)
    
    return result
}

get_camera_rectangle_at_target :: #force_inline proc(group: ^RenderGroup) -> (result: Rectangle2) {
    result = get_camera_rectangle_at_distance(group, group.game_camera.distance_above_target)
    
    return result
}
get_camera_rectangle_at_distance :: #force_inline proc(group: ^RenderGroup, distance_from_camera: f32) -> (result: Rectangle2) {
    camera_half_diameter := unproject(group, group.monitor_half_diameter_in_meters, distance_from_camera)
    result = rectangle_center_half_diameter(v2{}, camera_half_diameter) 
    
    return result
}

@(require_results)
unproject :: #force_inline proc(group: ^RenderGroup, projected: v2, distance_from_camera: f32) -> (result: v2) {
    result = projected * (distance_from_camera / group.game_camera.focal_length)
    
    return result
}

get_render_entity_basis_p :: #force_inline proc(group: ^RenderGroup, entry: RenderGroupEntryBasis, screen_size:v2) -> (position: v2, scale: f32, valid: b32) {
    near_clip_plane              :: 0.2
    base_p                       := entry.basis.p
    distance_to_p_z              := group.render_camera.distance_above_target - base_p.z
    
    if distance_to_p_z > near_clip_plane {
        raw := V3(base_p.xy + entry.offset.xy, 1)
        projected := group.render_camera.focal_length * raw / distance_to_p_z
        
        screen_center := screen_size * 0.5
        
        position = screen_center + projected.xy * group.meters_to_pixels_for_monitor
        scale    =                 projected.z  * group.meters_to_pixels_for_monitor
        valid    = true
    }
    
    return position, scale, valid
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

push_bitmap :: #force_inline proc(group: ^RenderGroup, bitmap: LoadedBitmap, height: f32, offset:= v3{}, color:= v4{1,1,1,1}) -> (result: ^RenderGroupEntryBitmap) {
    result = push_render_element(group, RenderGroupEntryBitmap)
    alpha := v4{1,1,1, group.global_alpha}
    
    if result != nil {
        result.basis      = group.default_basis
        result.bitmap     = bitmap
        result.offset     = offset
        result.color      = color * alpha
        result.size       = v2{bitmap.width_over_height, 1} * height
        
        align := bitmap.align_percentage * result.size
        result.offset.x -= align.x
        result.offset.y += align.y
    }
    
    return result
}

push_rectangle :: #force_inline proc(group: ^RenderGroup, offset:v3, size: v2, color:= v4{1,1,1,1}) {
    entry := push_render_element(group, RenderGroupEntryRectangle)
    alpha := v4{1,1,1, group.global_alpha}

    if entry != nil {
        entry.basis     = group.default_basis
        entry.color     = color * alpha
        entry.offset.xy = (offset.xy + entry.size * 0.5)
        entry.offset.z  = offset.z
        entry.size      = size
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
    result = push_render_element(group, RenderGroupEntryCoordinateSystem)

    if result != nil {
        result.color = color
    }
    
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

render_to_output :: proc(group: ^RenderGroup, target: LoadedBitmap) {
    scoped_timed_block(.render_to_output)
    
    screen_size      := vec_cast(f32, target.width, target.height)
    screen_center    := screen_size * 0.5
    meters_to_pixels := screen_size.x / 20
    pixels_to_meters := 1.0 / meters_to_pixels
    
    for base_address: u32 = 0; base_address < group.push_buffer_size; {
        header := cast(^RenderGroupEntryHeader) &group.push_buffer[base_address]
        base_address += size_of(RenderGroupEntryHeader)

        data := &group.push_buffer[base_address]
        
        switch header.type {
        case RenderGroupEntryClear:
            entry := cast(^RenderGroupEntryClear) data
            base_address += auto_cast size_of(entry^)
            
            draw_rectangle(target, screen_center, screen_size, entry.color)
        case RenderGroupEntryRectangle:
            entry := cast(^RenderGroupEntryRectangle) data
            base_address += auto_cast size_of(entry^)
            
            // TODO(viktor): handle invalid
            p, scale, valid := get_render_entity_basis_p(group, entry, screen_size)
            draw_rectangle(target, p, scale * entry.size, entry.color)

        case RenderGroupEntryBitmap:
            entry := cast(^RenderGroupEntryBitmap) data
            base_address += auto_cast size_of(entry^)
        
            // TODO(viktor): handle invalid
            p, scale, valid := get_render_entity_basis_p(group, entry, screen_size)
            when true {
                when true {
                    draw_rectangle_quickly_hopefully(target,
                        p, {scale * entry.size.x, 0}, {0, scale * entry.size.y}, 
                        entry.bitmap, entry.color, 
                        pixels_to_meters,
                    )
                } else {
                    draw_rectangle_slowly(target,
                        p, {scale * entry.size.x, 0}, {0, scale * entry.size.y}, 
                        entry.bitmap, {}, entry.color, 
                        {}, {}, {},
                        pixels_to_meters,
                    )
                }
            } else {
                draw_bitmap(target, entry.bitmap, p, clamp_01(entry.color))
            }

        case RenderGroupEntryCoordinateSystem:
            entry := cast(^RenderGroupEntryCoordinateSystem) data
            base_address += auto_cast size_of(entry^)
            when true {
                draw_rectangle_quickly_hopefully(target,
                    entry.origin, entry.x_axis, entry.y_axis, 
                    entry.texture, /* entry.normal, */ entry.color, 
                    /* entry.top, entry.middle, entry.bottom, */
                    pixels_to_meters,
                )
            } else {
                draw_rectangle_slowly(target,
                    entry.origin, entry.x_axis, entry.y_axis, 
                    entry.texture, entry.normal, entry.color, 
                    entry.top, entry.middle, entry.bottom,
                    pixels_to_meters,
                )
            }
        
            p := entry.origin
            x := p + entry.x_axis
            y := p + entry.y_axis
            size := v2{10, 10}
            
            draw_rectangle(target, p, size, Red)
            draw_rectangle(target, x, size, Red * 0.7)
            draw_rectangle(target, y, size, Red * 0.7)
            
        case:
            fmt.panicf("Unhandled Entry: %v", header.type)
        }
    }
}

draw_bitmap :: proc(buffer: LoadedBitmap, bitmap: LoadedBitmap, center: v2, color: v4) {
    rounded_center := round(center)

    left   := rounded_center.x - bitmap.width  / 2
    top	   := rounded_center.y - bitmap.height / 2
    right  := left + bitmap.width
    bottom := top  + bitmap.height

    src_left: i32
    src_top : i32
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

    src_row := bitmap.start + bitmap.pitch * src_top + src_left
    dst_row := left + top * buffer.width
    for _ in top..< bottom  {
        src_index := src_row
        dst_index := dst_row
        defer dst_row += buffer.pitch
        defer src_row += bitmap.pitch
        
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

@(enable_target_feature="sse2"/* , optimization_mode="none" */)
draw_rectangle_quickly_hopefully :: proc(buffer: LoadedBitmap, origin, x_axis, y_axis: v2, texture: LoadedBitmap, color: v4, pixels_to_meters: f32) {
    scoped_timed_block(.draw_rectangle_quickly_hopefully)
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
        floor(min(origin.x, (origin+x_axis).x, (origin + y_axis).x, (origin + x_axis + y_axis).x)),
        floor(min(origin.y, (origin+x_axis).y, (origin + y_axis).y, (origin + x_axis + y_axis).y)),
    }
    
    maximum := [2]i32{
        ceil( max(origin.x, (origin+x_axis).x, (origin + y_axis).x, (origin + x_axis + y_axis).x)),
        ceil( max(origin.y, (origin+x_axis).y, (origin + y_axis).y, (origin + x_axis + y_axis).y)),
    }
    
    // TODO(viktor): IMPORTANT(viktor):  STOP DOING THIS ONCE WE HAVE REAL ROW LOADING
    width_max      := (buffer.width-1)  - 8
    height_max     := (buffer.height-1) - 8
    inv_width_max  := 1 / cast(f32) width_max
    inv_height_max := 1 / cast(f32) height_max

    // TODO(viktor): this will need to be specified separately
    origin_z_     :f32= 0.5
    origin_y_     := (origin + 0.5*x_axis + 0.5*y_axis).y
    fixed_cast_y := inv_height_max * origin_y_

    maximum = clamp(maximum, [2]i32{0,0}, [2]i32{width_max, height_max})
    minimum = clamp(minimum, [2]i32{0,0}, [2]i32{width_max, height_max})
    
    n_x_axis := x_axis * inv_x_len_squared
    n_y_axis := y_axis * inv_y_len_squared
    
    // TODO(viktor): formalize texture boundaries
    texture_boundaries := vec_cast(f32, texture.width-2, texture.height-2)
    
    f32x8 :: #simd[4]f32
    inv_255 := cast(f32x8) (1.0 / 255.0)
    one_255 := cast(f32x8) 255
    one     := cast(f32x8) 1
    zero    := cast(f32x8) 0
    one_plus_epsilon := cast(f32x8) 1.00000001
    
    color_r := cast(f32x8) color.r
    color_g := cast(f32x8) color.g
    color_b := cast(f32x8) color.b
    color_a := cast(f32x8) color.a
                
    origin_x := cast(f32x8) origin.x
    origin_y := cast(f32x8) origin.y
    
    n_x_axis_x := cast(f32x8) n_x_axis.x
    n_x_axis_y := cast(f32x8) n_x_axis.y
    n_y_axis_x := cast(f32x8) n_y_axis.x
    n_y_axis_y := cast(f32x8) n_y_axis.y
    
    scoped_timed_block_counted(.test_pixel, cast(i64) ((maximum.x - minimum.x + 1) * (maximum.y - minimum.y + 1)) )
    for y in minimum.y..=maximum.y {
        for x_base := minimum.x; x_base <= maximum.x; x_base += 4 {
            fx: f32x8 = ---
            fy: f32x8 = ---
            
            t00_r: f32x8 = ---
            t00_g: f32x8 = ---
            t00_b: f32x8 = ---
            t00_a: f32x8 = ---
            
            t01_r: f32x8 = ---
            t01_g: f32x8 = ---
            t01_b: f32x8 = ---
            t01_a: f32x8 = ---
            
            t10_r: f32x8 = ---
            t10_g: f32x8 = ---
            t10_b: f32x8 = ---
            t10_a: f32x8 = ---
            
            t11_r: f32x8 = ---
            t11_g: f32x8 = ---
            t11_b: f32x8 = ---
            t11_a: f32x8 = ---
            
            pixel_r: f32x8
            pixel_g: f32x8
            pixel_b: f32x8
            pixel_a: f32x8
                            
            pixel_p_x := f32x8{
                cast(f32) x_base, 
                cast(f32) x_base+1, 
                cast(f32) x_base+2, 
                cast(f32) x_base+3,
                // cast(f32) x_base+4,
                // cast(f32) x_base+5,
                // cast(f32) x_base+6,
                // cast(f32) x_base+7,
            }
            pixel_p_y := cast(f32x8) y 
            
            delta_x := pixel_p_x - origin_x
            delta_y := pixel_p_y - origin_y

            // u := dot(delta, n_x_axis)
            // v := dot(delta, n_y_axis)
            u := delta_x * n_x_axis_x + delta_y * n_x_axis_y
            v := delta_x * n_y_axis_x + delta_y * n_y_axis_y
            
            // u >= 0 && u <= 1 && v >= 0 && v <= 1
            // should_fill := simd.ceil( simd.max(u, zero) * simd.max(one_plus_epsilon - u, zero) * simd.max(v, zero) * simd.max(one_plus_epsilon - v, zero) )
            for i in i32(0)..<4 {
                x := x_base + i
                
                ui := (cast([^]f32)&u)[i]
                vi := (cast([^]f32)&v)[i]
                // if (cast([^]f32)&should_fill)[i] != 0 {
                if ui >= 0 && ui <= 1 && vi >= 0 && vi <= 1 {
                    t := v2{ (cast([^]f32)&u)[i], (cast([^]f32)&v)[i] } * texture_boundaries
                    s := vec_cast(i32, t)
                    (cast([^]f32)&fx)[i] = t.x - cast(f32) s.x
                    (cast([^]f32)&fy)[i] = t.y - cast(f32) s.y
                    
                    assert(s.x >= 0 && s.x < texture.width)
                    assert(s.y >= 0 && s.y < texture.height)

                    // t00, t01, t10, t11 := sample_bilinear(texture, s)
                    (cast([^]f32)&t00_r)[i] = cast(f32) texture.memory[texture.start + (s.y+0) * texture.pitch + s.x + 0].r
                    (cast([^]f32)&t00_g)[i] = cast(f32) texture.memory[texture.start + (s.y+0) * texture.pitch + s.x + 0].g
                    (cast([^]f32)&t00_b)[i] = cast(f32) texture.memory[texture.start + (s.y+0) * texture.pitch + s.x + 0].b
                    (cast([^]f32)&t00_a)[i] = cast(f32) texture.memory[texture.start + (s.y+0) * texture.pitch + s.x + 0].a
                    
                    (cast([^]f32)&t01_r)[i] = cast(f32) texture.memory[texture.start + (s.y+0) * texture.pitch + s.x + 1].r
                    (cast([^]f32)&t01_g)[i] = cast(f32) texture.memory[texture.start + (s.y+0) * texture.pitch + s.x + 1].g
                    (cast([^]f32)&t01_b)[i] = cast(f32) texture.memory[texture.start + (s.y+0) * texture.pitch + s.x + 1].b
                    (cast([^]f32)&t01_a)[i] = cast(f32) texture.memory[texture.start + (s.y+0) * texture.pitch + s.x + 1].a
                    
                    (cast([^]f32)&t10_r)[i] = cast(f32) texture.memory[texture.start + (s.y+1) * texture.pitch + s.x + 0].r
                    (cast([^]f32)&t10_g)[i] = cast(f32) texture.memory[texture.start + (s.y+1) * texture.pitch + s.x + 0].g
                    (cast([^]f32)&t10_b)[i] = cast(f32) texture.memory[texture.start + (s.y+1) * texture.pitch + s.x + 0].b
                    (cast([^]f32)&t10_a)[i] = cast(f32) texture.memory[texture.start + (s.y+1) * texture.pitch + s.x + 0].a
                    
                    (cast([^]f32)&t11_r)[i] = cast(f32) texture.memory[texture.start + (s.y+1) * texture.pitch + s.x + 1].r
                    (cast([^]f32)&t11_g)[i] = cast(f32) texture.memory[texture.start + (s.y+1) * texture.pitch + s.x + 1].g
                    (cast([^]f32)&t11_b)[i] = cast(f32) texture.memory[texture.start + (s.y+1) * texture.pitch + s.x + 1].b
                    (cast([^]f32)&t11_a)[i] = cast(f32) texture.memory[texture.start + (s.y+1) * texture.pitch + s.x + 1].a
                    
                    (cast([^]f32)&pixel_r)[i] = cast(f32) buffer.memory[buffer.start + y * buffer.pitch + x].r
                    (cast([^]f32)&pixel_g)[i] = cast(f32) buffer.memory[buffer.start + y * buffer.pitch + x].g
                    (cast([^]f32)&pixel_b)[i] = cast(f32) buffer.memory[buffer.start + y * buffer.pitch + x].b
                    (cast([^]f32)&pixel_a)[i] = cast(f32) buffer.memory[buffer.start + y * buffer.pitch + x].a
                }
            }
            
            // t00 = srgb_255_to_linear_1(t00)
            // t01 = srgb_255_to_linear_1(t01)
            // t10 = srgb_255_to_linear_1(t10)
            // t11 = srgb_255_to_linear_1(t11)
            t00_a *= inv_255
            t00_r = square(t00_r * inv_255)
            t00_g = square(t00_g * inv_255)
            t00_b = square(t00_b * inv_255)
            
            t01_a *= inv_255
            t01_r = square(t01_r * inv_255)
            t01_g = square(t01_g * inv_255)
            t01_b = square(t01_b * inv_255)
            
            t10_a *= inv_255
            t10_r = square(t10_r * inv_255)
            t10_g = square(t10_g * inv_255)
            t10_b = square(t10_b * inv_255)
            
            t11_a *= inv_255
            t11_r = square(t11_r * inv_255)
            t11_g = square(t11_g * inv_255)
            t11_b = square(t11_b * inv_255)
            
            // texel := blend_bilinear(t00, t01, t10, t11, f)
            ifx := one - fx
            ify := one - fy
            l0  := ify * ifx
            l1  := ify * fx
            l2  :=  fy * ifx
            l3  :=  fy * fx
            
            texel_r := l0 * t00_r + l1 * t01_r + l2 * t10_r + l3 * t11_r
            texel_g := l0 * t00_g + l1 * t01_g + l2 * t10_g + l3 * t11_g
            texel_b := l0 * t00_b + l1 * t01_b + l2 * t10_b + l3 * t11_b
            texel_a := l0 * t00_a + l1 * t01_a + l2 * t10_a + l3 * t11_a
            
            texel_r *= color_r
            texel_g *= color_g
            texel_b *= color_b
            texel_a *= color_a
            
            texel_r = clamp_01(texel_r)
            texel_g = clamp_01(texel_g)
            texel_b = clamp_01(texel_b)
        
            // pixel := srgb_255_to_linear_1(vec_cast(f32, dst^))
            pixel_r = square(pixel_r * inv_255)
            pixel_g = square(pixel_g * inv_255)
            pixel_b = square(pixel_b * inv_255)
            pixel_a *= inv_255
            
            inv_texel_a := (one - texel_a)
            blended_r := inv_texel_a * pixel_r + texel_r
            blended_g := inv_texel_a * pixel_g + texel_g
            blended_b := inv_texel_a * pixel_b + texel_b
            blended_a := inv_texel_a * pixel_a + texel_a 
            
            // blended = linear_1_to_srgb_255(blended)
            blended_r  = one_255 * square_root(blended_r)
            blended_g  = one_255 * square_root(blended_g)
            blended_b  = one_255 * square_root(blended_b)
            blended_a *= one_255

            // TODO(viktor): can this be done easier?
            r1 := simd.shuffle(blended_r, zero, 0, 1, 2, 3)
            g1 := simd.shuffle(blended_g, zero, 0, 1, 2, 3)
            b1 := simd.shuffle(blended_b, zero, 0, 1, 2, 3)
            a1 := simd.shuffle(blended_a, zero, 0, 1, 2, 3)

            // r2 := simd.shuffle(blended_r, zero, 4, 5, 6, 7)
            // g2 := simd.shuffle(blended_g, zero, 4, 5, 6, 7)
            // b2 := simd.shuffle(blended_b, zero, 4, 5, 6, 7)
            // a2 := simd.shuffle(blended_a, zero, 4, 5, 6, 7)
            
            intr1 := x86._mm_cvttps_epi32(r1) 
            intg1 := x86._mm_cvttps_epi32(g1) 
            intb1 := x86._mm_cvttps_epi32(b1) 
            inta1 := x86._mm_cvttps_epi32(a1) 
            
            // intr2 := x86._mm_cvttps_epi32(r2)
            // intg2 := x86._mm_cvttps_epi32(g2)
            // intb2 := x86._mm_cvttps_epi32(b2)
            // inta2 := x86._mm_cvttps_epi32(a2)

            mixed1 := cast(simd.i64x2) 0
            mixed1 =    intr1 | 
                simd.shl(intg1, cast(simd.u64x2)  8) | 
                simd.shl(intb1, cast(simd.u64x2) 16) | 
                simd.shl(inta1, cast(simd.u64x2) 24)
                
            // mixed2 := cast(simd.i64x2) 0
            // mixed2 =    intr2 | 
            //     simd.shl(intg2, cast(simd.u64x2)  8) | 
            //     simd.shl(intb2, cast(simd.u64x2) 16) | 
            //     simd.shl(inta2, cast(simd.u64x2) 32)
            
            #assert(size_of([4]ByteColor) == size_of(mixed1))
            // #assert(size_of([4]ByteColor) == size_of(mixed2))
                
            pixel1 := cast(^[4]ByteColor) &buffer.memory[buffer.start + y * buffer.pitch + x_base]
            pixel2 := cast(^[4]ByteColor) &buffer.memory[buffer.start + y * buffer.pitch + x_base + 4]
            x86._mm_storeu_si128(auto_cast pixel1, mixed1)
            // x86._mm_storeu_si128(auto_cast pixel2, mixed2)
        }
    }
}
draw_rectangle_slowly :: proc(buffer: LoadedBitmap, origin, x_axis, y_axis: v2, texture, normal_map: LoadedBitmap, color: v4, top, middle, bottom: EnvironmentMap, pixels_to_meters: f32) {
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
        floor(min(origin.x, (origin+x_axis).x, (origin + y_axis).x, (origin + x_axis + y_axis).x)),
        floor(min(origin.y, (origin+x_axis).y, (origin + y_axis).y, (origin + x_axis + y_axis).y)),
    }
    
    maximum := [2]i32{
        ceil( max(origin.x, (origin+x_axis).x, (origin + y_axis).x, (origin + x_axis + y_axis).x)),
        ceil( max(origin.y, (origin+x_axis).y, (origin + y_axis).y, (origin + x_axis + y_axis).y)),
    }
    
    width_max      := buffer.width-1
    height_max     := buffer.height-1
    inv_width_max  := 1 / cast(f32) width_max
    inv_height_max := 1 / cast(f32) height_max

    // TODO(viktor): this will need to be specified separately
    origin_z     :f32= 0.5
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
                s := vec_cast(i32, t)
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

                dst := &buffer.memory[buffer.start + y * buffer.pitch + x]
                pixel := srgb_255_to_linear_1(vec_cast(f32, dst^))
                
                
                blended := (1 - texel.a) * pixel + texel
                blended = linear_1_to_srgb_255(blended)
                
                dst^ = vec_cast(u8, blended)
            }
        }
    }
}

draw_rectangle :: proc(buffer: LoadedBitmap, center: v2, size: v2, color: v4){
    rounded_center := floor(center)
    rounded_size   := floor(size)
    
    left   := rounded_center.x - rounded_size.x / 2
    top	   := rounded_center.y - rounded_size.y / 2
    right  := left + rounded_size.x
    bottom := top  + rounded_size.y
    
    if left < 0 do left = 0
    if top  < 0 do top  = 0
    if right  > buffer.width  do right  = buffer.width
    if bottom > buffer.height do bottom = buffer.height

    for y in top..<bottom {
        for x in left..<right {
            // TODO(viktor): should use pitch here
            dst := &buffer.memory[buffer.start + y*buffer.pitch + x]
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
sample :: #force_inline proc(texture: LoadedBitmap, p: [2]i32) -> (result: v4) {
    texel := texture.memory[texture.start + p.y * texture.pitch + p.x]
    result = vec_cast(f32, texel)
    
    return result
}

sample_bilinear :: #force_inline proc(texture: LoadedBitmap, p: [2]i32) -> (s00, s01, s10, s11: v4) {
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
    lod_index := cast(i32) (roughness * cast(f32) (len(environment_map.LOD)-1) + 0.5)
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
        texel := &lod.memory[lod.start + index.y * lod.pitch + index.x]
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

// NOTE(viktor): srgb_to_linear and linear_to_srgb assume a gamma of 2 instead of the usual 2.2
@(require_results)
srgb_to_linear :: #force_inline proc(srgb: v4) -> (result: v4) {
    result.r = square(srgb.r)
    result.g = square(srgb.g)
    result.b = square(srgb.b)
    result.a = srgb.a
    
    return result
} 
@(require_results)
srgb_255_to_linear_1 :: #force_inline proc(srgb: v4) -> (result: v4) {
    inv_255: f32 = 1.0 / 255.0
    result = srgb * inv_255
    result = srgb_to_linear(result)
    
    return result
}
                
@(require_results)
linear_to_srgb :: #force_inline proc(linear: v4) -> (result: v4) {
    result.r = square_root(linear.r)
    result.g = square_root(linear.g)
    result.b = square_root(linear.b)
    result.a = linear.a
    
    return result
} 
@(require_results)
linear_1_to_srgb_255 :: #force_inline proc(linear: v4) -> (result: v4) {
    result = linear_to_srgb(linear)
    result *= 255
    
    return result
}