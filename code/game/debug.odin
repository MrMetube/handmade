package game

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

DebugMaxEventCount :: 5_000_000 when DebugEnabled else 0
MaxFrameCount :: 256

////////////////////////////////////////////////

DebugState :: struct {
    initialized: b32,
    paused:      b32,
    
    arena: Arena,

    total_frame_count: i32,
    
    most_recent_frame_ordinal: i32,
    oldest_frame_ordinal_that_is_already_freed:      i32,
    collating_frame_ordinal:   i32,
    frames: [MaxFrameCount]DebugFrame,
    
    thread:            ^DebugThread,
    first_free_thread: ^DebugThread,
    max_thread_count:  u32,
    
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
    
    mouse_text_stack_y: f32,
    
    // Overlay rendering
    render_group: RenderGroup,
    
    text_transform:    Transform,
    shadow_transform:  Transform,
    ui_transform:      Transform,
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
    first_free_stored_event: ^DebugStoredEvent,
}

DebugFrame :: struct {
    profile_root: ^DebugStoredEvent,
    frame_index: i32,
    
    begin_clock,
    end_clock:       i64,
    seconds_elapsed: f32,
    
    stored_event_count:  u32,
    profile_block_count: u32,
    data_block_count:    u32,
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
    
    frame_index: i32,
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
#assert(size_of(DebugEvent) == 128) // !!!! See below
@common DebugTableSize :: 1_280_000_152
#assert(size_of(DebugTable) == DebugTableSize)
DebugTable :: struct {
    record_increment: u64,
    edit_event: DebugEvent,
    // @Correctness No attempt is currently made to ensure that the final
    // debug records being written to the event array actually complete
    // their output prior to the swap of the event array index.
    current_events_index: u32,
    events_state:   DebugEventsState,
    events:         [2][DebugMaxEventCount]DebugEvent,
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

DebugElementFrame :: struct {
    total_clocks: u64,
    events: Deque(DebugStoredEvent),
}

DebugElement :: #type SingleLinkedList(DebugElementLink)
DebugElementLink :: struct {
    guid:   DebugGUID,
    frames: [MaxFrameCount]DebugElementFrame,
}

DebugStoredEvent :: struct {
    next: ^DebugStoredEvent,
    
    using it: struct #raw_union {
        event: DebugEvent,
        node:  DebugProfileNode,
    },

    frame_index: i32,
    // TODO(viktor): Store call attribution data here?
}

DebugProfileNode :: struct {
    element: ^SingleLinkedList(DebugElementLink),
    
    first_child:      ^DebugStoredEvent,
    next_same_parent: ^DebugStoredEvent,
    
    parent_relative_clock: u32,
    duration:              u32,
    
    thread_index: u16,
    core_index:   u16,
    
    aggregate_count: u32,
    
}

DebugId :: struct {
    value: [2]pmm,
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
        
        debug.collating_frame_ordinal   = 1
        debug.most_recent_frame_ordinal = 0
        debug.oldest_frame_ordinal_that_is_already_freed      = 0
        
        // :PointerArithmetic
        total_memory := memory.debug_storage[size_of(DebugState):]
        init_arena(&debug.arena, total_memory)
        
        when true {
            sub_arena(&debug.per_frame_arena, &debug.arena, 3 * len(total_memory) / 4)
        } else { 
            // NOTE(viktor): use this to test the handling of deallocation and freeing of frames
            sub_arena(&debug.per_frame_arena, &debug.arena, 200 * Kilobyte)
        }
        
        debug.root_group    = create_group(debug, "Root")
        debug.profile_group = create_group(debug, "Profiles")
        
        debug.backing_transform = default_flat_transform()
        debug.ui_transform  = default_flat_transform()
        debug.shadow_transform  = default_flat_transform()
        debug.text_transform    = default_flat_transform()
        debug.backing_transform.sort_bias = 100_000
        debug.ui_transform.sort_bias  = 200_000
        debug.shadow_transform.sort_bias  = 400_000
        debug.text_transform.sort_bias    = 800_000
        
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

collate_debug_records :: proc(debug: ^DebugState, events: []DebugEvent) {
    timed_function()
    
    collation_frame := &debug.frames[debug.collating_frame_ordinal]
    for &event in events {
        thread: ^DebugThread
        thread_count: u32 = 1
        for thread = debug.thread; thread != nil && thread.thread_index != event.thread_index; thread = thread.next {
            thread_count += 1
        }
        debug.max_thread_count = max(debug.max_thread_count, thread_count)
        
        if thread == nil {
            thread = list_pop(&debug.first_free_thread) or_else push(&debug.arena, DebugThread, no_clear())
            thread^ = { thread_index = event.thread_index }
            
            list_push(&debug.thread, thread)
        }
        assert(thread.thread_index == event.thread_index)
        
        frame_index := debug.total_frame_count
        default_parent_group := debug.root_group
        if thread.first_open_data_block != nil {
            default_parent_group = thread.first_open_data_block.group
        }
        
        switch value in event.value {
          case FrameMarker:
            collation_frame.end_clock       = event.clock
            collation_frame.seconds_elapsed = value.seconds_elapsed
            
            root := collation_frame.profile_root
            if root != nil {
                root.node.duration = cast(u32) (collation_frame.end_clock - collation_frame.begin_clock)
            }
            
            debug.total_frame_count += 1
            
            debug.most_recent_frame_ordinal = debug.collating_frame_ordinal
            increment_frame_ordinal(&debug.collating_frame_ordinal)
            if debug.collating_frame_ordinal == debug.oldest_frame_ordinal_that_is_already_freed {
                free_oldest_frame(debug)
            }
            init_frame(debug, &debug.frames[debug.collating_frame_ordinal], event.clock)
            
          case BeginDataBlock:
            collation_frame.data_block_count += 1
            
            block := alloc_open_block(debug, thread, frame_index, event.clock, &thread.first_open_data_block, nil)
            group := get_group_by_hierarchical_name(debug, default_parent_group, event.guid.name, true)
            block.group = group
            
          case ThreadIntervalProfile, DebugEventLink, DebugEventGroup,
            BitmapId, SoundId, FontId, 
            b32, f32, u32, i32, 
            v2, v3, v4, 
            Rectangle2, Rectangle3:
            
            element := get_element_from_guid(debug, event.guid, default_parent_group)
            store_event(debug, event, element)
            
          case EndDataBlock:
            matching_block := thread.first_open_data_block
            if matching_block != nil {
                free_open_block(thread, &thread.first_open_data_block)
            }
            
          case BeginTimedBlock:
            collation_frame.profile_block_count += 1
            
            element := get_element_from_guid(debug, event.guid, parent = debug.profile_group, create_hierarchy = false)
            
            parent_event := collation_frame.profile_root
            clock_basis := collation_frame.begin_clock
            if thread.first_open_timed_block != nil {
                clock_basis = thread.first_open_timed_block.begin_clock
                parent_event = thread.first_open_timed_block.event
            } else if parent_event == nil {
                parent_event = store_event(debug, {}, element)
                collation_frame.profile_root = parent_event
                clock_basis = collation_frame.begin_clock
            }
            
            stored_event := store_event(debug, event, element)
            assert(stored_event != nil)
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
            if thread.first_open_timed_block != nil {
                matching_block := thread.first_open_timed_block
                
                assert(matching_block.event != nil)
                
                node := &matching_block.event.node
                assert(node != nil)
                assert(node.duration == 0)
                
                node.duration = cast(u32) (event.clock - matching_block.begin_clock)
                node.aggregate_count += 1
                free_open_block(thread, &thread.first_open_timed_block)
            }
        }
    }
}

store_event :: proc(debug: ^DebugState, event: DebugEvent, element: ^DebugElement) -> (result: ^DebugStoredEvent) {
    if debug.root_group == nil do return
    
    collation_frame := &debug.frames[debug.collating_frame_ordinal]
    collation_frame.stored_event_count += 1
    
    attempts := 100
    ok: b32
    for result == nil {
        attempts -= 1
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
                assert(debug.oldest_frame_ordinal_that_is_already_freed != debug.collating_frame_ordinal)
                free_oldest_frame(debug)
            }
        }
    }
    
    if attempts == 0 {
        panic("failed to free a frame")
    }
    
    result^ = {
        event       = event,
        frame_index = collation_frame.frame_index,
        
    }
    
    deque_append(&element.frames[debug.collating_frame_ordinal].events, result)
    
    return result 
}

