package game

import hha "./asset_builder"
import "core:fmt"
import "core:hash"
import "base:runtime"
import "base:intrinsics"

////////////////////////////////////////////////

GlobalDebugTable: DebugTable

DebugTable :: struct {
    // @Correctness No attempt is currently made to ensure that the final
    // debug records being written to the event array actually complete
    // their output prior to the swap of the event array index.
    current_events_index: u32,
    events_state:   DebugEventsState,
    events:         [64][16*65536]DebugEvent,
    
    records: DebugRecords,
}

DebugEvent  :: struct {
    clock: i64,
    
    thread_index: u16,
    core_index:   u16,
    record_index: u32,
    
    type: DebugEventType,
}

DebugEventsState :: bit_field u64 {
    // @Volatile Later on we transmute this to a u64 to 
    // atomically increment one of the fields
    events_index: u32 | 32,
    array_index:  u32 | 32,
}

DebugEventType :: enum u8 {
    BeginBlock, EndBlock,
    FrameMarker,
}

////////////////////////////////////////////////

DebugState :: struct {
    index:          u32,
    counter_states: [512]DebugCounterState,
}

DebugCounterState :: struct {
	loc: DebugRecordLocation,
    snapshots: [144]DebugCounterSnapshot,
}

////////////////////////////////////////////////

DebugRecords :: [512]DebugRecord
DebugRecord  :: struct {
    hash:  u32,
    index: u32,
    loc:   DebugRecordLocation,
}

DebugRecordLocation :: struct {
    file_path: string,
	line:      i32,
	name:      string,
}
////////////////////////////////////////////////

DebugCounterSnapshot :: struct {
    hit_count:   i64,
    cycle_count: i64,
}

////////////////////////////////////////////////

DebugStatistic :: struct {
    min, max, avg, count: f64
}

////////////////////////////////////////////////
// Exports

@export
debug_frame_end :: proc(memory: ^GameMemory) {
    if memory.debug_storage == nil do return
    
    assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)
    
    modular_add(&GlobalDebugTable.current_events_index, 1, len(GlobalDebugTable.events))
    events_state := atomic_exchange(&GlobalDebugTable.events_state, { events_index = 0, array_index = GlobalDebugTable.current_events_index })
    
    modular_add(&debug_state.index, 1, len(debug_state.counter_states[0].snapshots))
    
    events := GlobalDebugTable.events[events_state.array_index][:events_state.events_index]
    for event in events {
        entry := &GlobalDebugTable.records[event.record_index]
        if entry.index != event.record_index {
            // :HotReload we clear the records on reload because the hashing will not
            // produce the same mapping due to threading and conditional calls, thereby
            // invalidating certain records/hash slots
            continue
        }
        
        counter := &debug_state.counter_states[event.record_index]
        counter.loc = entry.loc
        
        snapshot := &counter.snapshots[debug_state.index]
        switch event.type {
        case .BeginBlock:
            snapshot.hit_count   += 1
            snapshot.cycle_count -= event.clock
        case .EndBlock:
            snapshot.cycle_count += event.clock
        case .FrameMarker:
            
        }
    }
}

@export
frame_marker :: #force_inline proc(loc := #caller_location) {
    record_debug_event(.FrameMarker, NilHashValue)
    frame_marker := &GlobalDebugTable.records[NilHashValue]
    frame_marker.loc.file_path = loc.file_path
    frame_marker.loc.line = loc.line
    frame_marker.loc.name = "Frame Marker"
    frame_marker.index = NilHashValue
    frame_marker.hash  = NilHashValue
}

@export
begin_timed_block:: #force_inline proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) {
    ok: b32
    
    key := DebugRecordLocation{
        name      = name,
        file_path = loc.file_path,
        line      = loc.line,
    }
    
    // TODO(viktor): Check the overhead of this
    result.hit_count = hit_count
    result.record_index, ok = get(&GlobalDebugTable.records, key)
    if !ok {
        result.record_index = put(&GlobalDebugTable.records, key)
    }
    
    record_debug_event(.BeginBlock, result.record_index)
    
    return result
    
}

@export
end_timed_block:: #force_inline proc(block: TimedBlock) {
    // TODO(viktor): check manual blocks are closed once and exactly once
    // TODO(viktor): record the hit count here
    record_debug_event(.EndBlock, block.record_index)
}

////////////////////////////////////////////////

@(deferred_out=end_timed_block)
timed_block:: #force_inline proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) {
    return begin_timed_block(name, loc, hit_count)
}

@(deferred_out=end_timed_function)
timed_function :: #force_inline proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) { 
    return begin_timed_function(loc, hit_count)
}

begin_timed_function :: #force_inline proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) { 
    return begin_timed_block(loc.procedure, loc, hit_count)
}

end_timed_function :: #force_inline proc(block: TimedBlock) {
    end_timed_block(block)
}

