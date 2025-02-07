package game

import "core:fmt"
import "core:hash" // TODO(viktor): I do not need this

PROFILE  :: #config(PROFILE, false)

////////////////////////////////////////////////

DebugMaxThreadCount     :: 256
DebugMaxHistoryLength   :: 12
DebugMaxRegionsPerFrame :: 14000

GlobalDebugTable: DebugTable

////////////////////////////////////////////////

DebugState :: struct {
    inititalized: b32,
    paused:       b32,
    
    // NOTE(viktor): Collation
    arena:            Arena,
    collation_memory: TemporaryMemory,
    collation_index:  u32,
    collation_frame:  ^DebugFrame,
    scopes_to_record: []^DebugRecord,
    
    frame_bar_scale:      f32,
    frame_bar_lane_count: u32,
    
    frame_count: u32,
    frames:      []DebugFrame,
    
    threads: []DebugThread,
}

DebugFrame :: struct {
    begin_clock,
    end_clock:       i64,
    seconds_elapsed: f32,
    region_count:    u32,
    regions:         []DebugRegion,
}

DebugRegion :: struct {
    record:       ^DebugRecord,
    cycle_count:  i64,
    lane_index:   u32,
    t_min, t_max: f32,
}

DebugThread :: struct {
    thread_index:     u32, // Also used as a lane_index
    
    first_free_block: ^DebugOpenBlock,
    first_open_block: ^DebugOpenBlock,
}

DebugOpenBlock :: struct {
    frame_index:   u32,
    source:        ^DebugRecord,
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
    
    records: [DebugMaxThreadCount]DebugRecords,
}

DebugEvent :: struct {
    clock: i64,
    as: struct #raw_union {
        block: struct {
            thread_index: u16,
            core_index:   u16,                    
        },
        frame_marker: struct {
            seconds_elapsed: f32,
        }
    },
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
    BeginBlock, 
    EndBlock,
    FrameMarker,
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

refresh_collation :: proc(debug_state: ^DebugState) {
    restart_collation(debug_state, GlobalDebugTable.events_state.array_index)
    collate_debug_records(debug_state, GlobalDebugTable.events_state.array_index)
}

restart_collation :: proc(debug_state: ^DebugState, invalid_index: u32) {
    end_temporary_memory(debug_state.collation_memory)
    debug_state.collation_memory = begin_temporary_memory(&debug_state.arena)
    
    debug_state.frames = push(&debug_state.arena, DebugFrame, DebugMaxHistoryLength)
    debug_state.frame_bar_scale = 1.0 / 60_000_000.0//1
    debug_state.frame_count = 0
    
    debug_state.collation_index = invalid_index + 1
    debug_state.collation_frame = nil
}

@export
debug_frame_end :: proc(memory: ^GameMemory) {
    if memory.debug_storage == nil do return
    assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)

    modular_add(&GlobalDebugTable.current_events_index, 1, len(GlobalDebugTable.events))
    events_state := atomic_exchange(&GlobalDebugTable.events_state, { events_index = 0, array_index = GlobalDebugTable.current_events_index })
    GlobalDebugTable.event_count[events_state.array_index] = events_state.events_index
    
    if !debug_state.inititalized {
        defer debug_state.inititalized = true
        // :PointerArithmetic
        init_arena(&debug_state.arena, memory.debug_storage[size_of(DebugState):])
        debug_state.threads = push(&debug_state.arena, DebugThread, DebugMaxThreadCount)
        debug_state.scopes_to_record = push(&debug_state.arena, ^DebugRecord, DebugMaxThreadCount)
        
        debug_state.collation_memory = begin_temporary_memory(&debug_state.arena)
        restart_collation(debug_state, events_state.array_index)
    }
    
    if !debug_state.paused {
        if debug_state.collation_index >= DebugMaxHistoryLength-1 {
            restart_collation(debug_state, events_state.array_index)
        }
        
        collate_debug_records(debug_state, events_state.array_index)
    }
}

