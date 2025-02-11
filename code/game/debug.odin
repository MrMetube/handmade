package game

import "core:fmt"
import "core:hash" // TODO(viktor): I do not need this

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
    
    root_group:   ^DebugVariable,
    compiling:    b32,
    compiler:     DebugExecutingProcess,
    menu_p:       v2,
    hot_variable: ^DebugVariable,
    profile_on:   b32,
    framerate_on: b32,
    
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

DebugVariableValue :: union { 
    b32, 
    i32,
    u32,
    f32,
    v2,
    v3,
    v4,
    DebugVariableGroup
}

DebugVariable :: struct {
    name:   string,
    value:  DebugVariableValue,
    parent: ^DebugVariable,
    next:   ^DebugVariable,
}

DebugVariableGroup :: struct {
    expanded: b32,
    
    first_child: ^DebugVariable,
    last_child:  ^DebugVariable,
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
    
    if memory.reloaded_executable {
        restart_collation(GlobalDebugTable.events_state.array_index)
    }
    
    if !debug_state.paused {
        if debug_state.collation_index >= DebugMaxHistoryLength-1 {
            restart_collation(events_state.array_index)
        }
        
        collate_debug_records(events_state.array_index)
    }
}

debug_reset :: proc(memory: ^GameMemory, assets: ^Assets, work_queue: ^PlatformWorkQueue, buffer: Bitmap) {
    assert(len(memory.debug_storage) >= size_of(DebugState))
    debug_state := cast(^DebugState) raw_data(memory.debug_storage)
    if !debug_state.inititalized {
        debug_state.inititalized = true
        // :PointerArithmetic
        init_arena(&debug_state.debug_arena, memory.debug_storage[size_of(DebugState):])
        init_debug_variables()
        
        sub_arena(&debug_state.collation_arena, &debug_state.debug_arena, 64 * Megabyte)
        
        
        
        debug_state.work_queue = work_queue
        debug_state.buffer     = buffer
        
        debug_state.threads = push(&debug_state.collation_arena, DebugThread, DebugMaxThreadCount)
        debug_state.scopes_to_record = push(&debug_state.collation_arena, ^DebugRecord, DebugMaxThreadCount)
        
        debug_state.font_scale = 0.6
        
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
    
    target_fps :: 72

    pad_x :: 20
    pad_y :: 20
    
    orthographic(debug_state.render_group, {debug_state.buffer.width, debug_state.buffer.height}, 1)
    
    if debug_state.compiling {
        state := Platform.debug.get_process_state(debug_state.compiler)
        if state.is_running {
            push_text_line("Recompiling...")
        } else {
            debug_state.compiling = false
        }
    }
    
    if DEBUG_ShowFramerate {
        push_text_line(fmt.tprintf("Last Frame time: %5.4f ms", debug_state.frames[0].seconds_elapsed*1000))
    }
    
    debug_main_menu(debug_state, mouse_p)
    if input.mouse_right.ended_down {
        if input.mouse_right.half_transition_count > 0 {
            debug_state.menu_p = mouse_p
        }
    } else if was_pressed(input.mouse_left) {
        if debug_state.hot_variable != nil {
            reload := true
            switch &value in debug_state.hot_variable.value {
              case DebugVariableGroup:
                value.expanded = !value.expanded
                reload = false
              case b32:
                value = !value
              case i32, u32, f32, v2, v3, v4:
            }
            
            if reload do write_handmade_config()
        }
    }
    
    if DEBUG_ShowProfilingGraph {
        debug_state.profile_rect = rectangle_center_diameter(v2{0, 0}, v2{600, 600})
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

write_handmade_config :: proc() {
    debug_state := get_debug_state()
    if debug_state == nil do return
    
    if debug_state.compiling do return
    debug_state.compiling = true
    
    write :: proc(buffer: []u8, line: string) -> (result: u32) {
        for r, i in line {
            assert(r < 256, "no unicode in config")
            buffer[i] = cast(u8) r
        }
        
        result = auto_cast len(line)
        return result
    }
    
    contents: [4096*4]u8
    cursor: u32
    cursor += write(contents[cursor:], "package game\n\n")
    
    start := debug_state.root_group.value.(DebugVariableGroup).first_child
    for var := start; var != nil;  {
        next: ^DebugVariable
        defer var = next
        
        t: typeid
        switch value in var.value {
          case DebugVariableGroup:
            cursor += write(contents[cursor:], fmt.tprintfln("// %s", var.name))
            next = value.first_child
          case b32: t = b32
          case f32: t = f32
          case i32: t = i32
          case u32: t = u32
          case v2:  t = v2
          case v3:  t = v3
          case v4:  t = v4
        }
        
        if next == nil {
            cursor += write(contents[cursor:], fmt.tprintfln("%s :%w: %w", var.name, t, var.value))
            
            next = var
            for next != nil {
                if next.next != nil {
                    next = next.next
                    break
                } else {
                    next = next.parent
                }
            }
        }
    }
    
    HandmadeConfigFilename :: "../code/game/debug_config.odin"
    Platform.debug.write_entire_file(HandmadeConfigFilename, contents[:cursor])
    debug_state.compiler = Platform.debug.execute_system_command(`D:\handmade\`, `D:\handmade\build\build.exe`, `-Game`)
}

debug_main_menu :: proc(debug_state: ^DebugState, mouse_p: v2) {
    // menu_items := [?]string {
    //     "Toggle Profiler Pause",
    //     "Mark Loop Point",
    // }
    if debug_state.font_info == nil do return
    
    p := v2{ debug_state.left_edge, debug_state.cp_y}
    line_advance := get_line_advance(debug_state.font_info) * debug_state.font_scale
    depth: f32
    
    debug_state.hot_variable = nil
    
    start := debug_state.root_group.value.(DebugVariableGroup).first_child
    for var := start; var != nil;  {
        text:  string
        color := White
        
        depth_delta: f32
        defer depth += depth_delta
        
        next: ^DebugVariable
        defer var = next
        
        switch value in var.value {
          case DebugVariableGroup:
            text = fmt.tprintf("%s %v", value.expanded ? "-" : "+",  var.name)
            if value.expanded {
                color = Yellow
                next = value.first_child
                depth_delta = 1
            }
          case b32, u32, i32, f32, v2, v3, v4:
            text = fmt.tprintf("%s %v", var.name, value)
        }
        
        if next == nil {
            next = var
            for next != nil {
                if next.next != nil {
                    next = next.next
                    break
                } else {
                    next = next.parent
                    depth_delta -= 1 
                }
            }
        }
        
        text_p := p + {depth*line_advance*2, 0}
        text_rect := rectangle_add_offset(debug_measure_text(text), text_p)
        if rectangle_contains(text_rect, mouse_p) {
            color = Blue
            debug_state.hot_variable = var
        }
        
        debug_push_text(text, text_p, color)
        p.y -= line_advance
    }
    
    debug_state.cp_y = p.y
}

init_debug_variables :: proc () {
    DebugVariableDefinitionContext :: struct {
        arena:       ^Arena,
        group:       ^DebugVariable,
    }

    push_variable :: proc(ctx: ^DebugVariableDefinitionContext, name: string, value: DebugVariableValue) -> (result: ^DebugVariable) {
        result = push(ctx.arena, DebugVariable)
        result.name   = push_string(ctx.arena, name)
        result.value  = value
        result.parent = ctx.group
        
        if ctx.group != nil {
            group := &ctx.group.value.(DebugVariableGroup)
            if group != nil {
                if group.last_child != nil {
                    group.last_child.next = result
                    group.last_child      = result
                } else {
                    group.first_child = result
                    group.last_child  = result
                }
            }
        }
                
        return result
    }
    
    begin_variable_group :: proc(ctx: ^DebugVariableDefinitionContext, group_name: string) {
        group := push_variable(ctx, group_name, DebugVariableGroup{})
        ctx.group = group
    }
    
    add_variable :: proc(ctx: ^DebugVariableDefinitionContext, value: DebugVariableValue, variable_name := #caller_expression(value)) {
        var := push_variable(ctx, variable_name, value)
    }
    
    end_variable_group :: proc(ctx: ^DebugVariableDefinitionContext) {
        assert(ctx.group != nil)
        ctx.group = ctx.group.parent
    }
    debug_state := get_debug_state()
    assert(debug_state != nil)
    ctx := DebugVariableDefinitionContext { arena = &debug_state.debug_arena }
    begin_variable_group(&ctx, "Root")
    
    begin_variable_group(&ctx, "Profiling")
        add_variable(&ctx, DEBUG_Profiling)
        add_variable(&ctx, DEBUG_ShowFramerate)
        add_variable(&ctx, DEBUG_ShowProfilingGraph)
    end_variable_group(&ctx)
    

    begin_variable_group(&ctx, "Audio")
        add_variable(&ctx, DEBUG_SoundPanningWithMouse)
        add_variable(&ctx, DEBUG_SoundPitchingWithMouse)
    end_variable_group(&ctx)

    begin_variable_group(&ctx, "Rendering")
        add_variable(&ctx, DEBUG_UseDebugCamera)
        add_variable(&ctx, DEBUG_DebugCameraDistance)
    
        add_variable(&ctx, DEBUG_RenderSingleThreaded)
        add_variable(&ctx, DEBUG_TestWeirdScreenSizes)
        
        begin_variable_group(&ctx, "Bounds")
            add_variable(&ctx, DEBUG_ShowSpaceBounds)
            add_variable(&ctx, DEBUG_ShowGroundChunkBounds)
        end_variable_group(&ctx)
        
        begin_variable_group(&ctx, "ParticleSystem")
            add_variable(&ctx, DEBUG_ParticleSystemTest)
            add_variable(&ctx, DEBUG_ParticleGrid)
        end_variable_group(&ctx)
        
        begin_variable_group(&ctx, "CoordinateSystem")
            add_variable(&ctx, DEBUG_CoordinateSystemTest)
            add_variable(&ctx, DEBUG_ShowLightingBounceDirection)
            add_variable(&ctx, DEBUG_ShowLightingSampling)
        end_variable_group(&ctx)
    end_variable_group(&ctx)

    begin_variable_group(&ctx, "Entities")
        add_variable(&ctx, DEBUG_FamiliarFollowsHero)
        add_variable(&ctx, DEBUG_HeroJumping)
    end_variable_group(&ctx)
    
    debug_state.root_group = ctx.group
}

////////////////////////////////////////////////

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
    when !DEBUG_Profiling do return result
    
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

@(export, disabled=!DEBUG_Profiling)
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

@(export, disabled=!DEBUG_Profiling)
frame_marker :: #force_inline proc(seconds_elapsed: f32, loc := #caller_location) {
    record_debug_event_frame_marker(seconds_elapsed)
    
    frame_marker := &GlobalDebugTable.records[context.user_index][NilHashValue]
    frame_marker.loc.file_path = loc.file_path
    frame_marker.loc.line = loc.line
    frame_marker.loc.name = "Frame Marker"
    frame_marker.index = NilHashValue
    frame_marker.hash  = NilHashValue
}

@(disabled=!DEBUG_Profiling)
record_debug_event_frame_marker :: #force_inline proc (seconds_elapsed: f32) {
    event := record_debug_event_common(.FrameMarker, NilHashValue)
    event.as.frame_marker = {
        seconds_elapsed = seconds_elapsed,
    }
}

@(disabled=!DEBUG_Profiling)
record_debug_event_block :: #force_inline proc (type: DebugEventType, record_index: u32) {
    event := record_debug_event_common(type, record_index)
    event.as.block = {
        thread_index = cast(u16) context.user_index,
        core_index   = 0,
    }
}

@require_results
record_debug_event_common :: #force_inline proc (type: DebugEventType, record_index: u32) -> (event: ^DebugEvent) {
    when !DEBUG_Profiling do return
    
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