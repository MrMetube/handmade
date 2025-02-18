package game

import "base:intrinsics"

import "core:reflect"
import "core:fmt"

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
// TODO(viktor): pause/unpause profiling

// @Idea Memory Debugger with tracking allocator and maybe a 
// tree graph to visualize the size of the allocated types and such in each arena?
// Maybe a table view of largest entries or most entries of a type.

DebugEnabled :: INTERNAL

GlobalDebugTable:  DebugTable
GlobalDebugMemory: ^GameMemory
DebugMaxEventsCount     :: 500_000 when DebugEnabled else 0
DebugMaxRegionsPerFrame :: 15000   when DebugEnabled else 0

////////////////////////////////////////////////

DebugState :: struct {
    inititalized: b32,
    paused:       b32,
    debug_arena:  Arena,

    frame_count:       i32,
    oldest_frame:      ^DebugFrame,
    most_recent_frame: ^DebugFrame,
    first_free_frame:  ^DebugFrame,

    collation_frame:  ^DebugFrame,
    
    thread:            ^DebugThread,
    first_free_thread: ^DebugThread,
    
    scope_to_record: string,

    debug_values:  ^DebugEvent,
    root_group:    ^DebugEvent,
    view_hash:     [4096]^DebugView,
    tree_sentinel: DebugTree,
    
    selected_count: u32,
    selected_ids:   [64]DebugId,
    
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
    top_edge:     f32,
    ascent:       f32,
    left_edge:    f32,
    right_edge:   f32,
    
    font_id:      FontId,
    font:         ^Font,
    font_info:    ^FontInfo,
    
    //
    dump_depth: u32,
}

DebugFrame :: #type SingleLinkedList(DebugFrameLink)
DebugFrameLink :: struct {
    begin_clock,
    end_clock:       i64,
    seconds_elapsed: f32,
    // :Expandable
    region_count:    u32,
    regions:         []DebugRegion,
    
    root: ^DebugEvent,
    
    frame_bar_lane_count: u32,
}

DebugRegion :: struct {
    event:        ^DebugEvent,
    cycle_count:  i64,
    lane_index:   u32,
    t_min, t_max: f32,
}

DebugThread :: #type SingleLinkedList(DebugThreadLink)
DebugThreadLink :: struct {
    thread_index:     u16,
    
    first_free_block:      ^DebugOpenBlock,
    first_open_code_block: ^DebugOpenBlock,
    first_open_data_block: ^DebugOpenBlock,
}

DebugOpenBlock :: struct {
    frame_index:   i32,
    opening_event: ^DebugEvent,
    group:         ^DebugEvent,
    
    using next : struct #raw_union {
        parent, 
        next_free:     ^DebugOpenBlock,
    }
}

////////////////////////////////////////////////

DebugTable :: struct {
    // @Correctness No attempt is currently made to ensure that the final
    // debug records being written to the event array actually complete
    // their output prior to the swap of the event array index.
    current_events_index: u32,
    events_state:   DebugEventsState,
    events:         [2][DebugMaxEventsCount]DebugEvent,
}

// TODO(viktor): we now only need 1 bit to know the array index
DebugEventsState :: bit_field u64 {
    // @Volatile Later on we transmute this to a u64 to 
    // atomically increment one of the fields
    events_index: u32 | 32,
    array_index:  u32 | 32,
}

@common 
DebugEventLocation :: struct {
    name:         string,
    file_path:    string,
    line:         u32,
}

// TODO(viktor): compact this, we have a lot of them
DebugEvent :: struct {
    loc: DebugEventLocation,
    
    clock:        i64,
    thread_index: u16,
    core_index:   u16,
          
    value: DebugValue,
}

DebugValue :: union {
    MarkEvent,
    
    FrameMarker,
    
    BeginCodeBlock, 
    EndCodeBlock,
    BeginDataBlock, 
    EndDataBlock,
    
    b32,
    i32,
    u32,
    f32,
    v2,
    v3,
    v4,
    Rectangle2,
    Rectangle3,
    
    BitmapId,
    SoundId,
    FontId,
    
    DebugVariableProfile,
    
    DebugEventLink,
    DebugEventGroup,
}

MarkEvent :: struct { event: ^DebugEvent }

FrameMarker :: struct {
    seconds_elapsed: f32,
}

BeginCodeBlock :: struct {}
EndCodeBlock   :: struct {}
BeginDataBlock :: struct { id: rawpointer }
EndDataBlock   :: struct {}

