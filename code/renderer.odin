package main

// @todo(viktor): Pull this out into a third layer or into the game so that we can hotreload it

import "core:simd"

GlobalDebugRenderSingleThreaded: b32 = false

TileRenderWork :: struct {
    commands: ^RenderCommands, 
    prep:     RenderPrep,
    targets:  [] Bitmap,
    
    base_clip_rect: Rectangle2i, 
}

init_render_commands :: proc (commands: ^RenderCommands, push_buffer: []u8, width, height: i32) {
    commands ^= {
        width  = width, 
        height = height,
        
        push_buffer = push_buffer,
    }
}

prep_for_render :: proc (commands: ^RenderCommands, temp_arena: ^Arena) -> (result: RenderPrep) {
    linearize_clip_rects(commands, &result, temp_arena)
    
    return result
}

linearize_clip_rects :: proc (commands: ^RenderCommands, prep: ^RenderPrep, arena: ^Arena) {
    timed_function()
    
    count := commands.clip_rects_count
    prep.clip_rects =  make_array(arena, RenderEntryClip, count)
    
    for rect := commands.rects.last; rect != nil; rect = rect.next {
        append(&prep.clip_rects, rect^)
    }
    
    assert(count == auto_cast prep.clip_rects.count)
}

aspect_ratio_fit :: proc (render_size: v2i, window_size: v2i) -> (result: Rectangle2i) {
    if render_size.x > 0 && render_size.y > 0 && window_size.x > 0 && window_size.y > 0 {
        optimal_window_width  := round(i32, cast(f32) window_size.y * cast(f32) render_size.x / cast(f32) render_size.y)
        optimal_window_height := round(i32, cast(f32) window_size.x * cast(f32) render_size.y / cast(f32) render_size.x)
        
        window_center := window_size / 2
        optimal_window_size: v2i
        if optimal_window_width > window_size.x {
            // Top and Bottom black bars
            optimal_window_size = {window_size.x, optimal_window_height}
        } else {
            // Left and Right black bars
            optimal_window_size = {optimal_window_width, window_size.y}
        }
        result = rectangle_center_dimension(window_center, optimal_window_size)
    }
    
    return result
}

////////////////////////////////////////////////

software_render_commands :: proc (queue: ^WorkQueue, commands: ^RenderCommands, prep: RenderPrep, base_target: Bitmap, arena: ^Arena) {
    timed_function()
    
    targets := push_slice(arena, Bitmap, commands.max_render_target_index + 1)
    targets[0] = base_target
    for &target in targets[1:] {
        target = base_target
        target.memory = push_slice(arena, Color, target.width * target.height, align_no_clear(LaneWidth * size_of(Color)))
    }
    
    /* @todo(viktor):
        - Actually ballpark the memory bandwidth for our DrawRectangleQuickly
        - Re-test some of our instruction choices
    */
    
    tile_count :: v2i{4, 4}
    works: [tile_count.x * tile_count.y] TileRenderWork
    
    tile_size := v2i{base_target.width, base_target.height} / tile_count
    tile_size.x = align(LaneWidth, tile_size.x)
    
    work_index: i32
    for y in 0..<tile_count.y {
        for x in 0..<tile_count.x {
            work := &works[work_index]
            defer work_index += 1
            
            work ^= {
                commands = commands,
                prep     = prep,
                targets  = targets,
                base_clip_rect = {
                    min = tile_size * {x, y},
                },
            }
            
            work.base_clip_rect.max = work.base_clip_rect.min + tile_size
            
            if x == tile_count.x-1 {
                work.base_clip_rect.max.x = base_target.width 
            }
            if y == tile_count.y-1 {
                work.base_clip_rect.max.y = base_target.height
            }
            
            if GlobalDebugRenderSingleThreaded {
                do_tile_render_work(work)
            } else {
                enqueue_work(queue, work, do_tile_render_work)
            }
        }
    }
    
    complete_all_work(queue)
}

