package game

@(export)
begin_timed_block:: #force_inline proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) {
    when DebugTimingDisabled do return result
    
    result = {
        loc = { 
            name      = name,
            file_path = loc.file_path,
            line      = auto_cast loc.line,
        },
        hit_count = hit_count,
    }
    
    record_debug_event_common(BeginCodeBlock{}, result.loc)
    
    return result
}

@export
end_timed_block:: #force_inline proc(block: TimedBlock) {
    if DebugTimingDisabled do return
    // TODO(viktor): record the hit count here
    record_debug_event_common(EndCodeBlock{}, block.loc)
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
    
    record_debug_event_value(FrameMarker{seconds_elapsed}, loc, "Frame Marker")
}

begin_data_block :: #force_inline proc(value: ^$T, loc := #caller_location, name := #caller_expression(value)) {
    if DebugTimingDisabled do return
    
    record_debug_event_value(BeginDataBlock{}, loc, name)
}

end_data_block :: #force_inline proc(loc := #caller_location) {
    if DebugTimingDisabled do return
    
    record_debug_event_value(EndDataBlock{}, loc, "EndDataBlock")
}

record_debug_event_value :: #force_inline proc(value: DebugValue, loc := #caller_location, name := #caller_expression(value)) {
    if DebugTimingDisabled do return
    
    record_debug_event_common(value, {
        name      = name,
        file_path = loc.file_path,
        line      = auto_cast loc.line,
    })
}

record_debug_event_common :: #force_inline proc (value: DebugValue, loc: DebugEventLocation) {
    when DebugTimingDisabled do return
    
    events := transmute(DebugEventsState) atomic_add(cast(^u64) &GlobalDebugTable.events_state, 1)
    event := &GlobalDebugTable.events[events.array_index][events.events_index]
    event^ = {
        loc          = loc,
        
        clock        = read_cycle_counter(),
        thread_index = cast(u16) context.user_index,
        core_index   = 0,
        
        value        = value,
    }
}
