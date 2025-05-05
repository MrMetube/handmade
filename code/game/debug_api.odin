package game

DebugEnabled :: true

DebugGUID :: struct {
    name: string,
    file_path: string,
    line:   u32,
    column: u32,
    procedure: string,
}

@export
debug_record_b32 :: proc(value: ^b32, name: string = #caller_expression(value), loc := #caller_location) { debug_record_value(value, name, loc) }
debug_record_value :: proc(value: ^$Value, name: string = #caller_expression(value), loc := #caller_location) { 
    guid := DebugGUID{name, loc.file_path, cast(u32) loc.line, cast(u32) loc.column, loc.procedure}
    
    event := debug_record_event(nil, guid)
    if GlobalDebugTable.edit_event.guid == guid {
        value^ = GlobalDebugTable.edit_event.value.(Value)
    }
    event.value = value^
}

////////////////////////////////////////////////
// Selection

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

debug_requested :: proc(id: DebugId) -> (result: b32) {
    when !DebugEnabled do return result
    
    debug := debug_get_state()

    if debug.hot_interaction.id == id || is_selected(debug, id) {
        result = true
    }
        
    return result
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

////////////////////////////////////////////////
// Record Insertion

// TODO(viktor): whats the best default?
debug_thread_interval_profile :: proc {debug_thread_interval_profile_all, debug_thread_interval_profile_proc}
debug_thread_interval_profile_all :: proc(loc := #caller_location) {
    debug_thread_interval_profile_proc(update_and_render, "All", loc)
}
debug_thread_interval_profile_proc :: proc(function: $P, name := #caller_expression(function), loc := #caller_location) {
    debug_record_event(ThreadIntervalProfile{}, name, loc)
}

@(deferred_none=debug_end_data_block)
debug_data_block :: proc(name: string, loc := #caller_location) {
    debug_record_event(BeginDataBlock{}, name, loc)
}

@export
debug_begin_data_block :: proc(name: string, loc := #caller_location) {
    debug_record_event(BeginDataBlock{}, name, loc)
}

@export
debug_end_data_block :: proc() {
    debug_record_event(EndDataBlock{}, "EndDataBlock")
}

////////////////////////////////////////////////
// Timed Blocks and Functions

@export
begin_timed_block :: proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: i64, out: string) {
    when !DebugEnabled do return result 
    
    debug_record_event(BeginTimedBlock{}, name, loc)
    
    result = hit_count
    return result, name
}

@export
end_timed_block :: proc(hit_count: i64, name: string) {
    when !DebugEnabled do return
    // TODO(viktor): record the hit count here
    debug_record_event(EndTimedBlock{}, name)
}

@(deferred_out=end_timed_block)
timed_block :: proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: i64, out: string) {
    return begin_timed_block(name, loc, hit_count)
}


// IMPORTANT TODO(viktor): reenable this and fix the end_timed_block name/guid passing
// @(deferred_out = end_timed_block)
timed_function :: proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: i64, out: string) { 
    return //begin_timed_block(loc.procedure, loc, hit_count)
}

debug_record_event :: proc { debug_record_event_loc, debug_record_event_guid }
debug_record_event_loc :: proc(value: DebugValue, name: string, loc:= #caller_location) -> (result: ^DebugEvent) {
    return debug_record_event_guid(value, { name, loc.file_path, cast(u32) loc.line, cast(u32) loc.column, loc.procedure })
}
debug_record_event_guid :: proc(value: DebugValue, guid: DebugGUID) -> (result: ^DebugEvent) {
    when !DebugEnabled do return
    
    state := transmute(DebugEventsState) atomic_add(cast(^u64) &GlobalDebugTable.events_state, 1)
    result = &GlobalDebugTable.events[state.array_index][state.events_index]
    
    result^ = {
        guid = guid,
        
        clock        = read_cycle_counter(),
        thread_index = cast(u16) context.user_index,
        core_index   = 0,
        
        value = value,
    }
    
    return result
}

////////////////////////////////////////////////
// Only used by the platform layer

@export
frame_marker :: proc(seconds_elapsed: f32, loc := #caller_location) {
    if !DebugEnabled do return
    
    debug_record_event(FrameMarker{seconds_elapsed}, "Frame Marker", loc)
}