collate_debug_records :: proc(debug_state: ^DebugState, invalid_events_index: u32) {
    // @Hack why should this need to be reset? Think dont guess
    for &thread in debug_state.threads do thread.first_open_block = nil
    
    modular_add(&debug_state.collation_index, 0, DebugMaxHistoryLength)
    for {
        if debug_state.collation_index == invalid_events_index do break
        defer modular_add(&debug_state.collation_index, 1, DebugMaxHistoryLength)
        
        for &event in GlobalDebugTable.events[debug_state.collation_index][:GlobalDebugTable.event_count[debug_state.collation_index]] {
            if event.type == .FrameMarker {
                if debug_state.collation_frame != nil {
                    debug_state.collation_frame.end_clock = event.clock
                    modular_add(&debug_state.frame_count, 1, auto_cast len(debug_state.frames))
                    debug_state.collation_frame.seconds_elapsed = event.as.frame_marker.seconds_elapsed
                    
                    clocks := cast(f32) (debug_state.collation_frame.end_clock - debug_state.collation_frame.begin_clock)
                    if clocks != 0 {
                        // scale := 1.0 / clocks
                        // debug_state.frame_bar_scale = min(debug_state.frame_bar_scale, scale)
                    }
                }
                
                debug_state.collation_frame = &debug_state.frames[debug_state.frame_count]
                debug_state.collation_frame^ = {
                    begin_clock     = event.clock,
                    end_clock       = -1,
                    regions         = push(&debug_state.arena, DebugRegion, DebugMaxRegionsPerFrame)
                }
            } else if debug_state.collation_frame != nil {
                debug_state.frame_bar_lane_count = max(debug_state.frame_bar_lane_count, cast(u32) event.as.block.thread_index)
                
                source := &GlobalDebugTable.records[event.as.block.thread_index][event.record_index]
                frame_relative_clock := event.clock - debug_state.collation_frame.begin_clock
                thread := &debug_state.threads[event.as.block.thread_index]
                frame_index := debug_state.frame_count-1
                
                switch event.type {
                case .FrameMarker: unreachable()
                case .BeginBlock:
                    block := thread.first_free_block
                    if block != nil {
                        thread.first_free_block = block.next_free
                    } else {
                        block = push(&debug_state.arena, DebugOpenBlock)
                    }
                    block^ = {
                        frame_index   = frame_index,
                        opening_event = &event,
                        parent        = thread.first_open_block,
                        source        = source,
                    }
                    thread.first_open_block = block
                case .EndBlock:
                    matching_block := thread.first_open_block
                    if matching_block != nil {
                        opening_event := matching_block.opening_event
                        if opening_event != nil && opening_event.as.block.thread_index == event.as.block.thread_index && opening_event.record_index == event.record_index {
                            if matching_block.frame_index == frame_index {
                                record_from :: #force_inline proc(block: ^DebugOpenBlock) -> (result: ^DebugRecord) {
                                    result = block != nil ? block.source : nil
                                    return 
                                }
                                
                                if record_from(matching_block.parent) == debug_state.scopes_to_record[event.as.block.thread_index] {
                                    t_min := cast(f32) (opening_event.clock - debug_state.collation_frame.begin_clock)
                                    t_max := cast(f32) (event.clock - debug_state.collation_frame.begin_clock)
                                    
                                    threshold :: 0.001
                                    if t_max - t_min > threshold {
                                        region := &debug_state.collation_frame.regions[debug_state.collation_frame.region_count]
                                        debug_state.collation_frame.region_count += 1
                                        
                                        region^ = {
                                            record      = source,
                                            cycle_count = event.clock - opening_event.clock,
                                            lane_index = cast(u32) event.as.block.thread_index,
                                            t_min = t_min,
                                            t_max = t_max,
                                        }
                                    }
                                } else {
                                    // TODO(viktor): nested regions
                                }
                            } else {
                                // TODO(viktor): Record all frames in between and begin/end spans
                            }
                            
                            // TODO(viktor): These free list do not behave well with either multi threading and or the frame boundaries which free the temporary memory 
                            // matching_block.next_free = thread.first_free_block
                            // thread.first_free_block = matching_block
                            
                            thread.first_open_block = matching_block.parent
                        } else {
                            // TODO(viktor): Record span that goes to the beginning of the frame
                        }
                    }
                }

            }
        }
    }
}

