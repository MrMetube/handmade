package game

import "core:fmt"
import "core:hash" // TODO(viktor): I do not need this

////////////////////////////////////////////////

DebugMaxThreadCount     :: 256
DebugMaxHistoryLength   :: 64
DebugMaxRegionsPerFrame :: 65536

GlobalDebugTable: DebugTable

////////////////////////////////////////////////

DebugState :: struct {
    inititalized: b32,
    
    // NOTE(viktor): Collation
    arena: Arena,
    collation_memory: TemporaryMemory,
    
    frame_bar_scale:      f32,
    frame_bar_lane_count: u32,
    
    frame_count: u32,
    frames:      []DebugFrame,
    
    threads:          []DebugThread,
    first_free_block: ^DebugOpenBlock,
}

DebugFrame :: struct {
    begin_clock,
    end_clock:    i64,
    region_count: u32,
    regions:      []DebugRegion,
}

DebugRegion :: struct {
    lane_index:   u32,
    t_min, t_max: f32,
}

DebugThread :: struct {
    thread_index:     u32, // Also used as a lane_index
    first_open_block: ^DebugOpenBlock,
}

DebugOpenBlock :: struct {
    frame_index:   u32,
    opening_event: ^DebugEvent,
    parent, 
    next_free:     ^DebugOpenBlock,
}

////////////////////////////////////////////////

