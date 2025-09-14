package game

DebugEventLink :: struct {
    // @volatile sentinel() abuses the fact that first_child and last_child could be viewed as prev and next
    next, prev:              ^DebugEventLink,
    first_child, last_child: ^DebugEventLink,
    
    name:     string,
    element:  ^DebugElement,
}

sentinel :: proc(from: ^DebugEventLink) -> (result: ^DebugEventLink) {
    result = cast(^DebugEventLink) &from.first_child
    return result
}
has_children :: proc(link: ^DebugEventLink) -> (result: b32) {
    result = sentinel(link) != link.first_child
    return result
}

DebugTree :: struct {
    prev, next: ^DebugTree,
    p:    v2,
    root: ^DebugEventLink,
}

DebugView :: struct {
    next: ^DebugView,
    id:   DebugId,
    kind: union {
        DebugViewBlock,
        DebugViewProfileGraph,
        DebugViewCollapsible,
        DebugViewArenaGraph,
    },
}

DebugId :: struct {
    value: [2]pmm,
}

DebugViewCollapsible :: struct {
    expanded:   b32,
}

DebugViewArenaGraph :: struct {
    block: DebugViewBlock,
    arena: ^Arena,
}

DebugViewProfileGraph :: struct {
    block: DebugViewBlock,
    root:  DebugGUID,
}

DebugViewBlock :: struct {
    size: v2,
}

////////////////////////////////////////////////

DebugInteraction :: struct {
    id:   DebugId,
    kind: DebugInteractionKind,
    
    // @todo(viktor): fix up the old usages and give this a proper type
    // Can we use only one tag for both target and value?
    target: pmm,
    
    value: union {
        ^DebugTree,
        ^DebugEventLink,
        ^v2,
        ^b32,
        
        i32,
        b32,
        DebugInteractionKind,
        DebugValue,
        DebugGUID,
    },
}

DebugInteractionKind :: enum {
    None, 
    
    NOP,
    AutoDetect,
    
    ToggleValue,
    DragValue,
    
    Tear,
    Move,
    Resize,
    
    Select,
    
    SetValue, SetValueContinously,
}

////////////////////////////////////////////////

Layout :: struct {
    debug:        ^DebugState,
    mouse_p:      v2,
    dt: f32,
    
    base_p: v2,
    p:      v2,
    
    next_line_dy: f32,
    
    depth:        f32,
    line_advance: f32,
    spacing:      v2,
    
    no_line_feed:     u32,
    line_initialized: b32,
}

LayoutElement :: struct {
    layout:  ^Layout,
    
    size:        ^v2,
    flags:       LayoutElementFlags,
    interaction: DebugInteraction,
    
    bounds: Rectangle2,
}

LayoutElementFlags :: bit_set[LayoutElementFlag]
LayoutElementFlag :: enum {
    HasInteraction,
    
    Resizable, 
    HasBorder,
}

////////////////////////////////////////////////

TextRenderOperation:: enum {
    Measure, Draw, 
}

////////////////////////////////////////////////

overlay_debug_info :: proc(debug: ^DebugState, input: Input) {
    timed_function()

    if debug.render_group.assets == nil do return

    orthographic(&debug.render_group, 1)
    
    debug.default_clip_rect = debug.render_group.current_clip_rect_index

    mouse_p := unproject_with_transform(debug.render_group.camera, default_flat_transform(), input.mouse.p).xy
    
    debug.mouse_text_layout = begin_layout(debug, mouse_p+{15,0}, mouse_p, input.delta_time)
    draw_trees(debug, mouse_p, input.delta_time)
    end_layout(&debug.mouse_text_layout)
    
    most_recent_frame := debug.frames[debug.most_recent_frame_ordinal]
    debug.root_group.name = format_string(debug.root_info, "%", view_seconds(most_recent_frame.seconds_elapsed, precision = 3))
    
    interact(debug, input, mouse_p)
}

draw_trees :: proc(debug: ^DebugState, mouse_p: v2, dt: f32) {
    timed_function()
    
    assert(debug.font_info != nil)
    
    for tree := debug.tree_sentinel.next; tree != &debug.tree_sentinel; tree = tree.next {
        layout := begin_layout(debug, tree.p, mouse_p, dt)
        defer end_layout(&layout)
        
        draw_tree(&layout, mouse_p, tree, tree.root)
    }
}

draw_tree :: proc(layout: ^Layout, mouse_p: v2, tree: ^DebugTree, link: ^DebugEventLink) {
    group := tree.root
    debug := layout.debug
    
    if !has_children(link) {
        draw_element(layout, id_from_link(tree, link), link.element)
    } else {
        timed_block("draw event group")
        
        id := id_from_link(tree, link)
        view := get_view_for_variable(debug, id)
        if _, ok := view.kind.(DebugViewCollapsible); !ok {
            view.kind = DebugViewCollapsible{}
        }
        collapsible := &view.kind.(DebugViewCollapsible)
        
        expanded := collapsible.expanded
        text := debug_print("% %", expanded ? "-" : "+", link.name)
        text_bounds := measure_text(debug, text)
                
        size := v2{ get_dimension(text_bounds).x, layout.line_advance }
        element := begin_ui_element_rectangle(layout, &size)
        
        interaction: DebugInteraction
        if !debug.alt_ui {
            interaction = set_value_interaction(id, &collapsible.expanded, !collapsible.expanded)
        } else {
            interaction = { id = id, kind = .Tear, target = link }
        }
        
        set_ui_element_default_interaction(&element, interaction)
        end_ui_element(&element, false)
        
        color := interaction_is_hot(debug, interaction) ? Isabelline : Jasmine
        push_text(debug, text, {element.bounds.min.x, element.bounds.max.y - debug.ascent * debug.font_scale}, color)
        
        if expanded {
            layout.depth += 1
            defer layout.depth -= 1
            
            for child := link.first_child; child != sentinel(link); child = child.next {
                draw_tree(layout, mouse_p, tree, child)
            }
        }
    }
    
    move_interaction := DebugInteraction{ id = id_from_link(tree, group), kind = .Move, value = &tree.p }
    
    move_handle := rectangle_min_dimension(tree.p, v2{8, 8})
    color := interaction_is_hot(debug, move_interaction) ? Isabelline : Jasmine
    push_rectangle(&debug.render_group, move_handle, debug.ui_transform, color)
    
    if contains(move_handle, mouse_p) {
        debug.next_hot_interaction = move_interaction
    }
}