overlay_debug_info :: proc(memory: ^GameMemory, input: Input) {
    if memory.debug_storage == nil do return
    assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)

    mouse_p := input.mouse_position
    if was_pressed(input.mouse_right) {
        debug_state.paused = !debug_state.paused
    }
    
    target_fps :: 72

    pad_x :: 80
    pad_y :: 80
    
    lane_count   := cast(f32) debug_state.frame_bar_lane_count +1 
    full_width   := GlobalWidth - pad_x
    full_height  := GlobalHeight - pad_y
    
    bar_padding  :: 2
    bar_height   := full_height / cast(f32) len(debug_state.frames) - bar_padding
    lane_height  := bar_height / lane_count
    chart_width  :: 600.0
    
    chart_left :f32= -0.5 * full_width
    chart_top  :f32= 0.5 * full_height - pad_y
    target_left: f32 = chart_width
    target_height :f32= full_height
    
    push_rectangle(Debug_render_group, 
        rectangle_min_diameter(v2{chart_left + target_left * 0.5, chart_top + target_height}, v2{1, target_height}), 
        v4{1, 1, 1, 1}
    )
      
    if debug_state.frame_count > 0 {
        push_text_line(fmt.tprintf("Last Frame time: %5.4f ms", debug_state.frames[0].seconds_elapsed*1000))
    }
    
    hsv_to_rgb :: proc(hsv: v3) -> (rgb: v3) {
        hue, sat, val := hsv[0], hsv[1], hsv[2]
        
        if sat == 0 do return {val, val, val}
    
        h_i := floor(hue * 6, i32);
        hue_fraction := hue * 6 - cast(f32) h_i
        p := val * (1 - sat)
        q := val * (1 - hue_fraction * sat)
        t := val * (1 - (1 - hue_fraction) * sat)
    
        switch h_i {
        case 0: return {val, t, p}
        case 1: return {q, val, p}
        case 2: return {p, val, t}
        case 3: return {p, q, val}
        case 4: return {t, p, val}
        case 5: return {val, p, q}
        case 6: return {val, t, q} // @Hack its ai code, get a real implementation
        }
        return 
    }
    colors: [10]v4
    for &color, i in colors {
        color.rgb = hsv_to_rgb({1/cast(f32)(i+1), 0.6, 0.9})
        color.a = 1
    }
    
    hot_region: ^DebugRegion
    scale := debug_state.frame_bar_scale * chart_width
    for frame_index in 0..<len(debug_state.frames) {
        frame := &debug_state.frames[(frame_index + cast(int) debug_state.collation_index) % len(debug_state.frames)]
        
        stack_x := chart_left
        stack_y := chart_top - (bar_height + bar_padding) * cast(f32) frame_index
        for &region, region_index in frame.regions[:frame.region_count] {
            
            x_min := stack_x + scale * region.t_min
            x_max := stack_x + scale * region.t_max

            y_min := stack_y + 0.5 * lane_height + lane_height * cast(f32) region.lane_index
            y_max := y_min + lane_height
            rect := rectangle_min_max(v2{x_min, y_min}, v2{x_max, y_max})

            color := colors[(17*region.record.hash) % len(colors)]
            color = colors[region.record.hash % len(colors)]
                        
            push_rectangle(Debug_render_group, rect, color)
            if rectangle_contains(rect, mouse_p) {
                record := region.record
                if was_pressed(input.mouse_left) {
                    hot_region = &region
                }
                text := fmt.tprintf("%s - %d cycles [%s:% 4d]", record.loc.name, region.cycle_count, record.loc.file_path, record.loc.line)
                push_text_at(text, mouse_p)
            }
        }
    }
    
    if was_pressed(input.mouse_left) {
        if hot_region != nil {
            debug_state.scopes_to_record[hot_region.lane_index] = hot_region.record
        } else {
            for &scope in debug_state.scopes_to_record do scope = nil
        }
        refresh_collation(debug_state)
    }
}

font_scale : f32 = 0.6
cp_y:f32
ascent: f32
left_edge: f32
font_id: FontId
font: ^Font
GlobalWidth: f32
GlobalHeight: f32

