package game

import "base:intrinsics"

import "core:fmt"

/*
    ////////////////////////////////////////////////
    
    - Anywhere in the code debug events can be cheaply registered
    - This is a thread safe operation
    - At the end of the frame we collate all these events 
    - To track data we collect events of interest into elements
    - an element keep a history of values
    
    ////////////////////////////////////////////////
*/

// TODO(viktor): "Mark Loop Point" as debug action
// TODO(viktor): pause/unpause profiling

// @Idea Memory Debugger with tracking allocator and maybe a 
// tree graph to visualize the size of the allocated types and 
// such in each arena?Maybe a table view of largest entries or 
// most entries of a type.

GlobalDebugMemory: ^GameMemory
GlobalDebugTable: ^DebugTable

DebugMaxEventsCount :: 5_000_000 when DebugEnabled else 0


////////////////////////////////////////////////

DebugState :: struct {
    initialized: b32,
    paused:      b32,
    
    arena: Arena,

    total_frame_count: u32,
    frame_count:       u32,

    frames: Deque(DebugFrame),

    collation_frame:  ^DebugFrame,
    
    thread:            ^DebugThread,
    first_free_thread: ^DebugThread,
    
    element_hash: [1024]^DebugElement,
    
    root_group:    ^DebugEventGroup,
    profile_group: ^DebugEventGroup,
    
    view_hash:     [4096]^DebugView,
    tree_sentinel: DebugTree,
    
    selected_count: u32,
    selected_ids:   [64]DebugId,
    
    alt_ui:               b32,
    last_mouse_p:         v2,
    interaction:          DebugInteraction,
    hot_interaction:      DebugInteraction,
    next_hot_interaction: DebugInteraction,
    
    menu_p:       v2,
    profile_on:   b32,
    framerate_on: b32,
    
    // Overlay rendering
    render_group: RenderGroup,
    
    text_transform:    Transform,
    shadow_transform:  Transform,
    backing_transform: Transform,
    
    font_scale:   f32,
    top_edge:     f32,
    ascent:       f32,
    left_edge:    f32,
    right_edge:   f32,
    
    font_id:      FontId,
    font:         ^Font,
    font_info:    ^FontInfo,
    
    // Per-frame storage management
    per_frame_arena:         Arena,
    first_free_frame:        ^DebugFrame,
    first_free_stored_event: ^DebugStoredEvent,
}

DebugFrame :: #type SingleLinkedList(DebugFrameLink)
DebugFrameLink :: struct {
    root_profile_node: ^DebugStoredEvent,
    frame_index: u32,
    
    begin_clock,
    end_clock:       i64,
    seconds_elapsed: f32,
    
    stored_event_count:  u32,
    profile_block_count: u32,
    data_block_count:    u32,
}

// TODO(viktor): Remove this its no longer used
DebugRegion :: struct {
    event:        ^DebugEvent,
    cycle_count:  i64,
    lane_index:   u32,
    t_min, t_max: f32,
}

DebugThread :: #type SingleLinkedList(DebugThreadLink)
DebugThreadLink :: struct {
    thread_index: u16,
    
    first_free_block:       ^DebugOpenBlock,
    first_open_timed_block: ^DebugOpenBlock,
    first_open_data_block:  ^DebugOpenBlock,
}

DebugOpenBlock :: struct {
    using next: struct #raw_union {
        parent, 
        next_free:     ^DebugOpenBlock,
    },
    
    frame_index: u32,
    begin_clock: i64,
    element: ^DebugElement,
    
    event: ^DebugStoredEvent,
    
    group: ^DebugEventGroup,
}

////////////////////////////////////////////////

#assert(size_of(DebugEventLinkData) == 16)
#assert(size_of(DebugEventLink) == 32)
#assert(size_of(DebugEventGroup) == 48)
#assert(size_of(DebugValue) == 56)
#assert(size_of(DebugGUID) == 56)
#assert(size_of(DebugEvent) == 128) // !!!!
#assert(size_of(DebugTable) == 1_280_000_144)
DebugTable :: struct {
    edit_event: DebugEvent,
    
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
    // atomically increment the events_index
    events_index: u32 | 32,
    array_index:  u32 | 32,
}

// IMPORTANT TODO(viktor): @Size Compact this, we have a lot of them
DebugEvent :: struct {
    guid: DebugGUID,
    
    clock:        i64,
    thread_index: u16,
    core_index:   u16,
          
    value: DebugValue,
}

