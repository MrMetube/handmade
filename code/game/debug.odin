package game

import "core:fmt"
import "core:hash" // TODO(viktor): I do not need this


/* IMPORTANT TODO(viktor): explicit type for Expandable
    ie :: struct {
        ...
        array_count: u32,
        array:       [N]T,
    }
    
    Push entries and expand count in one operation.
    Get the slice of the filled values.
    
    Maybe this is just a dynamic array if we ever get
    a handmade Allocator.
*/ 

// TODO(viktor): "Mark Loop Point" as debug action

// TODO(viktor): Memorydebugger with tracking allocator and maybe a 
// tree graph to visualize the size of the allocated types and such in each arena?
// Maybe a table view of largest entries or most entries of a type.

DebugTimingDisabled :: !INTERNAL || !DEBUG_Profiling

GlobalDebugTable:  DebugTable
GlobalDebugMemory: ^GameMemory

DebugMaxThreadCount     :: 256   when !DebugTimingDisabled else 0
DebugMaxHistoryLength   :: 6     when !DebugTimingDisabled else 0
DebugMaxRegionsPerFrame :: 14000 when !DebugTimingDisabled else 0

when DebugTimingDisabled {
    #assert(len(GlobalDebugTable.event_count) == 0)
    #assert(len(GlobalDebugTable.events)      == 0)
    #assert(len(GlobalDebugTable.records)     == 0)
}

////////////////////////////////////////////////

DebugState :: struct {
    inititalized: b32,
    paused:       b32,
    debug_arena:  Arena,
    
    // NOTE(viktor): Collation
    collation_arena:  Arena,
    collation_memory: TemporaryMemory,
    collation_index:  u32,
    collation_frame:  ^DebugFrame,
    scopes_to_record: []^DebugRecord,
    
    
    frame_bar_scale:      f32,
    frame_bar_lane_count: u32,
    
    frame_count: u32,
    frames:      []DebugFrame,
    
    threads: []DebugThread,

    root_group:    ^DebugVariable,
    view_hash:     [4096]^DebugView,
    tree_sentinel: DebugTree,
    
    last_mouse_p:         v2,
    interaction:          DebugInteraction,
    hot_interaction:      DebugInteraction,
    next_hot_interaction: DebugInteraction,
    
    compiling:    b32,
    compiler:     DebugExecutingProcess,
    menu_p:       v2,
    profile_on:   b32,
    framerate_on: b32,
    
    // NOTE(viktor): Overlay rendering
    render_group: ^RenderGroup,
    
    work_queue: ^PlatformWorkQueue, 
    buffer:     Bitmap,
    
    font_scale:   f32,
    top_edge:         f32,
    ascent:       f32,
    left_edge:    f32,
    right_edge:   f32,
    
    font_id:      FontId,
    font:         ^Font,
    font_info:    ^FontInfo,
}

DebugFrame :: struct {
    begin_clock,
    end_clock:       i64,
    seconds_elapsed: f32,
    region_count:    u32,
    regions:         []DebugRegion,
}

DebugRegion :: struct {
    record:       ^DebugRecord,
    cycle_count:  i64,
    lane_index:   u32,
    t_min, t_max: f32,
}

DebugThread :: struct {
    thread_index:     u32, // Also used as a lane_index
    
    first_free_block: ^DebugOpenBlock,
    first_open_block: ^DebugOpenBlock,
}

DebugOpenBlock :: struct {
    frame_index:   u32,
    source:        ^DebugRecord,
    opening_event: ^DebugEvent,
    parent, 
    next_free:     ^DebugOpenBlock,
}

////////////////////////////////////////////////

DebugTable :: struct {
    // @Correctness No attempt is currently made to ensure that the final
    // debug records being written to the event array actually complete
    // their output prior to the swap of the event array index.
    current_events_index: u32,
    events_state:   DebugEventsState,
    event_count:    [DebugMaxHistoryLength]u32,
    events:         [DebugMaxHistoryLength][16*65536]DebugEvent,
    
    records: [DebugMaxThreadCount]DebugRecords,
}

DebugEvent :: struct {
    clock: i64,
    as: struct #raw_union {
        block: struct {
            thread_index: u16,
            core_index:   u16,                    
        },
        frame_marker: struct {
            seconds_elapsed: f32,
        },
    },
    record_index: u32,
    type: DebugEventType,
    
}

DebugEventsState :: bit_field u64 {
    // @Volatile Later on we transmute this to a u64 to 
    // atomically increment one of the fields
    events_index: u32 | 32,
    array_index:  u32 | 32,
}

DebugEventType :: enum u8 {
    BeginBlock, 
    EndBlock,
    FrameMarker,
}

////////////////////////////////////////////////

DebugRecords :: [512]DebugRecord
DebugRecord  :: struct {
    hash:  u32,
    index: u32,
    loc:   DebugRecordLocation,
}

DebugRecordLocation :: struct {
    file_path: string,
	line:      i32,
	name:      string,
}

////////////////////////////////////////////////

DebugInteraction :: struct {
    kind: DebugInteractionKind,
    target: union {
        ^DebugVariable, 
        ^DebugTree,
        ^v2,
        // TODO(viktor): add hot region from profile view
    },
}

DebugInteractionKind :: enum {
    None, 
    
    NOP,
    AutoDetect,
    
    Toggle,
    DragValue,
    
    Move,
    Resize,
}

////////////////////////////////////////////////

