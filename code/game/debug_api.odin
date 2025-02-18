package game

import "core:fmt"
import "core:os"

debug_pointer_id :: proc(pointer: rawpointer) -> (result: DebugId) {
    when !DebugEnabled do return result
    
    result[0] = pointer
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
    
    if result {
        debug_record_value(BeginDataBlock{}, loc, name)
    }
    
    return result
}

debug_end_data_block :: #force_inline proc(loc := #caller_location) {
    if !DebugEnabled do return
    
    debug_record_value(EndDataBlock{}, loc, "EndDataBlock")
}



@(export)
begin_timed_block:: #force_inline proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) {
    when !DebugEnabled do return result
    
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
    if !DebugEnabled do return
    // TODO(viktor): record the hit count here
    record_debug_event_common(EndCodeBlock{}, block.loc)
}

@(deferred_out=end_timed_block)
timed_block:: #force_inline proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) {
    return begin_timed_block(name, loc, hit_count)
}



@(deferred_out=end_timed_function)
timed_function :: #force_inline proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) { 
    return begin_timed_block(loc.procedure, loc, hit_count)
}

end_timed_function :: #force_inline proc(block: TimedBlock) {
    end_timed_block(block)
}



@export
frame_marker :: #force_inline proc(seconds_elapsed: f32, loc := #caller_location) {
    if !DebugEnabled do return
    
    debug_record_value(FrameMarker{seconds_elapsed}, loc, "Frame Marker")
}


debug_record_value :: #force_inline proc(value: DebugValue, loc := #caller_location, name := #caller_expression(value)) {
    if !DebugEnabled do return
    
    record_debug_event_common(value, {
        name      = name,
        file_path = loc.file_path,
        line      = auto_cast loc.line,
    })
}

record_debug_event_common :: #force_inline proc (value: DebugValue, loc: DebugEventLocation) {
    when !DebugEnabled do return
    
    events := transmute(DebugEventsState) atomic_add(cast(^u64) &GlobalDebugTable.events_state, 1)
    length := len(GlobalDebugTable.events[events.array_index])
    if events.events_index > auto_cast length {
        fmt.printfln("Index %v is out of range 0..<%v", events.events_index, length)
        os.exit(1)
    }
    event := &GlobalDebugTable.events[events.array_index][events.events_index]
    event^ = {
        loc          = loc,
        
        clock        = read_cycle_counter(),
        thread_index = cast(u16) context.user_index,
        core_index   = 0,
        
        value        = value,
    }
}
