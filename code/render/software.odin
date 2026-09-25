#!+build
package render

import "core:simd"
import game "../game"

TileRenderWork :: struct {
    commands: ^game.RenderCommands,
    targets:  [] game.Bitmap,
    
    base_clip_rect: game.Rectangle2i,
}

////////////////////////////////////////////////

software_render_commands :: proc (queue: ^game.WorkQueue, commands: ^game.RenderCommands, base_target: game.Bitmap, arena: game.Allocator, single_threaded: bool) {
    timed_function()
    
    // @todo(viktor): removed from commands on day 384
    max_render_target_index := 1
    
    targets := game.make(arena, game.Bitmap, max_render_target_index + 1)
    targets[0] = base_target
    for &target in targets[1:] {
        target = base_target
        target.memory = game.make(arena, game.Color, target.dimension.x * target.dimension.y, game.align_no_clear(game.LaneWidth * size_of(game.Color)))
    }
    
    /* @todo(viktor):
        - Actually ballpark the memory bandwidth for our DrawRectangleQuickly
        - Re-test some of our instruction choices
    */
    
    tile_count :: game.v2i{4, 4}
    works: [tile_count.x * tile_count.y] TileRenderWork
    
    tile_size := base_target.dimension / tile_count
    tile_size.x = game.align(game.LaneWidth, tile_size.x)
    
    work_index: i32
    for y in 0..<tile_count.y {
        for x in 0..<tile_count.x {
            work := &works[work_index]
            defer work_index += 1
            
            work ^= {
                commands = commands,
                targets  = targets,
                base_clip_rect = {
                    min = tile_size * {x, y},
                },
            }
            
            work.base_clip_rect.max = work.base_clip_rect.min + tile_size
            
            if x == tile_count.x-1 {
                work.base_clip_rect.max.x = base_target.dimension.x 
            }
            if y == tile_count.y-1 {
                work.base_clip_rect.max.y = base_target.dimension.y
            }
            
            if single_threaded {
                do_tile_render_work(work)
            } else {
                game.Platform.enqueue_work(queue, work, do_tile_render_work)
            }
        }
    }
    
    game.Platform.complete_all_work(queue)
}