reset_debug_renderer :: proc(width, height: i32) {
    begin_render(Debug_render_group)
    orthographic(Debug_render_group, {width, height}, 1)
    
    
    GlobalWidth  = cast(f32) width
    GlobalHeight = cast(f32) height
    
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

push_text_at :: proc(text: string, p:v2) {
    // TODO(viktor): kerning and unicode test lines
    // AVA: WA ty fi ij `^?'\"
    // 贺佳樱我爱你
    // 0123456789°
    p := p
    if font != nil {
        font_info := get_font_info(Debug_render_group.assets, font_id)
    
        previous_codepoint: rune
        for codepoint in text {
            defer previous_codepoint = codepoint
            
            advance_x := get_horizontal_advance_for_pair(font, font_info, previous_codepoint, codepoint)
            p.x += advance_x * font_scale
            
            bitmap_id := get_bitmap_for_glyph(font, font_info, codepoint)
            info := get_bitmap_info(Debug_render_group.assets, bitmap_id)
            
            if info != nil && codepoint != ' ' {
                push_bitmap(Debug_render_group, bitmap_id, cast(f32) info.dimension.y * font_scale, V3(p, 0))
            }
        }
    }
}

push_text_line :: proc(text: string) {
    if Debug_render_group != nil {
        assert(Debug_render_group.inside_render)
        
        push_text_at(text, {left_edge, cp_y})
        if font != nil {
            font_info := get_font_info(Debug_render_group.assets, font_id)
            advance_y := get_line_advance(font_info)
            cp_y -= font_scale * advance_y
        }
    }
}

////////////////////////////////////////////////

@(export)
begin_timed_block:: #force_inline proc(name: string, loc := #caller_location, #any_int hit_count: i64 = 1) -> (result: TimedBlock) {
    when !PROFILE do return result
    
    records := &GlobalDebugTable.records[context.user_index]

    key := DebugRecordLocation{
        name      = name,
        file_path = loc.file_path,
        line      = loc.line,
    }
    ok: b32
    // TODO(viktor): Check the overhead of this
    result.record_index, ok = get(records, key)
    if !ok {
        result.record_index = put(records, key)
    }
    result.hit_count = hit_count
    
    record_debug_event_block(.BeginBlock, result.record_index)
    
    return result
}

@(export, disabled=!PROFILE)
end_timed_block:: #force_inline proc(block: TimedBlock) {
    // TODO(viktor): check manual blocks are closed once and exactly once
    // TODO(viktor): record the hit count here
    record_debug_event_block(.EndBlock, block.record_index)
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

@(export, disabled=!PROFILE)
frame_marker :: #force_inline proc(seconds_elapsed: f32, loc := #caller_location) {
    record_debug_event_frame_marker(seconds_elapsed)
    
    frame_marker := &GlobalDebugTable.records[context.user_index][NilHashValue]
    frame_marker.loc.file_path = loc.file_path
    frame_marker.loc.line = loc.line
    frame_marker.loc.name = "Frame Marker"
    frame_marker.index = NilHashValue
    frame_marker.hash  = NilHashValue
}

record_debug_event_frame_marker :: #force_inline proc (seconds_elapsed: f32) {
    event := record_debug_event_common(.FrameMarker, NilHashValue)
    event.as.frame_marker = {
        seconds_elapsed = seconds_elapsed,
    }
}
record_debug_event_block :: #force_inline proc (type: DebugEventType, record_index: u32) {
    event := record_debug_event_common(type, record_index)
    event.as.block = {
        thread_index = cast(u16) context.user_index,
        core_index   = 0,
    }
}
@require_results
record_debug_event_common :: #force_inline proc (type: DebugEventType, record_index: u32) -> (event: ^DebugEvent) {
    when !PROFILE do return
    
    events := transmute(DebugEventsState) atomic_add(cast(^u64) &GlobalDebugTable.events_state, 1)
    event = &GlobalDebugTable.events[events.array_index][events.events_index]
    event^ = {
        type         = type,
        clock        = read_cycle_counter(),
        record_index = record_index,
    }
    
    return event
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

@(private="file")
NilHashValue :: 0

@(private="file")
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

@(private="file")
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

@(private="file")
put :: proc(ht: ^DebugRecords, value: DebugRecordLocation) -> (hash_index: u32) {
    entry: ^DebugRecord
    hash_value: u32
    entry, hash_value, hash_index = find(ht, value)
    
    entry.hash  = hash_value
    entry.index = hash_index
    entry.loc   = value
    
    return hash_index
}

@(private="file")
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

DebugStatistic :: struct {
    min, max, avg, count: f64
}

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