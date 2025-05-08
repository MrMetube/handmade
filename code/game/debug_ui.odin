package game

import "core:fmt"

DebugEventGroup :: struct {
    name:     string,
    sentinel: DebugEventLink,
}

DebugEventLink :: #type LinkedList(DebugEventLinkData)
DebugEventLinkData :: struct {
    value: union {
        ^DebugEventGroup,
        ^DebugElement,
    },
}

DebugTree :: #type LinkedList(DebugTreeData)
DebugTreeData :: struct {
    p:    v2,
    root: ^DebugEventGroup,
}

DebugView :: #type SingleLinkedList(DebugViewData)
DebugViewData :: struct {
    id:   DebugId,
    kind: union {
        DebugViewVariable,
        DebugViewBlock,
        DebugViewProfileGraph,
        DebugViewCollapsible,
    },
}

DebugViewVariable :: struct {}

DebugViewCollapsible :: struct {
    expanded_always:   b32,
    expanded_alt_view: b32,
}

DebugViewProfileGraph :: struct {
    block: DebugViewBlock,
    root:  DebugGUID,
}
DebugViewBlock :: struct {
    size: v2,
}

DebugEventInterator :: struct {
    link:     ^DebugEventLink,
    sentinel: ^DebugEventLink,
}

////////////////////////////////////////////////

DebugInteraction :: struct {
    id:   DebugId,
    kind: DebugInteractionKind,
    target: union {
        ^DebugElement, 
        ^DebugTree,
        ^DebugEventLink,
        ^v2,
    },
}

DebugInteractionKind :: enum {
    None, 
    
    NOP,
    AutoDetect,
    
    ToggleValue,
    DragValue,
    
    Move,
    Resize,
    ToggleExpansion,
    
    SetProfileGraphRoot,
    Select,
}

////////////////////////////////////////////////

Layout :: struct {
    debug:        ^DebugState,
    mouse_p:      v2,
    p:            v2,
    depth:        f32,
    line_advance: f32,
    spacing_y:    f32,
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
    Resizable, 
    HasInteraction,
}

////////////////////////////////////////////////

overlay_debug_info :: proc(debug: ^DebugState, input: Input) {
    if debug.render_group.assets == nil do return

    orthographic(&debug.render_group, {debug.render_group.commands.width, debug.render_group.commands.height}, 1)

    mouse_p := unproject_with_transform(debug.render_group.camera, default_flat_transform(), input.mouse.p).xy
    draw_main_menu(debug, input, mouse_p)
    debug_interact(debug, input, mouse_p)
    
    if ShowFramerate && debug.frames.first != nil {
        debug_push_text_line(debug, fmt.tprintf("Last Frame: %5.4f ms, %d events, %d data blocks, %d profile_blocks", 
            debug.frames.first.seconds_elapsed*1000,
            debug.collation_frame.stored_event_count,
            debug.collation_frame.data_block_count,
            debug.collation_frame.profile_block_count)
        )
        debug_push_text_line(debug, fmt.tprintf("Remaining Frame memory: %m", cast(u64) len(debug.per_frame_arena.storage) - debug.per_frame_arena.used))
    }
}