draw_element :: proc(using layout: ^Layout, id: DebugId, element: ^DebugElement) {
    timed_function()
    
    view := get_view_for_variable(debug, id)
    
    if element == nil {
        basic_text_element(layout, "element was nil")
        return
    }
    oldest_stored_event := element.frames[debug.viewed_frame_ordinal].events.last
    
    
    switch type in element.type {
      case SoundId, FontId, 
        BeginTimedBlock, EndTimedBlock,
        BeginDataBlock, EndDataBlock,
        FrameMarker:
        // @note(viktor): nothing
        
      case BitmapId:
        event := oldest_stored_event != nil ? &oldest_stored_event.event : nil
        if event != nil {
            value := event.value.(BitmapId)
            if _, ok := &view.kind.(DebugViewBlock); !ok {
                view.kind = DebugViewBlock{}
                block := &view.kind.(DebugViewBlock)
                block.size = 100
            }
            block := &view.kind.(DebugViewBlock)
            
            bitmap: ^Bitmap
            if bitmap = get_bitmap(debug.render_group.assets, value, debug.render_group.generation_id); bitmap != nil {
                dim := get_used_bitmap_dim(&debug.render_group, bitmap^, default_flat_transform(), block.size.y, 0, use_alignment = false)
                block.size = dim.size
            }
            
            ui_element := begin_ui_element_rectangle(layout, &block.size)
            ui_element.flags += {.Resizable}
            end_ui_element(&ui_element, true)
            
            bitmap_height := block.size.y
            bitmap_offset := V3(ui_element.bounds.min, 0)
            push_rectangle(&debug.render_group, ui_element.bounds, debug.backing_transform, DarkBlue )
            
            if bitmap != nil {
                push_bitmap(&debug.render_group, value, debug.ui_transform, bitmap_height, bitmap_offset, use_alignment = false)
            }
        }
    
      case DebugEventLink, b32, f32, i32, i64, u32, v2, v3, v4, Rectangle2, Rectangle3:
        null_event := DebugEvent {
            guid = element.guid,
            value = element.type,
        }
        
        event := oldest_stored_event != nil ? &oldest_stored_event.event : &null_event
        value := event.value
        
        text: string
        if _, ok := &event.value.(DebugEventLink); ok {
            if _, okc := &view.kind.(DebugViewCollapsible); !okc {
                view.kind = DebugViewCollapsible{}
            }
            collapsible := &view.kind.(DebugViewCollapsible)
            text = debug_print("% %", collapsible.expanded ? "-" : "+", element.guid.name)
        } else {
            text = debug_print("% %", element.guid.name, value)
        }
        
        autodetect_interaction := DebugInteraction{ id = id, kind = .AutoDetect, target = element }
        basic_text_element(layout, text, autodetect_interaction)
        
      case FrameInfo:
        viewed_frame := &debug.frames[debug.viewed_frame_ordinal]
        text := debug_print("Viewed Frame: %, % events, % data_blocks, % profile_blocks",
            view_seconds(viewed_frame.seconds_elapsed,       precision = 0), 
            view_magnitude(viewed_frame.stored_event_count,  precision = 0), 
            view_magnitude(viewed_frame.data_block_count,    precision = 0), 
            view_magnitude(viewed_frame.profile_block_count, precision = 0), 
        )
        basic_text_element(layout, text)
        
      case ArenaOccupancy:
        event :^DebugEvent= oldest_stored_event != nil ? &oldest_stored_event.event : nil
        if event != nil {
            graph, ok := &view.kind.(DebugViewArenaGraph)
            if !ok {
                view.kind = DebugViewArenaGraph{}
                graph = &view.kind.(DebugViewArenaGraph)
                graph.block.size = v2{400, 16}
                
                value := event.value.(ArenaOccupancy)
                graph.arena = value.arena
            }
            
            _, is_occupancy    := element.type.(ArenaOccupancy)
            begin_ui_row(layout)
                boolean_button(layout, "Occupancy", is_occupancy, set_value_interaction(id, &element.type, cast(DebugValue) ArenaOccupancy{}))
                arena := graph.arena
                
                text := debug_print("%, % / %", element.guid.name, view_memory_size(arena.used), view_memory_size(len(arena.storage)))
                action_button(layout, text, {}, backdrop_color = {})
            end_ui_row(layout)
            
            
            ui_element := begin_ui_element_rectangle(layout, &graph.block.size)
            ui_element.flags += {.HasBorder, .Resizable}
            end_ui_element(&ui_element, false)
            
            rect := ui_element.bounds
            
            #partial switch value in element.type {
              case ArenaOccupancy:
                draw_arena_occupancy(debug, arena, mouse_p, rect)
              case: unreachable()
            }
        }
        
      case FrameSlider:
        graph, ok := &view.kind.(DebugViewProfileGraph)
        if !ok {
            view.kind = DebugViewProfileGraph{}
            graph = &view.kind.(DebugViewProfileGraph)
            graph.block.size = v2{1000, 32}
        }
        
        begin_ui_row(layout)
            boolean_button(layout, debug.paused ? "Unpause" : "Pause",       debug.paused, set_value_interaction(id, &debug.paused, !debug.paused))
            if debug.paused {
                boolean_button(layout, "< Back",      false,        set_value_interaction(id, &debug.viewed_frame_ordinal, (debug.viewed_frame_ordinal+MaxFrameCount-1)%MaxFrameCount))
                boolean_button(layout, "Most Recent", debug.viewed_frame_ordinal == debug.most_recent_frame_ordinal, set_value_interaction(id, &debug.viewed_frame_ordinal, debug.most_recent_frame_ordinal))
                boolean_button(layout, "Forward >",   false,        set_value_interaction(id, &debug.viewed_frame_ordinal, (debug.viewed_frame_ordinal+1)%MaxFrameCount))
            }
        end_ui_row(layout)
        
        ui_element := begin_ui_element_rectangle(layout,&graph.block.size)
        ui_element.flags += {.HasBorder, .Resizable}
        end_ui_element(&ui_element, false)
        draw_frame_slider(debug, mouse_p, ui_element.bounds, element)
        
        
      case ThreadProfileGraph, FrameBarsGraph, TopClocksList:
        graph, ok := &view.kind.(DebugViewProfileGraph)
        if !ok {
            view.kind = DebugViewProfileGraph{}
            graph = &view.kind.(DebugViewProfileGraph)
            graph.block.size = {1000, 100}
        }
        
        _, is_profile    := element.type.(ThreadProfileGraph)
        _, is_frame_bars := element.type.(FrameBarsGraph)
        _, is_top_clocks := element.type.(TopClocksList)

        viewed_element := get_element_from_guid(debug, graph.root)
        if viewed_element == nil {
            viewed_element = debug.profile_root
        }
        
        begin_ui_row(layout)
            boolean_button(layout, "Threads", is_profile,   set_value_interaction(id, &element.type, cast(DebugValue) ThreadProfileGraph{}))
            boolean_button(layout, "Frames", is_frame_bars, set_value_interaction(id, &element.type, cast(DebugValue) FrameBarsGraph{}))
            boolean_button(layout, "Clocks", is_top_clocks, set_value_interaction(id, &element.type, cast(DebugValue) TopClocksList{}))
            action_button(layout,  "Root", set_value_interaction(id, &graph.root, DebugGUID{} ))
            text := debug_print("Viewing: %", viewed_element.guid.name)
            action_button(layout, text, {}, backdrop_color = {})
        end_ui_row(layout)
        
        ui_element := begin_ui_element_rectangle(layout, &graph.block.size)
        ui_element.flags += {.Resizable}
        end_ui_element(&ui_element, true)
                
        rect := ui_element.bounds
        push_rectangle(&debug.render_group, rect, debug.backing_transform, {0,0,0,0.7})
        
        old_clip_rect := debug.render_group.current_clip_rect_index
        debug.render_group.current_clip_rect_index = push_clip_rect(&debug.render_group, rect, debug.render_target_index, debug.backing_transform)
        defer debug.render_group.current_clip_rect_index = old_clip_rect
        
        if contains(rect, mouse_p) {
            debug.next_hot_interaction = set_value_interaction(DebugId{ value = {&graph.root, viewed_element} }, &graph.root, viewed_element.guid)
        }
        
        #partial switch value in element.type {
          case ThreadProfileGraph:
            draw_profile(debug, &graph.root, mouse_p, dt, rect, viewed_element)
          case FrameBarsGraph:
            draw_frame_bars(debug, &graph.root, mouse_p, dt, rect, viewed_element)
          case TopClocksList:
            draw_top_clocks(debug, &graph.root, mouse_p, rect, viewed_element)
          case: unreachable()
        }
    }
}