DebugView :: #type SingleLinkedList(DebugViewData)
DebugViewData :: struct {
    tree: DebugTree,
    var:  ^DebugVariable,
    
    kind: union {
        DebugViewVariable,
        DebugViewBlock,
        DebugViewCollapsable,
    }
}

DebugViewVariable :: struct {}

DebugViewCollapsable :: struct {
    expanded_always:   b32,
    expanded_alt_view: b32,
}

DebugViewBlock :: struct {
    size: v2,
}

////////////////////////////////////////////////

DebugTree :: #type LinkedList(DebugTreeData)
DebugTreeData :: struct {
    p:    v2,
    root: ^DebugVariable,
}

DebugVariable :: struct {
    name:   string,
    value:  DebugVariableValue,
}

DebugVariableValue :: union { 
    b32, i32, u32, f32, 
    v2, v3, v4,
    
    DebugVariableProfile,
    DebugBitmapDisplay,
    DebugVariableList,
}

// TODO(viktor): @CompilerBug this should just be:
// #type LinkedList(DebugVariable)
// But the compiler will go into an infinite loop.
// C:\Odin\odin.exe version dev-2025-02:584fdc0d4
DebugVariableList :: #type LinkedList(DebugVariableListData)
DebugVariableListData :: struct {
    var: ^DebugVariable,
}
// :LinkedListIteration
DebugVariableInterator :: struct {
    link:     ^DebugVariableList,
    sentinel: ^DebugVariableList,
}

DebugBitmapDisplay :: struct {
    id:   BitmapId,
}

DebugVariableProfile :: struct {
}