draw_main_menu :: proc(debug: ^DebugState, input: Input, mouse_p: v2) {
    assert(debug.font_info != nil)
    
    stack: Stack([64]DebugEventInterator)
    for tree := debug.tree_sentinel.next; tree != &debug.tree_sentinel; tree = tree.next {
        layout := Layout {
            debug        = debug,
            mouse_p      = mouse_p,
            
            p            = tree.p,
            depth        = 0,
            line_advance = debug_get_line_advance(debug),
            spacing_y    = 4,
        }
        
        group := tree.root
        
        if group != nil {
            stack_push(&stack, DebugEventInterator{
                link     = group.sentinel.next,
                sentinel = &group.sentinel,
            })
            
            for stack.depth > 0 {
                iter := stack_peek(&stack)
                if iter.link == iter.sentinel {
                    stack.depth  -= 1
                    layout.depth -= 1
                } else {
                    link := iter.link
                    iter.link = link.next
                    
                    depth_delta: f32
                    defer layout.depth += depth_delta
                    
                    switch &value in link.value {
                      case ^DebugEventGroup:
                        view := get_debug_view_for_variable(debug, debug_id_from_link(tree, link))

                        collapsible, ok := view.kind.(DebugViewCollapsible)
                        if !ok {
                            view.kind = DebugViewCollapsible{}
                            collapsible = view.kind.(DebugViewCollapsible)
                        }
                        
                        expanded: b32
                        if collapsible.expanded_always {
                            expanded = true
                            stack_push(&stack, DebugEventInterator{
                                link     = value.sentinel.next,
                                sentinel = &value.sentinel,
                            })
                            depth_delta = 1
                        }
                        
                        interaction := DebugInteraction{
                            kind = .ToggleExpansion,
                            id   = debug_id_from_link(tree, link),
                        }
                        
                        if debug.alt_ui {
                            interaction.kind = .Move
                            interaction.target = link
                        }
                        
                        is_hot := interaction_is_hot(debug, interaction)
                        color := is_hot ? Blue : White
                        
                        last_slash: u32
                        #reverse for r, index in value.name {
                            if r == '/' {
                                last_slash = auto_cast index
                                break
                            }
                        }
                        
                        view_name := last_slash != 0 ? value.name[last_slash+1:] : value.name
                        text := fmt.tprint(expanded ? "-" : "+", view_name)
                        text_bounds := debug_measure_text(debug, text)
                        
                        size := v2{ rectangle_get_dimension(text_bounds).x, layout.line_advance }
                        
                        element := begin_ui_element_rectangle(&layout, &size)
                        set_ui_element_default_interaction(&element, interaction)
                        end_ui_element(&element, false)
                        
                        debug_push_text(debug, text, {element.bounds.min.x, element.bounds.max.y - debug.ascent * debug.font_scale}, color)
                        
                      case ^DebugElement:
                        id := debug_id_from_link(tree, link)
                        draw_event(&layout, id, value, value.events.first)
                    }
                }
            }
            
            debug.top_edge = layout.p.y
            
            move_interaction := DebugInteraction{
                kind   = .Move,
                target = &tree.p,
                id = debug_id_from_link(tree, &group.sentinel),
            }
            
            move_handle := rectangle_min_dimension(tree.p, v2{8, 8})
            push_rectangle(&debug.render_group, move_handle, debug.ui_transform, interaction_is_hot(debug, move_interaction) ? Blue : White)
        
            if rectangle_contains(move_handle, mouse_p) {
                debug.next_hot_interaction = move_interaction
            }
        }
    }
}

