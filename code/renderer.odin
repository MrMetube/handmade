package main

// @todo(viktor): Pull this out into a third layer or into the game so that we can hotreload it

import "core:simd"

GlobalDebugRenderSingleThreaded: b32 = false
GlobalDebugShowLightingSampling: b32
GlobalDebugShowRenderSortGroups: b32

TileRenderWork :: struct {
    commands: ^RenderCommands, 
    prep:     RenderPrep,
    targets:  [] Bitmap,
    
    base_clip_rect: Rectangle2i, 
}

SortGridEntry :: struct {
    next:           ^SortGridEntry,
    occupant_index: u16,
}

SpriteGraphWalk :: struct {
    nodes:   [] SortSpriteBounds,
    offsets: ^Array(u32),
    hit_cycle: b32,
}

init_render_commands :: proc(commands: ^RenderCommands, push_buffer: []u8, width, height: i32) {
    commands ^= {
        width  = width, 
        height = height,
        
        render_entry_count = 1,
        push_buffer = push_buffer,
        push_buffer_data_at = auto_cast len(push_buffer),
    }
}

prep_for_render :: proc(commands: ^RenderCommands, temp_arena: ^Arena) -> (result: RenderPrep) {
    sort_render_elements(commands, &result, temp_arena)
    linearize_clip_rects(commands, &result, temp_arena)
    
    return result
}