DebugVariableDefinitionContext :: struct {
    debug: ^DebugState,
    
    depth: u32,
    group_stack: [64]^DebugVariable,
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

@export
debug_frame_end :: proc(memory: ^GameMemory, buffer: Bitmap, input: Input) {
    when !INTERNAL do return
    assert(len(memory.debug_storage) >= size_of(DebugState))
    debug := cast(^DebugState) raw_data(memory.debug_storage)
    
    assets, work_queue := debug_get_game_assets_and_work_queue(memory)
    { // Debug reset
        if !debug.inititalized {
            debug.inititalized = true
    
            // :PointerArithmetic
            init_arena(&debug.debug_arena, memory.debug_storage[size_of(DebugState):])
            
            ctx := DebugVariableDefinitionContext { debug = debug }

            debug_begin_variable_group(&ctx, "Debugging")
                init_debug_variables(&ctx)

                debug_begin_variable_group(&ctx, "Assets")
                    debug_add_variable(&ctx, DebugBitmapDisplay{id = first_bitmap_from(assets, .Monster) }, "")
                debug_end_variable_group(&ctx)
                
                debug_begin_variable_group(&ctx, "Profile")
                    debug_begin_variable_group(&ctx, "By Thread")
                        debug_add_variable(&ctx, DebugVariableProfile{}, "")
                    debug_end_variable_group(&ctx)
                    debug_begin_variable_group(&ctx, "By Function")
                        debug_add_variable(&ctx, DebugVariableProfile{}, "")
                    debug_end_variable_group(&ctx)
                debug_end_variable_group(&ctx)
                debug.root_group = ctx.group_stack[1]
            debug_end_variable_group(&ctx)
            assert(ctx.depth == 0)
                
            list_init_sentinel(&debug.tree_sentinel)
            
            sub_arena(&debug.collation_arena, &debug.debug_arena, 64 * Megabyte)
            
            debug.scopes_to_record = push(&debug.collation_arena, ^DebugRecord, DebugMaxThreadCount)
            
            debug.font_scale = 0.6

            debug.work_queue = work_queue
            debug.buffer     = buffer
            
            
            debug.left_edge  = -0.5 * cast(f32) buffer.width
            debug.right_edge =  0.5 * cast(f32) buffer.width
            debug.top_edge   =  0.5 * cast(f32) buffer.height
            
            add_tree(debug, debug.root_group, { debug.left_edge, debug.top_edge })
            
            debug.collation_memory = begin_temporary_memory(&debug.collation_arena)
            restart_collation(debug, GlobalDebugTable.events_state.array_index)
        }

        if debug.render_group == nil {
            debug.render_group = make_render_group(&debug.debug_arena, assets, 32 * Megabyte, false)
            assert(debug.render_group != nil)
        }
        if debug.render_group.inside_render do return 

        if debug.font == nil {
            debug.font_id = best_match_font_from(assets, .Font, #partial { .FontType = cast(f32) AssetFontType.Debug }, #partial { .FontType = 1 })
            debug.font    = get_font(assets, debug.font_id, debug.render_group.generation_id)
            load_font(debug.render_group.assets, debug.font_id, false)
            debug.font_info = get_font_info(assets, debug.font_id)
            debug.ascent = get_baseline(debug.font_info)
        }
            
        begin_render(debug.render_group)
    }
    
    modular_add(&GlobalDebugTable.current_events_index, 1, len(GlobalDebugTable.events))
    events_state := atomic_exchange(&GlobalDebugTable.events_state, { events_index = 0, array_index = GlobalDebugTable.current_events_index })
    GlobalDebugTable.event_count[events_state.array_index] = events_state.events_index
    
    if memory.reloaded_executable {
        restart_collation(debug, GlobalDebugTable.events_state.array_index)
    }
    
    if !debug.paused {
        if cast(i32) debug.collation_index >= DebugMaxHistoryLength-1 {
            restart_collation(debug, events_state.array_index)
        }
        
        collate_debug_records(debug, events_state.array_index)
    }

    debug.next_hot_interaction = {}
    
    overlay_debug_info(debug, input)
    
    tiled_render_group_to_output(debug.work_queue, debug.render_group, debug.buffer)
    end_render(debug.render_group)
}

////////////////////////////////////////////////

restart_collation :: proc(debug: ^DebugState, invalid_index: u32) {
    end_temporary_memory(debug.collation_memory)
    debug.collation_memory = begin_temporary_memory(&debug.collation_arena)
    
    debug.frames = push(&debug.collation_arena, DebugFrame, DebugMaxHistoryLength)
    debug.threads = push(&debug.collation_arena, DebugThread, DebugMaxThreadCount)
    debug.frame_bar_scale = 1.0 / 60_000_000.0//1
    debug.frame_count = 0
    
    debug.collation_index = invalid_index + 1
    debug.collation_frame = nil
}

refresh_collation :: proc(debug: ^DebugState) {
    restart_collation(debug, GlobalDebugTable.events_state.array_index)
    collate_debug_records(debug, GlobalDebugTable.events_state.array_index)
}

collate_debug_records :: proc(debug: ^DebugState, invalid_events_index: u32) {
    // @Hack why should this need to be reset? Think dont guess
    for &thread in debug.threads do thread.first_open_block = nil
    
    modular_add(&debug.collation_index, 0, DebugMaxHistoryLength)
    for {
        if debug.collation_index == invalid_events_index do break
        defer modular_add(&debug.collation_index, 1, DebugMaxHistoryLength)
        
        for &event in GlobalDebugTable.events[debug.collation_index][:GlobalDebugTable.event_count[debug.collation_index]] {
            if event.type == .FrameMarker {
                if debug.collation_frame != nil {
                    debug.collation_frame.end_clock = event.clock
                    modular_add(&debug.frame_count, 1, auto_cast len(debug.frames))
                    debug.collation_frame.seconds_elapsed = event.as.frame_marker.seconds_elapsed
                    
                    clocks := cast(f32) (debug.collation_frame.end_clock - debug.collation_frame.begin_clock)
                    if clocks != 0 {
                        // scale := 1.0 / clocks
                        // debug_state.frame_bar_scale = min(debug_state.frame_bar_scale, scale)
                    }
                }
                
                debug.collation_frame = &debug.frames[debug.frame_count]
                debug.collation_frame^ = {
                    begin_clock     = event.clock,
                    end_clock       = -1,
                    regions         = push(&debug.collation_arena, DebugRegion, DebugMaxRegionsPerFrame),
                }
            } else if debug.collation_frame != nil {
                debug.frame_bar_lane_count = max(debug.frame_bar_lane_count, cast(u32) event.as.block.thread_index)
                
                source := &GlobalDebugTable.records[event.as.block.thread_index][event.record_index]
                thread := &debug.threads[event.as.block.thread_index]
                frame_index := debug.frame_count-1
                
                switch event.type {
                case .FrameMarker: unreachable()
                case .BeginBlock:
                    block := thread.first_free_block
                    if block != nil {
                        thread.first_free_block = block.next_free
                    } else {
                        block = push(&debug.collation_arena, DebugOpenBlock)
                    }
                    block^ = {
                        frame_index   = frame_index,
                        opening_event = &event,
                        parent        = thread.first_open_block,
                        source        = source,
                    }
                    thread.first_open_block = block
                case .EndBlock:
                    matching_block := thread.first_open_block
                    if matching_block != nil {
                        opening_event := matching_block.opening_event
                        if opening_event != nil && opening_event.as.block.thread_index == event.as.block.thread_index && opening_event.record_index == event.record_index {
                            if matching_block.frame_index == frame_index {
                                record_from :: #force_inline proc(block: ^DebugOpenBlock) -> (result: ^DebugRecord) {
                                    result = block != nil ? block.source : nil
                                    return result
                                }
                                
                                if record_from(matching_block.parent) == debug.scopes_to_record[event.as.block.thread_index] {
                                    t_min := cast(f32) (opening_event.clock - debug.collation_frame.begin_clock)
                                    t_max := cast(f32) (event.clock - debug.collation_frame.begin_clock)
                                    
                                    threshold :: 0.001
                                    if t_max - t_min > threshold {
                                        region := &debug.collation_frame.regions[debug.collation_frame.region_count]
                                        debug.collation_frame.region_count += 1
                                        
                                        region^ = {
                                            record      = source,
                                            cycle_count = event.clock - opening_event.clock,
                                            lane_index = cast(u32) event.as.block.thread_index,
                                            t_min = t_min,
                                            t_max = t_max,
                                        }
                                    }
                                } else {
                                    // TODO(viktor): nested regions
                                }
                            } else {
                                // TODO(viktor): Record all frames in between and begin/end spans
                            }
                            
                            matching_block.next_free = thread.first_free_block
                            thread.first_free_block = matching_block
                            
                            thread.first_open_block = matching_block.parent
                        } else {
                            // TODO(viktor): Record span that goes to the beginning of the frame
                        }
                    }
                }

            }
        }
    }
}

////////////////////////////////////////////////

overlay_debug_info :: proc(debug: ^DebugState, input: Input) {
    if debug.render_group == nil do return

    orthographic(debug.render_group, {debug.buffer.width, debug.buffer.height}, 1)

    if debug.compiling {
        state := Platform.debug.get_process_state(debug.compiler)
        if state.is_running {
            debug_push_text_line(debug, "Recompiling...")
        } else {
            assert(state.return_code == 0)
            debug.compiling = false
        }
    }

    debug_main_menu(debug, input)
    debug_interact(debug, input)
    
    if DEBUG_ShowFramerate {
        debug_push_text_line(debug, fmt.tprintf("Last Frame time: %5.4f ms", debug.frames[0].seconds_elapsed*1000))
    }
}

debug_draw_profile :: proc (debug: ^DebugState, input: Input, rect: Rectangle2) {
    push_rectangle(debug.render_group, rect, DarkBlue )
    
    target_fps :: 72

    bar_padding :: 1
    lane_height :f32
    lane_count  := cast(f32) debug.frame_bar_lane_count +1 
    frame_count := cast(f32) len(debug.frames)
    if frame_count > 0 && lane_count > 0 {
        lane_height = ((rectangle_get_diameter(rect).y / frame_count) - bar_padding) / lane_count
    }
    
    bar_height       := lane_height * lane_count
    bar_plus_spacing := bar_height + bar_padding
    
    chart_left  := rect.min.x
    chart_top   := rect.max.y - bar_plus_spacing
    chart_width := rectangle_get_diameter(rect).x
    
    scale := debug.frame_bar_scale * chart_width
    
    hot_region: ^DebugRegion
    for frame_index in 0..<len(debug.frames) {
        frame := &debug.frames[(frame_index + cast(int) debug.collation_index) % len(debug.frames)]
        
        stack_x := chart_left
        stack_y := chart_top - bar_plus_spacing * cast(f32) frame_index
        for &region in frame.regions[:frame.region_count] {
            
            x_min := stack_x + scale * region.t_min
            x_max := stack_x + scale * region.t_max

            y_min := stack_y + lane_height * cast(f32) region.lane_index
            y_max := y_min + lane_height - bar_padding
            stack_rect := rectangle_min_max(v2{x_min, y_min}, v2{x_max, y_max})
            
            color_wheel := color_wheel
            color_index := region.record.loc.line % len(color_wheel)
            color := color_wheel[color_index]
                        
            push_rectangle(debug.render_group, stack_rect, color)
            if rectangle_contains(stack_rect, input.mouse.p) {
                hot_region = &region
                
                record := region.record
                text := fmt.tprintf("%s - %d cycles [%s:% 4d]", record.loc.name, region.cycle_count, record.loc.file_path, record.loc.line)
                debug_push_text(debug, text, input.mouse.p)
            }
        }
    }
    
    if was_pressed(input.mouse.left) {
        if hot_region != nil {
            debug.scopes_to_record[hot_region.lane_index] = hot_region.record
            // TODO(viktor): @Cleanup clicking regions and variables at the same time should be handled better
            debug.hot_interaction.kind = .NOP
        } else {
            for &scope in debug.scopes_to_record do scope = nil
        }
        refresh_collation(debug)
    }
}

debug_begin_interact :: proc(debug: ^DebugState, input: Input, alt_ui: b32) {
    if debug.hot_interaction.kind != .None {
        if debug.hot_interaction.kind == .AutoDetect {
            target := debug.hot_interaction.target.(^DebugVariable)
            switch var in target.value {
              case u32, i32, v2, v3, v4, DebugBitmapDisplay:
                debug.hot_interaction.kind = .NOP
              case b32, DebugVariableList, DebugVariableProfile:
                debug.hot_interaction.kind = .Toggle
              case f32:
                debug.hot_interaction.kind = .DragValue
            }
            
            if alt_ui {
                debug.hot_interaction.kind = .Move
            }
        }
        
        #partial switch debug.hot_interaction.kind {
          case .Move:
            switch target in debug.hot_interaction.target {
              case ^v2:
                // NOTE(viktor): nothing
              case ^DebugVariable:
                unimplemented()
                // root_group := debug_add_root_group(debug, "NewUserGroup")
                // debug_add_variable_reference_to_group(debug, root_group, debug.hot_interaction.target.(^DebugVariable))
                // tree := add_tree(debug, root_group, {0, 0})
                // debug.hot_interaction.target = &tree.p
              case ^DebugTree:
                unreachable()
            }
            
        }
        
        debug.interaction = debug.hot_interaction
    } else {
        debug.interaction.kind = .NOP
    }
}