do_tile_render_work :: proc (data: pmm) {
    timed_function()
    
    using work := cast(^TileRenderWork) data
    assert(commands != nil)
    
    clip_rect := base_clip_rect
    clip_rect_index := max(u16)
    
    for target, index in targets {
        clear_color: v4
        if index == 0 {
            clear_color = commands.clear_color
        }
        clear_render_target(target, clip_rect, clear_color)
    }
    
    target: Bitmap
    for header_offset: u32; header_offset < commands.push_buffer_data_at; {
        // :PointerArithmetic
        header := cast(^RenderEntryHeader) &commands.push_buffer[header_offset]
        header_offset += size_of(RenderEntryHeader)
        entry_data := &commands.push_buffer[header_offset]
        
        if header.type != .RenderEntryClip && clip_rect_index != header.clip_rect_index {
            clip_rect_index = header.clip_rect_index
            
            clip := prep.clip_rects.data[clip_rect_index]
            clip_rect = get_intersection(base_clip_rect, clip.clip_rect)
            
            target_index := clip.render_target_index
            target = targets[target_index]
            assert(target.memory != nil)
        }
        
        switch header.type {
          case .None: unreachable()
          case .RenderEntryClip: 
            // @note(viktor): clip rects are handled before rendering
            header_offset += size_of(RenderEntryClip)
          
          case .RenderEntryBlendRenderTargets:
            entry := cast(^RenderEntryBlendRenderTargets) entry_data
            header_offset += size_of(RenderEntryBlendRenderTargets)
            
            source := targets[entry.source_index]
            dest   := targets[entry.dest_index]
            blend_render_target(dest, clip_rect, source, entry.alpha)
            
          case .RenderEntryRectangle:
            entry := cast(^RenderEntryRectangle) entry_data
            header_offset += size_of(RenderEntryRectangle)
            
            rect := rectangle_min_dimension(entry.p, V3(entry.dim, 0))
            draw_rectangle_fill_color_axis_aligned(target, clip_rect, rect, entry.premultiplied_color)
            
          case .RenderEntryBitmap:
            entry := cast(^RenderEntryBitmap) entry_data
            header_offset += size_of(RenderEntryBitmap)
            
            draw_rectangle_with_texture(target, clip_rect, entry.p, entry.x_axis.xy, entry.y_axis.xy, entry.bitmap, entry.premultiplied_color)
            
          case .RenderEntryCube:
            entry := cast(^RenderEntryCube) entry_data
            header_offset += size_of(RenderEntryCube)
            
            unimplemented("move the software renderer to 3D")
        }
    }
}

////////////////////////////////////////////////
// @todo(viktor): 
// - Compress vector operations into simd

MaskFF :: 0xffffffff
Inv255 :: 1.0 / 255
MaxColorValue :: 255 * 255

// 133Mcy
// 133Mcy - with clear
//  46Mcy - with blend !LETS GO!
//  60Mcy 4  /// (133 / 60 - 1) * 100
//  46Mcy 8  /// (133 / 46 - 1) * 100
//  38Mcy 16 /// (133 / 36 - 1) * 100

clear_render_target :: proc (dest: Bitmap, clip_rect: Rectangle2i, color: v4) {
    timed_function()
    
    ctx: Shader_Context
    ok, pmin, pmax, pstep := shader_init_with_rect(&ctx, dest, clip_rect, clip_rect)
    assert(ok)
    
    color := vec_cast(lane_f32, color * 255)
    color = srgb_to_linear(color)
    packed := pack_pixel(color)
    
    for y := pmin.y; y < pmax.y; y += pstep.y {
        for x := pmin.x; x < pmax.x; x += pstep.x {
            shader_update_load_and_store_mask(&ctx, x)
            shader_store_pixels_at(&ctx, packed, x, y)
        }
    }
}

blend_render_target :: proc (dest: Bitmap, clip_rect: Rectangle2i, source: Bitmap, alpha: f32) {
    timed_function()
    
    ctx: Shader_Context
    ok, pmin, pmax, pstep := shader_init_with_rect(&ctx, dest, clip_rect, clip_rect)
    assert(ok)
    
    for y := pmin.y; y < pmax.y; y += pstep.y {
        for x := pmin.x; x < pmax.x; x += pstep.x {
            pixels := shader_load_pixels(&ctx, x, y)
            
            // @todo(viktor): this is should be easier to do
            src    := &source.memory[x + y * source.width]
            texel_ := simd.masked_load(src, cast(lane_u32) 0, ctx.mask)
            texel  := unpack_pixel(texel_)
            
            texel = srgb_to_linear(texel)
            
            t := alpha * (texel.a * Inv255)
            blended := linear_blend(pixels, texel, t)
            
            blended = linear_to_srgb(blended)
            
            packed := pack_pixel(blended)
            
            shader_store_pixels(&ctx, packed)
        }
    }
}

