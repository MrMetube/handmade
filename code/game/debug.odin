package game

import hha "./asset_builder"
import "core:fmt"
import "core:hash"
import "base:runtime"
import "base:intrinsics"

////////////////////////////////////////////////

DebugState :: struct {
    counter_states: [MaxTranslationUnits][512]DebugCounterState,
    
    index:         u32,
    frame_infos:   [144]DebugFrameInfo,
}

DebugCounterState :: struct {
    using loc: runtime.Source_Code_Location,
    snapshots: [144]DebugCounterSnapshot,
}

DebugStatistic :: struct {
    min, max, avg, count: f64
}

////////////////////////////////////////////////

@export
debug_frame_end :: proc(memory: ^GameMemory, frame_info: DebugFrameInfo) {
    if memory.debug_storage == nil do return
    
    assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)
    
    GlobalDebugTable.current_events_index = GlobalDebugTable.current_events_index == 0 ? 1 : 0
    events_state := atomic_exchange(&GlobalDebugTable.events_state, { events_index = 0, array_index = GlobalDebugTable.current_events_index })
    #assert(len(GlobalDebugTable.events) == 2)
    zero_slice(GlobalDebugTable.events[events_state.array_index == 0 ? 1 : 0][:])
    
    debug_state.frame_infos[debug_state.index] = frame_info
    debug_state.index += 1
    if debug_state.index >= len(debug_state.frame_infos) {
        debug_state.index = 0
    }
    
    // Clear out counter states, even if no event is associated with it.
    for unit in 0..<MaxTranslationUnits {
        for &counter in debug_state.counter_states[unit] {
            counter.snapshots[debug_state.index] = {}
        }
    }
    
    events := GlobalDebugTable.events[events_state.array_index][:events_state.events_index]
    for event in events {
        entry := &GlobalDebugTable.records[event.translation_unit][event.record_index]
        assert(entry.index == event.record_index)
        
        counter := &debug_state.counter_states[event.translation_unit][event.record_index]
        if counter.loc == {} {
            counter.loc = entry.loc
        } else {
            // :HotReload The static strings to the file and procedure do not survive a reload.
            assert(counter.loc.line   == entry.loc.line)
            assert(counter.loc.column == entry.loc.column)
        }
        
        snapshot := &counter.snapshots[debug_state.index]
        switch event.type {
        case .BeginBlock:
            snapshot.hit_count   += 1
            snapshot.cycle_count -= event.clock
            snapshot.depth += 1
        case .EndBlock:
            snapshot.cycle_count += event.clock
            snapshot.depth -= 1
        }
    }
}

overlay_debug_info :: proc(memory: ^GameMemory) {
    timed_block()
    
    if memory.debug_storage == nil do return
    
    assert(size_of(DebugState) <= len(memory.debug_storage), "The DebugState cannot fit inside the debug memory")
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)
    
    // NOTE(viktor): kerning and unicode test lines
    // Debug_text_line("贺佳樱我爱你")
    // Debug_text_line("AVA: WA ty fi ij `^?'\"")
    // Debug_text_line("0123456789°")
    
    text_line("Debug Game Cycle Counts:")
    for unit in 0..<MaxTranslationUnits {
        for state in debug_state.counter_states[unit] {
            if state.loc == {} do continue
            
            cycles := debug_statistic_begin()
            hits   := debug_statistic_begin()
            cphs   := debug_statistic_begin()
            
            for snapshot in state.snapshots {
                if snapshot.depth != 0 {
                    continue
                    // Its either a bug or the events for this snapshot are running parallel over multiple frames
                }
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
                
                text_line(fmt.tprintf("%28s(% 4d): % 12.0f : % 6.0f : % 10.0f", state.procedure, state.line, cycles.avg, hits.avg, cphs.avg))
            }
        }
    }
    
    target_frames_per_seconds :: 72.0
    bar_width    :: 5
    bar_spacing  :: 3
    chart_height :: 120
    
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