draw_event :: proc(using layout: ^Layout, id: DebugId, in_element: ^DebugElement, stored_event: ^DebugStoredEvent) {
    if stored_event != nil {
        view := get_debug_view_for_variable(debug, id)
        
        event := &stored_event.event
        
        text: string
        
        autodetect_interaction := DebugInteraction{ 
            kind = .AutoDetect, 
            id = id, 
            target = in_element,
        }
        
        is_hot := interaction_is_hot(debug, autodetect_interaction)
        color := is_hot ? Blue : White
        
        switch value in event.value {
          case ThreadIntervalProfile:
            graph, ok := &view.kind.(DebugViewProfileGraph)
            if !ok {
                view.kind = DebugViewProfileGraph{}
                graph = &view.kind.(DebugViewProfileGraph)
                graph.block.size = {80, 60}
            }
            
            element := begin_ui_element_rectangle(layout, &graph.block.size)
            make_ui_element_resizable(&element)
            // TODO(viktor): reenable pausing the profiler
            // pause := DebugInteraction{
            //     kind   = .ToggleValue,
            //     id     = id,
            //     target = event,
            // }
            // set_ui_element_default_interaction(&element, pause)
            end_ui_element(&element, true)
            
            root: ^DebugProfileNode
            
            frame := debug.frames.first
            if frame != nil {
                viewed_element :^DebugElement= get_element_from_guid(debug, graph.root)
                if viewed_element != nil {
                    // TODO(viktor): @Speed we will have to check more and more frames the longer the game runs
                    prev : ^DebugStoredEvent
                    for search := viewed_element.events.last; search != nil; search = search.next {
                        if search.frame_index == frame.frame_index {
                            root = &search.node
                        }
                        prev = search
                    }
                }
                
                if root == nil {
                    if frame.root_profile_node != nil {
                        root = &frame.root_profile_node.node
                    }
                }
            }
            
            if root != nil {
                debug_draw_profile(layout, mouse_p, element.bounds, root, id)
            }
            
          case SoundId, FontId, 
            BeginTimedBlock, EndTimedBlock,
            BeginDataBlock, EndDataBlock,
            FrameMarker:
            // NOTE(viktor): nothing
            
          case BitmapId:
            block, ok := &view.kind.(DebugViewBlock)
            if !ok {
                view.kind = DebugViewBlock{}
                block = &view.kind.(DebugViewBlock)
            }
            
            if bitmap := get_bitmap(debug.render_group.assets, value, debug.render_group.generation_id); bitmap != nil {
                dim := get_used_bitmap_dim(&debug.render_group, bitmap^, default_flat_transform(), block.size.y, 0, use_alignment = false)
                block.size = dim.size
                
                element := begin_ui_element_rectangle(layout, &block.size)
                make_ui_element_resizable(&element)
                move := DebugInteraction{ kind = .Move, id = id, target = in_element}
                set_ui_element_default_interaction(&element, move)
                end_ui_element(&element, true)
                
                bitmap_height := block.size.y
                bitmap_offset := V3(element.bounds.min, 0)
                push_rectangle(&debug.render_group, element.bounds, debug.backing_transform, DarkBlue )
                push_bitmap(&debug.render_group, value, debug.ui_transform, bitmap_height, bitmap_offset, use_alignment = false)
            }
        
          case DebugEventLink, DebugEventGroup,
            b32, f32, i32, u32, v2, v3, v4, Rectangle2, Rectangle3:
            if _, ok := &event.value.(DebugEventGroup); ok {
                collapsible, okc := &view.kind.(DebugViewCollapsible)
                if !okc {
                    view.kind = DebugViewCollapsible{}
                    collapsible = &view.kind.(DebugViewCollapsible)
                }
                text = fmt.tprintf("%s %v", collapsible.expanded_always ? "-" : "+", event.guid.name)
            } else {
                last_slash: u32
                #reverse for r, index in event.guid.name {
                    if r == '/' {
                        last_slash = auto_cast index
                        break
                    }
                }
                text = fmt.tprintf("%s %v", last_slash != 0 ? event.guid.name[last_slash+1:] : event.guid.name, value)
            }
            
            text_bounds := debug_measure_text(debug, text)
            
            size := v2{ rectangle_get_dimension(text_bounds).x, layout.line_advance }
            
            element := begin_ui_element_rectangle(layout, &size)
            set_ui_element_default_interaction(&element, autodetect_interaction)
            end_ui_element(&element, false)
            
            debug_push_text(debug, text, {element.bounds.min.x, element.bounds.max.y - debug.ascent * debug.font_scale}, color)
        }
    }
}

debug_draw_profile :: proc (layout: ^Layout, mouse_p: v2, rect: Rectangle2, root: ^DebugProfileNode, graph_id: DebugId) {
    debug := layout.debug
    {
        color := Black
        color.a = 0.7
        push_rectangle(&layout.debug.render_group, rect, debug.backing_transform, color)
    }
    
    debug.mouse_text_stack_y = 10
    
    lane_count := cast(f32) debug.max_thread_count
    lane_height := safe_ratio_n(rectangle_get_dimension(rect).y, lane_count, rectangle_get_dimension(rect).y)
    
    debug_draw_profile_lane(layout, mouse_p, rect, root, graph_id, lane_height, lane_height)
}

