#+vet !unused-procedures
package game

DebugEnabled :: true && INTERNAL

DebugGUID :: struct {
    name:      string,
    file_path: string,
    procedure: string,
    line:   u32,
    column: u32,
}

@(export) debug_record_f32 :: proc (value: ^f32, name: string = #caller_expression(value)) { debug_record_value(value, name) }
@(export) debug_record_b32 :: proc (value: ^b32, name: string = #caller_expression(value)) { debug_record_value(value, name) }
@(export) debug_record_i64 :: proc (value: ^i64, name: string = #caller_expression(value)) { debug_record_value(value, name) }
@(export) debug_record_i32 :: proc (value: ^i32, name: string = #caller_expression(value)) { debug_record_value(value, name) }
debug_record_value :: proc (value: ^$Value, name: string = #caller_expression(value)) { 
    if GlobalDebugTable == nil do return
    guid := DebugGUID{ name = name }
    
    event := debug_record_event(GlobalDebugTable, nil, guid)
    when Value == bool { // @cleanup
        if GlobalDebugTable.edit_event.guid == guid {
            value ^= cast(bool) GlobalDebugTable.edit_event.value.(b32)
        }
        event.value = cast(b32) value^
    } else {
        if GlobalDebugTable.edit_event.guid == guid {
            value ^= GlobalDebugTable.edit_event.value.(Value)
        }
        event.value = value^
    }
}

////////////////////////////////////////////////
// Selection

debug_set_mouse_p :: proc (mouse_p: v2) {
    when !DebugEnabled do return
    
    GlobalDebugTable.mouse_p = mouse_p
}
debug_get_mouse_p :: proc () -> v2 {
    when !DebugEnabled do return {}
    
    result := GlobalDebugTable.mouse_p
    return result
}

debug_pointer_id :: proc { debug_pointer_id_raw, debug_pointer_id_poly }
debug_pointer_id_poly :: proc (pointer: $P)  -> DebugId { return debug_pointer_id_raw(auto_cast pointer) }
debug_pointer_id_raw  :: proc (pointer: pmm) -> DebugId {
    when !DebugEnabled do return {}
    
    result: DebugId
    result.value[0] = pointer
    return result
}

debug_hit :: proc (id: DebugId, z: f32) {
    debug := get_debug_state()
    if debug == nil do return
    
    debug.next_hot_interaction = {
        id = id,
        kind = .Select,
    }
}

debug_highlighted :: proc (id: DebugId) -> (highlighted: bool, color: v4) {
    when !DebugEnabled do return highlighted, color
    
    debug := get_debug_state()
    if debug == nil do return
    
    if debug.hot_interaction.id == id {
        highlighted = true
        color = Emerald
    }
    
    if is_selected(debug, id) {
        highlighted = true
        color = Isabelline
    }
        
    return highlighted, color
}

debug_requested :: proc (id: DebugId) -> bool {
    when !DebugEnabled do return
    
    debug := get_debug_state()
    if debug == nil do return false
    
    result: bool
    if is_selected(debug, id) {
        result = true
    }
        
    return result
}

select :: proc (debug: ^DebugState, id: DebugId) {
    if !is_selected(debug, id) {
        debug.selected_ids[debug.selected_count] = id
        debug.selected_count += 1
    }
}

clear_selection :: proc (debug: ^DebugState) {
    debug.selected_count = 0
}

is_selected :: proc (debug: ^DebugState, id: DebugId) -> bool {
    result: bool
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

@(export)
debug_ui_element :: proc (kind: DebugValue, name:= #caller_expression(kind), loc := #caller_location) {
    debug_record_event(kind, name, loc)
}

@(deferred_none=debug_end_data_block)
debug_data_block :: proc (name: string, loc := #caller_location) {
    debug_record_event(BeginDataBlock{}, name, loc)
}

@(export)
debug_begin_data_block :: proc (name: string, loc := #caller_location) {
    debug_record_event(BeginDataBlock{}, name, loc)
}

@(export)
debug_end_data_block :: proc () {
    debug_record_event(EndDataBlock{}, "EndDataBlock")
}

////////////////////////////////////////////////
// Timed Blocks and Functions

@(export)
begin_timed_block :: proc (name: string, loc := #caller_location) {
    when !DebugEnabled do return result 
    
    debug_record_event(BeginTimedBlock{}, name, loc)
}

@(export)
end_timed_block :: proc () {
    when !DebugEnabled do return
    debug_record_event(EndTimedBlock{}, "")
}

@(deferred_none=end_timed_block)
timed_block :: proc (name: string, loc := #caller_location) {
    begin_timed_block(name, loc)
}

@(deferred_out = end_timed_block)
timed_function :: proc (loc := #caller_location) { 
    begin_timed_block(loc.procedure, loc)
}

debug_record_event :: proc { debug_record_event_loc, debug_record_event_guid }
debug_record_event_loc :: proc (value: DebugValue, name: string, loc := #caller_location) -> ^DebugEvent {
    return debug_record_event_guid(GlobalDebugTable, value, { name, loc.file_path, loc.procedure , cast(u32) loc.line, cast(u32) loc.column})
}
debug_record_event_guid :: proc (table: ^DebugTable, value: DebugValue, guid: DebugGUID) -> ^DebugEvent {
    if !DebugEnabled do return nil
    if table == nil  do return nil
    
    // @volatile
    state := transmute(DebugEventsState) atomic_add(cast(^u64) &table.events_state, table.record_increment)
    result := &table.events[state.array_index][state.events_index]
    
    result ^= {
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

@(export)
debug_set_event_recording :: proc (table: ^DebugTable, active: bool) {
    if !DebugEnabled do return
    if table == nil  do return
    
    table.record_increment = active ? 1 : 0
}

@(export)
frame_marker :: proc (seconds_elapsed: f32, loc := #caller_location) {
    if !DebugEnabled do return
    
    debug_record_event(FrameMarker{seconds_elapsed}, "Frame Marker", loc)
}