draw_arena_occupancy :: proc(debug: ^DebugState, arena: ^Arena, mouse_p: v2, rect: Rectangle2) {
    push_rectangle(&debug.render_group, rect, debug.backing_transform, DarkGreen)
    
    scale := cast(f32) (cast(f64) arena.used / cast(f64) len(arena.storage))
    
    split_point := linear_blend(rect.min.x, rect.max.x, scale)
    filled := rectangle_min_max(rect.min, v2{split_point, rect.max.y})
    unused := rectangle_min_max(v2{split_point, rect.min.y}, rect.max)
    push_rectangle(&debug.render_group, unused, debug.backing_transform, {0,0,0,0.7})
    push_rectangle(&debug.render_group, filled, debug.ui_transform, Green)
}

add_tooltip :: proc(debug: ^DebugState, text: string) {
    // @todo(viktor): we could return this buffer and let the caller fill it, to not need to copy it
    assert(len(text) < len(debug.tooltips.data[0]))
    
    slot: ^[256]u8
    if debug.tooltips.count == auto_cast len(debug.tooltips.data) {
        slot = &debug.tooltips.data[debug.tooltips.count-1]
    } else {
        slot = append(&debug.tooltips)
    }
    copy_slice(slot[:len(text)], transmute([] u8) text)
}

draw_tooltips :: proc(debug: ^DebugState) {
    for &tooltip in slice(&debug.tooltips) {
        text: string = cast(string) transmute(cstring) &tooltip
        color := Isabelline
        
        layout := &debug.mouse_text_layout
        text_bounds := measure_text(debug, text)
        size := v2{ get_dimension(text_bounds).x, layout.line_advance }
        
        element := begin_ui_element_rectangle(layout, &size)
        end_ui_element(&element, false)
        
        render_group := &debug.render_group
        old_clip_rect := render_group.current_clip_rect_index
        render_group.current_clip_rect_index = debug.default_clip_rect
        defer render_group.current_clip_rect_index = old_clip_rect
        
        p := v2{element.bounds.min.x, element.bounds.max.y - debug.ascent * debug.font_scale}
        text_bounds = add_offset(text_bounds, p)
        text_bounds = add_radius(text_bounds, 4)
        
        before := debug.text_transform
        defer debug.text_transform = before
        
        debug.text_transform.chunk_z += 1000
        push_rectangle(&debug.render_group, text_bounds, debug.text_transform, {0,0,0,0.95})
        debug.text_transform.chunk_z += 1000
        push_text(debug, text, p, color)
    }
    
    clear(&debug.tooltips)
}

get_total_clocks :: proc(frame: ^DebugElementFrame) -> (result: i64) {
    for event := frame.events.last; event != nil; event = event.next {
        result += event.node.duration
    }
    return result
}

