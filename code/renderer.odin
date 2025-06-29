package main

// @todo(viktor): Pull this out into a third layer or into the game so that we can hotreload it

import "core:simd"

GlobalDebugRenderSingleThreaded: b32
GlobalDebugShowLightingBounceDirection: b32
GlobalDebugShowLightingSampling: b32
GlobalDebugShowRenderSortGroups: b32

TileRenderWork :: struct {
    commands: ^RenderCommands, 
    prep:     RenderPrep,
    targets:  []Bitmap,
    
    base_clip_rect: Rectangle2i, 
}

SortGridEntry :: struct {
    next:           ^SortGridEntry,
    occupant_index: u16,
}

SpriteGraphWalk :: struct {
    nodes:   []SortSpriteBounds,
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

aspect_ratio_fit :: proc (render_size: [2]i32, window_size: [2]i32) -> (result: Rectangle2i) {
    if render_size.x > 0 && render_size.y > 0 && window_size.x > 0 && window_size.y > 0 {
        optimal_window_width  := round(i32, cast(f32) window_size.y * cast(f32) render_size.x / cast(f32) render_size.y)
        optimal_window_height := round(i32, cast(f32) window_size.x * cast(f32) render_size.y / cast(f32) render_size.x)
        
        window_center := window_size / 2
        optimal_window_size: [2]i32
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
    for start: i32; start < auto_cast len(nodes); {
        count, hit_barrier := build_sprite_graph(nodes[start:], arena, vec_cast(f32, commands.width, commands.height))
        
        if hit_barrier {
            assert(nodes[start+count-1].offset == SpriteBarrierValue)
            barrier_count += 1
        }
        
        sub_nodes := nodes[start :][: count - (hit_barrier ? 1 : 0)]
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
        
        start += count
    }
    
    prep.sorted_offsets =  slice(offsets)
    assert(offsets.count + barrier_count == auto_cast len(nodes))
}

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
    
    bucketing := game.begin_timed_block("bucketing")
    
    grid: [Width][Height]^SortGridEntry
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
    game.end_timed_block(bucketing)
    
    return count, hit_barrier
}

walk_sprite_graph_front_to_back :: proc(walk: ^SpriteGraphWalk, index: u16) {
    at := &walk.nodes[index]
    
    walk.hit_cycle ||= .Cycle in at.flags
    if .Visited in at.flags do return

    at.flags += { .Visited, .Cycle }

    for edge := at.first_edge_with_me_as_the_front; edge != nil; edge = edge.next_edge_with_same_front {
        assert(edge.front == index)
        walk_sprite_graph_front_to_back(walk, edge.behind)
    }
    
    // @note(viktor): Do work here!
    append(walk.offsets, at.offset)
    
    if !walk.hit_cycle {
        at.flags -= { .Cycle }
    }
}

////////////////////////////////////////////////

software_render_commands :: proc(queue: ^PlatformWorkQueue, commands: ^RenderCommands, prep: RenderPrep, base_target: Bitmap, arena: ^Arena) {
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
    
    tile_count :: [2]i32{4, 4}
    works: [tile_count.x * tile_count.y]TileRenderWork
    
    tile_size  := [2]i32{base_target.width, base_target.height} / tile_count
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

do_tile_render_work : PlatformWorkQueueCallback : proc(data: pmm) {
    timed_function()
    using work := cast(^TileRenderWork) data
    assert(commands != nil)

    clip_rect := base_clip_rect
    clip_rect_index := max(u16)
    
    for target, index in targets {
        clear_color := commands.clear_color
        if index == 0 {
            clear_color.a = clear_color.a
        } else {
            clear_color.a = 0
        }
        clear_render_target(target, clear_color, clip_rect)
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
            blend_render_target(dest, entry.alpha, source, clip_rect)
            
          case .RenderEntryRectangle:
            entry := cast(^RenderEntryRectangle) entry_data
            origin := entry.rect.min
            dim := get_dimension(entry.rect)
            x_axis := v2{dim.x, 0}
            y_axis := v2{0, dim.y}
            draw_rectangle(target, origin, x_axis, y_axis, entry.premultiplied_color, clip_rect)
            
          case .RenderEntryBitmap:
            entry := cast(^RenderEntryBitmap) entry_data
            
            draw_rectangle(target,
                entry.p, entry.x_axis, entry.y_axis,
                entry.bitmap^, entry.premultiplied_color,
                clip_rect,
            )
        }
    }
}

draw_rectangle :: proc { draw_rectangle_with_texture, draw_rectangle_fill_color, draw_rectangle_fill_color_axis_aligned }

////////////////////////////////////////////////
// @important @todo(viktor): 
// - Compress vector operations into simd floats
// - Extract the copypastas in these routines into functions

@(enable_target_feature="sse,sse2")
draw_rectangle_with_texture :: proc(buffer: Bitmap, origin, x_axis, y_axis: v2, texture: Bitmap, color: v4, clip_rect: Rectangle2i) {
    /* 
    length_x_axis := length(x_axis)
    length_y_axis := length(y_axis)
    normal_x_axis := (length_y_axis / length_x_axis) * x_axis
    normal_y_axis := (length_x_axis / length_y_axis) * y_axis
    // @note(viktor): normal_z_scale could be a parameter if we want people
    // to have control over the amount of scaling in the z direction that
    // the normals appear to have
    normal_z_scale := linear_blend(length_x_axis, length_y_axis, 0.5)
    */
    
    fill_rect := rectangle_inverted_infinity(Rectangle2i)
    for testp in ([?]v2{origin, (origin+x_axis), (origin + y_axis), (origin + x_axis + y_axis)}) {
        floorp := floor(i32, testp)
        ceilp  := ceil(i32,  testp)
        
        fill_rect.min.x = min(fill_rect.min.x, floorp.x)
        fill_rect.min.y = min(fill_rect.min.y, floorp.y)
        fill_rect.max.x = max(fill_rect.max.x, ceilp.x)
        fill_rect.max.y = max(fill_rect.max.y, ceilp.y)
    }
    fill_rect = get_intersection(fill_rect, clip_rect)
    
    if !has_area(fill_rect) do return
    
    maskFF :: 0xffffffff
    maskFFx8 :u32x8: maskFF
    clip_mask := maskFFx8
    
    start_clip_mask := clip_mask
    if fill_rect.min.x & 7 != 0 {
        start_clip_masks := [?]u32x8 {
            {0..<8 = maskFF},
            {1..<8 = maskFF},
            {2..<8 = maskFF},
            {3..<8 = maskFF},
            {4..<8 = maskFF},
            {5..<8 = maskFF},
            {6..<8 = maskFF},
            {7..<8 = maskFF},
        }
        
        start_clip_mask = start_clip_masks[fill_rect.min.x & 7]
        fill_rect.min.x = align8(fill_rect.min.x) - 8
    }
    
    end_clip_mask := clip_mask
    if fill_rect.max.x & 7 != 0 {
        end_clip_masks := [?]u32x8 {
            {0..<8 = maskFF},
            {0..<1 = maskFF},
            {0..<2 = maskFF},
            {0..<3 = maskFF},
            {0..<4 = maskFF},
            {0..<5 = maskFF},
            {0..<6 = maskFF},
            {0..<7 = maskFF},
        }
        
        end_clip_mask = end_clip_masks[fill_rect.max.x & 7]
        fill_rect.max.x = align8(fill_rect.max.x)
    }
    
    delta := vec_cast(f32x8, fill_rect.min) - vec_cast(f32x8, origin) 
    delta.x += { 0, 1, 2, 3, 4, 5, 6, 7 }
    
    determinant := x_axis.x * y_axis.y - x_axis.y * y_axis.x
    // @todo(viktor): Just don't draw if the axis are not independent
    if determinant == 0 do determinant = 1
    
    normal_x_axis := vec_cast(f32x8, v2{ y_axis.y, -y_axis.x} / determinant)
    normal_y_axis := vec_cast(f32x8, v2{-x_axis.y,  x_axis.x} / determinant)
    
    delta_n_x_axis := delta * normal_x_axis
    delta_n_y_axis := delta * normal_y_axis
    
    delta_u_row := delta_n_x_axis.x + delta_n_x_axis.y
    delta_v_row := delta_n_y_axis.x + delta_n_y_axis.y
    
    inv_255         :f32x8= 1.0 / 255.0
    max_color_value :f32x8= 255 * 255
    
    color := vec_cast(f32x8, color)
        
    texture_size := vec_cast(f32x8, texture.width, texture.height) - 2
        
    texture_width := cast(i32x8) texture.width
    
    for y := fill_rect.min.y; y < fill_rect.max.y; y += 1 {
        // @note(viktor): iterative calculations will lead to arithmetic errors,
        // so we calculate always based of the index.
        y_index := cast(f32) (y - fill_rect.min.y)
        u_row := delta_u_row + y_index * normal_x_axis.y
        v_row := delta_v_row + y_index * normal_y_axis.y
        
        clip_mask = start_clip_mask
        for x := fill_rect.min.x; x < fill_rect.max.x; x += 8 {
            defer {
                if x + 8*2 < fill_rect.max.x {
                    clip_mask = maskFF
                } else {
                    clip_mask = end_clip_mask
                }
            }
            
            x_index := cast(f32) (x - fill_rect.min.x) / 8
            u := u_row + x_index * normal_x_axis.x * 8
            v := v_row + x_index * normal_y_axis.x * 8
            uv := [2]f32x8{u,v}
            
            uv = clamp_01(uv)
            
            // @note(viktor): Bias texture coordinates to start on the 
            // boundary between the 0,0 and 1,1 pixels
            t := uv * texture_size + 0.5
            s := vec_cast(i32x8, t)
            f := t - vec_cast(f32x8, s)
            
            // @note(viktor): bilinear sample
            fetch := cast(ummx8) (s.y * texture_width + s.x)
            
            ummx8 :: #simd [8]umm
            texture_memory := cast(ummx8) raw_data(texture.memory)
            texture_width  := cast(ummx8) texture.width
            
            texel_ := texture_memory + fetch * size_of(Color)
            
            zero := cast(u32x8) 0
            sample_a := simd.gather(cast(#simd [8]pmm) (texel_ + size_of(Color) * 0),                   zero, maskFFx8)
            sample_b := simd.gather(cast(#simd [8]pmm) (texel_ + size_of(Color) * 1),                   zero, maskFFx8)
            sample_c := simd.gather(cast(#simd [8]pmm) (texel_ + size_of(Color) * texture_width),       zero, maskFFx8)
            sample_d := simd.gather(cast(#simd [8]pmm) (texel_ + size_of(Color) * (texture_width + 1)), zero, maskFFx8)
            
            ta := unpack_pixel(sample_a)
            tb := unpack_pixel(sample_b)
            tc := unpack_pixel(sample_c)
            td := unpack_pixel(sample_d)
            
            // @note(viktor): srgb to linear
            ta.rgb = square(ta.rgb)
            tb.rgb = square(tb.rgb)
            tc.rgb = square(tc.rgb)
            td.rgb = square(td.rgb)
            
            u = uv[0]
            v = uv[1]
            // u >= 0 && u <= 1 && v >= 0 && v <= 1
            write_mask := clip_mask & simd.lanes_ge(u, 0) & simd.lanes_le(u, 1) & simd.lanes_ge(v, 0) & simd.lanes_le(v, 1)
            dest  := &buffer.memory[y * buffer.width + x]
            pixel_ := simd.masked_load(dest, cast(u32x8) 0, write_mask)
            pixel := unpack_pixel(pixel_)
            
            pixel.rgb = square(pixel.rgb)
            
            texel := bilinear_blend(ta, tb, tc, td, f)
            
            texel *= color
            texel.rgb = clamp(texel.rgb, 0, max_color_value)
            
            // @note(viktor): blend with target pixel
            inv_texel_a := (1 - (inv_255 * texel.a))
            
            blended := inv_texel_a * pixel + texel
            
            // @note(viktor): linear to srgb
            blended.rgb  = square_root(blended.rgb)
            mixed := pack_pixel(blended)
            
            simd.masked_store(dest, mixed, write_mask)
        }
    }
}

draw_rectangle_fill_color_axis_aligned :: proc(buffer: Bitmap, rect: Rectangle2, color: v4, clip_rect: Rectangle2i){
    origin := rect.min
    dim := get_dimension(rect)
    x_axis := v2{dim.x, 0}
    y_axis := v2{0, dim.y}
    
    draw_rectangle_fill_color(buffer, origin, x_axis, y_axis, color, clip_rect)
}

@(enable_target_feature="sse,sse2")
draw_rectangle_fill_color :: proc(buffer: Bitmap, origin, x_axis, y_axis: v2, color: v4, clip_rect: Rectangle2i){
    fill_rect := rectangle_inverted_infinity(Rectangle2i)
    for testp in ([?]v2{origin, (origin+x_axis), (origin + y_axis), (origin + x_axis + y_axis)}) {
        floorp := floor(i32, testp)
        ceilp  := ceil(i32, testp)
     
        fill_rect.min.x = min(fill_rect.min.x, floorp.x)
        fill_rect.min.y = min(fill_rect.min.y, floorp.y)
        fill_rect.max.x = max(fill_rect.max.x, ceilp.x)
        fill_rect.max.y = max(fill_rect.max.y, ceilp.y)
    }
    fill_rect = get_intersection(fill_rect, clip_rect)
    
    if !has_area(fill_rect) do return 
    
    
    maskFF :: 0xffff_ffff
    maskFFx8 :u32x8: maskFF
    clip_mask := maskFFx8
    
    start_clip_mask := clip_mask
    if fill_rect.min.x & 7 != 0 {
        start_clip_masks := [?]u32x8 {
            {0..<8 = maskFF},
            {1..<8 = maskFF},
            {2..<8 = maskFF},
            {3..<8 = maskFF},
            {4..<8 = maskFF},
            {5..<8 = maskFF},
            {6..<8 = maskFF},
            {7..<8 = maskFF},
        }
        start_clip_mask = start_clip_masks[fill_rect.min.x & 7]
        fill_rect.min.x = align8(fill_rect.min.x) - 8
    }
    
    end_clip_mask   := clip_mask
    if fill_rect.max.x & 7 != 0 {
        end_clip_masks := [?]u32x8 {
            {0..<8 = maskFF},
            {0..<1 = maskFF},
            {0..<2 = maskFF},
            {0..<3 = maskFF},
            {0..<4 = maskFF},
            {0..<5 = maskFF},
            {0..<6 = maskFF},
            {0..<7 = maskFF},
        }
        
        end_clip_mask = end_clip_masks[fill_rect.max.x & 7]
        fill_rect.max.x = align8(fill_rect.max.x)
    }

    normal_x_axis_ := 1 / length_squared(x_axis) * x_axis
    normal_y_axis_ := 1 / length_squared(y_axis) * y_axis
    
    normal_x_axis := vec_cast(f32x8, normal_x_axis_)
    normal_y_axis := vec_cast(f32x8, normal_y_axis_)
    
    delta := vec_cast(f32x8, fill_rect.min) - vec_cast(f32x8, origin) 
    delta.x += { 0, 1, 2, 3, 4, 5, 6, 7 }
    
    delta_n_x_axis := delta * normal_x_axis
    delta_n_y_axis := delta * normal_y_axis
    
    delta_u_row := delta_n_x_axis.x + delta_n_x_axis.y
    delta_v_row := delta_n_y_axis.x + delta_n_y_axis.y
    
    inv_255         :f32x8= (1.0 / 255.0)
    max_color_value :f32x8= (255 * 255)
    
    color := vec_cast(f32x8, color * 255)
    
    // @note(viktor): srgb to linear
    color.rgb = square(color.rgb)
    color.rgb = clamp(color.rgb, 0, max_color_value)
    inv_color_a := (1 - (inv_255 * color.a))
        
    for y := fill_rect.min.y; y < fill_rect.max.y; y += 1 {
        // @note(viktor): Iterative calculations will lead to arithmetic errors,
        // so we always calculate based of the index.
        // u := dot(delta, n_x_axis)
        // v := dot(delta, n_y_axis)
        y_index := cast(f32) (y - fill_rect.min.y)
        u_row := delta_u_row + y_index * normal_x_axis.y
        v_row := delta_v_row + y_index * normal_y_axis.y
        
        clip_mask = start_clip_mask
        for x := fill_rect.min.x; x < fill_rect.max.x; x += 8 {
            defer {
                if x + 16 < fill_rect.max.x {
                    clip_mask = maskFF
                } else {
                    clip_mask = end_clip_mask
                }
            }
            x_index := cast(f32) (x - fill_rect.min.x) / 8
            u := u_row + x_index * normal_x_axis.x * 8
            v := v_row + x_index * normal_y_axis.x * 8
            
            // u >= 0 && u <= 1 && v >= 0 && v <= 1
            write_mask := clip_mask & simd.lanes_ge(u, 0) & simd.lanes_le(u, 1) & simd.lanes_ge(v, 0) & simd.lanes_le(v, 1)
            
            dest  := &buffer.memory[y * buffer.width + x]
            pixel_ := simd.masked_load(dest, cast(u32x8) 0, write_mask)
            pixel := unpack_pixel(pixel_)
            
            // @note(viktor): srgb to linear
            pixel.rgb = square(pixel.rgb)
            
            // @todo(viktor): Maybe we should blend the edges to mitigate aliasing for rotated rectangles
            
            // @note(viktor): blend with target pixel
            blended := inv_color_a * pixel + color
            
            // @note(viktor): linear to srgb
            blended.rgb = square_root(blended.rgb)
            mixed := pack_pixel(blended)
            
            simd.masked_store(dest, mixed, write_mask)
        }
    }
}

clear_render_target :: proc(dest: Bitmap, color: v4, clip_rect: Rectangle2i) {
    color := vec_cast(f32x8, color)
    // @note(viktor): linear to srgb
    color.rgb = square_root(color.rgb)
    color *= 255
    
    for y := clip_rect.min.y; y < clip_rect.max.y; y += 1 {
        for x := clip_rect.min.x; x < clip_rect.max.x; x += 8 {
            index := y * dest.width + x
            pixel := cast(^u32x8) &dest.memory[index]
            pixel^ = pack_pixel(color)
        }
    }
}

blend_render_target :: proc(dest: Bitmap, alpha: f32, source: Bitmap, clip_rect: Rectangle2i) {
    inv_255 :f32x8= (1.0 / 255.0)
    
    for y := clip_rect.min.y; y < clip_rect.max.y; y += 1 {
        for x := clip_rect.min.x; x < clip_rect.max.x; x += 8 {
            index := y * dest.width + x
            // @todo(viktor): what about unaligned loads? why did we check those in the other routines and not here
            texel_ := &source.memory[index]
            texel := cast(^u32x8) texel_
            pixel := cast(^u32x8) &dest.memory[index]
            
            texelx8 := unpack_pixel(texel^)
            pixelx8 := unpack_pixel(pixel^)
            
            // @note(viktor): srgb to linear
            texelx8 *= inv_255
            texelx8.rgb = square(texelx8.rgb)
            pixelx8 *= inv_255
            pixelx8.rgb = square(pixelx8.rgb)
            
            texel_alpha := alpha * texelx8.a
            blended := linear_blend(pixelx8, texelx8, texel_alpha)
            
            // @note(viktor): linear to srgb
            blended.rgb = square_root(blended.rgb)
            blended *= 255
            
            pixel^ = pack_pixel(blended)
        }
    }
}

unpack_pixel :: proc(pixel: u32x8) -> (color: [4]f32x8) {
    color.r = cast(f32x8) (0xff &          pixel      )
    color.g = cast(f32x8) (0xff & simd.shr(pixel,  8) )
    color.b = cast(f32x8) (0xff & simd.shr(pixel,  16))
    color.a = cast(f32x8) (0xff & simd.shr(pixel,  24))
    
    return color
}

pack_pixel :: proc (value: [4]f32x8) -> (result: u32x8) {
    color := vec_cast(u32x8, value)
    result = color.r | simd.shl_masked(color.g, 8) | simd.shl_masked(color.b, 16) | simd.shl_masked(color.a, 24)
    return result
}

////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////
////////////////////////////////////////////////

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
    @note(viktor):

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

    // @note(viktor): pick which LOD to sample from
    lod_index := round(i32, roughness * cast(f32) (len(environment_map.LOD)-1))
    lod := environment_map.LOD[lod_index]
    lod_size := vec_cast(f32, lod.width, lod.height)

    // @note(viktor): compute the distance to the map and the
    // scaling factor for meters-to-UVs
    uvs_per_meter: f32 = 0.1 // @todo(viktor): parameterize
    c := (uvs_per_meter * distance_from_map_in_z) / sample_direction.y
    offset := c * sample_direction.xz

    // @note(viktor): Find the intersection point
    uv := screen_space_uv + offset
    uv = clamp_01(uv)

    // @note(viktor): bilinear sample
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

    if GlobalDebugShowLightingSampling {
        // @note(viktor): Turn this on to see where in the map you're sampling!
        texel := &lod.memory[index.y * lod.width + index.x]
        texel ^= 255
    }

    return result
}

blend_bilinear :: proc(s00, s01, s10, s11: v4, t: v2) -> (result: v4) {
    result = linear_blend( linear_blend(s00, s01, t.x), linear_blend(s10, s11, t.x), t.y )

    return result
}

@(require_results)
unscale_and_bias :: proc(normal: v4) -> (result: v4) {
    inv_255: f32 = 1.0 / 255.0

    result.xyz = -1 + 2 * (normal.xyz * inv_255)
    result.w = inv_255 * normal.w

    return result
}

// @note(viktor): srgb_to_linear and linear_to_srgb assume a gamma of 2 instead of the usual 2.2
srgb_to_linear :: proc(srgb: v4) -> (result: v4) {
    result.rgb = square(srgb.rgb)
    result.a = srgb.a

    return result
}
srgb_255_to_linear_1 :: proc(srgb: v4) -> (result: v4) {
    inv_255: f32 = 1.0 / 255.0
    result = srgb * inv_255
    result = srgb_to_linear(result)

    return result
}

linear_to_srgb :: proc(linear: v4) -> (result: v4) {
    result.rgb = square_root(linear.rgb)
    result.a = linear.a

    return result
}
linear_1_to_srgb_255 :: proc(linear: v4) -> (result: v4) {
    result = linear_to_srgb(linear)
    result *= 255

    return result
}

draw_rectangle_slowly :: proc(buffer: Bitmap, origin, x_axis, y_axis: v2, texture, normal_map: Bitmap, color: v4, top, middle, bottom: EnvironmentMap, pixels_to_meters: f32) {
    timed_function()
    
    assert(texture.memory != nil)

    length_x_axis := length(x_axis)
    length_y_axis := length(y_axis)
    normal_x_axis := (length_y_axis / length_x_axis) * x_axis
    normal_y_axis := (length_x_axis / length_y_axis) * y_axis
    // @note(viktor): normal_z_scale could be a parameter if we want people
    // to have control over the amount of scaling in the z direction that
    // the normals appear to have
    normal_z_scale := linear_blend(length_x_axis, length_y_axis, 0.5)

    inv_x_len_squared := 1 / length_squared(x_axis)
    inv_y_len_squared := 1 / length_squared(y_axis)

    minimum := [2]i32{
        floor(i32, min(origin.x, (origin+x_axis).x, (origin + y_axis).x, (origin + x_axis + y_axis).x)),
        floor(i32, min(origin.y, (origin+x_axis).y, (origin + y_axis).y, (origin + x_axis + y_axis).y)),
    }

    maximum := [2]i32{
        ceil(i32, max(origin.x, (origin+x_axis).x, (origin + y_axis).x, (origin + x_axis + y_axis).x)),
        ceil(i32, max(origin.y, (origin+x_axis).y, (origin + y_axis).y, (origin + x_axis + y_axis).y)),
    }

    width_max      := buffer.width-1
    height_max     := buffer.height-1
    inv_width_max  := 1 / cast(f32) width_max
    inv_height_max := 1 / cast(f32) height_max

    // @todo(viktor): this will need to be specified separately
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

                // @todo(viktor): this epsilon should not exists
                EPSILON :: 0.000001
                assert(u + EPSILON >= 0 && u - EPSILON <= 1)
                assert(v + EPSILON >= 0 && v - EPSILON <= 1)

                // @todo(viktor): formalize texture boundaries
                t := v2{u,v} * vec_cast(f32, texture.width-2, texture.height-2)
                s := floor(i32, t)
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

                    // @note(viktor): the eye-vector is always assumed to be [0, 0, 1]
                    // This is just a simplified version of the reflection -e + 2 * dot(e, n) * n
                    bounce_direction := 2 * normal.z * normal.xyz
                    bounce_direction.z -= 2
                    // @todo(viktor): eventually we need to support two mappings
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

                    light_color := v3{} // @todo(viktor): how do we sample from the middle environment m?ap
                    if t_far_map > 0 {
                        distance_from_map_in_z := far_map.pz - pz
                        far_map_color := sample_environment_map(screen_space_uv, bounce_direction, normal.w, far_map, distance_from_map_in_z)
                        light_color = linear_blend(light_color, far_map_color, t_far_map)
                    }

                    texel.rgb += texel.a * light_color.rgb
                    if GlobalDebugShowLightingBounceDirection {
                        // @note(viktor): draws the bounce direction
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

                dst ^= vec_cast(u8, blended)
            }
        }
    }
}