debug_draw_profile_lane :: proc (layout: ^Layout, mouse_p: v2, rect: Rectangle2, root: ^DebugProfileNode, graph_id: DebugId, lane_stride, lane_height: f32) {
    debug := layout.debug
    
    frame_span := cast(f32) (root.duration)
    dimension := rectangle_get_dimension(rect)
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
        push_rectangle_outline(&layout.debug.render_group, region_rect, debug.ui_transform, color, 0.01 * lane_height)
        
        if rectangle_contains(rectangle_add_radius(region_rect, v2{5, 0}), mouse_p) {
            text := fmt.tprintf("%s - %d cycles [%s:% 4d]", element.guid.name, node.duration, element.guid.file_path, element.guid.line)
            debug_push_text(debug, text, mouse_p + {0, debug.mouse_text_stack_y})
            debug.mouse_text_stack_y -= debug_get_line_advance(debug)
            
            set_root := DebugInteraction {
                id = graph_id,
                kind = .SetProfileGraphRoot,
                target = element
            }
            
            debug.next_hot_interaction = set_root
        }
        
        if node.first_child != nil {
            debug_draw_profile_lane(layout, mouse_p, region_rect, node, graph_id, lane_height, lane_height*0.618033988749)
        }
    }
}

///////////////////////////////////////////////

begin_ui_element_rectangle :: proc(layout: ^Layout, size: ^v2) -> (result: LayoutElement) {
    result.layout  = layout
    result.size    = size
    
    return result
}

make_ui_element_resizable :: proc(element: ^LayoutElement) {
    element.flags += {.Resizable}
}

set_ui_element_default_interaction :: proc(element: ^LayoutElement, interaction: DebugInteraction) {
    element.flags += {.HasInteraction}
    element.interaction = interaction
}

end_ui_element :: proc(using element: ^LayoutElement, use_generic_spacing: b32) {
    SizeHandlePixels :: 4
    frame: v2
    if .Resizable in element.flags {
        frame = SizeHandlePixels / 2
    }
    total_size := element.size^ + frame * 2
    
    total_min    := layout.p + {layout.depth * 2 * layout.line_advance, -total_size.y}
    interior_min := total_min + frame
    
    total_bounds := rectangle_min_dimension(total_min, total_size)
    element.bounds = rectangle_min_dimension(interior_min, element.size^)

    was_resized: b32
    if .Resizable in element.flags {
        debug := element.layout.debug
        push_rectangle(&layout.debug.render_group, rectangle_min_dimension(total_min,                                   v2{total_size.x, frame.y}),             debug.shadow_transform, Black)
        push_rectangle(&layout.debug.render_group, rectangle_min_dimension(total_min + {0, frame.y},                    v2{frame.x, total_size.y - frame.y*2}), debug.shadow_transform, Black)
        push_rectangle(&layout.debug.render_group, rectangle_min_dimension(total_min + {total_size.x-frame.x, frame.y}, v2{frame.x, total_size.y - frame.y*2}), debug.shadow_transform, Black)
        push_rectangle(&layout.debug.render_group, rectangle_min_dimension(total_min + {0, total_size.y - frame.y},     v2{total_size.x, frame.y}),             debug.shadow_transform, Black)
        
        resize_box := rectangle_min_dimension(v2{element.bounds.max.x, total_min.y}, frame * 3)
        push_rectangle(&layout.debug.render_group, resize_box, debug.text_transform, White)
        
        resize_interaction := DebugInteraction {
            kind   = .Resize,
            target = element.size,
        }
        if rectangle_contains(resize_box, layout.mouse_p) {
            was_resized = true
            layout.debug.next_hot_interaction = resize_interaction
        }
    }
    
    if !was_resized && .HasInteraction in element.flags && rectangle_contains(element.bounds, layout.mouse_p) {
        layout.debug.next_hot_interaction = element.interaction
    }
    
    spacing := use_generic_spacing ? layout.spacing_y : 0
    layout.p.y = total_bounds.min.y - spacing
}