record_debug_event :: #force_inline proc (type: DebugEventType, record_index: u32) {
    events := transmute(DebugEventsState) atomic_add(cast(^u64) &GlobalDebugTable.events_state, 1)
    event := &GlobalDebugTable.events[events.array_index][events.events_index]
    event^ = {
        type         = type,
        clock        = read_cycle_counter(),
        thread_index = cast(u16) context.user_index,
        core_index   = 0,
        record_index = record_index,
    }
}

////////////////////////////////////////////////

overlay_debug_info :: proc(memory: ^GameMemory) {
    timed_function()
    
    if memory.debug_storage == nil do return
    
    assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)
    
    // NOTE(viktor): kerning and unicode test lines
    // Debug_text_line("贺佳樱我爱你")
    // Debug_text_line("AVA: WA ty fi ij `^?'\"")
    // Debug_text_line("0123456789°")
    
    text_line("Debug Game Cycle Counts:")
    for state in debug_state.counter_states {
        if state.loc == {} do continue
        
        cycles := debug_statistic_begin()
        hits   := debug_statistic_begin()
        cphs   := debug_statistic_begin()
        
        for snapshot in state.snapshots {
            denom := snapshot.hit_count if snapshot.hit_count != 0 else 1
            cycles_per_hit := snapshot.cycle_count / denom
            
            debug_statistic_accumulate(&cycles, snapshot.cycle_count)
            debug_statistic_accumulate(&hits,   snapshot.hit_count)
            debug_statistic_accumulate(&cphs,   cycles_per_hit)
        }
        debug_statistic_end(&cycles)
        debug_statistic_end(&hits)
        debug_statistic_end(&cphs)
        
        if Debug_render_group != nil {
            chart_min_y := cp_y
            chart_height := ascent * font_scale - 2
            width : f32 = 4
            if cycles.max > 0 {
                scale := 1 / cast(f32) cycles.max
                for snapshot, index in state.snapshots {
                    proportion := cast(f32) snapshot.cycle_count * scale
                    height := chart_height * proportion
                    push_rectangle(Debug_render_group, 
                        {cast(f32) index * width + 0.5*width, height * 0.5 + chart_min_y, 0}, 
                        {width, height}, 
                        {proportion, 0.7, 0.8, 1},
                    )
                }
            }
            
            text_line(fmt.tprintf("%28s(% 4d): % 12.0f : % 6.0f : % 10.0f", state.loc.name, state.loc.line, cycles.avg, hits.avg, cphs.avg))
        }
    }
    
    target_frames_per_seconds :: 72.0
    bar_width    :: 5
    bar_spacing  :: 3
    chart_height :: 120
 
    when false {
    full_width := cast(f32) len(debug_state.frame_infos) * (bar_width + bar_spacing) - bar_spacing
    pad_x := Debug_render_group.transform.screen_center.x - full_width * 0.5
    pad_y :: 20
    
    chart_left := left_edge + pad_x
    chart_min_y := -Debug_render_group.transform.screen_center.y + pad_y
    target_height: f32 = chart_height * 2
    target_padding :: 40
    target_width := full_width + target_padding
    background_color :: v4{0.08, 0.08, 0.3, 1}
    push_rectangle(Debug_render_group, 
        {chart_left + 0.5 * full_width, chart_min_y + (target_height) * 0.5, 0}, 
        {target_width, target_height}, 
        background_color
    )
    
    scale :f32: target_frames_per_seconds
    for &info, info_index in debug_state.frame_infos {
        prev_stamp: f32
        total: f32
        for stamp, stamp_index in info.timestamps[:info.count] {
            defer prev_stamp = stamp.seconds
            elapsed := stamp.seconds - prev_stamp
            defer total += elapsed
            
            proportion := elapsed * scale
            height := chart_height * proportion
            when !false { // NOTE(viktor): exagerate small timestamps
                MinHeight :: 3
                if height < MinHeight {
                    height = MinHeight
                    elapsed = MinHeight / (chart_height * scale)
                }
            }
            offset_x := cast(f32) info_index * (bar_width + bar_spacing)
            offset_y := total * scale * chart_height
            phase := cast(f32) (stamp_index) / cast(f32) (info.count-1)
            push_rectangle(Debug_render_group, 
                {chart_left + offset_x + 0.5*bar_width, chart_min_y + offset_y + 0.5*height, 0}, 
                {bar_width, height}, 
                {phase*phase, 1-phase, phase, 1},
            )
            push_rectangle(Debug_render_group, 
                {chart_left + offset_x + 0.5*(bar_width), chart_min_y + offset_y, 0}, 
                {bar_width+2, 1}, 
                background_color,
            )
        }
    }
    }
}

font_scale : f32 = 0.5
cp_y, ascent: f32
left_edge: f32
font_id: FontId
font: ^Font

