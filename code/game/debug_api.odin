package game

DebugEnabled :: true

@common 
TimedBlock :: struct {
    hit_count: i64,
    loc:       DebugEventLocation, 
}

@common 
DebugEventLocation :: struct {
    name:         string,
    file_path:    string,
    line:         u32,
}

debug_variable :: #force_inline proc($T: typeid, $name: string, loc := #caller_location) -> (result: T) {
    // TODO(viktor): allow different default value
   when !DebugEnabled do return {}
   else {
       @static event: DebugEvent
       if event.value == nil {
           debug_init_variable(&event, T{}, name, loc.file_path, auto_cast loc.line)
       }
       return event.value.(T)
   }
}

// TODO(viktor): Remove this!
debug_init_variable :: #force_inline proc(event: ^DebugEvent, initial_value: $T, name, file_path: string, line: u32) {
    event.loc = { name, file_path, line}
    event.value = initial_value
    debug_record_event_common(MarkEvent{event}, event.loc)
}

debug_pointer_id :: proc(pointer: pmm) -> (result: DebugId) {
    when !DebugEnabled do return result
    
    result.value[0] = pointer
    return result
}

debug_hit :: proc(id: DebugId, z: f32) {
    debug := debug_get_state()
    
    debug.next_hot_interaction = {
        id = id,
        kind = .Select,
    }
}

select :: proc(debug: ^DebugState, id: DebugId) {
    if !is_selected(debug, id) {
        debug.selected_ids[debug.selected_count] = id
        debug.selected_count += 1
    }
}

clear_selection :: proc(debug: ^DebugState) {
    debug.selected_count = 0
}

is_selected :: proc(debug: ^DebugState, id: DebugId) -> (result: b32) {
    for it in debug.selected_ids[:debug.selected_count] {
        if it == id {
            result = true
            break
        }
    }
    
    return result
}

debug_highlighted :: proc(id: DebugId) -> (highlighted: b32, color: v4) {
    when !DebugEnabled do return highlighted, color
    
    debug := debug_get_state()

    if debug.hot_interaction.id == id {
        highlighted = true
        color = Green
    }
    
    if is_selected(debug, id) {
        highlighted = true
        color = Yellow
    }
        
    return highlighted, color
}

debug_begin_data_block :: proc(id: DebugId, name: string, loc := #caller_location) -> (result: b32)  {
    if !DebugEnabled do return result
    debug := debug_get_state()
        
    result = debug.hot_interaction.id == id || is_selected(debug, id)
    
    debug_record_value(BeginDataBlock{}, loc, name)
    if result {
    }
    
    return result
}

debug_record_value :: #force_inline proc(value: DebugValue, loc := #caller_location, name := #caller_expression(value)) {
    if !DebugEnabled do return
    
    debug_record_event_common(value, {
        name      = name,
        file_path = loc.file_path,
        line      = auto_cast loc.line,
    })
}

debug_end_data_block :: #force_inline proc(loc := #caller_location) {
    if !DebugEnabled do return
    
    debug_record_value(EndDataBlock{}, loc, "EndDataBlock")
}



@(export)
begin_timed_block:: #force_inline proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) {
    when true do return // IMPORTANT TODO(viktor): FIX THIS!
    when !DebugEnabled do return result 
    
    result = {
        loc = { 
            name      = name,
            file_path = loc.file_path,
            line      = auto_cast loc.line,
        },
        hit_count = hit_count,
    }
    
    debug_record_event_common(BeginCodeBlock{}, result.loc)
    
    return result
}

@export
end_timed_block:: #force_inline proc(block: TimedBlock) {
    when true do return // IMPORTANT TODO(viktor): FIX THIS!
    when !DebugEnabled do return
    // TODO(viktor): record the hit count here
    debug_record_event_common(EndCodeBlock{}, block.loc)
}

@(deferred_out=end_timed_block)
timed_block :: #force_inline proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) {
    return begin_timed_block(name, loc, hit_count)
}



@(deferred_out = end_timed_block)
timed_function :: #force_inline proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) { 
    return begin_timed_block(loc.procedure, loc, hit_count)
}


@export
frame_marker :: #force_inline proc(seconds_elapsed: f32, loc := #caller_location) {
    if !DebugEnabled do return
    
    debug_record_value(FrameMarker{seconds_elapsed}, loc, "Frame Marker")
}


debug_record_event_common :: #force_inline proc(value: DebugValue, loc: DebugEventLocation) -> (result: ^DebugEvent) {
    when !DebugEnabled do return
    
    state := transmute(DebugEventsState) atomic_add(cast(^u64) &GlobalDebugTable.events_state, 1)
    result = &GlobalDebugTable.events[state.array_index][state.events_index]
    
    result^ = {
        loc          = loc,
        
        clock        = read_cycle_counter(),
        thread_index = cast(u16) context.user_index,
        core_index   = 0,
        
        value        = value,
    }
    
    return result
}