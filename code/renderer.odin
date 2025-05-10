package main

import "core:simd"
import win "core:sys/windows"

Global_Rendering_RenderSingleThreaded: b32
Global_Rendering_Environment_ShowLightingBounceDirection: b32
Global_Rendering_Environment_ShowLightingSampling: b32

TileRenderWork :: struct {
    commands: ^RenderCommands, 
    target:   Bitmap,
    
    clip_rect: Rectangle2i, 
}

init_render_commands :: proc(commands: ^RenderCommands, max_push_buffer_size: u32, push_buffer: pmm, width, height: i32) {
    commands^ = {
        width  = width, 
        height = height,
        
        push_buffer = (cast([^]u8) push_buffer)[:max_push_buffer_size],
        sort_entry_at = max_push_buffer_size,
    }
}

sort_render_elements :: proc(commands: ^RenderCommands, temp_memory: pmm) {
    block := game.begin_timed_block(#procedure)
    defer game.end_timed_block(block)
    // TODO(viktor): This is not the best way to sort.
    // :PointerArithmetic
    count := commands.push_buffer_element_count
    if count != 0 {
        sort_entries := (cast([^]SortEntry) &commands.push_buffer[commands.sort_entry_at])[:count]
        temp_space   := (cast([^]SortEntry) temp_memory)[:count]

        // merge_sort(sort_entries, temp_space)
        radix_sort(sort_entries, temp_space)
        
        when INTERNAL do is_sorted(sort_entries)
    }
}

software_render_commands :: proc(queue: ^PlatformWorkQueue, commands: ^RenderCommands, target: Bitmap) {
    assert(cast(umm) raw_data(target.memory) & (16 - 1) == 0)

    /* TODO(viktor):
        - Make sure the tiles are all cache-aligned
        - How big should the tiles be for performance?
        - Actually ballpark the memory bandwidth for our DrawRectangleQuickly
        - Re-test some of our instruction choices
    */
    
    tile_count :: [2]i32{4, 4}
    works: [tile_count.x * tile_count.y]TileRenderWork
    
    tile_size  := [2]i32{target.width, target.height} / tile_count
    tile_size.x = ((tile_size.x + (3)) / 4) * 4
    
    work_index: i32
    for y in 0..<tile_count.y {
        for x in 0..<tile_count.x {
            work := &works[work_index]
            defer work_index += 1
            
            work^ = {
                commands  = commands,
                target = target,
                clip_rect = {
                    min = tile_size * {x, y},
                },
            }
            
            work.clip_rect.max = work.clip_rect.min + tile_size
            
            if x == tile_count.x-1 {
                work.clip_rect.max.x = target.width 
            }
            if y == tile_count.y-1 {
                work.clip_rect.max.y = target.height
            }
            
            if Global_Rendering_RenderSingleThreaded {
                do_tile_render_work(work)
            } else {
                enqueue_work(queue, do_tile_render_work, work)
            }
        }
    }

    complete_all_work(queue)
}

do_tile_render_work : PlatformWorkQueueCallback : proc(data: pmm) {
    block := game.begin_timed_block(#procedure)
    defer game.end_timed_block(block)
    using work := cast(^TileRenderWork) data

    assert(commands != nil)
    assert(target.memory != nil)
    
    // :PointerArithmetic
    sort_entries := (cast([^]SortEntry) &commands.push_buffer[commands.sort_entry_at])[:commands.push_buffer_element_count]
        
    for sort_entry in sort_entries {
        header := cast(^RenderGroupEntryHeader) &commands.push_buffer[sort_entry.index]
        //:PointerArithmetic
        entry_data := &commands.push_buffer[sort_entry.index + size_of(RenderGroupEntryHeader)]
        
        switch header.type {
          case .RenderGroupEntryClear:
            entry := cast(^RenderGroupEntryClear) entry_data
            
            draw_rectangle(target, Rectangle2{vec_cast(f32, clip_rect.min), vec_cast(f32, clip_rect.max)} , entry.color, clip_rect)
            
          case .RenderGroupEntryRectangle:
            entry := cast(^RenderGroupEntryRectangle) entry_data
            draw_rectangle(target, entry.rect, entry.color, clip_rect)
            
          case .RenderGroupEntryBitmap:
            entry := cast(^RenderGroupEntryBitmap) entry_data
            draw_rectangle_quickly(target,
                entry.p, {entry.size.x, 0}, {0, entry.size.y},
                entry.bitmap^, entry.color,
                clip_rect,
            )
            
          case .RenderGroupEntryCoordinateSystem:
            entry := cast(^RenderGroupEntryCoordinateSystem) entry_data
            draw_rectangle_quickly(target,
                entry.origin, entry.x_axis, entry.y_axis,
                entry.texture, /* entry.normal, */ entry.color,
                /* entry.top, entry.middle, entry.bottom, */
                clip_rect, 
            )
            
            p := entry.origin
            x := p + entry.x_axis
            y := p + entry.y_axis
            size := v2{10, 10}
            
            // draw_rectangle(target, rectangle_center_dimension(p, size), Red, clip_rect)
            // draw_rectangle(target, rectangle_center_dimension(x, size), Red * 0.7, clip_rect)
            // draw_rectangle(target, rectangle_center_dimension(y, size), Red * 0.7, clip_rect)
            
          case:
            panic("Unhandled Entry")
        }
    }
}


////////////////////////////////////////////////

@(enable_target_feature="sse,sse2")
draw_rectangle_quickly :: proc(buffer: Bitmap, origin, x_axis, y_axis: v2, texture: Bitmap, color: v4, clip_rect: Rectangle2i) {
    block := game.begin_timed_block(#procedure)
    defer game.end_timed_block(block)
    
    // IMPORTANT TODO(viktor): @Robustness, these should be asserts. They only ever fail on hotreloading
    if !((texture.memory != nil) && (texture.width  >= 0) && (texture.height >= 0) &&
        (auto_cast len(texture.memory) == texture.height * texture.width) &&
        (texture.width_over_height >  0)) {
        return
    }
    
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
    fill_rect := inverted_infinity_rectangle(Rectangle2i)
    for testp in ([?]v2{origin, (origin+x_axis), (origin + y_axis), (origin + x_axis + y_axis)}) {
        floorp := floor(testp, i32)
        ceilp  := ceil(testp, i32)
     
        fill_rect.min.x = min(fill_rect.min.x, floorp.x)
        fill_rect.min.y = min(fill_rect.min.y, floorp.y)
        fill_rect.max.x = max(fill_rect.max.x, ceilp.x)
        fill_rect.max.y = max(fill_rect.max.y, ceilp.y)
    }
    fill_rect = rectangle_intersection(fill_rect, clip_rect)

    if rectangle_has_area(fill_rect) {
        maskFF :: 0xffffffff
        maskFFx8 :: cast(u32x8) maskFF
        clip_mask := maskFFx8
        
        start_clip_mask := clip_mask
        if fill_rect.min.x & 7 != 0 {
            start_clip_masks := [?]u32x8 {
                {maskFF, maskFF, maskFF, maskFF,maskFF, maskFF, maskFF, maskFF},
                {     0, maskFF, maskFF, maskFF,maskFF, maskFF, maskFF, maskFF},
                {     0,      0, maskFF, maskFF,maskFF, maskFF, maskFF, maskFF},
                {     0,      0,      0, maskFF,maskFF, maskFF, maskFF, maskFF},
                {     0,      0,      0,      0,maskFF, maskFF, maskFF, maskFF},
                {     0,      0,      0,      0,     0, maskFF, maskFF, maskFF},
                {     0,      0,      0,      0,     0,      0, maskFF, maskFF},
                {     0,      0,      0,      0,     0,      0,      0, maskFF},
            }
            
            start_clip_mask = start_clip_masks[fill_rect.min.x & 7]
            fill_rect.min.x = align8(fill_rect.min.x) - 8
        }

        end_clip_mask   := clip_mask
        if fill_rect.max.x & 7 != 0 {
            end_clip_masks := [?]u32x8 {
                {maskFF, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF},
                {maskFF,      0,      0,      0,      0,      0,      0,      0},
                {maskFF, maskFF,      0,      0,      0,      0,      0,      0},
                {maskFF, maskFF, maskFF,      0,      0,      0,      0,      0},
                {maskFF, maskFF, maskFF, maskFF,      0,      0,      0,      0},
                {maskFF, maskFF, maskFF, maskFF, maskFF,      0,      0,      0},
                {maskFF, maskFF, maskFF, maskFF, maskFF, maskFF,      0,      0},
                {maskFF, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF,      0},
            }
            
            end_clip_mask = end_clip_masks[fill_rect.max.x & 7]
            fill_rect.max.x = align8(fill_rect.max.x)
        }
        
        normal_x_axis := safe_ratio_0(x_axis, length_squared(x_axis))
        normal_y_axis := safe_ratio_0(y_axis, length_squared(y_axis))
        
        texture_width_x8  := cast(f32x8) (texture.width  - 2)
        texture_height_x8 := cast(f32x8) (texture.height - 2)

        inv_255         := cast(f32x8) (1.0 / 255.0)
        max_color_value := cast(f32x8) (255 * 255)
        
        color_r := cast(f32x8) color.r
        color_g := cast(f32x8) color.g
        color_b := cast(f32x8) color.b
        color_a := cast(f32x8) color.a

        normal_x_axis_x := cast(f32x8) normal_x_axis.x
        normal_x_axis_y := cast(f32x8) normal_x_axis.y
        normal_y_axis_x := cast(f32x8) normal_y_axis.x
        normal_y_axis_y := cast(f32x8) normal_y_axis.y
        
        texture_width := cast(i32x8) texture.width
        
        delta_x := cast(f32x8) fill_rect.min.x - cast(f32x8) origin.x + { 0, 1, 2, 3, 4, 5, 6, 7}
        delta_y := cast(f32x8) fill_rect.min.y - cast(f32x8) origin.y
        
        delta_y_n_x_axis_y := delta_y * normal_x_axis_y
        delta_y_n_y_axis_y := delta_y * normal_y_axis_y
        
        for y := fill_rect.min.y; y < fill_rect.max.y; y += 1 {
            // NOTE(viktor): iterative calculations will lead to arithmetic errors,
            // so we calculate always based of the index.
            // u := dot(delta, n_x_axis)
            // v := dot(delta, n_y_axis)
            y_index := cast(f32) (y - fill_rect.min.y)
            u_row := delta_x * normal_x_axis_x + delta_y_n_x_axis_y + y_index * normal_x_axis_y
            v_row := delta_x * normal_y_axis_x + delta_y_n_y_axis_y + y_index * normal_y_axis_y

            clip_mask = start_clip_mask
            for x := fill_rect.min.x; x < fill_rect.max.x; x += 8 {
                x_index := cast(f32) (x - fill_rect.min.x) / 8
                u := u_row + x_index * normal_x_axis_x * 8
                v := v_row + x_index * normal_y_axis_x * 8
                defer {
                    if x + 16 < fill_rect.max.x {
                        clip_mask = maskFF
                    } else {
                        clip_mask = end_clip_mask
                    }
                }
                
                // u >= 0 && u <= 1 && v >= 0 && v <= 1
                write_mask := clip_mask & simd.lanes_ge(u, 0) & simd.lanes_le(u, 1) & simd.lanes_ge(v, 0) & simd.lanes_le(v, 1)

                pixel := buffer.memory[y * buffer.width + x:][:8]
                // assert(cast(uintpointer) (&pixel[0]) & 31 == 0)
                original_pixel := simd.masked_load((&pixel[0]), cast(u32x8) 0, write_mask)
                
                u = clamp_01(u)
                v = clamp_01(v)

                // NOTE(viktor): Bias texture coordinates to start on the 
                // boundary between the 0,0 and 1,1 pixels
                tx := u * texture_width_x8  + 0.5
                ty := v * texture_height_x8 + 0.5

                sx := cast(i32x8) tx
                sy := cast(i32x8) ty

                fx := tx - cast(f32x8) sx
                fy := ty - cast(f32x8) sy

                // NOTE(viktor): bilinear sample
                fetch := cast(ummx8) (sy * texture_width + sx)
                
                ummx8 :: #simd [8]umm
                texture_memory := cast(ummx8) raw_data(texture.memory)
                texture_width  := cast(ummx8) texture.width
                
                texel := texture_memory + fetch * size_of(Color)
                
                zero := cast(u32x8) 0
                sample_a := simd.gather(cast(#simd [8]pmm) (texel + size_of(Color) * 0),                   zero, maskFFx8)
                sample_b := simd.gather(cast(#simd [8]pmm) (texel + size_of(Color) * 1),                   zero, maskFFx8)
                sample_c := simd.gather(cast(#simd [8]pmm) (texel + size_of(Color) * texture_width),       zero, maskFFx8)
                sample_d := simd.gather(cast(#simd [8]pmm) (texel + size_of(Color) * (texture_width + 1)), zero, maskFFx8)
                
                ta_r := cast(f32x8) (0xff &          sample_a      )
                ta_g := cast(f32x8) (0xff & simd.shr(sample_a,  8) )
                ta_b := cast(f32x8) (0xff & simd.shr(sample_a,  16))
                ta_a := cast(f32x8) (0xff & simd.shr(sample_a,  24))
                
                tb_r := cast(f32x8) (0xff &          sample_b      )
                tb_g := cast(f32x8) (0xff & simd.shr(sample_b,  8) )
                tb_b := cast(f32x8) (0xff & simd.shr(sample_b,  16))
                tb_a := cast(f32x8) (0xff & simd.shr(sample_b,  24))
                
                tc_r := cast(f32x8) (0xff &          sample_c      )
                tc_g := cast(f32x8) (0xff & simd.shr(sample_c,  8) )
                tc_b := cast(f32x8) (0xff & simd.shr(sample_c,  16))
                tc_a := cast(f32x8) (0xff & simd.shr(sample_c,  24))
                
                td_r := cast(f32x8) (0xff &          sample_d      )
                td_g := cast(f32x8) (0xff & simd.shr(sample_d,  8) )
                td_b := cast(f32x8) (0xff & simd.shr(sample_d,  16))
                td_a := cast(f32x8) (0xff & simd.shr(sample_d,  24))
                
                pixel_r := cast(f32x8) (0xff &          original_pixel      )
                pixel_g := cast(f32x8) (0xff & simd.shr(original_pixel,  8) )
                pixel_b := cast(f32x8) (0xff & simd.shr(original_pixel,  16))
                pixel_a := cast(f32x8) (0xff & simd.shr(original_pixel,  24))
                
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

                intr := cast(u32x8) blended_r
                intg := cast(u32x8) blended_g
                intb := cast(u32x8) blended_b
                inta := cast(u32x8) blended_a
                
                mixed := intr | simd.shl_masked(intg, 8) | simd.shl_masked(intb, 16) | simd.shl_masked(inta, 24)

                simd.masked_store(&pixel[0], mixed, write_mask)
            }
        }
    }
}

draw_rectangle_slowly :: proc(buffer: Bitmap, origin, x_axis, y_axis: v2, texture, normal_map: Bitmap, color: v4, top, middle, bottom: EnvironmentMap, pixels_to_meters: f32) {
    block := game.begin_timed_block(#procedure)
    defer game.end_timed_block(block)
    
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
                    if Global_Rendering_Environment_ShowLightingBounceDirection {
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

draw_rectangle :: proc(buffer: Bitmap, rect: Rectangle2, color: v4, clip_rect: Rectangle2i){
    origin := rect.min
    dim := rectangle_get_dimension(rect)
    x_axis := v2{dim.x, 0}
    y_axis := v2{0, dim.y}
    
    draw_rectangle_rotated(buffer, origin, x_axis, y_axis, color, clip_rect)
}

draw_rectangle_rotated :: proc(buffer: Bitmap, origin, x_axis, y_axis: v2, color: v4, clip_rect: Rectangle2i){
    fill_rect := inverted_infinity_rectangle(Rectangle2i)
    for testp in ([?]v2{origin, (origin+x_axis), (origin + y_axis), (origin + x_axis + y_axis)}) {
        floorp := floor(testp, i32)
        ceilp  := ceil(testp, i32)
     
        fill_rect.min.x = min(fill_rect.min.x, floorp.x)
        fill_rect.min.y = min(fill_rect.min.y, floorp.y)
        fill_rect.max.x = max(fill_rect.max.x, ceilp.x)
        fill_rect.max.y = max(fill_rect.max.y, ceilp.y)
    }
    fill_rect = rectangle_intersection(fill_rect, clip_rect)
    
    if rectangle_has_area(fill_rect) {
        maskFF :: 0xffffffff
        
        clip_mask := cast(u32x8) maskFF
        
        start_clip_mask := clip_mask
        if fill_rect.min.x & 7 != 0 {
            start_clip_masks := [?]u32x8 {
                {maskFF, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF},
                {     0, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF},
                {     0,      0, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF},
                {     0,      0,      0, maskFF, maskFF, maskFF, maskFF, maskFF},
                {     0,      0,      0,      0, maskFF, maskFF, maskFF, maskFF},
                {     0,      0,      0,      0,      0, maskFF, maskFF, maskFF},
                {     0,      0,      0,      0,      0,      0, maskFF, maskFF},
                {     0,      0,      0,      0,      0,      0,      0, maskFF},
            }

            start_clip_mask = start_clip_masks[fill_rect.min.x & 7]
            fill_rect.min.x = align8(fill_rect.min.x) - 8
        }
        
        end_clip_mask   := clip_mask
        if fill_rect.max.x & 7 != 0 {
            end_clip_masks := [?]u32x8 {
                {maskFF, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF},
                {maskFF,      0,      0,      0,      0,      0,      0,      0},
                {maskFF, maskFF,      0,      0,      0,      0,      0,      0},
                {maskFF, maskFF, maskFF,      0,      0,      0,      0,      0},
                {maskFF, maskFF, maskFF, maskFF,      0,      0,      0,      0},
                {maskFF, maskFF, maskFF, maskFF, maskFF,      0,      0,      0},
                {maskFF, maskFF, maskFF, maskFF, maskFF, maskFF,      0,      0},
                {maskFF, maskFF, maskFF, maskFF, maskFF, maskFF, maskFF,      0},
            }
            
            end_clip_mask = end_clip_masks[fill_rect.max.x & 7]
            fill_rect.max.x = align8(fill_rect.max.x)
        }
        
        normal_x_axis := safe_ratio_0(x_axis, length_squared(x_axis))
        normal_y_axis := safe_ratio_0(y_axis, length_squared(y_axis))
        
        inv_255         := cast(f32x8) (1.0 / 255.0)
        max_color_value := cast(f32x8) (255 * 255)
        
        normal_x_axis_x := cast(f32x8) normal_x_axis.x
        normal_x_axis_y := cast(f32x8) normal_x_axis.y
        normal_y_axis_x := cast(f32x8) normal_y_axis.x
        normal_y_axis_y := cast(f32x8) normal_y_axis.y
        
        delta_x := cast(f32x8) fill_rect.min.x - cast(f32x8) origin.x + { 0, 1, 2, 3, 4, 5, 6, 7}
        delta_y := cast(f32x8) fill_rect.min.y - cast(f32x8) origin.y
        
        delta_y_n_x_axis_y := delta_y * normal_x_axis_y
        delta_y_n_y_axis_y := delta_y * normal_y_axis_y
        
        
        // NOTE(viktor): premultiply color alpha
        color := color
        color.rgb *= color.a
        
        color *= 255
        color_r := cast(f32x8) color.r
        color_g := cast(f32x8) color.g
        color_b := cast(f32x8) color.b
        color_a := cast(f32x8) color.a
        
        // NOTE(viktor): srgb to linear
        color_r = square(color_r)
        color_g = square(color_g)
        color_b = square(color_b)
        
        color_r = clamp(color_r, 0, max_color_value)
        color_g = clamp(color_g, 0, max_color_value)
        color_b = clamp(color_b, 0, max_color_value)
        
        inv_color_a := (1 - (inv_255 * color_a))
        
        for y := fill_rect.min.y; y < fill_rect.max.y; y += 1 {
            // NOTE(viktor): Iterative calculations will lead to arithmetic errors,
            // so we always calculate based of the index.
            // u := dot(delta, n_x_axis)
            // v := dot(delta, n_y_axis)
            y_index := cast(f32) (y - fill_rect.min.y)
            u_row := delta_x * normal_x_axis_x + delta_y_n_x_axis_y + y_index * normal_x_axis_y
            v_row := delta_x * normal_y_axis_x + delta_y_n_y_axis_y + y_index * normal_y_axis_y
            
            clip_mask = start_clip_mask
            for x := fill_rect.min.x; x < fill_rect.max.x; x += 8 {
                x_index := cast(f32) (x - fill_rect.min.x) / 8
                u := u_row + x_index * normal_x_axis_x * 8
                v := v_row + x_index * normal_y_axis_x * 8
                defer {
                    if x + 16 < fill_rect.max.x {
                        clip_mask = maskFF
                    } else {
                        clip_mask = end_clip_mask
                    }
                }
                
                // u >= 0 && u <= 1 && v >= 0 && v <= 1
                write_mask := clip_mask & simd.lanes_ge(u, 0) & simd.lanes_le(u, 1) & simd.lanes_ge(v, 0) & simd.lanes_le(v, 1)
                
                pixel := buffer.memory[y * buffer.width + x:][:8]
                // assert(cast(uintpointer) (&pixel[0]) & 31 == 0)
                original_pixel := simd.masked_load((&pixel[0]), cast(u32x8) 0, write_mask)
                
                pixel_r := cast(f32x8) (0xff &          original_pixel      )
                pixel_g := cast(f32x8) (0xff & simd.shr(original_pixel,  8) )
                pixel_b := cast(f32x8) (0xff & simd.shr(original_pixel,  16))
                pixel_a := cast(f32x8) (0xff & simd.shr(original_pixel,  24))
                
                // NOTE(viktor): srgb to linear
                pixel_r = square(pixel_r)
                pixel_g = square(pixel_g)
                pixel_b = square(pixel_b)
                // TODO(viktor): Maybe we should blend the edges to mitigate aliasing for rotated rectangles
                
                // NOTE(viktor): blend with target pixel
                blended_r := inv_color_a * pixel_r + color_r
                blended_g := inv_color_a * pixel_g + color_g
                blended_b := inv_color_a * pixel_b + color_b
                blended_a := inv_color_a * pixel_a + color_a
                
                // NOTE(viktor): linear to srgb
                blended_r = square_root(blended_r)
                blended_g = square_root(blended_g)
                blended_b = square_root(blended_b)
                
                intr := cast(u32x8) blended_r
                intg := cast(u32x8) blended_g
                intb := cast(u32x8) blended_b
                inta := cast(u32x8) blended_a
                
                mixed := intr | simd.shl_masked(intg, 8) | simd.shl_masked(intb, 16) | simd.shl_masked(inta, 24)
                
                simd.masked_store(&pixel[0], mixed, write_mask)
            }
        }
    }
}

// TODO(viktor): should sample return a pointer instead?
sample :: proc(texture: Bitmap, p: [2]i32) -> (result: v4) {
    texel := texture.memory[ p.y * texture.width +  p.x]
    result = vec_cast(f32, texel)

    return result
}

sample_bilinear :: proc(texture: Bitmap, p: [2]i32) -> (s00, s01, s10, s11: v4) {
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
sample_environment_map :: proc(screen_space_uv: v2, sample_direction: v3, roughness: f32, environment_map: EnvironmentMap, distance_from_map_in_z: f32) -> (result: v3) {
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

    if Global_Rendering_Environment_ShowLightingSampling {
        // NOTE(viktor): Turn this on to see where in the map you're sampling!
        texel := &lod.memory[index.y * lod.width + index.x]
        texel^ = 255
    }

    return result
}

blend_bilinear :: proc(s00, s01, s10, s11: v4, t: v2) -> (result: v4) {
    result = lerp( lerp(s00, s01, t.x), lerp(s10, s11, t.x), t.y )

    return result
}

@(require_results)
unscale_and_bias :: proc(normal: v4) -> (result: v4) {
    inv_255: f32 = 1.0 / 255.0

    result.xyz = -1 + 2 * (normal.xyz * inv_255)
    result.w = inv_255 * normal.w

    return result
}