draw_rectangle_fill_color_axis_aligned :: proc (buffer: Bitmap, clip_rect: Rectangle2i, rect: Rectangle3, color: v4) {
    // @todo(viktor): Move to 3D
    rect := get_xy(rect)
    
    // @todo(viktor): is this actually necessary?
    fill_rect := rectangle_min_max(floor(i32, rect.min), ceil(i32, rect.max))
    
    ctx: Shader_Context
    ok, pmin, pmax, pstep := shader_init_with_rect(&ctx, buffer, clip_rect, fill_rect)
    if !ok do return
    
    color := vec_cast(lane_f32, color * 255)
    
    color = srgb_to_linear(color)
    color.rgb = clamp(color.rgb, 0, MaxColorValue)
    inv_color_a := (1 - (Inv255 * color.a))
    
    for y := pmin.y; y < pmax.y; y += pstep.y {
        for x := pmin.x; x < pmax.x; x += pstep.x {
            pixels := shader_load_pixels(&ctx, x, y)
            
            // @note(viktor): blend with target pixel
            blended := inv_color_a * pixels + color
            
            blended = linear_to_srgb(blended)
            
            packed := pack_pixel(blended)
            
            shader_store_pixels(&ctx, packed)
        }
    }
}

draw_rectangle_fill_color :: proc (buffer: Bitmap, clip_rect: Rectangle2i, origin, x_axis, y_axis: v2, color: v4) {
    ctx: Shader_Context
    ok, pmin, pmax, pstep := shader_init_with_rotation(&ctx, buffer, clip_rect, origin, x_axis, y_axis)
    if !ok do return
    
    color := vec_cast(lane_f32, color * 255)
    
    color = srgb_to_linear(color)
    color.rgb = clamp(color.rgb, 0, MaxColorValue)
    inv_color_a := (1 - (Inv255 * color.a))
    
    for y := pmin.y; y < pmax.y; y += pstep.y {
        shader_row_with_uv(&ctx, y)
        
        for x := pmin.x; x < pmax.x; x += pstep.x {
            pixels, _ := shader_load_pixels_with_uv(&ctx, x, y)
            
            // @note(viktor): blend with target pixel
            blended := inv_color_a * pixels + color
            
            blended = linear_to_srgb(blended)
            
            packed := pack_pixel(blended)
            
            shader_store_pixels(&ctx, packed)
        }
    }
}

draw_rectangle_with_texture :: proc (buffer: Bitmap, clip_rect: Rectangle2i, origin: v3, x_axis, y_axis: v2, texture: Bitmap, color: v4) {
    // @todo(viktor): Move to 3D
    origin := origin.xy
    
    ctx: Shader_Context
    ok, pmin, pmax, pstep := shader_init_with_rotation(&ctx,  buffer, clip_rect, origin, x_axis, y_axis)
    if !ok do return
    
    color := vec_cast(lane_f32, color)
    
    texture_size := vec_cast(lane_f32, texture.width, texture.height) - 2
    
    texture_width  := cast(lane_u32) texture.width
    texture_memory := cast(lane_umm) raw_data(texture.memory)

    zero := cast(lane_u32) 0
    mask := cast(lane_u32) MaskFF
    
    for y := pmin.y; y < pmax.y; y += pstep.y {
        shader_row_with_uv(&ctx, y)
        
        for x := pmin.x; x < pmax.x; x += pstep.x {
            pixel, uv := shader_load_pixels_with_uv(&ctx, x, y)
            
            // @note(viktor): Bias texture coordinates to start on the boundary between the 0,0 and 1,1 pixels
            t := uv * texture_size + 0.5
            s :=     vec_cast(lane_u32, t)
            f := t - vec_cast(lane_f32, s)
            
            // @note(viktor): bilinear sample
            index_a := cast(lane_umm) ((s.x + 0) + (s.y + 0) * texture_width)
            index_b := cast(lane_umm) ((s.x + 1) + (s.y + 0) * texture_width)
            index_c := cast(lane_umm) ((s.x + 0) + (s.y + 1) * texture_width)
            index_d := cast(lane_umm) ((s.x + 1) + (s.y + 1) * texture_width)
            
            texel_a := cast(lane_pmm) (texture_memory + index_a * size_of(Color))
            texel_b := cast(lane_pmm) (texture_memory + index_b * size_of(Color))
            texel_c := cast(lane_pmm) (texture_memory + index_c * size_of(Color))
            texel_d := cast(lane_pmm) (texture_memory + index_d * size_of(Color))
            
            sample_a := simd.gather(texel_a, zero, mask)
            sample_b := simd.gather(texel_b, zero, mask)
            sample_c := simd.gather(texel_c, zero, mask)
            sample_d := simd.gather(texel_d, zero, mask)
            
            ta := unpack_pixel(sample_a)
            tb := unpack_pixel(sample_b)
            tc := unpack_pixel(sample_c)
            td := unpack_pixel(sample_d)
            
            ta = srgb_to_linear(ta)
            tb = srgb_to_linear(tb)
            tc = srgb_to_linear(tc)
            td = srgb_to_linear(td)
            
            texel := bilinear_blend(ta, tb, tc, td, f)
            
            texel *= color
            texel.rgb = clamp(texel.rgb, 0, MaxColorValue)
            
            // @note(viktor): blend with target pixel
            inv_texel_a := (1 - (Inv255 * texel.a))
            blended := inv_texel_a * pixel + texel
            
            blended = linear_to_srgb(blended)
            
            packed := pack_pixel(blended)
            
            shader_store_pixels(&ctx, packed)
        }
    }
}