draw_frame_slider :: proc(debug: ^DebugState, mouse_p: v2, rect: Rectangle2, root_element: ^DebugElement) {
    push_rectangle(&debug.render_group, rect, debug.backing_transform, {0,0,0,0.7})
    
    dim := get_dimension(rect)
    bar_width := dim.x / cast(f32) (MaxFrameCount)
    
    at_x := rect.min.x
    for &frame, frame_ordinal in root_element.frames {
        frame_ordinal := cast(i32) frame_ordinal
        region_rect := rectangle_min_max(
            v2{at_x, rect.min.y},
            v2{at_x + bar_width, rect.max.y},
        )
        
        color: v4
        text: string
        
        switch frame_ordinal {
          case debug.most_recent_frame_ordinal:
            color = Emerald
            text = "Most recent Frame"
          case debug.oldest_frame_ordinal_that_is_already_freed:
            color = Red
            text = "Oldest Frame"
          case debug.viewed_frame_ordinal: 
            color = Green
          case: 
            frame_delta := debug.most_recent_frame_ordinal - frame_ordinal
            if frame_delta < 0 {
                frame_delta += MaxFrameCount
            }
            text = debug_print("% frames ago", frame_delta)
        }
        
        if contains(region_rect, mouse_p) {
            if color == 0 do color = V4(Green.rgb, 0.7)
            
            id := DebugId{ value = {root_element, &frame} }
            debug.next_hot_interaction = set_value_continously_interaction(id, &debug.viewed_frame_ordinal, frame_ordinal)
            add_tooltip(debug, text)
        }
        
        if color.a != 0 {
            push_rectangle(&debug.render_group, region_rect, debug.backing_transform, color)
            push_rectangle_outline(&debug.render_group, region_rect, debug.ui_transform, color * {.2, .2, .2, 1}, {1, 0})
        }
        at_x += bar_width
    }
}

draw_top_clocks :: proc(debug: ^DebugState, graph_root: ^DebugGUID, mouse_p: v2, rect: Rectangle2, root_element: ^DebugElement) {
    link_count: u32
    group := debug.profile_group
    for link := group.first_child; link != sentinel(group); link = link.next {
        link_count += 1
    }
    
    temp := begin_temporary_memory(&debug.arena)
    defer end_temporary_memory(temp)
    
    sort_entries := push_slice(temp.arena, SortEntry, link_count, no_clear())
    temp_space   := push_slice(temp.arena, SortEntry, link_count, no_clear())
    entries      := push_slice(temp.arena, ClockEntry, link_count, no_clear())
    
    total_time: f32
    entry_index: u32
    for link := group.first_child; link != sentinel(group); link = link.next {
        element := link.element
        assert(element != nil)
        assert(!has_children(link))
        
        entry := &entries[entry_index]
        defer entry_index += 1
        
        entry.element = element
        begin_debug_statistic(&entry.stats)
        
        frame := &element.frames[debug.viewed_frame_ordinal]
        for event := frame.events.last; event != nil; event = event.next {
            // duration_with_children := cast(f32) event.node.duration
            duration_without_children := cast(f32) (event.node.duration - event.node.duration_of_children)
            accumulate_debug_statistic(&entry.stats, duration_without_children)
        }
     
        end_debug_statistic(&entry.stats)
        
        sort_entries[entry_index] = {
            sort_key = -entry.stats.sum,
            index = entry_index,
        }
        total_time += entry.stats.sum
    }
    
    merge_sort(sort_entries, temp_space, compare_sort_entries)
    
    total_time_percentage := 1 / total_time * 100
    running_sum: f32
    p := v2{rect.min.x, rect.max.y} - v2{0, debug_get_baseline(debug)}
    for sort_entry in sort_entries {
        entry := entries[sort_entry.index]
        running_sum += entry.stats.sum
        
        text := debug_print("total %cy - % %% / % %% - %",
            view_magnitude(cast(u64) entry.stats.sum),
            view_float(entry.stats.sum * total_time_percentage, width = 2, precision = 2),
            view_float(running_sum * total_time_percentage, width = 2, precision = 2),
            entry.element.guid.name,
        )
        color_wheel := color_wheel
        color := color_wheel[sort_entry.index % len(color_wheel)]
        push_text(debug, text, p, color)
        
        region_rect := measure_text(debug, text)
        region_rect = add_offset(region_rect, p)
        if contains(region_rect, mouse_p) {
            tooltip := debug_print("average %cy - %hits",
                view_magnitude_decimal(entry.stats.avg),
                view_magnitude(cast(u64) entry.stats.count), 
            )
            add_tooltip(debug, tooltip)
        }
                
        if p.y < rect.min.y {
            break
        } else {
            p.y -= debug_get_line_advance(debug)
        }
    }
}