increment_frame_ordinal :: proc(value:^i32) {
    value^ = (value^+1) % len(DebugState{}.frames)
}

init_frame :: proc(debug: ^DebugState, frame: ^DebugFrame, begin_clock: i64) {
    frame^ = {
        frame_index = debug.total_frame_count,
        begin_clock = begin_clock,
    }
}

free_oldest_frame :: proc(debug: ^DebugState) {
    if debug.oldest_frame_ordinal_that_is_already_freed == debug.most_recent_frame_ordinal {
        increment_frame_ordinal(&debug.most_recent_frame_ordinal)
    }
    
    increment_frame_ordinal(&debug.oldest_frame_ordinal_that_is_already_freed)
    free_frame(debug, debug.oldest_frame_ordinal_that_is_already_freed)
}

free_frame :: proc(debug: ^DebugState, frame_ordinal: i32) {
    freed_count: u32
    for element in debug.element_hash {
        for element := element; element != nil; element = element.next {
            frame := &element.frames[frame_ordinal]
            
            for frame.events.last != nil {
                free_event := deque_remove_from_end(&frame.events)
                freed_count += 1
                { // NOTE(viktor): inlined list_push(&debug.first_free_stored_event, free_event) because ...
                    head    := &debug.first_free_stored_event
                    element := free_event
                    
                    element.next = head^
                    head^        = element
                }
            }
            
            frame^ = {}
        }
    }
    
    frame := &debug.frames[frame_ordinal]
    assert(freed_count == frame.stored_event_count)
}