////////////////////////////////////////////////

// @todo(viktor): How can we split this in a relevant and convinient way
// 1) Clear             - only clip_rect, only masked_stores into output
// 2) Blend             - only clip_rect, masked_loads from input and output and blends then stores
// 3) Fill Rect Aligned - rect-clip_rect intersection, blends output with color then stores
// 4) Fill Rect Rotated - axis-clip_rect intersection, blends output with color then stores
// 5) Texture Rotated   - axis-clip_rect intersection, bilinear sample texture in uv coords, blends output with texel then stores
// 6) (Texture Aligned) - ??? to be done

Shader_Context :: struct {
    buffer:    Bitmap,
    at:        ^Color,
    
    fill_rect: Rectangle2i,
    
    // 
    start_mask: lane_u32,
    end_mask:   lane_u32,
    mask: lane_u32,
    
    // Per function
    normal_x_axis: lane_v2,
    normal_y_axis: lane_v2,
    
    delta_u_row: lane_f32,
    delta_v_row: lane_f32,
    
    // Per row
    u_row: lane_f32,
    v_row: lane_f32,
}

////////////////////////////////////////////////

shader_init_with_rect :: proc (ctx: ^Shader_Context, bitmap: Bitmap, clip_rect, fill_rect: Rectangle2i) -> (ok: bool, pmin, pmax, pstep: v2i) {
    ctx.buffer = bitmap
    ctx.fill_rect = get_intersection(fill_rect, clip_rect)
    
    ok = has_area(ctx.fill_rect)
    if !ok do return ok, pmin, pmax, pstep
    
    _shader_init_mask_fill_rect(ctx)
    
    pmin = ctx.fill_rect.min
    pmax = ctx.fill_rect.max
    pstep = {LaneWidth, 1}
    
    return true, pmin, pmax, pstep
}