////////////////////////////////////////////////

add_tree :: proc(debug: ^DebugState, root: ^DebugEventGroup, p: v2) -> (result: ^DebugTree) {
    result = push(&debug.arena, DebugTree, no_clear())
    result^ = {
        root = root,
        p = p,
    }
    
    list_insert(&debug.tree_sentinel, result)
    
    return result
}

get_group_by_hierarchical_name :: proc(debug: ^DebugState, parent: ^DebugEventGroup, name: string, create_terminal: b32) -> (result: ^DebugEventGroup) {
    assert(parent != nil)
    result = parent
    
    first_slash := -1
    for r, index in name {
        if r == '/' {
            first_slash = index
            break
        }
    }
    
    if first_slash != -1 || create_terminal {
        left := first_slash != -1 ? name[:first_slash] : name
        result = get_or_create_group_with_name(debug, parent, left)
        if first_slash != -1 {
            right := name[first_slash+1:]
            result = get_group_by_hierarchical_name(debug, result, right, create_terminal)
        }
    }
    
    
    assert(result != nil)
    return result
}

get_or_create_group_with_name :: proc(debug: ^DebugState, parent: ^DebugEventGroup, name: string) -> (result: ^DebugEventGroup) {
    for link := parent.sentinel.next; link != &parent.sentinel; link = link.next {
        if group, ok := link.value.(^DebugEventGroup); ok && group != nil && group.name == name {
            result = group
        }
    }
    
    if result == nil {
        result = create_group(debug, name)
        add_group_to_group(debug, parent, result)
    }
    
    return result
}

create_group :: proc(debug: ^DebugState, name: string) -> (result: ^DebugEventGroup) {
    result = push(&debug.arena, DebugEventGroup)
    result.name = copy_string(&debug.arena, name)
    list_init_sentinel(&result.sentinel)
    
    return result
}

clone_group :: proc (debug: ^DebugState, source: ^DebugEventLink) -> (result: ^DebugEventGroup) {
    result = create_group(debug, copy_string(&debug.arena, "Cloned"))
    clone_event_link(debug, result, source)
    return result
}

clone_event_link :: proc (debug: ^DebugState, parent: ^DebugEventGroup, source: ^DebugEventLink) -> (result: ^DebugEventLink) {
    if group, ok := source.value.(^DebugEventGroup); ok {
        result = add_group_to_group(debug, parent, group)
    } else {
        result = add_element_to_group(debug, parent, source.value.(^DebugElement))
    }
    
    group, ok := source.value.(^DebugEventGroup)
    if ok && group.sentinel.next != nil {
        sub_group := push(&debug.arena, DebugEventGroup)
        sub_group.name = group.name
        list_init_sentinel(&sub_group.sentinel)
        
        for child := group.sentinel.next; child != &group.sentinel; child = child.next {
            clone_event_link(debug, sub_group, child)
        }
    }
    
    return result
}

add_element_to_group :: proc(debug: ^DebugState, parent: ^DebugEventGroup, element: ^DebugElement) -> (result: ^DebugEventLink) {
    result = push(&debug.arena, DebugEventLink)
    assert(element != nil)
    assert(parent != nil)
    
    list_insert(&parent.sentinel, result)
    result.value = element
    
    return result
}

add_group_to_group :: proc(debug: ^DebugState, parent: ^DebugEventGroup, child: ^DebugEventGroup) -> (result: ^DebugEventLink) {
    result = push(&debug.arena, DebugEventLink)
    assert(child != nil)
    assert(parent != nil)
    
    list_insert(&parent.sentinel, result)
    result.value = child
    
    return result
}

debug_id_from_link :: proc(tree: ^DebugTree, link: ^DebugEventLink) -> (result: DebugId) {
    result.value[0] = tree
    result.value[1] = link
    return result
}

debug_id_from_guid :: proc(guid: ^DebugGUID) -> (result: DebugId) {
    result.value[0] = guid
    result.value[1] = nil
    return result
}

