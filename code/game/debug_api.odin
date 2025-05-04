package game

DebugEnabled :: true

////////////////////////////////////////////////
// To be inspected for removal/cleanup

debug_pointer_id :: proc { debug_pointer_id_raw, debug_pointer_id_poly }
debug_pointer_id_poly :: proc(pointer: $P) -> (result: DebugId) { return debug_pointer_id_raw(auto_cast pointer) }
debug_pointer_id_raw :: proc(pointer: pmm) -> (result: DebugId) {
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

////////////////////////////////////////////////
// Record Insertion

debug_record_value :: proc(value: DebugValue, name := #caller_expression(value)) {
    if !DebugEnabled do return
    
    debug_record_event_common(value, name)
}

debug_profile :: proc(function: $P, name := #caller_expression(function)) {
    debug_record_event_common(Profile{}, name)
}

@(deferred_none=debug_end_data_block)
debug_data_block :: proc(name: string) {
    debug_record_event_common(BeginDataBlock{}, name)
}

debug_begin_data_block :: proc(id: DebugId, name: string) {
    if !DebugEnabled do return
    debug := debug_get_state()
 
    // TODO(viktor): Differentiate between selected and always recorded blocks (for usage in loops)
    // ok := debug.hot_interaction.id == id || is_selected(debug, id)
    
    debug_record_event_common(BeginDataBlock{}, name)
}

debug_end_data_block :: proc() {
    if !DebugEnabled do return
    
    debug_record_event_common(EndDataBlock{}, name = "EndDataBlock")
}

////////////////////////////////////////////////
// Timed Blocks and Functions

@(export)
begin_timed_block :: proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: i64) {
    when !DebugEnabled do return result 
    
    result = hit_count
    debug_record_event_common(BeginCodeBlock{}, name)
    
    return result
}

@export
end_timed_block :: proc(hit_count: i64) {
    when !DebugEnabled do return
    // TODO(viktor): record the hit count here
    debug_record_event_common(EndCodeBlock{}, "EndTimedBlock")
}

@(deferred_out=end_timed_block)
timed_block :: proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: i64) {
    return begin_timed_block(name, loc, hit_count)
}



@(deferred_out = end_timed_block)
timed_function :: proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: i64) { 
    return begin_timed_block(loc.procedure, loc, hit_count)
}

////////////////////////////////////////////////
// Only used by the platform layer

@export
frame_marker :: proc(seconds_elapsed: f32) {
    if !DebugEnabled do return
    
    debug_record_value(FrameMarker{seconds_elapsed}, "Frame Marker")
}


debug_record_event_common :: proc(value: DebugValue, name: string) -> (result: ^DebugEvent) {
    when !DebugEnabled do return
    
    state := transmute(DebugEventsState) atomic_add(cast(^u64) &GlobalDebugTable.events_state, 1)
    result = &GlobalDebugTable.events[state.array_index][state.events_index]
    
    result^ = {
        guid = name,
        
        clock        = read_cycle_counter(),
        thread_index = cast(u16) context.user_index,
        core_index   = 0,
        
        value        = value,
    }
    
    return result
}