debug_interact :: proc(debug: ^DebugState, input: Input) {
    mouse_dp := input.mouse.p - debug.last_mouse_p
    defer debug.last_mouse_p = input.mouse.p
    
    
    
    alt_ui := input.mouse.right.ended_down
    if debug.interaction.kind != .None {
        // NOTE(viktor): Mouse move interaction
        switch debug.interaction.kind {
          case .None: 
            unreachable()
            
          case .NOP, .AutoDetect, .Toggle:
            // NOTE(viktor): nothing
            
          case .DragValue:
            value := &debug.interaction.target.(^DebugVariable).value.(f32)
            value^ += 0.1 * mouse_dp.y
            
          case .Resize:
            value := debug.interaction.target.(^v2)
            value^ += mouse_dp * {1,-1}
            value.x = max(value.x, 10)
            value.y = max(value.y, 10)
          
          case .Move:
            value := debug.interaction.target.(^v2)
            value^ += mouse_dp
        }
        
        // NOTE(viktor): Click interaction
        for transition_index := input.mouse.left.half_transition_count; transition_index > 1; transition_index -= 1 {
            debug_end_interact(debug, input)
            debug_begin_interact(debug, input, alt_ui)
        }
        
        if !input.mouse.left.ended_down {
            debug_end_interact(debug, input)
        }
    } else {
        debug.hot_interaction = debug.next_hot_interaction
        
        for transition_index:= input.mouse.left.half_transition_count; transition_index > 1; transition_index -= 1 {
            debug_begin_interact(debug, input, alt_ui)
            debug_end_interact(debug, input)
        }
        
        if input.mouse.left.ended_down {
            debug_begin_interact(debug, input, alt_ui)
        }
    }
}