longest_frame_span: f32
d_longest_frame_span: f32
draw_frame_bars :: proc(debug: ^DebugState, graph_root: ^DebugGUID, mouse_p: v2, dt: f32, rect: Rectangle2, root_element: ^DebugElement) {
    // @todo(viktor): zooming and panning
    
    dim := get_dimension(rect)
    bar_width := dim.x / cast(f32) (MaxFrameCount-1)
    
    at_x := rect.min.x
    target_longest_frame_span: f32
    for &frame in root_element.frames {
        if frame.events.first == nil do continue
        
        root_node := &frame.events.first.node
        frame_span := cast(f32) root_node.duration
        target_longest_frame_span = max(target_longest_frame_span, frame_span)
    }
    
    delta_p := target_longest_frame_span - longest_frame_span
    dd_longest_frame_span := (delta_p > 0 ? 600 : 100) * (delta_p) + (delta_p > 0 ? 34 : 17) * (0 - d_longest_frame_span)
    dd_longest_frame_span += -3 * d_longest_frame_span
    d_longest_frame_span += dd_longest_frame_span * dt
    longest_frame_span += d_longest_frame_span * dt + 0.5 * dd_longest_frame_span * dt * dt
    
    transform := debug.ui_transform
    
    pixel_span := dim.y
    scale := safe_ratio_0(pixel_span, longest_frame_span)
    for &frame, frame_ordinal in root_element.frames {
        if frame.events.first == nil do continue
        
        root_node := &frame.events.first.node
        for event := root_node.first_child; event != nil; event = event.node.next_same_parent {
            node := &event.node
            
            element := node.element
            if element == nil do continue
            
            y_min := rect.min.y + scale * cast(f32) node.parent_relative_clock
            y_max := y_min      + scale * cast(f32) node.duration
            
            region_rect := rectangle_min_max(
                v2{at_x, y_min},
                v2{at_x + bar_width, y_max},
            )
            
            color_wheel := color_wheel
            color_index := cast(umm) element % len(color_wheel)
            color := color_wheel[color_index]
            
            if bar_width >= 1 && y_max - y_min >= 1 {
                border_color := color * {.2,.2,.2, 1}
                if auto_cast frame_ordinal == debug.viewed_frame_ordinal {
                    border_color = 1
                    transform.chunk_z += 10
                }
                push_rectangle(&debug.render_group, region_rect, transform, color)
                
                transform.chunk_z += 10
                push_rectangle_outline(&debug.render_group, region_rect, transform, border_color, 1)
            }
            
            if contains(region_rect, mouse_p) {
                text := debug_print("% - % cycles", element.guid.name, view_magnitude(node.duration))
                add_tooltip(debug, text)
                
                // @copypasta with draw_profile
                if node.first_child != nil {
                    id := DebugId { value = { graph_root, &element } }
                    debug.next_hot_interaction = set_value_interaction(id, graph_root, element.guid)
                }
            }
        }
        
        at_x += bar_width
    }
}

d_total_clocks, total_clocks: f32
draw_profile :: proc (debug: ^DebugState, graph_root: ^DebugGUID, mouse_p: v2, dt: f32, rect: Rectangle2, root_element: ^DebugElement) {
    lane_count := cast(f32) debug.max_thread_count
    lane_height := safe_ratio_n(get_dimension(rect).y, lane_count, get_dimension(rect).y)
    
    frame := &root_element.frames[debug.viewed_frame_ordinal]
    
    target_total_clocks := cast(f32) get_total_clocks(frame)
    
    delta_p := target_total_clocks - total_clocks
    dd_total_clocks := (delta_p > 0 ? 8000 : 2000) * (delta_p) + 100 * (0 - d_total_clocks)
    dd_total_clocks += -3 * d_total_clocks
    d_total_clocks += dd_total_clocks * dt
    total_clocks += d_total_clocks * dt + 0.5 * dd_total_clocks * dt * dt
    
    next_x := rect.min.x
    relative_clock: i64
    for event := frame.events.last; event != nil; event = event.next {
        relative_clock += event.node.duration
        t := cast(f32) (cast(f64) relative_clock / cast(f64) total_clocks)
        
        event_rect := rect
        event_rect.min.x = next_x
        event_rect.max.x = linear_blend(rect.min.x, rect.max.x, t)
        next_x = event_rect.max.x
        
        draw_profile_lane(debug, graph_root, mouse_p, event_rect, event, lane_height, lane_height)
    }
}

draw_profile_lane :: proc (debug: ^DebugState, graph_root: ^DebugGUID, mouse_p: v2, rect: Rectangle2, root_event: ^DebugStoredEvent, lane_stride, lane_height: f32) {
    root := root_event.node
    
    frame_span := cast(f32) (root.duration)
    dimension := get_dimension(rect)
    pixel_span := dimension.x
    
    frame_scale := safe_ratio_0(pixel_span, frame_span)

    for event := root.first_child; event != nil; event = event.node.next_same_parent {
        node := &event.node
        
        element := node.element
        if element == nil do continue
        
        x_min := rect.min.x + frame_scale * cast(f32) node.parent_relative_clock
        x_max := x_min      + frame_scale * cast(f32) node.duration
        
        lane_index := cast(f32) node.thread_index
        lane_y := rect.max.y - lane_stride*lane_index
        region_rect := rectangle_min_max(
            v2{x_min, lane_y - lane_height},
            v2{x_max, lane_y},
        )
     
        color_wheel := color_wheel
        color_index := cast(umm) element % len(color_wheel)
        color := color_wheel[color_index]
        
        if x_max - x_min >= 1 {
            transform := debug.ui_transform
            transform.chunk_z += cast(i32) (1000/lane_height)
            push_rectangle(&debug.render_group, region_rect, transform, color)
            
            transform.chunk_z += 10
            push_rectangle_outline(&debug.render_group, region_rect, transform, color * {.2,.2,.2, 1}, 1)
        }
        
        if contains(region_rect, mouse_p) {
            text := debug_print("% - % cycles", element.guid.name, view_magnitude(node.duration))
            add_tooltip(debug, text)
            
            if node.first_child != nil {
                id := DebugId { value = { graph_root, &element } }
                debug.next_hot_interaction = set_value_interaction(id, graph_root, element.guid)
            }
        }
        
        if node.first_child != nil {
            draw_profile_lane(debug, graph_root, mouse_p, region_rect, event, lane_height, lane_height/1.618033988749)
        }
    }
}

///////////////////////////////////////////////

begin_layout :: proc(debug: ^DebugState, p: v2, mouse_p: v2, dt: f32) -> (result: Layout) {
    result = {
        debug   = debug,
        mouse_p = mouse_p,
        dt      = dt,
        
        p      = p,
        base_p = p,
        
        line_advance = debug_get_line_advance(debug),
        spacing      = {12, 4},
    }
    return result
}

end_layout :: proc(layout: ^Layout) {
    
}

begin_ui_element_rectangle :: proc(layout: ^Layout, size: ^v2) -> (result: LayoutElement) {
    result.layout  = layout
    result.size    = size
    
    return result
}

set_ui_element_default_interaction :: proc(element: ^LayoutElement, interaction: DebugInteraction) {
    element.flags += {.HasInteraction}
    element.interaction = interaction
}