DebugValue :: union {
    FrameMarker,
    BeginTimedBlock, EndTimedBlock,
    
    BeginDataBlock, EndDataBlock,
    
    b32, i32, u32, f32,
    v2, v3, v4,
    Rectangle2,Rectangle3,
    
    BitmapId, SoundId, FontId,
    
    ThreadIntervalProfile,
    
    DebugEventLink,
    DebugEventGroup,
}

FrameMarker :: struct {
    seconds_elapsed: f32,
}

BeginTimedBlock :: struct {}
EndTimedBlock   :: struct {}
BeginDataBlock  :: struct {}
EndDataBlock    :: struct {}

ThreadIntervalProfile :: struct {}
Profile :: struct {}

////////////////////////////////////////////////

DebugElement :: #type SingleLinkedList(DebugElementLink)
DebugElementLink :: struct {
    guid:   DebugGUID,
    events: Deque(DebugStoredEvent),
}

DebugStoredEvent :: struct {
    next: ^DebugStoredEvent,
    
    using it: struct #raw_union {
        event: DebugEvent,
        node:  DebugProfileNode,
    },

    frame_index: u32,
    // TODO(viktor): Store call attribution data here?
}

DebugProfileNode :: struct {
    // NOTE(viktor): This cannot be ^DebugElement 
    // because we are still in the midst of defining those types through 
    // the polymorphic structs.
     
    element: ^SingleLinkedList(DebugElementLink),
    
    first_child:      ^DebugStoredEvent,
    next_same_parent: ^DebugStoredEvent,
    
    parent_relative_clock: u32,
    duration:              u32,
    
    thread_index: u16,
    core_index:   u16,
    
    aggregate_count: u32,
    
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

DebugId :: struct {
    value: [2]pmm,
}

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
    os_handle: umm,
}

@common DebugReadEntireFile       :: #type proc(filename: string) -> (result: []u8)
@common DebugWriteEntireFile      :: #type proc(filename: string, memory: []u8) -> b32
@common DebugFreeFileMemory       :: #type proc(memory: []u8)
@common DebugExecuteSystemCommand :: #type proc(directory, command, command_line: string) -> DebugExecutingProcess
@common DebugGetProcessState      :: #type proc(process: DebugExecutingProcess) -> DebugProcessState

////////////////////////////////////////////////

