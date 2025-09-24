#+vet !unused-procedures
package game

import "base:runtime"

DebugEnabled :: true && INTERNAL

DebugGUID :: struct {
    name:      string,
    file_path: string,
    procedure: string,
    line:   u32,
    column: u32,
}

@(export) debug_record_f32 :: proc(value: ^f32, name: string = #caller_expression(value)) { debug_record_value(value, name) }
@(export) debug_record_b32 :: proc(value: ^b32, name: string = #caller_expression(value)) { debug_record_value(value, name) }
@(export) debug_record_i64 :: proc(value: ^i64, name: string = #caller_expression(value)) { debug_record_value(value, name) }
debug_record_value :: proc(value: ^$Value, name: string = #caller_expression(value)) { 
    if GlobalDebugTable == nil do return
    guid := DebugGUID{ name = name }
    
    event := debug_record_event(nil, guid)
    if GlobalDebugTable.edit_event.guid == guid {
        value ^= GlobalDebugTable.edit_event.value.(Value)
    }
    event.value = value^
}

////////////////////////////////////////////////
// Selection

debug_set_mouse_p :: proc (mouse_p: v2) {
    when !DebugEnabled do return
    
    GlobalDebugTable.mouse_p = mouse_p
}
debug_get_mouse_p :: proc () -> (result: v2) {
    when !DebugEnabled do return
    
    result = GlobalDebugTable.mouse_p
    return result
}

debug_pointer_id :: proc { debug_pointer_id_raw, debug_pointer_id_poly }
debug_pointer_id_poly :: proc (pointer: $P)  -> (result: DebugId) { return debug_pointer_id_raw(auto_cast pointer) }
debug_pointer_id_raw  :: proc (pointer: pmm) -> (result: DebugId) {
    when !DebugEnabled do return
    
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

debug_highlighted :: proc (id: DebugId) -> (highlighted: b32, color: v4) {
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

debug_requested :: proc(id: DebugId) -> (result: b32) {
    when !DebugEnabled do return
    
    debug := get_debug_state()
    if debug == nil do return

    if is_selected(debug, id) {
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

@(export)
debug_ui_element :: proc(kind: DebugValue, name:= #caller_expression(kind), loc := #caller_location) {
    debug_record_event(kind, name, loc)
}

@(deferred_none=debug_end_data_block)
debug_data_block :: proc(name: string, loc := #caller_location) {
    debug_record_event(BeginDataBlock{}, name, loc)
}

@(export)
debug_begin_data_block :: proc(name: string, loc := #caller_location) {
    debug_record_event(BeginDataBlock{}, name, loc)
}

@(export)
debug_end_data_block :: proc() {
    debug_record_event(EndDataBlock{}, "EndDataBlock")
}

////////////////////////////////////////////////
// Timed Blocks and Functions

@(common) TimedBlockInfo :: struct {
    hit_count: i64, 
    name: string,
    loc: runtime.Source_Code_Location,
}

@(export)
begin_timed_block :: proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlockInfo) {
    when !DebugEnabled do return result 
    
    debug_record_event(BeginTimedBlock{}, name, loc)
    
    result.hit_count = hit_count
    result.name = name
    result.loc = loc
    return result
}

@(export)
end_timed_block :: proc(info: TimedBlockInfo) {
    when !DebugEnabled do return
    if info == {} do return
    // @todo(viktor): record the hit count here
    debug_record_event(EndTimedBlock{}, info.name, info.loc)
}

@(deferred_out=end_timed_block)
timed_block :: proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlockInfo) {
    return begin_timed_block(name, loc, hit_count)
}

@(deferred_out = end_timed_block)
timed_function :: proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlockInfo) { 
    return begin_timed_block(loc.procedure, loc, hit_count)
}

debug_record_event :: proc { debug_record_event_loc, debug_record_event_guid }
debug_record_event_loc :: proc(value: DebugValue, name: string, loc := #caller_location) -> (result: ^DebugEvent) {
    return debug_record_event_guid(value, { name, loc.file_path, loc.procedure , cast(u32) loc.line, cast(u32) loc.column})
}
debug_record_event_guid :: proc(value: DebugValue, guid: DebugGUID) -> (result: ^DebugEvent) {
    when !DebugEnabled do return
    if GlobalDebugTable == nil do return
    
    // @volatile
    state := transmute(DebugEventsState) atomic_add(cast(^u64) &GlobalDebugTable.events_state, GlobalDebugTable.record_increment)
    result = &GlobalDebugTable.events[state.array_index][state.events_index]
    
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
debug_set_event_recording :: proc(active: b32, table := GlobalDebugTable) {
    if !DebugEnabled do return
    if table == nil do return
    
    table.record_increment = active ? 1 : 0
}

@(export)
frame_marker :: proc(seconds_elapsed: f32, loc := #caller_location) {
    if !DebugEnabled do return
    
    debug_record_event(FrameMarker{seconds_elapsed}, "Frame Marker", loc)
}