end_ui_element :: proc(using element: ^LayoutElement, use_generic_spacing: b32) {
    if !layout.line_initialized {
        layout.line_initialized = true
        layout.p.x = layout.base_p.x + layout.depth * 2 * layout.line_advance
        layout.next_line_dy = 0
    }
    
    border: v2
    SizeHandlePixels :: 4
    if .Resizable in element.flags || .HasBorder in element.flags {
        border = SizeHandlePixels / 2
    }
    total_size := element.size^ + border * 2
    
    total_min    := layout.p + {0, -total_size.y}
    interior_min := total_min + border
    
    total_bounds  := rectangle_min_dimension(total_min, total_size)
    element.bounds = rectangle_min_dimension(interior_min, element.size^)

    was_resized: b32
    if border != 0 {
        debug := element.layout.debug
        push_rectangle(&layout.debug.render_group, rectangle_min_dimension(total_min,                                     v2{total_size.x, border.y}),              debug.shadow_transform, DarkGreen)
        push_rectangle(&layout.debug.render_group, rectangle_min_dimension(total_min + {0, border.y},                     v2{border.x, total_size.y - border.y*2}), debug.shadow_transform, DarkGreen)
        push_rectangle(&layout.debug.render_group, rectangle_min_dimension(total_min + {total_size.x-border.x, border.y}, v2{border.x, total_size.y - border.y*2}), debug.shadow_transform, DarkGreen)
        push_rectangle(&layout.debug.render_group, rectangle_min_dimension(total_min + {0, total_size.y - border.y},      v2{total_size.x, border.y}),              debug.shadow_transform, DarkGreen)
        
        if .Resizable in element.flags {
            resize_box := rectangle_min_dimension(v2{element.bounds.max.x, total_min.y}, border * 3)
            push_rectangle(&layout.debug.render_group, resize_box, debug.text_transform, Isabelline)
            
            resize_interaction := DebugInteraction {
                kind   = .Resize,
                value = element.size,
            }
            if contains(resize_box, layout.mouse_p) {
                was_resized = true
                layout.debug.next_hot_interaction = resize_interaction
            }
        }
    }
    
    if !was_resized && .HasInteraction in element.flags && contains(element.bounds, layout.mouse_p) {
        layout.debug.next_hot_interaction = element.interaction
    }
    
    advance_element(layout, total_bounds)
}

advance_element :: proc(layout: ^Layout, element_rect: Rectangle2) {
    layout.next_line_dy = min(layout.next_line_dy, element_rect.min.y - layout.p.y)
    
    if layout.no_line_feed == 0 {
        layout.p.y += layout.next_line_dy - layout.spacing.y
        layout.line_initialized = false
    } else {
        layout.p.x += get_dimension(element_rect).x + layout.spacing.x
    }
}

begin_ui_row :: proc(layout: ^Layout) {
    layout.no_line_feed += 1
}

action_button :: proc(layout: ^Layout, label: string, interaction: DebugInteraction, backdrop_color :v4= DarkGreen) {
    basic_text_element(layout, label, interaction, padding = 5, backdrop_color = backdrop_color)
}

boolean_button :: proc(layout: ^Layout, label: string, highlighted: $bool,  interaction: DebugInteraction) {
    basic_text_element(layout, label, interaction, highlighted ? Green : Jasmine, padding = 5, backdrop_color = DarkGreen)
}

end_ui_row :: proc(layout: ^Layout) {
    assert(layout.no_line_feed > 0)
    layout.no_line_feed -= 1
    
    advance_element(layout, rectangle_min_max(layout.p, layout.p))
}

basic_text_element :: proc(layout: ^Layout, text: string, interaction: DebugInteraction = {}, item_color := Jasmine, hot_color := Isabelline, padding :v2 = 0, backdrop_color :v4= 0) {
    color := interaction_is_hot(layout.debug, interaction) ? hot_color : item_color
    
    debug := layout.debug
    text_bounds := measure_text(debug, text)
    size := v2{ get_dimension(text_bounds).x, layout.line_advance }
    size += 2*padding
    
    element := begin_ui_element_rectangle(layout, &size)
    set_ui_element_default_interaction(&element, interaction)
    end_ui_element(&element, false)
    
    p := v2{element.bounds.min.x + padding.x, element.bounds.max.y - padding.y - debug.ascent * debug.font_scale}
    if backdrop_color.a > 0 {
        push_rectangle(&debug.render_group, element.bounds, debug.backing_transform, backdrop_color)
    }
    push_text(debug, text, p, color)
}

////////////////////////////////////////////////

set_value_interaction :: proc(id: DebugId, target: ^$T, value: T) -> (result: DebugInteraction) {
    result.id = id
    result.kind = .SetValue
    result.target = target
    result.value = value
    
    return result
}

set_value_continously_interaction :: proc(id: DebugId, target: ^$T, value: T) -> (result: DebugInteraction) {
    result.id = id
    result.kind = .SetValueContinously
    result.target = target
    result.value = value
    
    return result
}

interaction_is_hot :: proc(debug: ^DebugState, interaction: DebugInteraction) -> (result: b32) {
    if interaction.kind != .None {
        result = debug.hot_interaction.id == interaction.id
    }
    return result
}