debug_end_interact :: proc(debug: ^DebugState, input: Input) {
    reload: b32
    switch debug.interaction.kind {
      case .None: 
        unreachable()
      
      case .NOP, .Move, .Resize, .AutoDetect: 
        // NOTE(viktor): nothing
      
      case .DragValue: 
        reload = true
      
      case .Toggle:
        target := debug.interaction.target.(^DebugVariable)
        
        switch &value in target.value {
          case f32, u32, i32, v2, v3, v4, DebugBitmapDisplay:
            unreachable()
            
          case DebugVariableList:
            view := get_debug_view_for_variable(debug, value.var).kind.(DebugViewCollapsable)
            view.expanded_always = !view.expanded_always
            
          case DebugVariableProfile:
            debug.paused = !debug.paused
            
          case b32:
            value = !value
            reload = true
        }
    }
    
    if reload do write_handmade_config(debug)
    
    debug.interaction = {}
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

end_ui_element :: proc(using element: ^LayoutElement, use_spacing: b32) {
    SizeHandlePixels :: 4
    frame: v2
    if .Resizable in element.flags {
        frame = SizeHandlePixels
    }
    total_size := element.size^ + frame * 2
    
    total_min    := layout.p + {layout.depth * 2 * layout.line_advance, -total_size.y}
    interior_min := total_min + frame
    
    total_bounds := rectangle_min_diameter(total_min, total_size)
    element.bounds = rectangle_min_diameter(interior_min, element.size^)

    was_resized: b32
    if .Resizable in element.flags {
        push_rectangle(layout.debug.render_group, rectangle_min_diameter(total_min,                                   v2{total_size.x, frame.y}),             Black)
        push_rectangle(layout.debug.render_group, rectangle_min_diameter(total_min + {0, frame.y},                    v2{frame.x, total_size.y - frame.y*2}), Black)
        push_rectangle(layout.debug.render_group, rectangle_min_diameter(total_min + {total_size.x-frame.x, frame.y}, v2{frame.x, total_size.y - frame.y*2}), Black)
        push_rectangle(layout.debug.render_group, rectangle_min_diameter(total_min + {0, total_size.y - frame.y},     v2{total_size.x, frame.y}),             Black)
        
        resize_box := rectangle_min_diameter(v2{element.bounds.max.x, total_min.y}, frame)
        push_rectangle(layout.debug.render_group, resize_box, White)
        
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
    
    spacing := use_spacing ? layout.spacing_y : 0
    layout.p.y = total_bounds.min.y - spacing
}

get_debug_view_for_variable :: proc(debug: ^DebugState, var: ^DebugVariable) -> (result: DebugView) {
    return 
}

debug_main_menu :: proc(debug: ^DebugState, input: Input) {
    if debug.font_info == nil do return
    stack: Stack(DebugVariableInterator, 64)
    
    for tree := debug.tree_sentinel.next; tree != &debug.tree_sentinel; tree = tree.next {
        mouse_p := input.mouse.p
        
        layout := Layout {
            debug        = debug,
            mouse_p      = mouse_p,
            
            p            = tree.p,
            depth        = 0,
            line_advance = get_line_advance(debug.font_info) * debug.font_scale,
            spacing_y    = 4,
        }
        
        stack_push(&stack, DebugVariableInterator{
            link     = tree.root.value.(DebugVariableList).next,
            sentinel = &tree.root.value.(DebugVariableList),
        })
        
        for stack.depth > 0 {
            // :LinkedListIteration
            iter := stack_peek(&stack)
            if iter.link == iter.sentinel {
                stack.depth -= 1
            } else {
                var := iter.link.var
                defer iter.link = iter.link.next
                
                autodetect_interaction := DebugInteraction{
                    kind   = .AutoDetect,
                    target = var,
                }

                is_hot := debug_interaction_is_hot(debug, autodetect_interaction)
                
                text: string
                color := is_hot ? Blue : White
                
                depth_delta: f32
                defer layout.depth += depth_delta
                
                // TODO(viktor): View Cache
                view: DebugView = get_debug_view_for_variable(debug, var)
                
                switch value in var.value {
                case DebugVariableProfile:
                    block := &view.kind.(DebugViewBlock)
                    element := begin_ui_element_rectangle(&layout, &block.size)
                    make_ui_element_resizable(&element)
                    set_ui_element_default_interaction(&element, autodetect_interaction)
                    end_ui_element(&element, true)
                    
                    debug_draw_profile(debug, input, element.bounds)
                    
                case DebugBitmapDisplay:
                    block := &view.kind.(DebugViewBlock)
                    if bitmap := get_bitmap(debug.render_group.assets, value.id, debug.render_group.generation_id); bitmap != nil {
                        dim := get_used_bitmap_dim(debug.render_group, bitmap^, block.size.y, 0, use_alignment = false)
                        block.size = dim.size
                    }

                    element := begin_ui_element_rectangle(&layout, &block.size)
                    make_ui_element_resizable(&element)
                    set_ui_element_default_interaction(&element, {kind = .Move, target = var })
                    end_ui_element(&element, true)
                    
                    bitmap_height := block.size.y
                    bitmap_offset := V3(element.bounds.min, 0)
                    push_rectangle(debug.render_group, element.bounds, DarkBlue )
                    push_bitmap(debug.render_group, value.id, bitmap_height, bitmap_offset, use_alignment = false)
                    
                case DebugVariableList, b32, u32, i32, f32, v2, v3, v4:
                    if list, ok := value.(DebugVariableList); ok {
                        view := view.kind.(DebugViewCollapsable)
                        text = fmt.tprintf("%s %v", view.expanded_always ? "-" : "+",  var.name)
                        iter = stack_push(&stack, DebugVariableInterator{
                            link     = list.next,
                            sentinel = &list,
                        })
                    } else {
                        text = fmt.tprintf("%s %v", var.name, value)
                    }
                    
                    text_bounds := debug_measure_text(debug, text)
                    
                    size := v2{ rectangle_get_diameter(text_bounds).x, layout.line_advance }
                    
                    element := begin_ui_element_rectangle(&layout, &size)
                    set_ui_element_default_interaction(&element, autodetect_interaction)
                    end_ui_element(&element, false)
                    
                    debug_push_text(debug, text, {element.bounds.min.x, element.bounds.max.y - debug.ascent * debug.font_scale}, color)
                }
            }
        }
        
        debug.top_edge = layout.p.y
        
        move_interaction := DebugInteraction{
            kind   = .Move,
            target = &tree.p,
        }
        
        move_handle := rectangle_min_diameter(tree.p, v2{8, 8})
        push_rectangle(debug.render_group, move_handle, debug_interaction_is_hot(debug, move_interaction) ? Blue : White)
    
        if rectangle_contains(move_handle, mouse_p) {
            debug.next_hot_interaction = move_interaction
        }
    }
    
}

write_handmade_config :: proc(debug: ^DebugState) {
    if debug.compiling do return
    debug.compiling = true
    
    write :: proc(buffer: []u8, line: string) -> (result: u32) {
        for r, i in line {
            assert(r < 256, "no unicode in config")
            buffer[i] = cast(u8) r
        }
        
        result = auto_cast len(line)
        return result
    }
    
    // TODO(viktor): is this still needed?
    seen_names: [1024]string
    seen_names_cursor: u32
    contents: [4096*4]u8
    cursor: u32
    cursor += write(contents[cursor:], "package game\n\n")
    
    stack: Stack(DebugVariableInterator, 64)
    stack_push(&stack, DebugVariableInterator{
        link     = debug.root_group.value.(DebugVariableList).next,
        sentinel = &debug.root_group.value.(DebugVariableList),
    })
    
    for stack.depth > 0 {
        iter := stack_peek(&stack)
        if iter.link == iter.sentinel {
            stack.depth -= 1
        } else {
            var := iter.link.var
            defer iter.link = iter.link.next
            
            should_write := true
            t: typeid
            switch &value in var.value {
            case DebugVariableProfile, DebugBitmapDisplay: 
                // NOTE(viktor): transient data
                should_write = false
            case DebugVariableList:
                cursor += write(contents[cursor:], fmt.tprintfln("// %s", var.name))
                should_write = false
                iter = stack_push(&stack, DebugVariableInterator{
                    link     = value.next,
                    sentinel = &value,
                })
            case b32: t = b32
            case f32: t = f32
            case i32: t = i32
            case u32: t = u32
            case v2:  t = v2
            case v3:  t = v3
            case v4:  t = v4
            }
            
            for name in seen_names[:seen_names_cursor] {
                if !should_write do break
                if name == var.name do should_write = false
            }
            
            if should_write {
                cursor += stack.depth * 4
                cursor += write(contents[cursor:], fmt.tprintfln("%s :%w: %w", var.name, t, var.value))
                seen_names[seen_names_cursor] = var.name
                seen_names_cursor += 1
            }
        }
    }
    
    HandmadeConfigFilename :: "../code/game/debug_config.odin"
    Platform.debug.write_entire_file(HandmadeConfigFilename, contents[:cursor])
    debug.compiler = Platform.debug.execute_system_command(`D:\handmade\`, `D:\handmade\build\build.exe`, `-Game`)
}
            
debug_interaction_is_hot :: proc(debug: ^DebugState, interaction: DebugInteraction) -> (result: b32) {
    result = debug.hot_interaction == interaction
    return result
}

add_tree :: proc(debug: ^DebugState, root: ^DebugVariable, p: v2) -> (result: ^DebugTree) {
    result = push(&debug.debug_arena, DebugTree)
    result^ = {
        root = root,
        p = p,
    }
    
    list_insert(&debug.tree_sentinel, result)
    
    return result
}

init_debug_variables :: proc (ctx: ^DebugVariableDefinitionContext) {
    debug_begin_variable_group(ctx, "Profiling")
        debug_add_variable(ctx, DEBUG_Profiling)
        debug_add_variable(ctx, DEBUG_ShowFramerate)
    debug_end_variable_group(ctx)

    debug_begin_variable_group(ctx, "Rendering")
        debug_add_variable(ctx, DEBUG_UseDebugCamera)
        debug_add_variable(ctx, DEBUG_DebugCameraDistance)
    
        debug_add_variable(ctx, DEBUG_RenderSingleThreaded)
        debug_add_variable(ctx, DEBUG_TestWeirdScreenSizes)
        
        debug_begin_variable_group(ctx, "Bounds")
            debug_add_variable(ctx, DEBUG_ShowSpaceBounds)
            debug_add_variable(ctx, DEBUG_ShowGroundChunkBounds)
        debug_end_variable_group(ctx)
        
        debug_begin_variable_group(ctx, "ParticleSystem")
            debug_add_variable(ctx, DEBUG_ParticleSystemTest)
            debug_add_variable(ctx, DEBUG_ParticleGrid)
        debug_end_variable_group(ctx)
        
        debug_begin_variable_group(ctx, "CoordinateSystem")
            debug_add_variable(ctx, DEBUG_CoordinateSystemTest)
            debug_add_variable(ctx, DEBUG_ShowLightingBounceDirection)
            debug_add_variable(ctx, DEBUG_ShowLightingSampling)
        debug_end_variable_group(ctx)
    debug_end_variable_group(ctx)

    debug_begin_variable_group(ctx, "Audio")
        debug_add_variable(ctx, DEBUG_SoundPanningWithMouse)
        debug_add_variable(ctx, DEBUG_SoundPitchingWithMouse)
    debug_end_variable_group(ctx)

    debug_add_variable(ctx, DEBUG_FamiliarFollowsHero)
    debug_add_variable(ctx, DEBUG_HeroJumping)
}

debug_begin_variable_group :: proc(ctx: ^DebugVariableDefinitionContext, group_name: string) {
    var := debug_add_variable_unreferenced(ctx, DebugVariableList{}, group_name)
    list_init_sentinel(&var.value.(DebugVariableList))
 
    ctx.group_stack[ctx.depth] = var
    ctx.depth += 1
}

debug_add_variable_to_group :: proc(ctx: ^DebugVariableDefinitionContext, group: ^DebugVariable, element: ^DebugVariable) {
    entry := push(&ctx.debug.debug_arena, DebugVariableList)
    entry.var = element
    
    list  := &group.value.(DebugVariableList)
    list_insert(list, entry)
}

debug_add_variable_unreferenced :: proc(ctx: ^DebugVariableDefinitionContext, value: DebugVariableValue, variable_name: string) -> (result: ^DebugVariable) {
    result = push(&ctx.debug.debug_arena, DebugVariable)
    result^ = {
        name  = push_string(&ctx.debug.debug_arena, variable_name),
        value = value,
    }
    return result
}

debug_add_variable :: proc(ctx: ^DebugVariableDefinitionContext, value: DebugVariableValue, variable_name := #caller_expression(value)) -> (result: ^DebugVariable) {
    result = debug_add_variable_unreferenced(ctx, value, variable_name)
    
    parent := ctx.group_stack[ctx.depth]
    if parent != nil {
        debug_add_variable_to_group(ctx, parent, result)
    }
    
    return result
}

debug_end_variable_group :: proc(ctx: ^DebugVariableDefinitionContext) {
    assert(ctx.depth > 0)
    ctx.depth -= 1
}

////////////////////////////////////////////////

debug_push_text :: proc(debug: ^DebugState, text: string, p: v2, color: v4 = 1) {
    if debug.font != nil {
        text_op(.Draw, debug.render_group, debug.font, debug.font_info, text, p, debug.font_scale, color)
    }
}

debug_measure_text :: proc(debug: ^DebugState, text: string) -> (result: Rectangle2) {
    if debug.font != nil {
        result = text_op(.Measure, debug.render_group, debug.font, debug.font_info, text, {0, 0}, debug.font_scale)
    }
    
    return result
}

debug_push_text_line :: proc(debug: ^DebugState, text: string) {
    assert(debug.render_group.inside_render)
    
    debug_push_text(debug, text, {debug.left_edge, debug.top_edge} - {0, debug.ascent * debug.font_scale})
    if debug.font != nil {
        advance_y := get_line_advance(debug.font_info)
        debug.top_edge -= debug.font_scale * advance_y
    }
}

TextRenderOperation:: enum {
    Measure, Draw, 
}

text_op :: proc(operation: TextRenderOperation, group: ^RenderGroup, font: ^Font, font_info: ^FontInfo, text: string, p:v2, font_scale: f32, color: v4 = 1) -> (result: Rectangle2) {
    result = inverted_infinity_rectangle(Rectangle2)
    // TODO(viktor): kerning and unicode test lines
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
                push_bitmap(group, bitmap_id, height, V3(p, 0), color)
            }
          case .Measure:
            bitmap := get_bitmap(group.assets, bitmap_id, group.generation_id)
            if bitmap != nil {
                dim := get_used_bitmap_dim(group, bitmap^, height, V3(p, 0))
                glyph_rect := rectangle_min_diameter(dim.p.xy, dim.size)
                result = rectangle_union(result, glyph_rect)
            }
        }
    }
    
    return result
}

////////////////////////////////////////////////

@(export)
begin_timed_block:: #force_inline proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) {
    when DebugTimingDisabled do return result
    
    records := &GlobalDebugTable.records[context.user_index]

    key := DebugRecordLocation{
        name      = name,
        file_path = loc.file_path,
        line      = loc.line,
    }
    ok: b32
    // TODO(viktor): Check the overhead of this
    result.record_index, ok = get(records, key)
    if !ok {
        result.record_index = put(records, key)
    }
    result.hit_count = hit_count
    
    record_debug_event_block(.BeginBlock, result.record_index)
    
    return result
}

@export
end_timed_block:: #force_inline proc(block: TimedBlock) {
    if DebugTimingDisabled do return
    // TODO(viktor): check manual blocks are closed once and exactly once
    // TODO(viktor): record the hit count here
    record_debug_event_block(.EndBlock, block.record_index)
}

@(deferred_out=end_timed_block)
timed_block:: #force_inline proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) {
    return begin_timed_block(name, loc, hit_count)
}

begin_timed_function :: #force_inline proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) { 
    return begin_timed_block(loc.procedure, loc, hit_count)
}

end_timed_function :: #force_inline proc(block: TimedBlock) {
    end_timed_block(block)
}

@(deferred_out=end_timed_function)
timed_function :: #force_inline proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) { 
    return begin_timed_function(loc, hit_count)
}

@export
frame_marker :: #force_inline proc(seconds_elapsed: f32, loc := #caller_location) {
    if DebugTimingDisabled do return
    
    record_debug_event_frame_marker(seconds_elapsed)
    
    frame_marker := &GlobalDebugTable.records[context.user_index][NilHashValue]
    frame_marker.loc.file_path = loc.file_path
    frame_marker.loc.line = loc.line
    frame_marker.loc.name = "Frame Marker"
    frame_marker.index = NilHashValue
    frame_marker.hash  = NilHashValue
}

record_debug_event_frame_marker :: #force_inline proc (seconds_elapsed: f32) {
    if DebugTimingDisabled do return
    
    event := record_debug_event_common(.FrameMarker, NilHashValue)
    event.as.frame_marker = {
        seconds_elapsed = seconds_elapsed,
    }
}

record_debug_event_block :: #force_inline proc (type: DebugEventType, record_index: u32) {
    if DebugTimingDisabled do return
    
    event := record_debug_event_common(type, record_index)
    event.as.block = {
        thread_index = cast(u16) context.user_index,
        core_index   = 0,
    }
}

@require_results
record_debug_event_common :: #force_inline proc (type: DebugEventType, record_index: u32) -> (event: ^DebugEvent) {
    when DebugTimingDisabled do return
    
    events := transmute(DebugEventsState) atomic_add(cast(^u64) &GlobalDebugTable.events_state, 1)
    event = &GlobalDebugTable.events[events.array_index][events.events_index]
    event^ = {
        type         = type,
        clock        = read_cycle_counter(),
        record_index = record_index,
    }
    
    return event
}

////////////////////////////////////////////////
// HashTable Implementation for the DebugRecords
//   TODO(viktor): as all the hashes of the source code locations
//   are known at compile time, it should be possible to bake these 
//   into the table and hash O(1) retrieval and storage.
//   This would require the build script to aggregate all the 
//   invocations of of timed_block() and generate a hash for each
//   and insert it into the source code.
//
//   The language default map type is not thread-safe.
//   This is _not_ a general implementation and assumes
//   a fixed size backing array and will fail if it
//   should "grow".

@(private="file")
NilHashValue :: 0

@(private="file")
find :: proc(ht: ^DebugRecords, value: DebugRecordLocation) -> (result: ^DebugRecord, hash_value, hash_index: u32) {
    hash_value = get_hash(ht, value)
    hash_index = hash_value
    for {
        result = &ht[hash_index]
        if result.hash == NilHashValue || result.hash == hash_value && result.loc == value {
            break
        }
        modular_add(&hash_index, 1 ,len(ht))
        
        if hash_index == hash_value {
            assert(false, "cannot insert")
        }
    }
    return result, hash_value, hash_index
}

@(private="file")
get_hash :: proc(ht: ^DebugRecords, value: DebugRecordLocation) -> (result: u32) {
    result = cast(u32) (313 + value.line * 464) % len(ht)
    
    if result == NilHashValue {
        strings := [2]u32{
            hash.djb2(transmute([]u8) value.file_path),
            hash.djb2(transmute([]u8) value.name),
        }
        bytes := (cast([^]u8) &strings[0])[:size_of(strings)]
        result = hash.djb2(bytes) % len(ht)
        assert(result != NilHashValue)
    }
    
    return result
}

@(private="file")
put :: proc(ht: ^DebugRecords, value: DebugRecordLocation) -> (hash_index: u32) {
    entry: ^DebugRecord
    hash_value: u32
    entry, hash_value, hash_index = find(ht, value)
    
    entry.hash  = hash_value
    entry.index = hash_index
    entry.loc   = value
    
    return hash_index
}

@(private="file")
get :: proc(ht: ^DebugRecords, value: DebugRecordLocation) -> (hash_index: u32, ok: b32) {
    entry: ^DebugRecord
    hash_value: u32
    entry, hash_value, hash_index = find(ht, value)
    
    if entry != nil && entry.hash == hash_value && entry.loc == value {
        return hash_index, true
    } else {
        return NilHashValue, false
    }
}

////////////////////////////////////////////////

DebugStatistic :: struct {
    min, max, avg, count: f64,
}

debug_statistic_begin :: #force_inline proc() -> (result: DebugStatistic) {
    result = {
        min = max(f64),
        max = min(f64),
    }
    return result
}

debug_statistic_accumulate :: #force_inline proc(stat: ^DebugStatistic, value: $N) {
    value := cast(f64) value
    stat.min    = min(stat.min, value)
    stat.max    = max(stat.max, value)
    stat.avg   += value
    stat.count += 1
}

debug_statistic_end :: #force_inline proc(stat: ^DebugStatistic) {
    if stat.count == 0 {
        stat.min = 0
        stat.max = 0
        stat.avg = 0
    } else {
        stat.avg /= stat.count
    }
}