DebugVariableProfile :: struct {}

DebugTree :: #type LinkedList(DebugTreeData)
DebugTreeData :: struct {
    p:    v2,
    root: ^DebugEvent,
}

DebugView :: #type SingleLinkedList(DebugViewData)
DebugViewData :: struct {
    id:   DebugId,
    kind: union {
        DebugViewVariable,
        DebugViewBlock,
        DebugViewCollapsible,
    },
}

DebugViewVariable :: struct {}

DebugViewCollapsible :: struct {
    expanded_always:   b32,
    expanded_alt_view: b32,
}

DebugViewBlock :: struct {
    size: v2,
}

DebugId :: [2]rawpointer

DebugEventGroup :: struct {
    sentinel: DebugEventLink,
}

DebugEventLink :: struct {
    next, prev: ^DebugEventLink,
    event:      ^DebugEvent,
    children:   ^DebugEventGroup,
}

// :LinkedListIteration
DebugEventInterator :: struct {
    link:     ^DebugEventLink,
    sentinel: ^DebugEventLink,
}

////////////////////////////////////////////////

DebugInteraction :: struct {
    id:   DebugId,
    kind: DebugInteractionKind,
    target: union {
        ^DebugEvent, 
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
    
    Select,
}

////////////////////////////////////////////////

@common 
TimedBlock :: struct {
    hit_count: i64,
    loc:       DebugEventLocation, 
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


@common 
DebugCode :: struct {
    read_entire_file:       DebugReadEntireFile,
    write_entire_file:      DebugWriteEntireFile,
    free_file_memory:       DebugFreeFileMemory,
    execute_system_command: DebugExecuteSystemCommand,
    get_process_state:      DebugGetProcessState,
}

@common 
DebugProcessState :: struct {
    started_successfully: b32,
    is_running:           b32,
    return_code:          i32,
}

@common
DebugExecutingProcess :: struct {
    os_handle: uintpointer,
}

@common DebugReadEntireFile       :: #type proc(filename: string) -> (result: []u8)
@common DebugWriteEntireFile      :: #type proc(filename: string, memory: []u8) -> b32
@common DebugFreeFileMemory       :: #type proc(memory: []u8)
@common DebugExecuteSystemCommand :: #type proc(directory, command, command_line: string) -> DebugExecutingProcess
@common DebugGetProcessState      :: #type proc(process: DebugExecutingProcess) -> DebugProcessState

////////////////////////////////////////////////

@export
debug_frame_end :: proc(memory: ^GameMemory, buffer: Bitmap, input: Input) {
    when !INTERNAL do return
    assert(len(memory.debug_storage) >= size_of(DebugState))
    debug := cast(^DebugState) raw_data(memory.debug_storage)
    
    assets, work_queue := debug_get_game_assets_and_work_queue(memory)
    if !debug.inititalized {
        debug.inititalized = true

        // :PointerArithmetic
        init_arena(&debug.debug_arena, memory.debug_storage[size_of(DebugState):])
        
        debug.debug_values = create_event_group(debug, "Values Root")
        
        debug.root_group = create_event_group(debug, "Root")
        debug_append_event_to_group(debug, debug.root_group, debug_create_event(&debug.debug_arena, DebugVariableProfile{}, "Profile"))
        
        list_init_sentinel(&debug.tree_sentinel)
        
        debug.font_scale = 0.6

        debug.work_queue = work_queue
        debug.buffer     = buffer
        
        
        debug.left_edge  = -0.5 * cast(f32) buffer.width
        debug.right_edge =  0.5 * cast(f32) buffer.width
        debug.top_edge   =  0.5 * cast(f32) buffer.height
        
        debug_add_tree(debug, debug.root_group, { debug.left_edge, debug.top_edge })
    }
    
    if debug.render_group == nil {
        debug.render_group = make_render_group(&debug.debug_arena, assets, 32 * Megabyte, false)
        assert(debug.render_group != nil)
    }
    assert(!debug.render_group.inside_render)

    if debug.font == nil {
        debug.font_id = best_match_font_from(assets, .Font, #partial { .FontType = cast(f32) AssetFontType.Debug }, #partial { .FontType = 1 })
        debug.font    = get_font(assets, debug.font_id, debug.render_group.generation_id)
        load_font(debug.render_group.assets, debug.font_id, false)
        debug.font_info = get_font_info(assets, debug.font_id)
        debug.ascent = get_baseline(debug.font_info)
    }
        
    begin_render(debug.render_group)

    events_state := atomic_exchange(&GlobalDebugTable.events_state, { events_index = 0, array_index = GlobalDebugTable.current_events_index == 0 ? 1 : 0 })

    collate_debug_records(debug, GlobalDebugTable.events[events_state.array_index][:events_state.events_index])

    overlay_debug_info(debug, input)
    
    tiled_render_group_to_output(debug.work_queue, debug.render_group, debug.buffer)
    end_render(debug.render_group)
    
    debug.next_hot_interaction = {}
}

debug_get_state :: proc() -> (result: ^DebugState) {
    result = cast(^DebugState) raw_data(GlobalDebugMemory.debug_storage)
    return result
}

debug_dump_var :: proc(debug: ^DebugState, a: any) {
    prefix : string
    for _ in 0..<debug.dump_depth {
        prefix = fmt.tprint(prefix, "    ", sep="")
    }
    
    data, type := a.data, a.id
    info := type_info_of(type)
    
    if reflect.is_struct(info) || reflect.is_raw_union(info) {
        for field in reflect.struct_fields_zipped(type) {
            field := field
            field_buffer := fmt.tprint(prefix, field.name, " =", sep="")
            base_len := len(field_buffer)
            manually: b32
            
            member_pointer :rawpointer= &(cast([^]u8) data)[field.offset]
            switch reflect.type_info_base(field.type) {
              case type_info_of(string):
                value := cast(^string) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(u8):
                value := cast(^u8) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(u16):
                value := cast(^u16) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(u32):
                value := cast(^u32) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(u64):
                value := cast(^u32) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(i32):
                value := cast(^i32) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(i64):
                value := cast(^i64) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(f32):
                value := cast(^f32) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(b32):
                value := cast(^b32) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(v2):
                value := cast(^v2) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(v3):
                value := cast(^v3) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case type_info_of(v4):
                value := cast(^v4) member_pointer
                field_buffer = fmt.tprint(field_buffer, value^)
              case:
                if reflect.is_enum(field.type) {
                    names := reflect.enum_field_names(field.type.id)
                    value := (cast(^u64) member_pointer)^
                    if value < auto_cast len(names) {
                        field_buffer = fmt.tprint(field_buffer, names[value])
                    }
                } else if reflect.is_bit_set(field.type) {
                    // TODO(viktor):  
                } else if reflect.is_pointer(field.type) {
                    field_buffer = fmt.tprint(field_buffer, member_pointer)
                    bogus := cast(^^u8) member_pointer
                    
                    if bogus^ != nil {
                        // @Copypasta from below
                        debug.dump_depth += 1
                        defer debug.dump_depth -= 1
                        
                        
                        debug_push_text_line(debug, fmt.tprint(prefix, field.name, ":", sep=""))
                        raw_any :: struct{data:rawpointer, type:typeid}
                        debug_dump_var(debug, transmute(any) raw_any{member_pointer, field.type.id})
                        manually = true
                    }
                } else {
                    debug.dump_depth += 1
                    defer debug.dump_depth -= 1
                    
                    if struct_named, ok := field.type.variant.(reflect.Type_Info_Named); ok {
                        debug_push_text_line(debug, fmt.tprint(prefix, field.name, " :", struct_named.name, sep=""))
                    } else {
                        debug_push_text_line(debug, fmt.tprint(prefix, field.name, ":", sep=""))
                    }
                    
                    raw_any :: struct{data:rawpointer, type:typeid}
                    debug_dump_var(debug, transmute(any) raw_any{member_pointer, field.type.id})
                    manually = true
                }
            }
            
            if len(field_buffer) != base_len {
                debug_push_text_line(debug, field_buffer)
            } else if !manually {
                if named, ok := field.type.variant.(reflect.Type_Info_Named); ok {
                    debug_push_text_line(debug, fmt.tprint("TODO: ", prefix, field.name, " = ", named.name, sep=""))
                } else {
                    debug_push_text_line(debug, fmt.tprint("TODO: ", prefix, field.name, sep=""))
                }
            }
        }
    } else if reflect.is_array(info) || reflect.is_slice(info) {
        debug.dump_depth += 1
        defer debug.dump_depth -= 1
        
        too_many: b32
        it: int
        for e in reflect.iterate_array(a, &it) {
            debug_dump_var(debug, e)
            if it > 3 {
                too_many = true
                break
            }
        }
        if too_many {
            debug_push_text_line(debug, fmt.tprint(prefix, "...", sep=""))
        }
    } else {
        // TODO(viktor): bitfield
        if named, ok := info.variant.(reflect.Type_Info_Named); ok {
            debug_push_text_line(debug, fmt.tprint(prefix,"TODO: ", named.name, sep=""))
        }
    }
}

////////////////////////////////////////////////

new_frame :: proc(debug: ^DebugState, begin_clock: i64) -> (result: ^DebugFrame) {
    // TODO(viktor): simplify this once regions are more reasonable
    ok: b32
    if result, ok = list_pop(&debug.first_free_frame); ok {
        result^ = { regions = result.regions }
    } else {
        result = push(&debug.debug_arena, DebugFrame)
        result.regions = push(&debug.debug_arena, DebugRegion, DebugMaxRegionsPerFrame)
    }
    
    result.begin_clock = begin_clock
    result.root        = create_event_group(debug, "Frame Root")
    
    return result
}

free_frame :: proc(debug: ^DebugState, frame: ^DebugFrame) {
    // TODO(viktor): free(root_group)
    list_push(&debug.first_free_frame, frame)
}

collate_debug_records :: proc(debug: ^DebugState, events: []DebugEvent) {
    // @Hack why should this need to be reset? Think dont guess
    // for &thread in debug.threads do thread.first_open_code_block = nil
    
    for &event in events {
        collation_frame := debug.collation_frame
        if collation_frame == nil {
            debug.collation_frame = new_frame(debug, event.clock)
        }
        
        thread: ^DebugThread
        for thread = debug.thread; thread != nil && thread.thread_index != event.thread_index; thread = thread.next {}
        if thread == nil {
            thread = list_pop(&debug.first_free_thread) or_else push(&debug.debug_arena, DebugThread)
            thread.thread_index = event.thread_index
            list_push(&debug.thread, thread)
        }
        assert(thread != nil)
        assert(thread.thread_index == event.thread_index)
        
        frame_index := debug.frame_count - 1
        
        switch value in event.value {
          case FrameMarker:
            collation_frame.end_clock = event.clock
            collation_frame.seconds_elapsed = value.seconds_elapsed
            
            if debug.paused {
                free_frame(debug, collation_frame)
            } else {
                if debug.most_recent_frame != nil {
                    list_push(&debug.most_recent_frame, collation_frame)
                } else {
                    debug.most_recent_frame = collation_frame
                    debug.oldest_frame      = collation_frame
                }
            }
            
            debug.collation_frame = new_frame(debug, event.clock)
            
          case MarkEvent:
            debug_append_event_to_group(debug, get_group_by_hierarchical_name(debug, value.event.loc.name), value.event)
            
          case BeginCodeBlock:
            alloc_open_block(debug, thread, frame_index, &event, &thread.first_open_code_block)

          case BeginDataBlock:
            block := alloc_open_block(debug, thread, frame_index, &event, &thread.first_open_data_block)
            block.group = create_event_group(debug, event.loc.name)
            parent := block.parent != nil? block.parent.group : collation_frame.root
            link := debug_append_event_to_group(debug, parent, &event)
            link.children = &block.group.value.(DebugEventGroup)
            link.event = &event
            
          case DebugVariableProfile,
            DebugEventLink, DebugEventGroup,
            BitmapId, SoundId, FontId, 
            b32, f32, u32, i32, 
            v2, v3, v4, 
            Rectangle2, Rectangle3:
               
            if thread.first_open_data_block != nil {
               group := thread.first_open_data_block.group
                
                if group != nil {
                    debug_append_event_to_group(debug, group, &event)
                }
            }
            
          case EndDataBlock:
            matching_block := thread.first_open_data_block
                if matching_block != nil {
                free_open_block(thread, &thread.first_open_data_block)
            }
            
          case EndCodeBlock:
            matching_block := thread.first_open_code_block
            if matching_block != nil {
                opening_event := matching_block.opening_event
                if events_match(&event, opening_event) {
                    defer free_open_block(thread, &thread.first_open_code_block)
                    
                    if matching_block.frame_index == frame_index {
                        matching_name := ""
                        if matching_block.parent != nil do matching_name = matching_block.parent.opening_event.loc.name
                        
                        if matching_name == debug.scope_to_record {
                            t_min := cast(f32) (opening_event.clock - debug.collation_frame.begin_clock)
                            t_max := cast(f32) (event.clock - debug.collation_frame.begin_clock)
                            
                            threshold :: 0.001
                            if t_max - t_min > threshold {
                                region := &debug.collation_frame.regions[debug.collation_frame.region_count]
                                debug.collation_frame.region_count += 1
                                
                                region^ = {
                                    event       = &event,
                                    cycle_count = event.clock - opening_event.clock,
                                    lane_index  = cast(u32) event.thread_index,
                                    
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
                } else {
                    // TODO(viktor): Record span that goes to the beginning of the frame
                }
            }
        }
    }
}

alloc_open_block :: proc(debug: ^DebugState, thread: ^DebugThread, frame_index: i32, opening_event: ^DebugEvent, parent: ^^DebugOpenBlock) -> (result: ^DebugOpenBlock) {
    result = thread.first_free_block
    if result != nil {
        thread.first_free_block = result.next_free
    } else {
        result = push(&debug.debug_arena, DebugOpenBlock)
    }
    
    result ^= {
        frame_index   = frame_index,
        opening_event = opening_event,
    }
    
    result.parent = parent^
    parent^ = result
    
    return result
}

free_open_block :: proc(thread: ^DebugThread, first_open: ^^DebugOpenBlock) {
    free_block := first_open^
    free_block.next_free    = thread.first_free_block
    thread.first_free_block = free_block
    
    first_open^ = free_block.parent
}

events_match :: proc(a, b: ^DebugEvent) -> (result: b32) {
    result = b != nil && b.loc.name == a.loc.name
    return result
}

////////////////////////////////////////////////

overlay_debug_info :: proc(debug: ^DebugState, input: Input) {
    if debug.render_group == nil do return

    orthographic(debug.render_group, {debug.buffer.width, debug.buffer.height}, 0.75)

    if debug.compiling {
        state := Platform.debug.get_process_state(debug.compiler)
        if state.is_running {
            debug_push_text_line(debug, "Recompiling...")
        } else {
            fmt.println("ERROR: failed to recompile")
            debug.compiling = false
        }
    }

    mouse_p := unproject_with_transform(debug.render_group.transform, input.mouse.p).xy
    debug_main_menu(debug, input, mouse_p)
    debug_interact(debug, input, mouse_p)
    
    if debug_value(b32, "ShowFramerate") && debug.most_recent_frame != nil {
        debug_push_text_line(debug, fmt.tprintf("Last Frame time: %5.4f ms", debug.most_recent_frame.seconds_elapsed*1000))
    }
}

debug_draw_profile :: proc (debug: ^DebugState, input: Input, mouse_p: v2, rect: Rectangle2) {
    push_rectangle(debug.render_group, Rect3(rect, 0, 0), DarkBlue )
    
    target_fps :: 72
    frame_count := cast(f32) debug.frame_count
    bar_padding :: 1

    lane_count: f32
    frame_bar_scale :: 1. / 60_000_000.
    for frame := debug.oldest_frame; frame != nil; frame = frame.next {
        lane_count = max(lane_count, cast(f32) frame.frame_bar_lane_count + 1)
    }
    
    hot_region: ^DebugRegion
    frame_index: u32
    for frame := debug.oldest_frame; frame != nil; frame = frame.next {
        defer frame_index += 1

        lane_height :f32
        if frame_count > 0 && lane_count > 0 {
            lane_height = ((rectangle_get_diameter(rect).y / frame_count) - bar_padding) / lane_count
        }
        
        bar_height       := lane_height * lane_count
        bar_plus_spacing := bar_height + bar_padding
        
        chart_left  := rect.min.x
        chart_top   := rect.max.y - bar_plus_spacing
        chart_width := rectangle_get_diameter(rect).x
        
        scale := frame_bar_scale * chart_width
        
        stack_x := chart_left
        stack_y := chart_top - bar_plus_spacing * cast(f32) frame_index
        for &region in frame.regions[:frame.region_count] {
            
            x_min := stack_x + scale * region.t_min
            x_max := stack_x + scale * region.t_max

            y_min := stack_y + lane_height * cast(f32) region.lane_index
            y_max := y_min + lane_height - bar_padding
            stack_rect := rectangle_min_max(v2{x_min, y_min}, v2{x_max, y_max})
            
            color_wheel := color_wheel
            event := region.event
            color_index := event.loc.line % len(color_wheel)
            color := color_wheel[color_index]
                        
            push_rectangle(debug.render_group, stack_rect, color)
            if rectangle_contains(stack_rect, mouse_p) {
                hot_region = &region
                
                text := fmt.tprintf("%s - %d cycles [%s:% 4d]", event.loc.name, region.cycle_count, event.loc.file_path, event.loc.line)
                debug_push_text(debug, text, mouse_p)
            }
        }
    }
    
    if was_pressed(input.mouse.left) { // TODO(viktor): This probably wont update the view properly
        if hot_region != nil {
            debug.scope_to_record = hot_region.event.loc.name
            // TODO(viktor): @Cleanup clicking regions and variables at the same time should be handled better
            debug.hot_interaction.kind = .NOP
        } else {
            debug.scope_to_record = ""
        }
    }
}

debug_begin_click_interaction :: proc(debug: ^DebugState, input: Input, alt_ui: b32) {
    if debug.hot_interaction.kind != .None {
        if debug.hot_interaction.kind == .AutoDetect {
            target := debug.hot_interaction.target.(^DebugEvent)
            switch value in target.value {
              case FrameMarker, 
                   MarkEvent,
                   BitmapId, SoundId, FontId,
                   BeginCodeBlock, EndCodeBlock,
                   BeginDataBlock, EndDataBlock,
                   DebugEventGroup,
                   Rectangle2, Rectangle3,
                   u32, i32, v2, v3, v4:
                debug.hot_interaction.kind = .NOP
              case b32:
                debug.hot_interaction.kind = .Toggle
              case f32:
                debug.hot_interaction.kind = .DragValue
              case DebugEventLink, DebugVariableProfile:
                debug.hot_interaction.kind = .Toggle
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
              case ^DebugEvent:
                root_group := create_event_group(debug, "NewUserGroup")
                debug_append_event_to_group(debug, root_group, debug.hot_interaction.target.(^DebugEvent))
                tree := debug_add_tree(debug, root_group, {0, 0})
                debug.hot_interaction.target = &tree.p
              case ^DebugTree:
                unreachable()
            }
            
        }
        
        debug.interaction = debug.hot_interaction
    } else {
        debug.interaction.kind = .NOP
    }
}

debug_interact :: proc(debug: ^DebugState, input: Input, mouse_p: v2) {
    mouse_dp := mouse_p - debug.last_mouse_p
    defer debug.last_mouse_p = mouse_p
    
    alt_ui := input.alt_down
    
    interaction := &debug.interaction
    if interaction.kind != .None {
        // NOTE(viktor): Mouse move interaction
        switch interaction.kind {
          case .None: 
            unreachable()
            
          case .NOP, .AutoDetect, .Toggle:
            // NOTE(viktor): nothing
            
          case .Select:
            if !input.shift_down {
                clear_selection(debug)
            }
            select(debug, interaction.id)
            
          case .DragValue:
            event := interaction.target.(^DebugEvent)
            value := &event.value.(f32)
            value^ += 0.1 * mouse_dp.x
            
          case .Resize:
            value := interaction.target.(^v2)
            value^ += mouse_dp * {1,-1}
            value.x = max(value.x, 10)
            value.y = max(value.y, 10)
          
          case .Move:
            value := interaction.target.(^v2)
            value^ += mouse_dp
            
        }
        
        // NOTE(viktor): Click interaction
        for transition_index := input.mouse.left.half_transition_count; transition_index > 1; transition_index -= 1 {
            debug_end_click_interaction(debug, input)
            debug_begin_click_interaction(debug, input, alt_ui)
        }
        
        if !input.mouse.left.ended_down {
            debug_end_click_interaction(debug, input)
        }
    } else {
        debug.hot_interaction = debug.next_hot_interaction
        
        for transition_index:= input.mouse.left.half_transition_count; transition_index > 1; transition_index -= 1 {
            debug_begin_click_interaction(debug, input, alt_ui)
            debug_end_click_interaction(debug, input)
        }
        
        if input.mouse.left.ended_down {
            debug_begin_click_interaction(debug, input, alt_ui)
        }
    }
}

debug_end_click_interaction :: proc(debug: ^DebugState, input: Input) {
    interaction := &debug.interaction
    defer interaction^ = {}
    
    switch interaction.kind {
      case .None: 
        unreachable()
      
      case .NOP, .Move, .Resize, .AutoDetect, .Select, .DragValue:
        // NOTE(viktor): nothing
      
      case .Toggle:
        target := interaction.target.(^DebugEvent)
        
        #partial switch value in target.value {
          case DebugEventLink:
            view := get_debug_view_for_variable(debug, interaction.id)
            collapsible, ok := &view.kind.(DebugViewCollapsible)
            if !ok {
                view.kind = DebugViewCollapsible{}
                collapsible = &view.kind.(DebugViewCollapsible)
            }
            
            collapsible.expanded_always = !collapsible.expanded_always
          case DebugVariableProfile:
            debug.paused = !debug.paused
          case b32:
            // TODO(viktor): @CompilerBug 
            // Taking ref to value in the switch will cause an infinite loop in the compiler.
            value_ref := &target.value.(b32)
            value_ref^ = !value_ref^
        
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

end_ui_element :: proc(using element: ^LayoutElement, use_spacing: b32) {
    SizeHandlePixels :: 8
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

link_interaction :: #force_inline proc(kind: DebugInteractionKind, tree: ^DebugTree, link: ^DebugEventLink) -> (result: DebugInteraction) {
    result.id = debug_id_from_link(tree, link)
    result.target = link.event
    result.kind = kind
    
    return result
}

debug_id_from_link :: #force_inline proc(tree: ^DebugTree, link: ^DebugEventLink) -> (result: DebugId) {
    result[0] = tree
    result[1] = link
    return result
}

get_debug_view_for_variable :: proc(debug: ^DebugState, id: DebugId) -> (result: ^DebugView) {
    // TODO(viktor): BETTER HASH FUNCTION
    hash_index := ((cast(uintpointer) id[0] >> 2) + (cast(uintpointer) id[1] >> 2)) % len(debug.view_hash)
    slot := &debug.view_hash[hash_index]
    // :LinkedListIteration
    for search := slot^ ; search != nil; search = search.next {
        if search.id == id {
            result = search
            break
        }
    }
    
    if result == nil {
        result = push(&debug.debug_arena, DebugView)
        result.id = id
        list_push(slot, result)
    }
    
    return 
}

debug_main_menu :: proc(debug: ^DebugState, input: Input, mouse_p: v2) {
    if debug.font_info == nil do return
    stack: Stack([128]DebugEventInterator)
    
    // :LinkedListIteration
    for tree := debug.tree_sentinel.next; tree != &debug.tree_sentinel; tree = tree.next {
        layout := Layout {
            debug        = debug,
            mouse_p      = mouse_p,
            
            p            = tree.p,
            depth        = 0,
            line_advance = get_line_advance(debug.font_info) * debug.font_scale,
            spacing_y    = 4,
        }
        
        root := tree.root
        // root = debug.frames[0].root != nil ? debug.frames[0].root : root
        root = debug.debug_values
        
        if root != nil {
            group := &root.value.(DebugEventGroup)
            stack_push(&stack, DebugEventInterator{
                link     = group.sentinel.next,
                sentinel = &group.sentinel,
            })
            
            for stack.depth > 0 {
                iter := stack_peek(&stack)
                if iter.link == iter.sentinel {
                    stack.depth -= 1
                    layout.depth -= 1
                } else {
                    link := iter.link
                    event  := link.event
                    iter.link = link.next
                    
                    autodetect_interaction := link_interaction(.AutoDetect, tree, link)

                    is_hot := debug_interaction_is_hot(debug, autodetect_interaction)
                    
                    text: string
                    color := is_hot ? Blue : White
                    
                    depth_delta: f32
                    defer layout.depth += depth_delta
                    
                    view := get_debug_view_for_variable(debug, debug_id_from_link(tree, link))
                    // TODO(viktor): How can a link not have an event!?
                    if event != nil {
                        switch value in event.value {
                        case SoundId, FontId, 
                            BeginCodeBlock, EndCodeBlock,
                            BeginDataBlock, EndDataBlock,
                            FrameMarker, MarkEvent:
                            // NOTE(viktor): nothing
                        case DebugVariableProfile:
                            block, ok := &view.kind.(DebugViewBlock)
                            if !ok {
                                view.kind = DebugViewBlock{}
                                block = &view.kind.(DebugViewBlock)
                            }
                            
                            element := begin_ui_element_rectangle(&layout, &block.size)
                            make_ui_element_resizable(&element)
                            set_ui_element_default_interaction(&element, autodetect_interaction)
                            end_ui_element(&element, true)
                            
                            debug_draw_profile(debug, input, mouse_p, element.bounds)
                            
                        case BitmapId:
                            block, ok := &view.kind.(DebugViewBlock)
                            if !ok {
                                view.kind = DebugViewBlock{}
                                block = &view.kind.(DebugViewBlock)
                            }
                            
                            if bitmap := get_bitmap(debug.render_group.assets, value, debug.render_group.generation_id); bitmap != nil {
                                dim := get_used_bitmap_dim(debug.render_group, bitmap^, block.size.y, 0, use_alignment = false)
                                block.size = dim.size
                                
                                element := begin_ui_element_rectangle(&layout, &block.size)
                                make_ui_element_resizable(&element)
                                set_ui_element_default_interaction(&element, link_interaction(.Move, tree, link))
                                end_ui_element(&element, true)
                                
                                bitmap_height := block.size.y
                                bitmap_offset := V3(element.bounds.min, 0)
                                push_rectangle(debug.render_group, element.bounds, DarkBlue )
                                push_bitmap(debug.render_group, value, bitmap_height, bitmap_offset, use_alignment = false)
                            }
                            
                        case DebugEventLink, DebugEventGroup,
                            b32, f32, i32, u32, v2, v3, v4, Rectangle2, Rectangle3:
                            if _, ok := &event.value.(DebugEventGroup); ok {
                                collapsible, okc := &view.kind.(DebugViewCollapsible)
                                if !okc {
                                    view.kind = DebugViewCollapsible{}
                                    collapsible = &view.kind.(DebugViewCollapsible)
                                }
                                text = fmt.tprintf("%s %v", collapsible.expanded_always ? "-" : "+", event.loc.name)
                            } else {
                                text = fmt.tprintf("%s %v", event.loc.name, value)
                            }
                            
                            text_bounds := debug_measure_text(debug, text)
                            
                            size := v2{ rectangle_get_diameter(text_bounds).x, layout.line_advance }
                            
                            element := begin_ui_element_rectangle(&layout, &size)
                            set_ui_element_default_interaction(&element, autodetect_interaction)
                            end_ui_element(&element, false)
                            
                            debug_push_text(debug, text, {element.bounds.min.x, element.bounds.max.y - debug.ascent * debug.font_scale}, color)
                        }
                    }
                    
                    if link.children != nil {
                        stack_push(&stack, DebugEventInterator{
                            link     = link.children.sentinel.next,
                            sentinel = &link.children.sentinel,
                        })
                        depth_delta = 1
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
}

debug_interaction_is_hot :: proc(debug: ^DebugState, interaction: DebugInteraction) -> (result: b32) {
    result = debug.hot_interaction == interaction
    return result
}


////////////////////////////////////////////////

get_group_by_hierarchical_name :: proc(debug: ^DebugState, name: string) -> (result: ^DebugEvent) {
    result = debug.debug_values
    return result
}

debug_add_tree :: proc(debug: ^DebugState, root: ^DebugEvent, p: v2) -> (result: ^DebugTree) {
    result = push(&debug.debug_arena, DebugTree)
    result^ = {
        root = root,
        p = p,
    }
    
    list_insert(&debug.tree_sentinel, result)
    
    return result
}

create_event_group :: proc(debug: ^DebugState, name: string) -> (result: ^DebugEvent) {
    result = push(&debug.debug_arena, DebugEvent)
    
    result.value = DebugEventGroup{}
    result.loc.name =  push_string(&debug.debug_arena, name)
    
    group := &result.value.(DebugEventGroup)
    group.sentinel.next = &group.sentinel
    group.sentinel.prev = &group.sentinel
    
    return result
}

debug_create_event :: proc(arena: ^Arena, value: $T, name: string) -> (result: ^DebugEvent) {
    result = push(arena, DebugEvent)
    
    result.value = value
    result.loc.name =  push_string(arena, name)
    
    return result
}

debug_append_event_to_group :: proc(debug: ^DebugState, group: ^DebugEvent, element: ^DebugEvent) -> (result: ^DebugEventLink) {
    result = push(&debug.debug_arena, DebugEventLink)
    assert(element != nil)
    result.event = element
    
    if group != nil {
        value := &group.value.(DebugEventGroup)
        parent  := &value.sentinel
        
        result.prev = parent
        result.next = parent.next
        
        result.next.prev = result
        result.prev.next = result
    }
    
    return result
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