reset_debug_renderer :: proc(width, height: i32) {
    timed_function()
    begin_render(Debug_render_group)
    orthographic(Debug_render_group, {width, height}, 1)
    
    font_id = best_match_font_from(Debug_render_group.assets, .Font, #partial { .FontType = cast(f32) hha.AssetFontType.Debug }, #partial { .FontType = 1 })
    font = get_font(Debug_render_group.assets, font_id, Debug_render_group.generation_id)
    
    baseline :f32= 10
    if font != nil {
        font_info := get_font_info(Debug_render_group.assets, font_id)
        baseline = get_baseline(font_info)
        ascent = get_baseline(font_info)
    } else {
        load_font(Debug_render_group.assets, font_id, false)
    }
    
    cp_y      =  0.5 * cast(f32) height - baseline * font_scale
    left_edge = -0.5 * cast(f32) width
}

text_line :: proc(text: string) {
    if Debug_render_group != nil {
        assert(Debug_render_group.inside_render)
        
        if font != nil {
            font_info := get_font_info(Debug_render_group.assets, font_id)
            cp_x := left_edge
            
            previous_codepoint: rune
            for codepoint in text {
                defer previous_codepoint = codepoint
                
                advance_x := get_horizontal_advance_for_pair(font, font_info, previous_codepoint, codepoint)
                cp_x += advance_x * font_scale
                
                bitmap_id := get_bitmap_for_glyph(font, font_info, codepoint)
                info := get_bitmap_info(Debug_render_group.assets, bitmap_id)
                
                if info != nil && codepoint != ' ' {
                    push_bitmap(Debug_render_group, bitmap_id, cast(f32) info.dimension.y * font_scale, {cp_x, cp_y, 0})
                }
            }
            
            advance_y := get_line_advance(font_info)
            cp_y -= font_scale * advance_y
        }
    }
}

////////////////////////////////////////////////
// HashTable Implementation for the DebugRecords
//   TODO(viktor): as all the hashes of the source code locations
//   are known at compile time, it should be possible to bake these 
//   into the table and hash O(1) retrieval and storage.
//   This would require the build script to aggregate all the 
//   invocations of of timed_block() and generate a hash for each
//   and insert it into the source code.
//
//   The language default map type is not thread-safe.
//   This is _not_ a general implementation and assumes
//   a fixed size backing array and will fail if it
//   should "grow".

find :: proc(ht: ^DebugRecords, value: DebugRecordLocation) -> (result: ^DebugRecord, hash_value, hash_index: u32) {
    hash_value = get_hash(ht, value)
    hash_index = hash_value
    for {
        result = &ht[hash_index]
        if result.hash == NilHashValue || result.hash == hash_value && result.loc == value {
            break
        }
        modular_add(&hash_index, 1 ,len(ht))
        
        if hash_index == hash_value {
            assert(false, "cannot insert")
        }
    }
    return result, hash_value, hash_index
}

get_hash :: proc(ht: ^DebugRecords, value: DebugRecordLocation) -> (result: u32) {
    result = cast(u32) (313 + value.line * 464) % len(ht)
    
    if result == NilHashValue {
        strings := [2]u32{
            hash.djb2(transmute([]u8) value.file_path),
            hash.djb2(transmute([]u8) value.name),
        }
        bytes := (cast([^]u8) &strings[0])[:size_of(strings)]
        result = hash.djb2(bytes) % len(ht)
        assert(result != NilHashValue)
    }
    
    return result
}

NilHashValue :: 0

put :: proc(ht: ^DebugRecords, value: DebugRecordLocation) -> (hash_index: u32) {
    entry: ^DebugRecord
    hash_value: u32
    entry, hash_value, hash_index = find(ht, value)
    
    entry.hash  = hash_value
    entry.index = hash_index
    entry.loc   = value
    
    return hash_index
}

get :: proc(ht: ^DebugRecords, value: DebugRecordLocation) -> (hash_index: u32, ok: b32) {
    entry: ^DebugRecord
    hash_value: u32
    entry, hash_value, hash_index = find(ht, value)
    
    if entry != nil && entry.hash == hash_value && entry.loc == value {
        return hash_index, true
    } else {
        return NilHashValue, false
    }
}

////////////////////////////////////////////////

debug_statistic_begin :: #force_inline proc() -> (result: DebugStatistic) {
    result = {
        min = max(f64),
        max = min(f64),
    }
    return result
}

debug_statistic_accumulate :: #force_inline proc(stat: ^DebugStatistic, value: $N) where intrinsics.type_is_numeric(N) {
    value := cast(f64) value
    stat.min    = min(stat.min, value)
    stat.max    = max(stat.max, value)
    stat.avg   += value
    stat.count += 1
}

debug_statistic_end :: #force_inline proc(stat: ^DebugStatistic) {
    if stat.count == 0 {
        stat.min = 0
        stat.max = 0
        stat.avg = 0
    } else {
        stat.avg /= stat.count
    }
}