do_tile_render_work :: proc (data: game.pmm) {
    timed_function()
    
    using work := cast(^TileRenderWork) data
    game.assert(commands != nil)
    
    clip_rect := base_clip_rect
    
    for target, index in targets {
        clear_color: game.v4
        if index == 0 {
            clear_color = commands.clear_color
        }
        clear_render_target(target, clip_rect, clear_color)
    }
    
    target: game.Bitmap
    
    for game.begin_reading(&commands.push_buffer); game.can_read(&commands.push_buffer); {
        type := game.read(&commands.push_buffer, game.RenderEntryType)
        
        switch type^ {
          case .None: unreachable()
            
          case .DepthClear: unimplemented()
          case .BeginPeels: unimplemented()
          case .EndPeels:   unimplemented()
            
          case .Textured_Quads:
            entry := game.read(&commands.push_buffer, game.Textured_Quads)
            
            clip_rect = game.get_intersection(base_clip_rect, entry.setup.clip_rect)
            
            // @todo(viktor): removed from entry.setup on day 384, it was never set
            render_target_index: int
            target = targets[render_target_index]
            game.assert(target.memory != nil)
            
            game.unused(draw_rectangle_fill_color_axis_aligned)
            game.unused(draw_rectangle_fill_color)
            game.unused(draw_rectangle_with_texture)
            
            // bitmap was this
            // draw_rectangle_with_texture(target, clip_rect, entry.p, entry.x_axis.xy, entry.y_axis.xy, entry.bitmap, entry.premultiplied_color)
            
            // rectangle was this
            // rect := game.rectangle_min_dimension(entry.p, game.V3(entry.dim, 0))
            // draw_rectangle_fill_color_axis_aligned(target, clip_rect, rect, entry.premultiplied_color)
            
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

clear_render_target :: proc (dest: game.Bitmap, clip_rect: game.Rectangle2i, color: game.v4) {
    timed_function()
    
    ctx: Shader_Context
    ok, pmin, pmax, pstep := shader_init_with_rect(&ctx, dest, clip_rect, clip_rect)
    game.assert(ok)
    
    color := cast(game.lane_v4) (color * 255)
    color = game.srgb_to_linear(color)
    packed := game.pack_pixel(color)
    
    for y := pmin.y; y < pmax.y; y += pstep.y {
        for x := pmin.x; x < pmax.x; x += pstep.x {
            shader_update_load_and_store_mask(&ctx, x)
            shader_store_pixels_at(&ctx, packed, x, y)
        }
    }
}

draw_rectangle_fill_color_axis_aligned :: proc (buffer: game.Bitmap, clip_rect: game.Rectangle2i, rect: game.Rectangle3, color: game.v4) {
    // @todo(viktor): Move to 3D
    rect := game.get_xy(rect)
    
    // @todo(viktor): is this actually necessary?
    fill_rect := game.rectangle_min_max(game.floor(i32, rect.min), game.ceil(i32, rect.max))
    
    ctx: Shader_Context
    ok, pmin, pmax, pstep := shader_init_with_rect(&ctx, buffer, clip_rect, fill_rect)
    if !ok do return
    
    color := cast(game.lane_v4) (color * 255)
    
    color = game.srgb_to_linear(color)
    color.rgb = game.clamp(color.rgb, cast(game.lane_f32) 0, cast(game.lane_f32) MaxColorValue)
    inv_color_a := (1 - (Inv255 * color.a))
    
    for y := pmin.y; y < pmax.y; y += pstep.y {
        for x := pmin.x; x < pmax.x; x += pstep.x {
            pixels := shader_load_pixels(&ctx, x, y)
            
            // @note(viktor): blend with target pixel
            blended := inv_color_a * pixels + color
            
            blended = game.linear_to_srgb(blended)
            
            packed := game.pack_pixel(blended)
            
            shader_store_pixels(&ctx, packed)
        }
    }
}

draw_rectangle_fill_color :: proc (buffer: game.Bitmap, clip_rect: game.Rectangle2i, origin, x_axis, y_axis: game.v2, color: game.v4) {
    ctx: Shader_Context
    ok, pmin, pmax, pstep := shader_init_with_rotation(&ctx, buffer, clip_rect, origin, x_axis, y_axis)
    if !ok do return
    
    color := cast(game.lane_v4) (color * 255)
    
    color = game.srgb_to_linear(color)
    color.rgb = game.clamp(color.rgb, cast(game.lane_f32) 0, cast(game.lane_f32) MaxColorValue)
    inv_color_a := (1 - (Inv255 * color.a))
    
    for y := pmin.y; y < pmax.y; y += pstep.y {
        shader_row_with_uv(&ctx, y)
        
        for x := pmin.x; x < pmax.x; x += pstep.x {
            pixels, _ := shader_load_pixels_with_uv(&ctx, x, y)
            
            // @note(viktor): blend with target pixel
            blended := inv_color_a * pixels + color
            
            blended = game.linear_to_srgb(blended)
            
            packed := game.pack_pixel(blended)
            
            shader_store_pixels(&ctx, packed)
        }
    }
}

draw_rectangle_with_texture :: proc (buffer: game.Bitmap, clip_rect: game.Rectangle2i, origin: game.v3, x_axis, y_axis: game.v2, texture: game.Bitmap, color: game.v4) {
    // @todo(viktor): Move to 3D
    origin := origin.xy
    
    ctx: Shader_Context
    ok, pmin, pmax, pstep := shader_init_with_rotation(&ctx,  buffer, clip_rect, origin, x_axis, y_axis)
    if !ok do return
    
    color := cast(game.lane_v4) color
    
    texture_size := cast(game.lane_v2) (texture.dimension - 2)
    
    texture_width  := cast(game.lane_u32) texture.dimension.x
    texture_memory := cast(game.lane_umm) raw_data(texture.memory)

    zero := cast(game.lane_u32) 0
    mask := cast(game.lane_u32) MaskFF
    
    for y := pmin.y; y < pmax.y; y += pstep.y {
        shader_row_with_uv(&ctx, y)
        
        for x := pmin.x; x < pmax.x; x += pstep.x {
            pixel, uv := shader_load_pixels_with_uv(&ctx, x, y)
            
            // @note(viktor): Bias texture coordinates to start on the boundary between the 0,0 and 1,1 pixels
            t := uv * texture_size + 0.5
            s :=     cast([2] game.lane_u32) t
            f := t - cast(game.lane_v2) s
            
            // @note(viktor): bilinear sample
            index_a := cast(game.lane_umm) ((s.x + 0) + (s.y + 0) * texture_width)
            index_b := cast(game.lane_umm) ((s.x + 1) + (s.y + 0) * texture_width)
            index_c := cast(game.lane_umm) ((s.x + 0) + (s.y + 1) * texture_width)
            index_d := cast(game.lane_umm) ((s.x + 1) + (s.y + 1) * texture_width)
            
            texel_a := cast(game.lane_pmm) (texture_memory + index_a * size_of(game.Color))
            texel_b := cast(game.lane_pmm) (texture_memory + index_b * size_of(game.Color))
            texel_c := cast(game.lane_pmm) (texture_memory + index_c * size_of(game.Color))
            texel_d := cast(game.lane_pmm) (texture_memory + index_d * size_of(game.Color))
            
            sample_a := simd.gather(texel_a, zero, mask)
            sample_b := simd.gather(texel_b, zero, mask)
            sample_c := simd.gather(texel_c, zero, mask)
            sample_d := simd.gather(texel_d, zero, mask)
            
            ta := game.unpack_pixel(sample_a)
            tb := game.unpack_pixel(sample_b)
            tc := game.unpack_pixel(sample_c)
            td := game.unpack_pixel(sample_d)
            
            ta = game.srgb_to_linear(ta)
            tb = game.srgb_to_linear(tb)
            tc = game.srgb_to_linear(tc)
            td = game.srgb_to_linear(td)
            
            texel := game.bilinear_blend(ta, tb, tc, td, f)
            
            texel *= color
            texel.rgb = game.clamp(texel.rgb, cast(game.lane_f32) 0, cast(game.lane_f32) MaxColorValue)
            
            // @note(viktor): blend with target pixel
            inv_texel_a := (1 - (Inv255 * texel.a))
            blended := inv_texel_a * pixel + texel
            
            blended = game.linear_to_srgb(blended)
            
            packed := game.pack_pixel(blended)
            
            shader_store_pixels(&ctx, packed)
        }
    }
}

////////////////////////////////////////////////

// @todo(viktor): How can we split this in a relevant and convinient way
// 1) Clear             - only clip_rect, only masked_stores into output
// 3) Fill Rect Aligned - rect-clip_rect intersection, blends output with color then stores
// 4) Fill Rect Rotated - axis-clip_rect intersection, blends output with color then stores
// 5) Texture Rotated   - axis-clip_rect intersection, bilinear sample texture in uv coords, blends output with texel then stores
// 6) (Texture Aligned) - ??? to be done

Shader_Context :: struct {
    buffer:    game.Bitmap,
    at:        ^game.Color,
    
    fill_rect: game.Rectangle2i,
    
    // 
    start_mask: game.lane_u32,
    end_mask:   game.lane_u32,
    mask: game.lane_u32,
    
    // Per function
    normal_x_axis: game.lane_v2,
    normal_y_axis: game.lane_v2,
    
    delta_u_row: game.lane_f32,
    delta_v_row: game.lane_f32,
    
    // Per row
    u_row: game.lane_f32,
    v_row: game.lane_f32,
}

////////////////////////////////////////////////

shader_init_with_rect :: proc (ctx: ^Shader_Context, bitmap: game.Bitmap, clip_rect, fill_rect: game.Rectangle2i) -> (ok: bool, pmin, pmax, pstep: game.v2i) {
    ctx.buffer = bitmap
    ctx.fill_rect = game.get_intersection(fill_rect, clip_rect)
    
    ok = game.has_area(ctx.fill_rect)
    if !ok do return ok, pmin, pmax, pstep
    
    _shader_init_mask_fill_rect(ctx)
    
    pmin = ctx.fill_rect.min
    pmax = ctx.fill_rect.max
    pstep = {game.LaneWidth, 1}
    
    return true, pmin, pmax, pstep
}

shader_init_with_rotation :: proc (ctx: ^Shader_Context, bitmap: game.Bitmap, clip_rect: game.Rectangle2i, origin, x_axis, y_axis: game.v2) -> (ok: bool, pmin, pmax, pstep: game.v2i) {
    rect := game.rectangle_origin_axis(origin, x_axis, y_axis)
    
    ok, pmin, pmax, pstep = shader_init_with_rect(ctx, bitmap, clip_rect, rect)
    if !ok do return ok, pmin, pmax, pstep
    
    ////////////////////////////////////////////////
    
    // @todo(viktor): Just don't draw if the axis are not independent?
    determinant := x_axis.x * y_axis.y - x_axis.y * y_axis.x
    if determinant == 0 do determinant = 1 
    
    normal_x_axis_ := game.v2{ y_axis.y, -y_axis.x} / determinant
    normal_y_axis_ := game.v2{-x_axis.y,  x_axis.x} / determinant
    
    ctx.normal_x_axis = cast(game.lane_v2) normal_x_axis_
    ctx.normal_y_axis = cast(game.lane_v2) normal_y_axis_
    
    delta := cast(game.lane_v2) ctx.fill_rect.min - cast(game.lane_v2) origin
    when game.LaneWidth == 4 {
        delta.x += { 0, 1, 2, 3 }
    } else when game.LaneWidth == 8 {
        delta.x += { 0, 1, 2, 3, 4, 5, 6, 7 }
    } else when game.LaneWidth == 16 {
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
    
    if !game.is_aligned(game.LaneWidth, ctx.fill_rect.min.x) {
        ctx.start_mask = start_masks[game.align_offset(game.LaneWidth, ctx.fill_rect.min.x)]
        ctx.fill_rect.min.x = game.align(game.LaneWidth, ctx.fill_rect.min.x) - game.LaneWidth
    }
    
    if !game.is_aligned(game.LaneWidth, ctx.fill_rect.max.x) {
        ctx.end_mask = end_masks[game.align_offset(game.LaneWidth, ctx.fill_rect.max.x)]
        ctx.fill_rect.max.x = game.align(game.LaneWidth, ctx.fill_rect.max.x)
    }
    
    if ctx.fill_rect.max.x - ctx.fill_rect.min.x == game.LaneWidth {
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
    } else if x + game.LaneWidth >= ctx.fill_rect.max.x {
        ctx.mask = ctx.end_mask
    } else {
        ctx.mask = MaskFF
    }
}

shader_load_pixels :: proc (ctx: ^Shader_Context, x, y: i32) -> (result: game.lane_v4) {
    shader_update_load_and_store_mask(ctx, x)
    result = _shader_load_pixels(ctx, x, y)
    
    return result
}

shader_load_pixels_with_uv :: proc (ctx: ^Shader_Context, x, y: i32) -> (pixels: game.lane_v4, uv: game.lane_v2) {
    shader_update_load_and_store_mask(ctx, x)
    uv = _shader_uv_and_mask(ctx, x, y)
    pixels = _shader_load_pixels(ctx, x, y)
    
    return pixels, uv
}

_shader_uv_and_mask :: proc (ctx: ^Shader_Context, x, y: i32) -> (result: game.lane_v2) {
    x_index := cast(f32) (x - ctx.fill_rect.min.x) / game.LaneWidth
    u := ctx.u_row + x_index * ctx.normal_x_axis.x * game.LaneWidth
    v := ctx.v_row + x_index * ctx.normal_y_axis.x * game.LaneWidth
    
    ctx.mask &= simd.lanes_ge(u, 0) & simd.lanes_le(u, 1) & simd.lanes_ge(v, 0) & simd.lanes_le(v, 1)
    
    u = game.clamp_01(u)
    v = game.clamp_01(v)
    
    return {u, v}
}

_shader_load_pixels :: proc (ctx: ^Shader_Context, x, y: i32) -> (result: game.lane_v4) {
    ctx.at  = &ctx.buffer.memory[x + y * ctx.buffer.dimension.x]
    pixel_ := simd.masked_load(ctx.at, cast(game.lane_u32) 0, ctx.mask)
    result  = game.unpack_pixel(pixel_)
    
    result = game.srgb_to_linear(result)
    return result
}

////////////////////////////////////////////////

shader_store_pixels_at :: proc (ctx: ^Shader_Context, packed: game.lane_u32, x, y: i32) {
    ctx.at = &ctx.buffer.memory[x + y * ctx.buffer.dimension.x]
    simd.masked_store(ctx.at, packed, ctx.mask)
}

shader_store_pixels :: proc (ctx: ^Shader_Context, packed: game.lane_u32) {
    simd.masked_store(ctx.at, packed, ctx.mask)
}

////////////////////////////////////////////////

when game.LaneWidth == 4 {
    start_masks := [?] game.lane_u32 {
        {0..<4 = MaskFF}, // no mask
        {1..<4 = MaskFF},
        {2..<4 = MaskFF},
        {3..<4 = MaskFF},
    }
    
    end_masks := [?] game.lane_u32 {
        {0..<4 = MaskFF}, // no mask
        {0..<1 = MaskFF},
        {0..<2 = MaskFF},
        {0..<3 = MaskFF},
    }
} else when game.LaneWidth == 8 {
    start_masks := [?] game.lane_u32 {
        {0..<8 = MaskFF}, // no mask
        {1..<8 = MaskFF},
        {2..<8 = MaskFF},
        {3..<8 = MaskFF},
        {4..<8 = MaskFF},
        {5..<8 = MaskFF},
        {6..<8 = MaskFF},
        {7..<8 = MaskFF},
    }
    
    end_masks := [?] game.lane_u32 {
        {0..<8 = MaskFF}, // no mask
        {0..<1 = MaskFF},
        {0..<2 = MaskFF},
        {0..<3 = MaskFF},
        {0..<4 = MaskFF},
        {0..<5 = MaskFF},
        {0..<6 = MaskFF},
        {0..<7 = MaskFF},
    }
} else when game.LaneWidth == 16 {
    start_masks := [?] game.lane_u32 {
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
    
    end_masks := [?] game.lane_u32 {
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