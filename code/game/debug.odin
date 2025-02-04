package game

import hha "./asset_builder"
import "core:fmt"
import "core:hash"
import "base:runtime"
import "base:intrinsics"

GameDebugRecords: DebugRecords



DebugRecords      :: [512]DebugRecordsEntry
DebugRecordsEntry :: struct{
    hash:   u32,
    loc:    runtime.Source_Code_Location,
    record: DebugRecord,
}

DebugState :: struct {
    count:         u32,
    couter_states: [512]DebugCounterState,
    
    index:         u32,
    frame_infos:   [144]DebugFrameInfo,
}

DebugCounterState :: struct {
    using loc: runtime.Source_Code_Location,
    index:     u32,
    snapshots: [144]DebugCounterSnapshot,
}

DebugCounterSnapshot :: struct {
    hit_count:   i32,
    cycle_count: i32,
}

DebugRecord :: struct {
    counts: DebugCounterSnapshot,
}

DebugStatistic :: struct {
    min, max, avg, count: f64
}

@export
debug_frame_end :: proc(memory: ^GameMemory, frame_info: DebugFrameInfo) {
    if memory.debug_storage == nil do return
    
    assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)
    
    debug_state.frame_infos[debug_state.index] = frame_info
    debug_state.index += 1
    if debug_state.index >= len(debug_state.frame_infos) {
        debug_state.index = 0
    }
    
    debug_state.count = 0
    for &entry in GameDebugRecords {
        if entry.hash != NilHashValue {
            loc    := entry.loc
            record := &entry.record
            
            state := &debug_state.couter_states[debug_state.count]
            debug_state.count += 1
            
            state.loc                    = loc
            state.snapshots[state.index] = record.counts
            
            record.counts = {}
            
            state.index += 1
            if state.index >= len(state.snapshots) {
                state.index = 0
            }
        }
    }
}

overlay_debug_info :: proc(memory: ^GameMemory) {
    if memory.debug_storage == nil do return
    
    assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)
    
    // NOTE(viktor): kerning and unicode test lines
    // Debug_text_line("贺佳樱我爱你")
    // Debug_text_line("AVA: WA ty fi ij `^?'\"")
    // Debug_text_line("0123456789°")
    
    text_line("Debug Game Cycle Counts:")
    for state, state_index in debug_state.couter_states[:debug_state.count] {
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
                    push_rectangle(Debug_render_group, {cast(f32) index * width + 0.5*width, height * 0.5 + chart_min_y, 0}, {width, height}, {proportion,0.7,0.8,1})
                }
            }
            
            text_line(fmt.tprintf("%28s(% 4d): % 12.0f : % 5.0f : % 10.0f", state.procedure, state.line, cycles.avg, hits.avg, cphs.avg))
        }
    }
    
    
    target_frames_per_seconds :: 72.0
    bar_width :: 5
    bar_spacing :: 3
    chart_height :: 150
    
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
            when false { // NOTE(viktor): exagerate small timestamps
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

font_scale : f32 = 0.5
cp_y, ascent: f32
left_edge: f32
font_id: FontId
font: ^Font

reset_debug_renderer :: proc(width, height: i32) {
    timed_block()
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

@(deferred_out=end_timed_block)
timed_block :: #force_inline proc(loc := #caller_location, #any_int hit_count: i32 = 1) -> (record: ^DebugRecord, start: i64, hit_count_out: i32) { 
    // TODO(viktor): @CompilerBug repro: Why can I use record here, when it is only using the loc?
    // if record not_in GameDebugRecords {
    // TODO(viktor): Check the overhead of this
    ok: b32
    record, ok = get(&GameDebugRecords, loc)
    if !ok {
        put(&GameDebugRecords, loc, {})
    }
    return record, read_cycle_counter(), hit_count
}

end_timed_block :: #force_inline proc(record: ^DebugRecord, start: i64, hit_count: i32) {
    if record != nil {
        end := read_cycle_counter()
        counts := DebugCounterSnapshot{ hit_count = hit_count, cycle_count = cast(i32) (end - start) }
        atomic_add(cast(^i64) &record.counts,  transmute(i64) counts)
    }
}

////////////////////////////////////////////////
// HashTable

@(private="file")
get_hash :: proc(ht: ^DebugRecords, value: runtime.Source_Code_Location) -> (result: u32) {
    result = cast(u32) (value.column * 391 + value.line * 464) % len(ht)
    
    if result == NilHashValue {
        strings := [2]u32{
            hash.djb2(transmute([]u8) value.file_path),
            hash.djb2(transmute([]u8) value.procedure),
        }
        bytes := (cast([^]u8) &strings[0])[:size_of(strings)]
        result = hash.djb2(bytes) % len(ht)
        assert(result != NilHashValue)
    }
    
    return result
}

@(private="file")
find :: proc(ht: ^DebugRecords, value: runtime.Source_Code_Location) -> (result: ^DebugRecordsEntry, hash_value: u32) {
    hash_value = get_hash(ht, value)
    hash_index := hash_value
    for {
        result = &ht[hash_index]
        if result.hash == NilHashValue || result.hash == hash_value && result.loc == value {
            break
        }
        hash_index += 1
        
        if hash_index == hash_value {
            assert(false, "cannot insert")
        }
    }
    return result, hash_value
}

@(private="file")
NilHashValue :: 0

@(private="file")
put :: proc(ht: ^DebugRecords, value: runtime.Source_Code_Location, record: DebugRecord) {
    entry, hash_value := find(ht, value)
    
    entry.hash   = hash_value
    entry.loc    = value
    entry.record = record
}

@(private="file")
get :: proc(ht: ^DebugRecords, value: runtime.Source_Code_Location) -> (record: ^DebugRecord, ok: b32) #optional_ok {
    entry, hash_value := find(ht, value)
    
    if entry != nil && entry.hash == hash_value && entry.loc == value {
        return &entry.record, true
    } else {
        return nil, false
    }
}