@export
debug_frame_end :: proc(memory: ^GameMemory, input: Input, render_commands: ^RenderCommands) {
    when !DebugEnabled do return
    
    assert(len(memory.debug_storage) >= size_of(DebugState))
    debug := cast(^DebugState) raw_data(memory.debug_storage)
    
    assets, generation_id := debug_get_game_assets_work_queue_and_generation_id(memory)
    if assets == nil do return
    
    if !debug.initialized {
        debug.initialized = true

        // :PointerArithmetic
        total_memory := memory.debug_storage[size_of(DebugState):]
        init_arena(&debug.arena, total_memory)
        
        when !true {
            sub_arena(&debug.per_frame_arena, &debug.arena, 3 * len(total_memory) / 4)
        } else { // NOTE(viktor): use this to test the handling of deallocation and freeing of frames
            sub_arena(&debug.per_frame_arena, &debug.arena, 200 * Kilobyte)
        }
        
        debug.root_group    = create_group(debug, "Root")
        debug.profile_group = create_group(debug, "Profiles")
        
        debug.backing_transform = default_flat_transform()
        debug.shadow_transform  = default_flat_transform()
        debug.text_transform    = default_flat_transform()
        debug.backing_transform.sort_bias = 100_000
        debug.shadow_transform.sort_bias  = 200_000
        debug.text_transform.sort_bias    = 300_000
        
        list_init_sentinel(&debug.tree_sentinel)
        
        debug.font_scale = 0.6

        debug_tree := add_tree(debug, debug.root_group, { debug.left_edge, debug.top_edge })
        
        debug.left_edge  = -0.5 * cast(f32) render_commands.width
        debug.right_edge =  0.5 * cast(f32) render_commands.width
        debug.top_edge   =  0.5 * cast(f32) render_commands.height   
        
        debug_tree.p = { debug.left_edge + 200, debug.top_edge - 50 }
    }
    
    init_render_group(&debug.render_group, assets, render_commands, false, generation_id)
    
    if debug.font == nil {
        debug.font_id = best_match_font_from(assets, .Font, #partial { .FontType = cast(f32) AssetFontType.Debug }, #partial { .FontType = 1 })
        debug.font    = get_font(assets, debug.font_id, debug.render_group.generation_id)
        load_font(debug.render_group.assets, debug.font_id, false)
        debug.font_info = get_font_info(assets, debug.font_id)
        debug.ascent = get_baseline(debug.font_info)
    }

    GlobalDebugTable.current_events_index = GlobalDebugTable.current_events_index == 0 ? 1 : 0 
    events_state := atomic_exchange(&GlobalDebugTable.events_state, { events_index = 0, array_index = GlobalDebugTable.current_events_index})
    
    collate_debug_records(debug, GlobalDebugTable.events[events_state.array_index][:events_state.events_index])
    overlay_debug_info(debug, input)
    
    debug.next_hot_interaction  = {}
    if debug.hot_interaction == {} do GlobalDebugTable.edit_event = {}
    debug.alt_ui = input.alt_down
}

debug_get_state :: proc() -> (result: ^DebugState) {
    if GlobalDebugMemory != nil {
        result = cast(^DebugState) raw_data(GlobalDebugMemory.debug_storage)
    }
    return result
}

////////////////////////////////////////////////

new_frame :: proc(debug: ^DebugState, begin_clock: i64) -> (result: ^DebugFrame) {
    ok: b32
    for result == nil {
        result, ok = list_pop(&debug.first_free_frame)
        if !ok {
            if arena_has_room(&debug.per_frame_arena, DebugFrame) {
                result = push(&debug.per_frame_arena, DebugFrame, no_clear())
            } else {
                free_oldest_frame(debug)
            }
        }
    }
    
    result^ = {
        frame_index = debug.total_frame_count,
        begin_clock = begin_clock,
    }
    
    debug.total_frame_count += 1
    
    return result
}

store_event :: proc(debug: ^DebugState, event: DebugEvent, element: ^DebugElement) -> (result: ^DebugStoredEvent) {
    if debug.root_group == nil do return
    frame_index := debug.collation_frame.frame_index
    debug.collation_frame.stored_event_count += 1
    
    ok: b32
    for result == nil {
        { // NOTE(viktor): inlined list_pop because polymorphic types kinda suck
            head := &debug.first_free_stored_event
            if head^ != nil {
                result = head^
                head^  = result.next
                
                ok = true
            }
        }
        
        if !ok {
            if arena_has_room(&debug.per_frame_arena, DebugStoredEvent) {
                result = push(&debug.per_frame_arena, DebugStoredEvent, no_clear())
            } else {
                free_oldest_frame(debug)
            }
        }
    }
    
    result^ = {
        event       = event,
        frame_index = frame_index,
    }
    
    deque_append(&element.events, result)
    
    return result 
}

free_oldest_frame :: proc(debug: ^DebugState) {
    oldest := deque_remove_from_end(&debug.frames)
    
    if oldest != nil {
        free_frame(debug, oldest)
    }
}

free_frame :: proc(debug: ^DebugState, frame: ^DebugFrame) {
    for element in debug.element_hash {
        for element := element; element != nil; element = element.next {
            for element.events.last != nil && element.events.last.frame_index <= frame.frame_index {
                free_event := deque_remove_from_end(&element.events)
                
                {// NOTE(viktor): inlined list_push(&debug.first_free_stored_event, free_event) because ...
                    head: ^^DebugStoredEvent = &debug.first_free_stored_event
                    element: ^DebugStoredEvent = free_event
                    element.next = head^
                    head^        = element
                }
                
            }
        }
    }
    
    list_push(&debug.first_free_frame, frame)
}

get_hash_from_guid :: proc(guid: DebugGUID) -> (result: u32) {
    // TODO(viktor): BETTER HASH FUNCTION
    for i in 0..<len(guid.name)      do result = result * 65599 + cast(u32) guid.name[i]
    for i in 0..<len(guid.file_path) do result = result * 65599 + cast(u32) guid.file_path[i]
    for i in 0..<len(guid.procedure) do result = result * 65599 + cast(u32) guid.procedure[i]
    
    return result
}

get_element_from_event :: proc { get_element_from_event_by_hash, get_element_from_event_by_parent }
get_element_from_event_by_hash :: proc (debug: ^DebugState, event: DebugEvent, hash_value: u32) -> (result: ^DebugElement) {
    assert(hash_value != 0)

    index := hash_value % len(debug.element_hash)
    
    for chain := debug.element_hash[index]; chain != nil; chain = chain.next {
        guids_are_equal := true
        
        if guids_are_equal && chain.guid.line      != event.guid.line      do guids_are_equal = false
        if guids_are_equal && chain.guid.column    != event.guid.column    do guids_are_equal = false
        if guids_are_equal && chain.guid.name      != event.guid.name      do guids_are_equal = false
        if guids_are_equal && chain.guid.file_path != event.guid.file_path do guids_are_equal = false
        if guids_are_equal && chain.guid.procedure != event.guid.procedure do guids_are_equal = false
        
        if guids_are_equal {
            result = chain
            break
        }
    }
    
    return result
}
get_element_from_event_by_parent :: proc(debug: ^DebugState, event: DebugEvent, parent: ^DebugEventGroup = nil, create_hierarchy: b32 = true) -> (result: ^DebugElement) {
    assert(event.guid != {})
    
    hash_value := get_hash_from_guid(event.guid)
    
    result = get_element_from_event(debug, event, hash_value)
    
    if result == nil {
        result = push(&debug.arena, DebugElement)
        result.guid = DebugGUID {
            line      = event.guid.line,
            column    = event.guid.column,
            name      = copy_string(&debug.arena, event.guid.name),
            file_path = copy_string(&debug.arena, event.guid.file_path),
            procedure = copy_string(&debug.arena, event.guid.procedure),
        }

        index := hash_value % len(debug.element_hash)
        list_push(&debug.element_hash[index], result)

        parent := parent
        if parent == nil do parent = debug.root_group
        
        parent_group := parent
        if create_hierarchy do parent_group = get_group_by_hierarchical_name(debug, parent, event.guid.name, false)
        
        add_element_to_group(debug, parent_group, result)
    }
    
    return result
}

collate_debug_records :: proc(debug: ^DebugState, events: []DebugEvent) {
    timed_function()
    
    collation_frame := debug.collation_frame
    if collation_frame != nil {
        collation_frame.data_block_count = 0
        collation_frame.stored_event_count = 0
        collation_frame.profile_block_count = 0
    }
    
    for &event in events {
        if collation_frame == nil {
            debug.collation_frame = new_frame(debug, event.clock)
            collation_frame = debug.collation_frame
        }
        assert(collation_frame != nil)
        
        thread: ^DebugThread
        for thread = debug.thread; thread != nil && thread.thread_index != event.thread_index; thread = thread.next {}
        
        if thread == nil {
            thread = list_pop(&debug.first_free_thread) or_else push(&debug.arena, DebugThread, no_clear())
            thread^ = { thread_index = event.thread_index }
            
            list_push(&debug.thread, thread)
        }
        assert(thread.thread_index == event.thread_index)
        
        frame_index := debug.collation_frame.frame_index
        default_parent_group := debug.root_group
        if thread.first_open_data_block != nil {
            default_parent_group = thread.first_open_data_block.group
        }
        
        switch value in event.value {
          case FrameMarker:
            collation_frame.end_clock       = event.clock
            collation_frame.seconds_elapsed = value.seconds_elapsed
            
            if collation_frame.root_profile_node != nil {
                collation_frame.root_profile_node.node.duration = cast(u32) (collation_frame.end_clock - collation_frame.begin_clock)
            }
            
            if debug.paused {
                free_frame(debug, collation_frame)
            } else {
                deque_append(&debug.frames, collation_frame)
            }
            
            debug.collation_frame = new_frame(debug, event.clock)
            collation_frame = debug.collation_frame
            collation_frame.root_profile_node = {}
            assert(debug.collation_frame != nil)
            
          case BeginDataBlock:
            collation_frame.data_block_count += 1
            
            if default_parent_group != nil {
                block := alloc_open_block(debug, thread, frame_index, event.clock, &thread.first_open_data_block, nil)
                group := get_group_by_hierarchical_name(debug, default_parent_group, event.guid.name, true)
                block.group = group
            }
            
          case ThreadIntervalProfile, DebugEventLink, DebugEventGroup,
            BitmapId, SoundId, FontId, 
            b32, f32, u32, i32, 
            v2, v3, v4, 
            Rectangle2, Rectangle3:
            
            element := get_element_from_event(debug, event, default_parent_group)
            store_event(debug, event, element)
            
          case EndDataBlock:
            matching_block := thread.first_open_data_block
            if matching_block != nil {
                free_open_block(thread, &thread.first_open_data_block)
            }
            
          case BeginTimedBlock:
            collation_frame.profile_block_count += 1
            
            element := get_element_from_event(debug, event, parent = debug.profile_group, create_hierarchy = false)
            
            parent_event: ^DebugStoredEvent
            clock_basis := collation_frame.begin_clock
            if thread.first_open_timed_block != nil && thread.first_open_timed_block.event != nil {
                clock_basis = thread.first_open_timed_block.begin_clock
                parent_event = thread.first_open_timed_block.event
            } else {
                if collation_frame.root_profile_node == nil {
                    collation_frame.root_profile_node = store_event(debug, {}, element)
                }
                parent_event = collation_frame.root_profile_node
                clock_basis = collation_frame.begin_clock
            }
            
            stored_event := store_event(debug, event, element)
            node := &stored_event.node
            node^ = {
                element = element,
                parent_relative_clock = cast(u32) (event.clock - clock_basis),
                
                thread_index = thread.thread_index,
                core_index   = event.core_index,
            }
            
            node.next_same_parent = parent_event.node.first_child
            parent_event.node.first_child = stored_event
            
            block := alloc_open_block(debug, thread, frame_index, event.clock, &thread.first_open_timed_block, element)
            block.event = stored_event
            
          case EndTimedBlock:
            matching_block := thread.first_open_timed_block
            if matching_block != nil {
                assert(thread.thread_index == event.thread_index)
                
                assert(matching_block.event != nil)
                node := &matching_block.event.node
                assert(node != nil)
                
                node.duration = cast(u32) (event.clock - matching_block.begin_clock)
                node.aggregate_count += 1
                free_open_block(thread, &thread.first_open_timed_block)
            }
        }
    }
}

alloc_open_block :: proc(debug: ^DebugState, thread: ^DebugThread, frame_index: u32, begin_clock: i64, parent: ^^DebugOpenBlock, element: ^DebugElement) -> (result: ^DebugOpenBlock) {
    result = thread.first_free_block
    if result != nil {
        thread.first_free_block = result.next_free
    } else {
        result = push(&debug.arena, DebugOpenBlock, no_clear())
        result = result
    }
    
    result ^= {
        frame_index = frame_index,
        begin_clock = begin_clock,
        element     = element,
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

////////////////////////////////////////////////

overlay_debug_info :: proc(debug: ^DebugState, input: Input) {
    if debug.render_group.assets == nil do return

    orthographic(&debug.render_group, {debug.render_group.commands.width, debug.render_group.commands.height}, 1)

    mouse_p := unproject_with_transform(debug.render_group.camera, default_flat_transform(), input.mouse.p).xy
    draw_main_menu(debug, input, mouse_p)
    debug_interact(debug, input, mouse_p)
    
    if ShowFramerate && debug.frames.first != nil {
        debug_push_text_line(debug, fmt.tprintf("Last Frame time: %5.4f ms", debug.frames.first.seconds_elapsed*1000))
        debug_push_text_line(debug, fmt.tprintf("Remaining Frame memory: %m", cast(u64) len(debug.per_frame_arena.storage) - debug.per_frame_arena.used))
        debug_push_text_line(debug, fmt.tprintf("Stored Events / Frame: %v", debug.collation_frame.stored_event_count))
        debug_push_text_line(debug, fmt.tprintf("Data Blocks / Frame: %v", debug.collation_frame.data_block_count))
        debug_push_text_line(debug, fmt.tprintf("Profile Blocks / Frame: %v", debug.collation_frame.profile_block_count))
    }
}

debug_draw_profile :: proc (layout: ^Layout, mouse_p: v2, rect: Rectangle2, root: ^DebugStoredEvent) {
    debug := layout.debug
    {
        color := Black
        color.a = 0.7
        push_rectangle(&layout.debug.render_group, rect, debug.backing_transform, color)
    }
    
    frame_span := cast(f32) (root.node.duration)
    pixel_span := rectangle_get_dimension(rect).x
    
    frame_scale := safe_ratio_0(pixel_span, frame_span)
    
    lane_count :f32= 1 // cast(f32) frame.frame_bar_lane_count
    
    lane_height := safe_ratio_0(rectangle_get_dimension(rect).y, lane_count)
    
    for event := root.node.first_child; event != nil; event = event.node.next_same_parent {
        node := event.node
        defer {
            // if node == nil do node = node.first_child
        }
        
        element : ^DebugElement = node.element
        assert(element != nil)
        
        x_min := rect.min.x + frame_scale * cast(f32) node.parent_relative_clock
        x_max := x_min      + frame_scale * cast(f32) node.duration
        
        lane_index := cast(f32) node.thread_index
        
        region_rect := rectangle_min_max(
            v2{x_min, rect.max.y - lane_height * (lane_index+1)},
            v2{x_max, rect.max.y - lane_height * (lane_index+0)},
        )
        
        color_wheel := color_wheel
        color_index := cast(umm) element % len(color_wheel)
        color := color_wheel[color_index]
        
        if rectangle_has_area(region_rect) {
            push_rectangle(&layout.debug.render_group, region_rect, debug.shadow_transform, color)
            
            if rectangle_contains(region_rect, mouse_p) {
                text := fmt.tprintf("%s - %d cycles [%s:% 4d]", element.guid.name, node.duration, element.guid.file_path, element.guid.line)
                debug_push_text(debug, text, mouse_p)
            }
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
        
        // Maybe change the target
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

debug_interact :: proc(debug: ^DebugState, input: Input, mouse_p: v2) {
    mouse_dp := mouse_p - debug.last_mouse_p
    defer debug.last_mouse_p = mouse_p
    
    interaction := &debug.interaction
    if interaction.kind != .None {
        // Mouse move interaction
        event: ^DebugEvent
        
        if element, ok := interaction.target.(^DebugElement); ok do event = &element.events.first.event
        
        switch interaction.kind {
          case .None: 
            unreachable()
            
          case .NOP, .AutoDetect, .ToggleValue, .ToggleExpansion:
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

debug_end_click_interaction :: proc(debug: ^DebugState, input: Input) {
    interaction := &debug.interaction
    defer interaction^ = {}
    
    switch interaction.kind {
      case .None: 
        unreachable()
      
      case .NOP, .Move, .Resize, .AutoDetect, .Select, .DragValue:
        // NOTE(viktor): nothing
      
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

debug_id_from_link :: proc(tree: ^DebugTree, link: ^DebugEventLink) -> (result: DebugId) {
    result.value[0] = tree
    result.value[1] = link
    return result
}

debug_id_from_guid :: proc(tree: ^DebugTree, guid: ^DebugGUID) -> (result: DebugId) {
    result.value[0] = tree
    result.value[1] = guid
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

draw_main_menu :: proc(debug: ^DebugState, input: Input, mouse_p: v2) {
    assert(debug.font_info != nil)
    
    stack: Stack([64]DebugEventInterator)
    for tree := debug.tree_sentinel.next; tree != &debug.tree_sentinel; tree = tree.next {
        layout := Layout {
            debug        = debug,
            mouse_p      = mouse_p,
            
            p            = tree.p,
            depth        = 0,
            line_advance = get_line_advance(debug.font_info) * debug.font_scale,
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
            push_rectangle(&debug.render_group, move_handle, debug.text_transform, interaction_is_hot(debug, move_interaction) ? Blue : White)
        
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
            block, ok := &view.kind.(DebugViewBlock)
            if !ok {
                view.kind = DebugViewBlock{}
                block = &view.kind.(DebugViewBlock)
                block.size = {80, 60}
            }
            
            element := begin_ui_element_rectangle(layout, &block.size)
            make_ui_element_resizable(&element)
            // TODO(viktor): reenable pausing the profiler
            // pause := DebugInteraction{
            //     kind   = .ToggleValue,
            //     id     = id,
            //     target = event,
            // }
            // set_ui_element_default_interaction(&element, pause)
            end_ui_element(&element, true)
            
            frame := debug.frames.first
            if frame != nil && frame.root_profile_node != nil {
                debug_draw_profile(layout, mouse_p, element.bounds, frame.root_profile_node)
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
                push_bitmap(&debug.render_group, value, debug.shadow_transform, bitmap_height, bitmap_offset, use_alignment = false)
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


interaction_is_hot :: proc(debug: ^DebugState, interaction: DebugInteraction) -> (result: b32) {
    result = debug.hot_interaction.id == interaction.id
    return result
}

////////////////////////////////////////////////

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

add_tree :: proc(debug: ^DebugState, root: ^DebugEventGroup, p: v2) -> (result: ^DebugTree) {
    result = push(&debug.arena, DebugTree, no_clear())
    result^ = {
        root = root,
        p = p,
    }
    
    list_insert(&debug.tree_sentinel, result)
    
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

////////////////////////////////////////////////

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
        advance_y := get_line_advance(debug.font_info)
        debug.top_edge -= debug.font_scale * advance_y
    }
}

TextRenderOperation:: enum {
    Measure, Draw, 
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