shader_init_with_rotation :: proc (ctx: ^Shader_Context, bitmap: Bitmap, clip_rect: Rectangle2i, origin, x_axis, y_axis: v2) -> (ok: bool, pmin, pmax, pstep: v2i) {
    rect := rectangle_origin_axis(origin, x_axis, y_axis)
    
    ok, pmin, pmax, pstep = shader_init_with_rect(ctx, bitmap, clip_rect, rect)
    if !ok do return ok, pmin, pmax, pstep
    
    ////////////////////////////////////////////////
    
    // @todo(viktor): Just don't draw if the axis are not independent?
    determinant := x_axis.x * y_axis.y - x_axis.y * y_axis.x
    if determinant == 0 do determinant = 1 
    
    normal_x_axis_ := v2{ y_axis.y, -y_axis.x} / determinant
    normal_y_axis_ := v2{-x_axis.y,  x_axis.x} / determinant
    
    ctx.normal_x_axis = vec_cast(lane_f32, normal_x_axis_)
    ctx.normal_y_axis = vec_cast(lane_f32, normal_y_axis_)
    
    delta := vec_cast(lane_f32, ctx.fill_rect.min) - vec_cast(lane_f32, origin) 
    when LaneWidth == 4 {
        delta.x += { 0, 1, 2, 3 }
    } else when LaneWidth == 8 {
        delta.x += { 0, 1, 2, 3, 4, 5, 6, 7 }
    } else when LaneWidth == 16 {
        delta.x += { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }
    } else {
        #panic("unhandled lane width")
    }
    
    delta_n_x_axis := delta * ctx.normal_x_axis
    delta_n_y_axis := delta * ctx.normal_y_axis
    
    ctx.delta_u_row = delta_n_x_axis.x + delta_n_x_axis.y
    ctx.delta_v_row = delta_n_y_axis.x + delta_n_y_axis.y
    
    return ok, pmin, pmax, pstep
}

_shader_init_mask_fill_rect :: proc (ctx: ^Shader_Context) {
    ctx.start_mask = MaskFF
    ctx.end_mask   = MaskFF
    
    if !is_aligned(LaneWidth, ctx.fill_rect.min.x) {
        ctx.start_mask = start_masks[align_offset(LaneWidth, ctx.fill_rect.min.x)]
        ctx.fill_rect.min.x = align(LaneWidth, ctx.fill_rect.min.x) - LaneWidth
    }
    
    if !is_aligned(LaneWidth, ctx.fill_rect.max.x) {
        ctx.end_mask = end_masks[align_offset(LaneWidth, ctx.fill_rect.max.x)]
        ctx.fill_rect.max.x = align(LaneWidth, ctx.fill_rect.max.x)
    }
    
    if ctx.fill_rect.max.x - ctx.fill_rect.min.x == LaneWidth {
        ctx.start_mask &= ctx.end_mask
        ctx.end_mask = ctx.start_mask
    }
}

////////////////////////////////////////////////

shader_row_with_uv :: proc (ctx: ^Shader_Context, y: i32) {
    // @note(viktor): Iterative calculations will lead to arithmetic errors, so we always calculate based of the index.
    y_index := cast(f32) (y - ctx.fill_rect.min.y)
    ctx.u_row = ctx.delta_u_row + y_index * ctx.normal_x_axis.y
    ctx.v_row = ctx.delta_v_row + y_index * ctx.normal_y_axis.y
}

////////////////////////////////////////////////

shader_update_load_and_store_mask :: proc (ctx: ^Shader_Context, x: i32) {
    if x == ctx.fill_rect.min.x {
        ctx.mask = ctx.start_mask
    } else if x + LaneWidth >= ctx.fill_rect.max.x {
        ctx.mask = ctx.end_mask
    } else {
        ctx.mask = MaskFF
    }
}

shader_load_pixels :: proc (ctx: ^Shader_Context, x, y: i32) -> (result: lane_v4) {
    shader_update_load_and_store_mask(ctx, x)
    result = _shader_load_pixels(ctx, x, y)
    
    return result
}

shader_load_pixels_with_uv :: proc (ctx: ^Shader_Context, x, y: i32) -> (pixels: lane_v4, uv: lane_v2) {
    shader_update_load_and_store_mask(ctx, x)
    uv = _shader_uv_and_mask(ctx, x, y)
    pixels = _shader_load_pixels(ctx, x, y)
    
    return pixels, uv
}

_shader_uv_and_mask :: proc (ctx: ^Shader_Context, x, y: i32) -> (result: lane_v2) {
    x_index := cast(f32) (x - ctx.fill_rect.min.x) / LaneWidth
    u := ctx.u_row + x_index * ctx.normal_x_axis.x * LaneWidth
    v := ctx.v_row + x_index * ctx.normal_y_axis.x * LaneWidth
    
    ctx.mask &= simd.lanes_ge(u, 0) & simd.lanes_le(u, 1) & simd.lanes_ge(v, 0) & simd.lanes_le(v, 1)
    
    u = clamp_01(u)
    v = clamp_01(v)
    
    return {u, v}
}