linearize_clip_rects :: proc(commands: ^RenderCommands, prep: ^RenderPrep, arena: ^Arena) {
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

sort_render_elements :: proc(commands: ^RenderCommands, prep: ^RenderPrep, arena: ^Arena) {
    timed_function()
    
    element_count := commands.render_entry_count
    if element_count == 0 do return
    
    nodes := slice(commands.sort_entries)
    offsets := make_array(arena, u32, len(nodes))
    
    barrier_count: i64
    should_sort := true
    for start: i32; start < auto_cast len(nodes); {
        count: i32
        hit_barrier: b32
        if should_sort {
            count, hit_barrier = build_sprite_graph(nodes[start:], arena, vec_cast(f32, commands.width, commands.height))
            
            if hit_barrier {
                assert(nodes[start:][count-1].offset == SpriteBarrierValue)
                barrier_count += 1
            }
            
            sub_nodes := nodes[start:][: count - (hit_barrier ? 1 : 0)]
            walk := SpriteGraphWalk { sub_nodes, &offsets, false }
            for at, index in walk.nodes {
                assert(at.offset != SpriteBarrierValue)
                
                walk.hit_cycle = false
                if at.offset == SpriteBarrierValue {
                    assert(false)
                    continue
                }
                walk_sprite_graph_front_to_back(&walk, auto_cast index)
            }
        } else {
            sub_nodes := nodes[start:]
            walk := SpriteGraphWalk { sub_nodes, &offsets, false }
            count, hit_barrier = unsorted_output(&walk, sub_nodes)
            
            if hit_barrier {
                barrier_count += 1
            }
        }
        
        if hit_barrier {
            terminator := &nodes[start:][count-1]
            should_sort = (transmute(u16) terminator.flags & SpriteBarrierTurnsOffSorting) == 0
        }
        start += count
    }
    
    prep.sorted_offsets =  slice(offsets)
    assert(offsets.count + barrier_count == auto_cast len(nodes))
}

////////////////////////////////////////////////

build_sprite_graph :: proc(nodes: []SortSpriteBounds, arena: ^Arena, screen_size: v2) -> (count: i32, hit_barrier: b32) {
    timed_function()
    
    assert(cast(u64) len(nodes) < cast(u64) max(type_of(SortSpriteBounds{}.generation_count)))
    if len(nodes) == 0 do return
    // Grid Factor vs cycles in "bucketing"
    //  o:none   / o:speed
    // 1 - 200 M / 
    // 2 -  85 M / 15 M
    // 4 -  60 M / 11 M
    // 8 -  55 M / 10 M
    // 12 - 55 M / 10 M
    Width  :: 8*16
    Height :: 8*9
    
    grid: [Width] [Height] ^SortGridEntry
    inv_cell_size := v2{Width, Height} / screen_size
    screen_rect := rectangle_min_dimension(v2{}, screen_size)
    
    for &a, index_a in nodes {
        count = cast(i32) index_a+1
        if a.offset == SpriteBarrierValue {
            hit_barrier = true
            break
        }
        
        index_a := cast(u16) index_a
        if !intersects(a.screen_bounds, screen_rect) do continue
        
        grid_span := rectangle_min_max(truncate(i32, inv_cell_size * a.screen_bounds.min), truncate(i32, inv_cell_size * a.screen_bounds.max))
        
        grid_span = get_intersection(grid_span, Rectangle2i{ min = {0,0}, max = ({Width, Height}-1) })
        
        for grid_x in grid_span.min.x ..= grid_span.max.x {
            for grid_y in grid_span.min.y ..= grid_span.max.y {
                entry := push(arena, SortGridEntry, no_clear())
                entry.occupant_index = auto_cast index_a
                
                slot := &grid[grid_x][grid_y]
                // :ListPush why is this half-deferred ?
                entry.next = slot^
                defer slot ^= entry
                
                for entry_b := slot^; entry_b != nil; entry_b = entry_b.next {
                    index_b := entry_b.occupant_index
                    b := &nodes[index_b]
                    
                    if b.generation_count == index_a || !intersects(a.screen_bounds, b.screen_bounds) do continue
                    b.generation_count = index_a
                    
                    front_index, behind_index := index_a, index_b
                    if sort_sprite_bounds_is_in_front_of(b.bounds, a.bounds) {
                        swap(&front_index, &behind_index)
                    }
                    
                    edge := push(arena, SpriteEdge, no_clear())
                    front := &nodes[front_index]
                    
                    edge.front  = auto_cast front_index
                    edge.behind = auto_cast behind_index
                    
                    edge.next_edge_with_same_front = front.first_edge_with_me_as_the_front
                    front.first_edge_with_me_as_the_front = edge
                    
                }
            }
        }
    }
    
    return count, hit_barrier
}

unsorted_output :: proc (walk: ^SpriteGraphWalk, nodes: [] SortSpriteBounds) -> (count: i32, hit_barrier: b32) {
    timed_function()
    
    assert(cast(u64) len(nodes) < cast(u64) max(type_of(SortSpriteBounds{}.generation_count)))
    if len(nodes) == 0 do return
    
    for &a, index_a in nodes {
        count = cast(i32) index_a+1
        if a.offset == SpriteBarrierValue {
            hit_barrier = true
            break
        }
        
        append(walk.offsets, a.offset)
    }
    
    return count, hit_barrier
}

walk_sprite_graph_front_to_back :: proc(walk: ^SpriteGraphWalk, index: u16) {
    at := &walk.nodes[index]
    
    walk.hit_cycle ||= .Cycle in at.flags
    if .Visited in at.flags do return
    
    at.flags += { .Visited, .Cycle }
    
    for edge := at.first_edge_with_me_as_the_front; edge != nil; edge = edge.next_edge_with_same_front {
        walk_sprite_graph_front_to_back(walk, edge.behind)
    }
    
    append(walk.offsets, at.offset)
    
    if !walk.hit_cycle {
        at.flags -= { .Cycle }
    }
}

////////////////////////////////////////////////

software_render_commands :: proc(queue: ^WorkQueue, commands: ^RenderCommands, prep: RenderPrep, base_target: Bitmap, arena: ^Arena) {
    timed_function()
    
    targets := push_slice(arena, Bitmap, commands.max_render_target_index+1)
    targets[0] = base_target
    for &target in targets[1:] {
        target = base_target
        target.memory = push_slice(arena, Color, target.width * target.height, align_no_clear(16))
        assert(cast(umm) raw_data(target.memory) & (16 - 1) == 0)
    }
    
    // @todo(viktor): Is this still relevant?
    /* @todo(viktor):
        - Make sure the tiles are all cache-aligned
        - How big should the tiles be for performance?
        - Actually ballpark the memory bandwidth for our DrawRectangleQuickly
        - Re-test some of our instruction choices
    */
    
    tile_count :: v2i{4, 4}
    works: [tile_count.x * tile_count.y]TileRenderWork
    
    tile_size  := v2i{base_target.width, base_target.height} / tile_count
    tile_size.x = ((tile_size.x + (3)) / 4) * 4
    
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

do_tile_render_work :: proc(data: pmm) {
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
    for sort_entry_index in prep.sorted_offsets {
        // :PointerArithmetic
        header := cast(^RenderEntryHeader) &commands.push_buffer[sort_entry_index]
        entry_data := &commands.push_buffer[sort_entry_index + size_of(RenderEntryHeader)]
        
        if clip_rect_index != header.clip_rect_index {
            clip_rect_index = header.clip_rect_index
            
            clip := prep.clip_rects.data[clip_rect_index]
            clip_rect = get_intersection(base_clip_rect, clip.rect)
            
            target_index := clip.render_target_index
            target = targets[target_index]
            assert(target.memory != nil)
        }
        
        switch header.type {
          case .None: unreachable()
          case .RenderEntryClip: // @note(viktor): clip rects are handled before rendering
          
          case .RenderEntryBlendRenderTargets:
            entry := cast(^RenderEntryBlendRenderTargets) entry_data
            
            source := targets[entry.source_index]
            dest   := targets[entry.dest_index]
            blend_render_target(dest, clip_rect, source, entry.alpha)
            
          case .RenderEntryRectangle:
            entry := cast(^RenderEntryRectangle) entry_data
            draw_rectangle(target, clip_rect, entry.rect, entry.premultiplied_color)
            
          case .RenderEntryBitmap:
            entry := cast(^RenderEntryBitmap) entry_data
            draw_rectangle(target, clip_rect, entry.p, entry.x_axis, entry.y_axis, entry.bitmap^, entry.premultiplied_color)
        }
    }
}

draw_rectangle :: proc { draw_rectangle_fill_color_axis_aligned, draw_rectangle_fill_color, draw_rectangle_with_texture }

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

clear_render_target :: proc(dest: Bitmap, clip_rect: Rectangle2i, color: v4) {
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

blend_render_target :: proc(dest: Bitmap, clip_rect: Rectangle2i, source: Bitmap, alpha: f32) {
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

draw_rectangle_fill_color_axis_aligned :: proc (buffer: Bitmap, clip_rect: Rectangle2i, rect: Rectangle2, color: v4) {
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

draw_rectangle_fill_color :: proc(buffer: Bitmap, clip_rect: Rectangle2i, origin, x_axis, y_axis: v2, color: v4) {
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

draw_rectangle_with_texture :: proc (buffer: Bitmap, clip_rect: Rectangle2i, origin, x_axis, y_axis: v2, texture: Bitmap, color: v4) {
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

Shader_Sampler :: struct {

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
    
    if !is_aligned_pow2(ctx.fill_rect.min.x, LaneWidth) {
        ctx.start_mask = start_masks[align_offset_pow2(ctx.fill_rect.min.x, LaneWidth)]
        ctx.fill_rect.min.x = align_pow2(ctx.fill_rect.min.x, LaneWidth) - LaneWidth
    }
    
    if !is_aligned_pow2(ctx.fill_rect.max.x, LaneWidth) {
        ctx.end_mask = end_masks[align_offset_pow2(ctx.fill_rect.max.x, LaneWidth)]
        ctx.fill_rect.max.x = align_pow2(ctx.fill_rect.max.x, LaneWidth)
    }
    
    if ctx.fill_rect.max.x - ctx.fill_rect.min.x < LaneWidth {
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

srgb_to_linear :: proc (color: lane_v4) -> (result: lane_v4) {
    result.rgb = square(color.rgb)
    result.a = color.a
    return result
}

linear_to_srgb :: proc (color: lane_v4) -> (result: lane_v4) {
    result.rgb = square_root(color.rgb)
    result.a = color.a
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