get_debug_view_for_variable :: proc(debug: ^DebugState, id: DebugId) -> (result: ^DebugView) {
    // TODO(viktor): BETTER HASH FUNCTION
    hash_index := ((cast(umm) id.value[0] >> 2) + (cast(umm) id.value[1] >> 2)) % len(debug.view_hash)
    slot := &debug.view_hash[hash_index]

    for search := slot^ ; search != nil; search = search.next {
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

interaction_is_hot :: proc(debug: ^DebugState, interaction: DebugInteraction) -> (result: b32) {
    result = debug.hot_interaction.id == interaction.id
    return result
}

debug_interact :: proc(debug: ^DebugState, input: Input, mouse_p: v2) {
    mouse_dp := mouse_p - debug.last_mouse_p
    defer debug.last_mouse_p = mouse_p
    
    interaction := &debug.interaction
    if interaction.kind != .None {
        // Mouse move interaction
        event: ^DebugEvent
        
        if element, ok := interaction.target.(^DebugElement); ok do event = &element.events.first.event
        
        // NOTE(viktor): Continous Interactions
        switch interaction.kind {
          case .None: 
            unreachable()
            
          case .NOP, .AutoDetect, .ToggleValue, .ToggleExpansion, .SetProfileGraphRoot:
            // nothing
            
          case .Select:
            if !input.shift_down {
                clear_selection(debug)
            }
            select(debug, interaction.id)
            
          case .DragValue:
            value := &event.value.(f32)
            value^ += 0.1 * mouse_dp.x
            GlobalDebugTable.edit_event = event^
            
          case .Resize:
            value := interaction.target.(^v2)
            value^ += mouse_dp * {1,-1}
            value.x = max(value.x, 80)
            value.y = max(value.y, 60)
            if event != nil do GlobalDebugTable.edit_event = event^
            
          case .Move:
            value := interaction.target.(^v2)
            value^ += mouse_dp
            if event != nil do GlobalDebugTable.edit_event = event^
        }
        
        // Click interaction
        for transition_index := input.mouse.left.half_transition_count; transition_index > 1; transition_index -= 1 {
            debug_end_click_interaction(debug, input)
            debug_begin_click_interaction(debug, input)
        }
        
        if !input.mouse.left.ended_down {
            debug_end_click_interaction(debug, input)
        }
    } else {
        debug.hot_interaction = debug.next_hot_interaction
        
        for transition_index:= input.mouse.left.half_transition_count; transition_index > 1; transition_index -= 1 {
            debug_begin_click_interaction(debug, input)
            debug_end_click_interaction(debug, input)
        }
        
        if input.mouse.left.ended_down {
            debug_begin_click_interaction(debug, input)
        }
    }
}

debug_begin_click_interaction :: proc(debug: ^DebugState, input: Input) {
    if debug.hot_interaction.kind != .None {
        // Detect Auto Interaction
        if debug.hot_interaction.kind == .AutoDetect {
            target := debug.hot_interaction.target.(^DebugElement)
            event := &target.events.first.event
            
            switch value in event.value {
              case FrameMarker, 
                   BitmapId, SoundId, FontId,
                   BeginTimedBlock, EndTimedBlock,
                   BeginDataBlock, EndDataBlock,
                   DebugEventGroup,
                   Rectangle2, Rectangle3,
                   ThreadIntervalProfile,
                   u32, i32, v2, v3, v4:
                debug.hot_interaction.kind = .NOP
              case b32:
                debug.hot_interaction.kind = .ToggleValue
              case f32:
                debug.hot_interaction.kind = .DragValue
              case DebugEventLink:
                debug.hot_interaction.kind = .ToggleValue
            }
        }
        
        // NOTE(viktor): Maybe change the target
        #partial switch debug.hot_interaction.kind {
          case .Move:
            switch target in debug.hot_interaction.target {
              case ^v2:
                // Nothing
              case ^DebugEventLink:
                group := clone_group(debug, target)
                
                tree := add_tree(debug, group, {0, 0})
                debug.hot_interaction.target = &tree.p
              case ^DebugTree, ^DebugElement:
                unreachable()
            }
            
        }
        
        debug.interaction = debug.hot_interaction
    } else {
        debug.interaction.kind = .NOP
    }
}

debug_end_click_interaction :: proc(debug: ^DebugState, input: Input) {
    interaction := &debug.interaction
    defer interaction^ = {}
    
    // NOTE(viktor): Discrete Interactions
    switch interaction.kind {
      case .None: 
        unreachable()
      
      case .NOP, .Move, .Resize, .AutoDetect, .Select, .DragValue:
        // NOTE(viktor): nothing
      
      case .SetProfileGraphRoot:
        view := get_debug_view_for_variable(debug, interaction.id)
        graph := &view.kind.(DebugViewProfileGraph)
        
        target := interaction.target.(^DebugElement)
        graph.root = target.guid
        
      case .ToggleExpansion:
        view := get_debug_view_for_variable(debug, interaction.id)
        collapsible, ok := &view.kind.(DebugViewCollapsible)
        if !ok {
            view.kind = DebugViewCollapsible{}
            collapsible = &view.kind.(DebugViewCollapsible)
        }
        
        collapsible.expanded_always = !collapsible.expanded_always
        
      case .ToggleValue:
        event := &interaction.target.(^DebugElement).events.first.event
        
        #partial switch &value in event.value {
        // TODO(viktor): reenable pausing profiles
          case ThreadIntervalProfile:
            debug.paused = !debug.paused
          case b32:
            value = !value
            GlobalDebugTable.edit_event = event^
        }
    }
}