get_hash_from_guid :: proc(guid: DebugGUID) -> (result: u32) {
    // TODO(viktor): BETTER HASH FUNCTION
    for i in 0..<len(guid.name)      do result = result * 65599 + cast(u32) guid.name[i]
    for i in 0..<len(guid.file_path) do result = result * 65599 + cast(u32) guid.file_path[i]
    for i in 0..<len(guid.procedure) do result = result * 65599 + cast(u32) guid.procedure[i]
    result = result * 65599 + guid.line
    result = result * 65599 + guid.column
    return result
}

get_element_from_guid :: proc { get_element_from_guid_by_hash, get_element_from_guid_by_parent, get_element_from_guid_raw }
get_element_from_guid_raw :: proc(debug: ^DebugState, guid: DebugGUID) -> (result: ^DebugElement) {
    hash_value := get_hash_from_guid(guid)
    result = get_element_from_guid_by_hash(debug, guid, hash_value)
    return result
}
get_element_from_guid_by_hash :: proc (debug: ^DebugState, guid: DebugGUID, hash_value: u32) -> (result: ^DebugElement) {
    assert(hash_value != 0)

    index := hash_value % len(debug.element_hash)
    
    for chain := debug.element_hash[index]; chain != nil; chain = chain.next {
        guids_are_equal := true
        
        if guids_are_equal && chain.guid.line      != guid.line      do guids_are_equal = false
        if guids_are_equal && chain.guid.column    != guid.column    do guids_are_equal = false
        if guids_are_equal && chain.guid.name      != guid.name      do guids_are_equal = false
        if guids_are_equal && chain.guid.file_path != guid.file_path do guids_are_equal = false
        if guids_are_equal && chain.guid.procedure != guid.procedure do guids_are_equal = false
        
        if guids_are_equal {
            result = chain
            break
        }
    }
    
    return result
}
get_element_from_guid_by_parent :: proc(debug: ^DebugState, guid: DebugGUID, parent: ^DebugEventGroup = nil, create_hierarchy: b32 = true) -> (result: ^DebugElement) {
    if guid != {} {   
        hash_value := get_hash_from_guid(guid)
        
        result = get_element_from_guid_by_hash(debug, guid, hash_value)
        
        if result == nil {
            result = push(&debug.arena, DebugElement)
            result.guid = DebugGUID {
                line      = guid.line,
                column    = guid.column,
                name      = copy_string(&debug.arena, guid.name),
                file_path = copy_string(&debug.arena, guid.file_path),
                procedure = copy_string(&debug.arena, guid.procedure),
            }

            index := hash_value % len(debug.element_hash)
            list_push(&debug.element_hash[index], result)

            parent := parent
            if parent == nil do parent = debug.root_group
            
            parent_group := parent
            if create_hierarchy do parent_group = get_group_by_hierarchical_name(debug, parent, guid.name, false)
            
            add_element_to_group(debug, parent_group, result)
        }
    }
    
    return result
}

alloc_open_block :: proc(debug: ^DebugState, thread: ^DebugThread, frame_index: i32, begin_clock: i64, parent: ^^DebugOpenBlock, element: ^DebugElement) -> (result: ^DebugOpenBlock) {
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

free_open_block :: proc(thread: ^DebugThread, first_open_block: ^^DebugOpenBlock) {
    free_block := first_open_block^
    first_open_block^ = free_block.parent
    
    free_block.next_free    = thread.first_free_block
    thread.first_free_block = free_block
}