DebugTable :: struct {
    // @Correctness No attempt is currently made to ensure that the final
    // debug records being written to the event array actually complete
    // their output prior to the swap of the event array index.
    current_events_index: u32,
    events_state:   DebugEventsState,
    event_count:    [DebugMaxHistoryLength]u32,
    events:         [DebugMaxHistoryLength][16*65536]DebugEvent,
    
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
    FrameMarker,
    BeginBlock, 
    EndBlock,
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

    if !debug_state.inititalized {
        defer debug_state.inititalized = true
        // :PointerArithmetic
        init_arena(&debug_state.arena, memory.debug_storage[size_of(DebugState):])
        debug_state.threads = push(&debug_state.arena, DebugThread, DebugMaxThreadCount)
        debug_state.first_free_block = nil
        
        debug_state.collation_memory = begin_temporary_memory(&debug_state.arena)
    }
    end_temporary_memory(debug_state.collation_memory)
    debug_state.collation_memory = begin_temporary_memory(&debug_state.arena)
    
    modular_add(&GlobalDebugTable.current_events_index, 1, len(GlobalDebugTable.events))
    events_state := atomic_exchange(&GlobalDebugTable.events_state, { events_index = 0, array_index = GlobalDebugTable.current_events_index })
    
    GlobalDebugTable.event_count[events_state.array_index] = events_state.events_index
    
    collate_debug_records(debug_state, GlobalDebugTable.events_state.array_index)
    k := 123
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

collate_debug_records :: proc(debug_state: ^DebugState, invalid_events_index: u32) {
    debug_state.frames = push(&debug_state.arena, DebugFrame, DebugMaxHistoryLength * 2)
    debug_state.frame_bar_lane_count = 0
    debug_state.frame_bar_scale = 1.0 / 60_000_000.0//1
    debug_state.frame_count = 0
    
    current_frame: ^DebugFrame
    
    events_index := invalid_events_index
    modular_add(&events_index, 1, DebugMaxHistoryLength)
    for {
        if events_index == invalid_events_index do break
        defer modular_add(&events_index, 1, DebugMaxHistoryLength)
        
        for &event in GlobalDebugTable.events[events_index][:GlobalDebugTable.event_count[events_index]] {
            if event.type == .FrameMarker {
                if current_frame != nil {
                    current_frame.end_clock = event.clock
                    clocks := cast(f32) (current_frame.end_clock - current_frame.begin_clock)
                    
                    if clocks != 0 {
                        // scale := 1.0 / clocks
                        // debug_state.frame_bar_scale = min(debug_state.frame_bar_scale, scale)
                    }
                }
                
                current_frame = &debug_state.frames[debug_state.frame_count]
                modular_add(&debug_state.frame_count, 1, auto_cast len(debug_state.frames))

                current_frame^ = {
                    begin_clock  = event.clock,
                    end_clock    = -1,
                    region_count = 0,
                    regions      = push(&debug_state.arena, DebugRegion, DebugMaxRegionsPerFrame)
                }
            } else if current_frame != nil {
                source := &GlobalDebugTable.records[event.record_index]
                frame_relative_clock := event.clock - current_frame.begin_clock
                thread := &debug_state.threads[event.thread_index]
                frame_index := debug_state.frame_count-1
                
                switch event.type {
                  case .FrameMarker: unreachable()
                  case .BeginBlock:
                    block := debug_state.first_free_block
                    if block != nil {
                        debug_state.first_free_block = block.next_free
                    } else {
                        block = push(&debug_state.arena, DebugOpenBlock)
                    }
                    block^ = {
                        frame_index   = frame_index,
                        opening_event = &event,
                        parent        = thread.first_open_block
                    }
                    thread.first_open_block = block
                  case .EndBlock:
                    matching_block := thread.first_open_block
                    if matching_block != nil && matching_block.frame_index == frame_index {
                        opening_event := matching_block.opening_event
                        if opening_event != nil &&
                           opening_event.thread_index == event.thread_index &&
                           opening_event.record_index == event.record_index {
                            
                            if matching_block.frame_index == frame_index {
                                if matching_block.parent == nil {
                                    region := &current_frame.regions[current_frame.region_count]
                                    current_frame.region_count += 1
                                    
                                    region^ = {
                                        lane_index = thread.thread_index,
                                        t_min = cast(f32) (opening_event.clock - current_frame.begin_clock),
                                        t_max = cast(f32) (event.clock - current_frame.begin_clock) ,
                                    }
                                } else {
                                    // TODO(viktor): nested regions
                                }
                            } else {
                                // TODO(viktor): Record all frames in between and begin/end spans
                            }
                            
                            matching_block.next_free = debug_state.first_free_block
                            debug_state.first_free_block = matching_block
                            
                            thread.first_open_block = matching_block.parent
                            matching_block^ = {}
                            
                        } else {
                            // TODO(viktor): Record span that goes to the beginning of the frame
                        }
                    }
                }

            }
        }
    }
}

overlay_debug_info :: proc(memory: ^GameMemory) {
    if memory.debug_storage == nil do return
    
    assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)

    
    
    target_fps   :: 72.0
    
    lane_count   := cast(f32) debug_state.frame_bar_lane_count
    lane_width   :: 8
    bar_width    := lane_width * lane_count
    bar_padding  :: 2
    chart_height :: 120

    full_width ::  500 //cast(f32) len(debug_state.frame_infos) * (bar_width + bar_spacing) - bar_spacing
    pad_x :: 20 // Debug_render_group.transform.screen_center.x - full_width * 0.5
    pad_y :: 20
    
    chart_left := left_edge + pad_x
    chart_bottom := -Debug_render_group.transform.screen_center.y + pad_y
    target_height: f32 = chart_height * 2
    target_padding :: 40
    target_width := full_width + target_padding
    background_color :: v4{0.08, 0.08, 0.3, 1}
    
    scale := debug_state.frame_bar_scale * chart_height
    for frame, frame_index in debug_state.frames[:debug_state.frame_count] {
        stack_x := chart_left + (bar_width * bar_padding) * cast(f32) frame_index
        stack_y := chart_bottom
        for region, region_index in frame.regions[:frame.region_count] {
            phase := cast(f32) (region_index) / cast(f32) len(frame.regions)-1
            color := v4{phase*phase, 1-phase, phase, 1}
            
            y_min := stack_y + scale * region.t_min
            y_max := stack_y + scale * region.t_max
            
            push_rectangle(Debug_render_group, {stack_x + 0.5 * lane_width + lane_width * cast(f32) region.lane_index, (y_min + y_max)*0.5, 0}, { lane_width, (y_max - y_min)}, color)
            // stack separator
            // push_rectangle(Debug_render_group, {stack_x, stack_y, 0} + offset_p + {0.5*(size.x), 0, 0}, {size.x+2, 1}, background_color)
        }
    }

    when false {
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
                chart_bottom := cp_y
                chart_height := ascent * font_scale - 2
                width : f32 = 4
                if cycles.max > 0 {
                    scale := 1 / cast(f32) cycles.max
                    for snapshot, index in state.snapshots {
                        proportion := cast(f32) snapshot.cycle_count * scale
                        height := chart_height * proportion
                        push_rectangle(Debug_render_group, 
                            {cast(f32) index * width + 0.5*width, height * 0.5 + chart_bottom, 0}, 
                            {width, height}, 
                            {proportion, 0.7, 0.8, 1},
                        )
                    }
                }
                
                text_line(fmt.tprintf("%28s(% 4d): % 12.0f : % 6.0f : % 10.0f", state.loc.name, state.loc.line, cycles.avg, hits.avg, cphs.avg))
            }
        }

        push_rectangle(Debug_render_group, 
            {chart_left + 0.5 * full_width, chart_bottom + (target_height) * 0.5, 0}, 
            {target_width, target_height}, 
            background_color
        )
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
    
    font_id = best_match_font_from(Debug_render_group.assets, .Font, #partial { .FontType = cast(f32) AssetFontType.Debug }, #partial { .FontType = 1 })
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
    // NOTE(viktor): kerning and unicode test lines
    // Debug_text_line("贺佳樱我爱你")
    // Debug_text_line("AVA: WA ty fi ij `^?'\"")
    // Debug_text_line("0123456789°")
    
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

debug_statistic_accumulate :: #force_inline proc(stat: ^DebugStatistic, value: $N) {
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