interact :: proc(debug: ^DebugState, input: Input, mouse_p: v2) {
    timed_function()
    
    mouse_dp := mouse_p - debug.last_mouse_p
    defer debug.last_mouse_p = mouse_p
    
    frame_ordinal := debug.most_recent_frame_ordinal
    
    interaction := &debug.interaction
    if interaction.kind != .None {
        // @note(viktor): Continous Interactions
        // Mouse move interaction
        
        switch interaction.kind {
          case .None: 
            unreachable()
            
          case .NOP, .AutoDetect, .ToggleValue, .SetValue:
            // nothing
         
          case .Select:
            if !input.shift_down {
                clear_selection(debug)
            }
            select(debug, interaction.id)
            
          case .SetValueContinously: // @copypasta from end_interaction
            target := interaction.target
            assert(target != nil)
            switch value in interaction.value {
              case DebugValue: 
                target := cast(^DebugValue) target 
                target ^= value
              case i32: 
                target := cast(^i32) target 
                target ^= value
              case b32: 
                target := cast(^b32) target 
                target ^= value
              case DebugInteractionKind: 
                target := cast(^DebugInteractionKind) target 
                target ^= value
            
              case DebugGUID: 
                target := cast(^DebugGUID) target 
                target ^= value    
              case ^b32: 
                target := cast(^^b32) target 
                target ^= value
              case ^v2: 
                target := cast(^^v2) target 
                target ^= value
              case ^DebugEventLink: 
                target := cast(^^DebugEventLink) target 
                target ^= value
              case ^DebugTree: 
                target := cast(^^DebugTree) target 
                target ^= value
            }
            
          case .DragValue:
            element := cast(^DebugElement) interaction.target
            event: ^DebugEvent
            if element != nil {
                event = &element.frames[frame_ordinal].events.first.event
            }
            
            value := &event.value.(f32)
            value^ += 0.1 * mouse_dp.x
            GlobalDebugTable.edit_event = event^
            
          case .Resize: // @todo(viktor): Better clamping
            element := cast(^DebugElement) interaction.target
            event: ^DebugEvent
            if element != nil {
                event = &element.frames[frame_ordinal].events.first.event
            }
            
            value := interaction.value.(^v2)
            value^ += mouse_dp * {1,-1}
            value.x = max(value.x, 10)
            value.y = max(value.y, 10)
            if event != nil do GlobalDebugTable.edit_event = event^
            
          case .Tear:
            value := interaction.value.(^v2)
            value^ += mouse_dp
            
          case .Move:
            value := interaction.value.(^v2)
            value^ += mouse_dp
            
            event := cast(^DebugEvent) interaction.target
            if event != nil do GlobalDebugTable.edit_event = event^
        }
        
        // Click interaction
        for transition_index := input.mouse.left.half_transition_count; transition_index > 1; transition_index -= 1 {
            end_click_interaction(debug, input)
            begin_click_interaction(debug, input)
        }
        
        if !input.mouse.left.ended_down {
            end_click_interaction(debug, input)
        }
    } else {
        debug.hot_interaction = debug.next_hot_interaction
        
        for transition_index := input.mouse.left.half_transition_count; transition_index > 1; transition_index -= 1 {
            begin_click_interaction(debug, input)
            end_click_interaction(debug, input)
        }
        
        if input.mouse.left.ended_down {
            begin_click_interaction(debug, input)
        }
    }
}

begin_click_interaction :: proc(debug: ^DebugState, input: Input) {
    frame_ordinal := debug.most_recent_frame_ordinal
    
    if debug.hot_interaction.kind != .None {
        // Detect Auto Interaction
        if debug.hot_interaction.kind == .AutoDetect {
            target := cast(^DebugElement) debug.hot_interaction.target
            first_stored_event := target.frames[frame_ordinal].events.first
            if first_stored_event != nil {
                event := &first_stored_event.event
            
                switch value in event.value {
                  case FrameMarker, 
                       BeginTimedBlock, EndTimedBlock,
                       BeginDataBlock, EndDataBlock,
                       ThreadProfileGraph, FrameBarsGraph, TopClocksList,
                       FrameSlider, FrameInfo,
                       ArenaOccupancy,
                       BitmapId, SoundId, FontId, Rectangle2, Rectangle3, u32, i32, i64, v2, v3, v4:
                    debug.hot_interaction.kind = .NOP
                  case b32:
                    debug.hot_interaction.kind = .ToggleValue
                  case f32:
                    debug.hot_interaction.kind = .DragValue
                  case DebugEventLink:
                    debug.hot_interaction.kind = .ToggleValue
                }
            }
        }
        
        if debug.hot_interaction.kind == .Tear {
            target := cast(^DebugEventLink) debug.hot_interaction.target
            group := clone_group(debug, target)
            
            tree := add_tree(debug, group, {0,0})
            debug.hot_interaction.value = &tree.p
        }
        
        debug.interaction = debug.hot_interaction
    } else {
        debug.interaction.kind = .NOP
    }
}

end_click_interaction :: proc(debug: ^DebugState, input: Input) {
    interaction := &debug.interaction
    defer interaction ^= {}
    
    frame_ordinal := debug.most_recent_frame_ordinal
    
    // @note(viktor): Discrete Interactions
    switch interaction.kind {
      case .None: 
        unreachable()
      
      case .NOP, .Move, .Resize, .Select, .AutoDetect, .Tear, .DragValue, .SetValueContinously:
        // @note(viktor): nothing
      
      case .SetValue:
        target := interaction.target
        assert(target != nil)
        switch value in interaction.value {
          case DebugValue: 
            target := cast(^DebugValue) target 
            target ^= value
          case i32: 
            target := cast(^i32) target 
            target ^= value
          case b32: 
            target := cast(^b32) target 
            target ^= value
          case DebugInteractionKind: 
            target := cast(^DebugInteractionKind) target 
            target ^= value
        
          case DebugGUID: 
            target := cast(^DebugGUID) target 
            target ^= value    
          case ^b32: 
            target := cast(^^b32) target 
            target ^= value
          case ^v2: 
            target := cast(^^v2) target 
            target ^= value
          case ^DebugEventLink: 
            target := cast(^^DebugEventLink) target 
            target ^= value
          case ^DebugTree: 
            target := cast(^^DebugTree) target 
            target ^= value
        }
        
      case .ToggleValue:
        element := cast(^DebugElement) interaction.target
        event := &element.frames[frame_ordinal].events.first.event
        
        #partial switch &value in event.value {
          case b32:
            value = !value
            GlobalDebugTable.edit_event = event^
        }
    }
}

////////////////////////////////////////////////

