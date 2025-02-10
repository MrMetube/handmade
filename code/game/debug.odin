package game

import "core:fmt"
import "core:hash" // TODO(viktor): I do not need this

PROFILE  :: #config(PROFILE, false)

////////////////////////////////////////////////

DebugMaxThreadCount     :: 256
DebugMaxHistoryLength   :: 6
DebugMaxRegionsPerFrame :: 14000

GlobalDebugTable:  DebugTable
GlobalDebugMemory: ^GameMemory

////////////////////////////////////////////////

DebugState :: struct {
    inititalized: b32,
    paused:       b32,
    debug_arena:   Arena,
    
    // NOTE(viktor): Collation
    collation_arena:  Arena,
    collation_memory: TemporaryMemory,
    collation_index:  u32,
    collation_frame:  ^DebugFrame,
    scopes_to_record: []^DebugRecord,
    
    
    frame_bar_scale:      f32,
    frame_bar_lane_count: u32,
    
    frame_count: u32,
    frames:      []DebugFrame,
    
    threads: []DebugThread,
    
    menu_p:         v2,
    hot_menu_index: i32,
    profile_on:     b32,
    framerate_on:   b32,
    
    // NOTE(viktor): Overlay rendering
    render_group: ^RenderGroup,
    
    work_queue: ^PlatformWorkQueue, 
    buffer:     Bitmap,
    
    profile_rect: Rectangle2,
    font_scale:   f32,
    cp_y:         f32,
    ascent:       f32,
    left_edge:    f32,
    
    font_id:      FontId,
    font:         ^Font,
    font_info:    ^FontInfo,
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

get_debug_state :: proc() -> (debug_state: ^DebugState) {
    return get_debug_state_with_memory(GlobalDebugMemory)
}
get_debug_state_with_memory :: proc(memory: ^GameMemory) -> (debug_state: ^DebugState) {
    assert(len(memory.debug_storage) >= size_of(DebugState))
    debug_state = cast(^DebugState) raw_data(memory.debug_storage)
    assert(debug_state.inititalized)
    
    return debug_state
}

@export
debug_frame_end :: proc(memory: ^GameMemory) {
    debug_state := get_debug_state()
    if debug_state == nil do return

    modular_add(&GlobalDebugTable.current_events_index, 1, len(GlobalDebugTable.events))
    events_state := atomic_exchange(&GlobalDebugTable.events_state, { events_index = 0, array_index = GlobalDebugTable.current_events_index })
    GlobalDebugTable.event_count[events_state.array_index] = events_state.events_index
    
    if !debug_state.paused {
        if debug_state.collation_index >= DebugMaxHistoryLength-1 {
            restart_collation(events_state.array_index)
        }
        
        collate_debug_records(events_state.array_index)
    }
}

////////////////////////////////////////////////

restart_collation :: proc(invalid_index: u32) {
    debug_state := get_debug_state()
    if debug_state == nil do return
    
    end_temporary_memory(debug_state.collation_memory)
    debug_state.collation_memory = begin_temporary_memory(&debug_state.collation_arena)
    
    debug_state.frames = push(&debug_state.collation_arena, DebugFrame, DebugMaxHistoryLength)
    debug_state.frame_bar_scale = 1.0 / 60_000_000.0//1
    debug_state.frame_count = 0
    
    debug_state.collation_index = invalid_index + 1
    debug_state.collation_frame = nil
}

refresh_collation :: proc() {
    debug_state := get_debug_state()
    if debug_state == nil do return
    
    restart_collation(GlobalDebugTable.events_state.array_index)
    collate_debug_records(GlobalDebugTable.events_state.array_index)
}

collate_debug_records :: proc(invalid_events_index: u32) {
    debug_state := get_debug_state()
    if debug_state == nil do return
    
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
                    regions         = push(&debug_state.collation_arena, DebugRegion, DebugMaxRegionsPerFrame)
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
                        block = push(&debug_state.collation_arena, DebugOpenBlock)
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

////////////////////////////////////////////////

debug_reset :: proc(memory: ^GameMemory, assets: ^Assets, work_queue: ^PlatformWorkQueue, buffer: Bitmap) {
    assert(len(memory.debug_storage) >= size_of(DebugState))
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)
    
    if !debug_state.inititalized {
        debug_state.inititalized = true
        // :PointerArithmetic
        init_arena(&debug_state.debug_arena, memory.debug_storage[size_of(DebugState):])
        sub_arena(&debug_state.collation_arena, &debug_state.debug_arena, 64 * Megabyte)
        
        debug_state.work_queue = work_queue
        debug_state.buffer     = buffer
        
        debug_state.threads = push(&debug_state.collation_arena, DebugThread, DebugMaxThreadCount)
        debug_state.scopes_to_record = push(&debug_state.collation_arena, ^DebugRecord, DebugMaxThreadCount)
        
        debug_state.font_scale = 0.6
        debug_state.hot_menu_index = -1
        
        debug_state.collation_memory = begin_temporary_memory(&debug_state.collation_arena)
        restart_collation(GlobalDebugTable.events_state.array_index)
    }
    
    if debug_state.render_group == nil {
        debug_state.render_group = make_render_group(&debug_state.debug_arena, assets, 32 * Megabyte, false)
        assert(debug_state.render_group != nil)
    }
    if debug_state.render_group.inside_render do return 
    
    begin_render(debug_state.render_group)
    
    debug_state.font_id = best_match_font_from(assets, .Font, #partial { .FontType = cast(f32) AssetFontType.Debug }, #partial { .FontType = 1 })
    debug_state.font    = get_font(assets, debug_state.font_id, debug_state.render_group.generation_id)
    
    baseline :f32= 10
    if debug_state.font != nil {
        debug_state.font_info = get_font_info(assets, debug_state.font_id)
        baseline = get_baseline(debug_state.font_info)
        debug_state.ascent = get_baseline(debug_state.font_info)
    } else {
        load_font(debug_state.render_group.assets, debug_state.font_id, false)
    }
    
    debug_state.cp_y      =  0.5 * cast(f32) buffer.height - baseline * debug_state.font_scale
    debug_state.left_edge = -0.5 * cast(f32) buffer.width
}

debug_end_and_overlay :: proc(input: Input) {
    debug_state := get_debug_state()
    if debug_state == nil do return
    
    overlay_debug_info(input)
    tiled_render_group_to_output(debug_state.work_queue, debug_state.render_group, debug_state.buffer)
    end_render(debug_state.render_group)
}

overlay_debug_info :: proc(input: Input) {
    debug_state := get_debug_state()
    if debug_state == nil || debug_state.render_group == nil do return

    mouse_p := input.mouse_position
    if was_pressed(input.mouse_right) {
    }
       
    if input.mouse_right.ended_down {
        if input.mouse_right.half_transition_count > 0 {
            debug_state.menu_p = mouse_p
        }
        debug_main_menu(debug_state, mouse_p)
    } else if input.mouse_right.half_transition_count > 0 {
        debug_main_menu(debug_state, mouse_p)
        switch debug_state.hot_menu_index {
          case 0:// "Toggle Profiler Graph",
            debug_state.profile_on = !debug_state.profile_on
          case 1:// "Toggle Framerate Counter",
            debug_state.framerate_on = !debug_state.framerate_on
          case 2:// "Toggle Profiler Pause",
            debug_state.paused = !debug_state.paused
          case 3:// "Mark Loop Point",
            
          case 4:// "Toggle Entity Bounds", 
          case 5:// "Toggle World Chunk Bounds", 
        }
    }
     
    target_fps :: 72

    pad_x :: 20
    pad_y :: 20
    
    orthographic(debug_state.render_group, {debug_state.buffer.width, debug_state.buffer.height}, 1)

    if debug_state.framerate_on {
        push_text_line(fmt.tprintf("Last Frame time: %5.4f ms", debug_state.frames[0].seconds_elapsed*1000))
    }
    
    if debug_state.profile_on {
        debug_state.profile_rect = rectangle_min_max(v2{50, 50}, v2{200, 200})
        push_rectangle(debug_state.render_group, debug_state.profile_rect, {0.08, 0.08, 0.2, 1} )
        
        bar_padding :: 2
        lane_count  := cast(f32) debug_state.frame_bar_lane_count +1 
        lane_height :f32
        frame_count := cast(f32) len(debug_state.frames)
        if frame_count > 0 && lane_count > 0 {
            lane_height = ((rectangle_get_diameter(debug_state.profile_rect).y / frame_count) - bar_padding) / lane_count
        }
        
        bar_height       := lane_height * lane_count
        bar_plus_spacing := bar_height + bar_padding
        
        full_height := bar_plus_spacing * frame_count
        
        chart_left  := debug_state.profile_rect.min.x
        chart_top   := debug_state.profile_rect.max.y - bar_plus_spacing
        chart_width := rectangle_get_diameter(debug_state.profile_rect).x
        
        scale := debug_state.frame_bar_scale * chart_width
        
        hot_region: ^DebugRegion
        for frame_index in 0..<len(debug_state.frames) {
            frame := &debug_state.frames[(frame_index + cast(int) debug_state.collation_index) % len(debug_state.frames)]
            
            stack_x := chart_left
            stack_y := chart_top - bar_plus_spacing * cast(f32) frame_index
            for &region, region_index in frame.regions[:frame.region_count] {
                
                x_min := stack_x + scale * region.t_min
                x_max := stack_x + scale * region.t_max

                y_min := stack_y + 0.5 * lane_height + lane_height * cast(f32) region.lane_index
                y_max := y_min + lane_height
                rect := rectangle_min_max(v2{x_min, y_min}, v2{x_max, y_max})
                
                color_wheel := color_wheel
                color := color_wheel[region.record.hash * 13 % len(color_wheel)]
                            
                push_rectangle(debug_state.render_group, rect, color)
                if rectangle_contains(rect, mouse_p) {
                    record := region.record
                    if was_pressed(input.mouse_left) {
                        hot_region = &region
                    }
                    text := fmt.tprintf("%s - %d cycles [%s:% 4d]", record.loc.name, region.cycle_count, record.loc.file_path, record.loc.line)
                    debug_push_text(text, mouse_p)
                }
            }
        }
        
        if was_pressed(input.mouse_left) {
            if hot_region != nil {
                debug_state.scopes_to_record[hot_region.lane_index] = hot_region.record
            } else {
                for &scope in debug_state.scopes_to_record do scope = nil
            }
            refresh_collation()
        }
    }
}

debug_main_menu :: proc(debug_state: ^DebugState, mouse_p: v2) {
    menu_items := [?]string {
        "Toggle Profiler Graph",
        "Toggle Framerate Counter",
        "Toggle Profiler Pause",
        "Mark Loop Point",
        "Toggle Entity Bounds", 
        "Toggle World Chunk Bounds", 
    }
    
    best_distance_squared := length_squared(debug_state.menu_p - mouse_p)
    hot_index :i32 = -1
    
    radius :f32= 200
    angle := Tau / cast(f32) len(menu_items)
    for item, item_index in menu_items {
        item_angle := angle * cast(f32) item_index
        text_rect := debug_measure_text(item)
        p := debug_state.menu_p + arm(item_angle) * radius
        
        distance_squared := length_squared(p - mouse_p)
        if best_distance_squared > distance_squared {
            best_distance_squared = distance_squared
            hot_index = auto_cast item_index
        }
        
        p +=  -0.5 * rectangle_get_diameter(text_rect)
        color : v4 = 1
        if auto_cast item_index == debug_state.hot_menu_index {
            color = Blue
        }
        debug_push_text(item, p, color)
    }
    
    debug_state.hot_menu_index = hot_index
}

debug_push_text :: proc(text: string, p: v2, color: v4 = 1) {
    debug_state := get_debug_state()
    if debug_state == nil do return
    
    if debug_state.font != nil {
        text_op(.Draw, debug_state.render_group, debug_state.font, debug_state.font_info, text, p, debug_state.font_scale, color)
    }
}

debug_measure_text :: proc(text: string) -> (result: Rectangle2) {
    debug_state := get_debug_state()
    if debug_state == nil do return
    
    if debug_state.font != nil {
        result = text_op(.Measure, debug_state.render_group, debug_state.font, debug_state.font_info, text, {0, 0}, debug_state.font_scale)
    }
    
    return result
}

push_text_line :: proc(text: string) {
    debug_state := get_debug_state()
    if debug_state == nil do return
    
    assert(debug_state.render_group.inside_render)
    
    debug_push_text(text, {debug_state.left_edge, debug_state.cp_y})
    if debug_state.font != nil {
        advance_y := get_line_advance(debug_state.font_info)
        debug_state.cp_y -= debug_state.font_scale * advance_y
    }
}

TextRenderOperation:: enum {
    Measure, Draw, 
}

text_op :: proc(operation: TextRenderOperation, group: ^RenderGroup, font: ^Font, font_info: ^FontInfo, text: string, p:v2, font_scale: f32, color: v4 = 1) -> (result: Rectangle2) {
    result = inverted_infinity_rectangle(Rectangle2)
    // TODO(viktor): kerning and unicode test lines
    // AVA: WA ty fi ij `^?'\"
    // 贺佳樱我爱你
    // 0123456789°
    p := p
    previous_codepoint: rune
    for codepoint in text {
        defer previous_codepoint = codepoint
        
        advance_x := get_horizontal_advance_for_pair(font, font_info, previous_codepoint, codepoint)
        p.x += advance_x * font_scale
        
        bitmap_id := get_bitmap_for_glyph(font, font_info, codepoint)
        info := get_bitmap_info(group.assets, bitmap_id)
        
        height := cast(f32) info.dimension.y * font_scale
        switch operation {
          case .Draw: 
            if codepoint != ' ' {
                push_bitmap(group, bitmap_id, height, V3(p, 0), color)
            }
          case .Measure:
            bitmap := get_bitmap(group.assets, bitmap_id, group.generation_id)
            if bitmap != nil {
                dim := get_used_bitmap_dim(group, bitmap^, height, V3(p, 0))
                glyph_rect := rectangle_min_diameter(dim.p.xy, dim.size)
                result = rectangle_union(result, glyph_rect)
            }
        }
    }
    
    return result
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