_shader_load_pixels :: proc (using ctx: ^Shader_Context, x, y: i32) -> (result: lane_v4) {
    at      = &buffer.memory[x + y * buffer.width]
    pixel_ := simd.masked_load(at, cast(lane_u32) 0, mask)
    result  = unpack_pixel(pixel_)
    
    result = srgb_to_linear(result)
    return result
}

////////////////////////////////////////////////

shader_store_pixels_at :: proc (ctx: ^Shader_Context, packed: lane_u32, x, y: i32) {
    ctx.at = &ctx.buffer.memory[x + y * ctx.buffer.width]
    simd.masked_store(ctx.at, packed, ctx.mask)
}

shader_store_pixels :: proc (ctx: ^Shader_Context, packed: lane_u32) {
    simd.masked_store(ctx.at, packed, ctx.mask)
}

////////////////////////////////////////////////

unpack_pixel :: proc (pixel: lane_u32) -> (color: lane_v4) {
    color.r = cast(lane_f32) (0xff &          pixel      )
    color.g = cast(lane_f32) (0xff & simd.shr(pixel,  8) )
    color.b = cast(lane_f32) (0xff & simd.shr(pixel,  16))
    color.a = cast(lane_f32) (0xff & simd.shr(pixel,  24))
    
    return color
}

pack_pixel :: proc (value: lane_v4) -> (result: lane_u32) {
    color := vec_cast(lane_u32, value)
    result = color.r | simd.shl_masked(color.g, 8) | simd.shl_masked(color.b, 16) | simd.shl_masked(color.a, 24)
    return result
}

////////////////////////////////////////////////

when LaneWidth == 4 {
    start_masks := [?] lane_u32 {
        {0..<4 = MaskFF}, // no mask
        {1..<4 = MaskFF},
        {2..<4 = MaskFF},
        {3..<4 = MaskFF},
    }
    
    end_masks := [?] lane_u32 {
        {0..<4 = MaskFF}, // no mask
        {0..<1 = MaskFF},
        {0..<2 = MaskFF},
        {0..<3 = MaskFF},
    }
} else when LaneWidth == 8 {
    start_masks := [?] lane_u32 {
        {0..<8 = MaskFF}, // no mask
        {1..<8 = MaskFF},
        {2..<8 = MaskFF},
        {3..<8 = MaskFF},
        {4..<8 = MaskFF},
        {5..<8 = MaskFF},
        {6..<8 = MaskFF},
        {7..<8 = MaskFF},
    }
    
    end_masks := [?] lane_u32 {
        {0..<8 = MaskFF}, // no mask
        {0..<1 = MaskFF},
        {0..<2 = MaskFF},
        {0..<3 = MaskFF},
        {0..<4 = MaskFF},
        {0..<5 = MaskFF},
        {0..<6 = MaskFF},
        {0..<7 = MaskFF},
    }
} else when LaneWidth == 16 {
    start_masks := [?] lane_u32 {
        { 0..<16 = MaskFF}, // no mask
        { 1..<16 = MaskFF},
        { 2..<16 = MaskFF},
        { 3..<16 = MaskFF},
        { 4..<16 = MaskFF},
        { 5..<16 = MaskFF},
        { 6..<16 = MaskFF},
        { 7..<16 = MaskFF},
        { 8..<16 = MaskFF},
        { 9..<16 = MaskFF},
        {10..<16 = MaskFF},
        {11..<16 = MaskFF},
        {12..<16 = MaskFF},
        {13..<16 = MaskFF},
        {14..<16 = MaskFF},
        {15..<16 = MaskFF},
    }
    
    end_masks := [?] lane_u32 {
        {0..<16 = MaskFF}, // no mask
        {0..< 1 = MaskFF},
        {0..< 2 = MaskFF},
        {0..< 3 = MaskFF},
        {0..< 4 = MaskFF},
        {0..< 5 = MaskFF},
        {0..< 6 = MaskFF},
        {0..< 7 = MaskFF},
        {0..< 8 = MaskFF},
        {0..< 9 = MaskFF},
        {0..<10 = MaskFF},
        {0..<11 = MaskFF},
        {0..<12 = MaskFF},
        {0..<13 = MaskFF},
        {0..<14 = MaskFF},
        {0..<15 = MaskFF},
    }
} else {
    #panic("unhandled lane width")
}