add_tree :: proc(debug: ^DebugState, root: ^DebugEventLink, p: v2) -> (result: ^DebugTree) {
    result = push(&debug.arena, DebugTree, no_clear())
    result ^= {
        root = root,
        p = p,
    }
    
    list_prepend(&debug.tree_sentinel, result)
    
    return result
}

get_group_by_hierarchical_name :: proc(debug: ^DebugState, parent: ^DebugEventLink, name: string, create_terminal: b32) -> (result: ^DebugEventLink) {
    assert(parent != nil)
    result = parent

    if create_terminal {
        result = get_or_create_group_with_name(debug, parent, name)
    }
    
    assert(result != nil)
    return result
}

get_or_create_group_with_name :: proc(debug: ^DebugState, parent: ^DebugEventLink, name: string) -> (result: ^DebugEventLink) {
    if has_children(parent) {
        for link := parent.first_child; link != sentinel(parent); link = link.next {
            if link != nil && link.name == name {
                result = link
            }
        }
    }
    
    if result == nil {
        result = create_link(debug, name)
        list_prepend(sentinel(parent), result)
    }
    
    return result
}

create_link :: proc(debug: ^DebugState, name: string) -> (result: ^DebugEventLink) {
    result = push(&debug.arena, DebugEventLink)
    result.name = copy_string(&debug.arena, name)
    
    result.last_child  = sentinel(result)
    result.first_child = sentinel(result)
    
    return result
}

add_element_to_group :: proc(debug: ^DebugState, parent: ^DebugEventLink, element: ^DebugElement) -> (result: ^DebugEventLink) {
    result = create_link(debug, "")
    
    if parent != nil {
        list_prepend(sentinel(parent), result)
    }
    result.element = element
    
    return result
}

clone_group :: proc (debug: ^DebugState, source: ^DebugEventLink) -> (result: ^DebugEventLink) {
    result = clone_event_link(debug, nil, source)
    return result
}

clone_event_link :: proc (debug: ^DebugState, parent: ^DebugEventLink, source: ^DebugEventLink) -> (result: ^DebugEventLink) {
    result = add_element_to_group(debug, parent, source.element)
    result.name = source.name
    
    for child := source.first_child; child != sentinel(source); child = child.next {
        clone_event_link(debug, result, child)
    }
    
    return result
}

id_from_link :: proc(tree: ^DebugTree, link: ^DebugEventLink) -> (result: DebugId) {
    result.value[0] = tree
    result.value[1] = link
    return result
}

get_view_for_variable :: proc(debug: ^DebugState, id: DebugId) -> (result: ^DebugView) {
    timed_function()
    // @todo(viktor): BETTER HASH FUNCTION
    hash_index := ((cast(umm) id.value[0] >> 2) + (cast(umm) id.value[1] >> 2)) % len(debug.view_hash)
    slot := &debug.view_hash[hash_index]

    for search := slot^; search != nil; search = search.next {
        if search.id == id {
            result = search
            break
        }
    }
    
    if result == nil {
        result = push(&debug.arena, DebugView)
        result.id = id
        list_push(slot, result)
    }
    
    return 
}

////////////////////////////////////////////////

debug_get_baseline :: proc(debug: ^DebugState) -> (result: f32) {
    result = get_baseline(debug.font_info) * debug.font_scale
    return result
}

debug_get_line_advance :: proc(debug: ^DebugState) -> (result: f32) {
    result = get_line_advance(debug.font_info) * debug.font_scale
    return result
}

push_text :: proc(debug: ^DebugState, text: string, p: v2, color: v4 = Jasmine, pz:f32=0) {
    if debug.font != nil && debug.font_info != nil {
        text_op(debug, .Draw, &debug.render_group, debug.font, debug.font_info, text, p, debug.font_scale, color, pz)
    }
}

measure_text :: proc(debug: ^DebugState, text: string) -> (result: Rectangle2) {
    if debug.font != nil && debug.font_info != nil {
        result = text_op(debug, .Measure, &debug.render_group, debug.font, debug.font_info, text, {0, 0}, debug.font_scale)
    }
    
    return result
}

text_op :: proc(debug: ^DebugState, operation: TextRenderOperation, group: ^RenderGroup, font: ^Font, font_info: ^FontInfo, text: string, p: v2, font_scale: f32, color: v4 = Jasmine, pz:f32= 0) -> (result: Rectangle2) {
    result = rectangle_inverted_infinity(Rectangle2)
    // @todo(viktor): @robustness kerning and unicode test lines
    // AVA: WA ty fi ij `^?'\"
    // 贺佳樱我爱你
    // 0123456789°
    p := p
    previous_codepoint: rune
    for codepoint in text {
        defer previous_codepoint = codepoint
        
        advance_x := get_horizontal_advance_for_pair(font, font_info, previous_codepoint, codepoint)
        p.x += advance_x * font_scale
        
        bitmap_id := get_bitmap_for_glyph(font, font_info, codepoint)
        info := get_bitmap_info(group.assets, bitmap_id)
        
        if info == nil {
            info = info
            break
        }
        height := cast(f32) info.dimension.y * font_scale
        switch operation {
          case .Draw: 
            if codepoint != ' ' {
                push_bitmap(group, bitmap_id, debug.shadow_transform, height, V3(p, pz) + {2,-2,0}, Black)
                push_bitmap(group, bitmap_id, debug.text_transform,   height, V3(p, pz), color)
            }
          case .Measure:
            bitmap := get_bitmap(group.assets, bitmap_id, group.generation_id)
            if bitmap != nil {
                dim := get_used_bitmap_dim(group, bitmap^, default_flat_transform(), height, V3(p, pz))
                glyph_rect := rectangle_min_dimension(dim.p.xy, dim.size)
                result = get_union(result, glyph_rect)
            }
        }
    }
    
    return result
}

////////////////////////////////////////////////

@(printlike)
debug_print :: proc (format: string, args: ..any) -> (result: string) {
    result = format_string(DebugPrintBuffer[:], format, ..args)
    return result
}