////////////////////////////////////////////////

TextRenderOperation:: enum {
    Measure, Draw, 
}

debug_push_text :: proc(debug: ^DebugState, text: string, p: v2, color: v4 = 1) {
    if debug.font != nil {
        text_op(debug, .Draw, &debug.render_group, debug.font, debug.font_info, text, p, debug.font_scale, color)
    }
}

debug_measure_text :: proc(debug: ^DebugState, text: string) -> (result: Rectangle2) {
    if debug.font != nil {
        result = text_op(debug, .Measure, &debug.render_group, debug.font, debug.font_info, text, {0, 0}, debug.font_scale)
    }
    
    return result
}

debug_push_text_line :: proc(debug: ^DebugState, text: string) {
    debug_push_text(debug, text, {debug.left_edge, debug.top_edge} - {0, debug.ascent * debug.font_scale})
    if debug.font != nil {
        advance_y := debug_get_line_advance(debug)
        debug.top_edge -= debug.font_scale * advance_y
    }
}

debug_get_line_advance :: proc(debug: ^DebugState) -> (result: f32) {
    result = get_line_advance(debug.font_info) * debug.font_scale
    return result
}

text_op :: proc(debug: ^DebugState, operation: TextRenderOperation, group: ^RenderGroup, font: ^Font, font_info: ^FontInfo, text: string, p:v2, font_scale: f32, color: v4 = 1) -> (result: Rectangle2) {
    result = inverted_infinity_rectangle(Rectangle2)
    // TODO(viktor): @Robustness kerning and unicode test lines
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
        
        height := cast(f32) info.dimension.y * font_scale
        switch operation {
            case .Draw: 
            if codepoint != ' ' {
                push_bitmap(group, bitmap_id, debug.text_transform,   height, V3(p, 0), color)
                push_bitmap(group, bitmap_id, debug.shadow_transform, height, V3(p, 0) + {2,-2,0}, {0,0,0,1})
            }
          case .Measure:
            bitmap := get_bitmap(group.assets, bitmap_id, group.generation_id)
            if bitmap != nil {
                dim := get_used_bitmap_dim(group, bitmap^, default_flat_transform(), height, V3(p, 0))
                glyph_rect := rectangle_min_dimension(dim.p.xy, dim.size)
                result = rectangle_union(result, glyph_rect)
            }
        }
    }
    
    return result
}