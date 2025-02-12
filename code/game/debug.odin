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
    
    
    last_mouse_p:         v2,
    interaction:          DebugInteraction,
    interacting_with:     ^DebugVariable,
    
    hot_interaction:      DebugInteraction,
    next_hot_interaction: DebugInteraction,
    
    hot:                  ^DebugVariable,
    next_hot:             ^DebugVariable,
    
    root_group:           ^DebugVariable,
    hierarchy:            DebugVariableHierarchy,
    
    
    compiling:    b32,
    compiler:     DebugExecutingProcess,
    menu_p:       v2,
    profile_on:   b32,
    framerate_on: b32,
    
    // NOTE(viktor): Overlay rendering
    render_group: ^RenderGroup,
    
    work_queue: ^PlatformWorkQueue, 
    buffer:     Bitmap,
    
    font_scale:   f32,
    top_edge:         f32,
    ascent:       f32,
    left_edge:    f32,
    right_edge:   f32,
    
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

DebugInteraction :: enum {
    None, 
    
    NOP,
    
    Toggle, 
    Drag,
    Tear,
    
    ResizeProfile,
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

DebugVariable :: struct {
    name:   string,
    value:  DebugVariableValue,
    parent: ^DebugVariable,
    next:   ^DebugVariable,
}

DebugVariableValue :: union { 
    b32, i32, u32, f32, 
    v2, v3, v4,
    
    DebugVariableThreadList,
    DebugVariableGroup,
}

DebugVariableThreadList :: struct {
    dimension: v2,
}

DebugVariableGroup :: struct {
    expanded: b32,
    
    first_child: ^DebugVariable,
    last_child:  ^DebugVariable,
}

DebugVariableHierarchy :: struct {
    ui_p:       v2,
    root_group: ^DebugVariable,
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
    debug := get_debug_state()
    if debug == nil do return

    modular_add(&GlobalDebugTable.current_events_index, 1, len(GlobalDebugTable.events))
    events_state := atomic_exchange(&GlobalDebugTable.events_state, { events_index = 0, array_index = GlobalDebugTable.current_events_index })
    GlobalDebugTable.event_count[events_state.array_index] = events_state.events_index
    
    if memory.reloaded_executable {
        restart_collation(debug, GlobalDebugTable.events_state.array_index)
    }
    
    if !debug.paused {
        if debug.collation_index >= DebugMaxHistoryLength-1 {
            restart_collation(debug, events_state.array_index)
        }
        
        collate_debug_records(debug, events_state.array_index)
    }
}

debug_reset :: proc(memory: ^GameMemory, assets: ^Assets, work_queue: ^PlatformWorkQueue, buffer: Bitmap) {
    assert(len(memory.debug_storage) >= size_of(DebugState))
    debug := cast(^DebugState) raw_data(memory.debug_storage)
    
    if !debug.inititalized {
        debug.inititalized = true
        // :PointerArithmetic
        init_arena(&debug.debug_arena, memory.debug_storage[size_of(DebugState):])
        
        ctx := DebugVariableDefinitionContext { arena = &debug.debug_arena }

        debug_begin_variable_group(&ctx, "Debugging")
        
        init_debug_variables(&ctx)

        debug_begin_variable_group(&ctx, "Profile")
            debug_begin_variable_group(&ctx, "By Thread")
                debug_add_variable(&ctx, DebugVariableThreadList{ dimension = {800, 100}}, "")
            debug_end_variable_group(&ctx)
            debug_begin_variable_group(&ctx, "By Function")
                debug_add_variable(&ctx, DebugVariableThreadList{ dimension = {800, 200}}, "")
            debug_end_variable_group(&ctx)
        debug_end_variable_group(&ctx)
        
        debug.root_group = ctx.group
        

        sub_arena(&debug.collation_arena, &debug.debug_arena, 64 * Megabyte)
                
        debug.threads = push(&debug.collation_arena, DebugThread, DebugMaxThreadCount)
        debug.scopes_to_record = push(&debug.collation_arena, ^DebugRecord, DebugMaxThreadCount)
        
        debug.font_scale = 0.6

        debug.work_queue = work_queue
        debug.buffer     = buffer
        
        debug.collation_memory = begin_temporary_memory(&debug.collation_arena)
        restart_collation(debug, GlobalDebugTable.events_state.array_index)
    }

    
    if debug.render_group == nil {
        debug.render_group = make_render_group(&debug.debug_arena, assets, 32 * Megabyte, false)
        assert(debug.render_group != nil)
    }
    if debug.render_group.inside_render do return 
    
    begin_render(debug.render_group)
    
    
    debug.font_id = best_match_font_from(assets, .Font, #partial { .FontType = cast(f32) AssetFontType.Debug }, #partial { .FontType = 1 })
    debug.font    = get_font(assets, debug.font_id, debug.render_group.generation_id)
    
    if debug.font != nil {
        debug.font_info = get_font_info(assets, debug.font_id)
        debug.ascent = get_baseline(debug.font_info)
    } else {
        load_font(debug.render_group.assets, debug.font_id, false)
    }
    
    debug.left_edge  = -0.5 * cast(f32) buffer.width
    debug.right_edge =  0.5 * cast(f32) buffer.width
    debug.top_edge   =  0.5 * cast(f32) buffer.height
    
    debug.hierarchy.root_group = debug.root_group
    debug.hierarchy.ui_p = { debug.left_edge, debug.top_edge }
}

////////////////////////////////////////////////

restart_collation :: proc(debug: ^DebugState, invalid_index: u32) {
    end_temporary_memory(debug.collation_memory)
    debug.collation_memory = begin_temporary_memory(&debug.collation_arena)
    
    debug.frames = push(&debug.collation_arena, DebugFrame, DebugMaxHistoryLength)
    debug.frame_bar_scale = 1.0 / 60_000_000.0//1
    debug.frame_count = 0
    
    debug.collation_index = invalid_index + 1
    debug.collation_frame = nil
}

refresh_collation :: proc(debug: ^DebugState) {
    restart_collation(debug, GlobalDebugTable.events_state.array_index)
    collate_debug_records(debug, GlobalDebugTable.events_state.array_index)
}

collate_debug_records :: proc(debug: ^DebugState, invalid_events_index: u32) {
    // @Hack why should this need to be reset? Think dont guess
    for &thread in debug.threads do thread.first_open_block = nil
    
    modular_add(&debug.collation_index, 0, DebugMaxHistoryLength)
    for {
        if debug.collation_index == invalid_events_index do break
        defer modular_add(&debug.collation_index, 1, DebugMaxHistoryLength)
        
        for &event in GlobalDebugTable.events[debug.collation_index][:GlobalDebugTable.event_count[debug.collation_index]] {
            if event.type == .FrameMarker {
                if debug.collation_frame != nil {
                    debug.collation_frame.end_clock = event.clock
                    modular_add(&debug.frame_count, 1, auto_cast len(debug.frames))
                    debug.collation_frame.seconds_elapsed = event.as.frame_marker.seconds_elapsed
                    
                    clocks := cast(f32) (debug.collation_frame.end_clock - debug.collation_frame.begin_clock)
                    if clocks != 0 {
                        // scale := 1.0 / clocks
                        // debug_state.frame_bar_scale = min(debug_state.frame_bar_scale, scale)
                    }
                }
                
                debug.collation_frame = &debug.frames[debug.frame_count]
                debug.collation_frame^ = {
                    begin_clock     = event.clock,
                    end_clock       = -1,
                    regions         = push(&debug.collation_arena, DebugRegion, DebugMaxRegionsPerFrame)
                }
            } else if debug.collation_frame != nil {
                debug.frame_bar_lane_count = max(debug.frame_bar_lane_count, cast(u32) event.as.block.thread_index)
                
                source := &GlobalDebugTable.records[event.as.block.thread_index][event.record_index]
                frame_relative_clock := event.clock - debug.collation_frame.begin_clock
                thread := &debug.threads[event.as.block.thread_index]
                frame_index := debug.frame_count-1
                
                switch event.type {
                case .FrameMarker: unreachable()
                case .BeginBlock:
                    block := thread.first_free_block
                    if block != nil {
                        thread.first_free_block = block.next_free
                    } else {
                        block = push(&debug.collation_arena, DebugOpenBlock)
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
                                
                                if record_from(matching_block.parent) == debug.scopes_to_record[event.as.block.thread_index] {
                                    t_min := cast(f32) (opening_event.clock - debug.collation_frame.begin_clock)
                                    t_max := cast(f32) (event.clock - debug.collation_frame.begin_clock)
                                    
                                    threshold :: 0.001
                                    if t_max - t_min > threshold {
                                        region := &debug.collation_frame.regions[debug.collation_frame.region_count]
                                        debug.collation_frame.region_count += 1
                                        
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
    debug := get_debug_state()
    if debug == nil do return
    
    debug.next_hot = nil
    debug.hot_interaction = .None
    
    overlay_debug_info(debug, input)
    
    tiled_render_group_to_output(debug.work_queue, debug.render_group, debug.buffer)
    end_render(debug.render_group)
}

overlay_debug_info :: proc(debug: ^DebugState, input: Input) {
    if debug.render_group == nil do return

    orthographic(debug.render_group, {debug.buffer.width, debug.buffer.height}, 1)

    if debug.compiling {
        state := Platform.debug.get_process_state(debug.compiler)
        if state.is_running {
            debug_push_text_line("Recompiling...")
        } else {
            assert(state.return_code == 0)
            debug.compiling = false
        }
    }

    debug_main_menu(debug, input)
    debug_interact(debug, input)
    
    if DEBUG_ShowFramerate {
        debug_push_text_line(fmt.tprintf("Last Frame time: %5.4f ms", debug.frames[0].seconds_elapsed*1000))
    }
}

debug_draw_profile :: proc (debug: ^DebugState, input: Input, rect: Rectangle2) {
    push_rectangle(debug.render_group, rect, {0.08, 0.08, 0.2, 1} )
    
    target_fps :: 72

    pad_x :: 20
    pad_y :: 20

    bar_padding :: 2
    lane_count  := cast(f32) debug.frame_bar_lane_count +1 
    lane_height :f32
    frame_count := cast(f32) len(debug.frames)
    if frame_count > 0 && lane_count > 0 {
        lane_height = ((rectangle_get_diameter(rect).y / frame_count) - bar_padding) / lane_count
    }
    
    bar_height       := lane_height * lane_count
    bar_plus_spacing := bar_height + bar_padding
    
    full_height := bar_plus_spacing * frame_count
    
    chart_left  := rect.min.x
    chart_top   := rect.max.y - bar_plus_spacing
    chart_width := rectangle_get_diameter(rect).x
    
    scale := debug.frame_bar_scale * chart_width
    
    hot_region: ^DebugRegion
    for frame_index in 0..<len(debug.frames) {
        frame := &debug.frames[(frame_index + cast(int) debug.collation_index) % len(debug.frames)]
        
        stack_x := chart_left
        stack_y := chart_top - bar_plus_spacing * cast(f32) frame_index
        for &region, region_index in frame.regions[:frame.region_count] {
            
            x_min := stack_x + scale * region.t_min
            x_max := stack_x + scale * region.t_max

            y_min := stack_y + 0.5 * lane_height + lane_height * cast(f32) region.lane_index
            y_max := y_min + lane_height
            stack_rect := rectangle_min_max(v2{x_min, y_min}, v2{x_max, y_max})
            
            color_wheel := color_wheel
            color := color_wheel[region.record.hash * 13 % len(color_wheel)]
                        
            push_rectangle(debug.render_group, stack_rect, color)
            if rectangle_contains(stack_rect, input.mouse.p) {
                record := region.record
                if was_pressed(input.mouse.left) {
                    hot_region = &region
                }
                text := fmt.tprintf("%s - %d cycles [%s:% 4d]", record.loc.name, region.cycle_count, record.loc.file_path, record.loc.line)
                debug_push_text(text, input.mouse.p)
            }
        }
    }
    
    if was_pressed(input.mouse.left) {
        if hot_region != nil {
            debug.scopes_to_record[hot_region.lane_index] = hot_region.record
        } else {
            for &scope in debug.scopes_to_record do scope = nil
        }
        refresh_collation(debug)
    }
}

debug_begin_interact :: proc(debug: ^DebugState, input: Input) {
    if debug.hot != nil {
        if debug.hot_interaction == .None {
            #partial switch var in debug.hot.value {
              case b32, DebugVariableGroup:
                debug.interaction = .Toggle
              case f32:
                debug.interaction = .Drag
            }
        } else {
            debug.interaction = debug.hot_interaction
        }
        
        if debug.interaction != .None {
            debug.interacting_with = debug.hot
        }
    } else {
        debug.interaction = .NOP
    }
}

debug_end_interact :: proc(debug: ^DebugState, input: Input) {
    defer {
        debug.interaction = .None
        debug.interacting_with = nil
    }
    
    if debug.interaction != .NOP {
        // assert(debug.interacting_with != nil)
        
        #partial switch debug.interaction {
          case .NOP: unreachable()
          case .Toggle:
            reload := true
            #partial switch &value in debug.interacting_with.value {
            case DebugVariableGroup:
                value.expanded = !value.expanded
                reload = false
            case b32:
                value = !value
            }
            
            if reload do write_handmade_config()
        }
    }
}

debug_interact :: proc(debug: ^DebugState, input: Input) {
    mouse_dp := input.mouse.p - debug.last_mouse_p
    defer debug.last_mouse_p = input.mouse.p
    
    if debug.interaction != .None {
        var := debug.interacting_with
        // NOTE(viktor): Mouse move interaction
        #partial switch debug.interaction {
          case .Drag:
            #partial switch &value in var.value {
              case f32:
                value += 0.1 * mouse_dp.y
            }
          case .ResizeProfile:
            value := &var.value.(DebugVariableThreadList)
            value.dimension += mouse_dp * {1,-1}
            value.dimension.x = max(value.dimension.x, 10)
            value.dimension.y = max(value.dimension.y, 10)
        }
        
        // NOTE(viktor): Click interaction
        for transition_index := input.mouse.left.half_transition_count; transition_index > 1; transition_index -= 1 {
            debug_end_interact(debug, input)
            debug_begin_interact(debug, input)
        }
        
        if !input.mouse.left.ended_down {
            debug_end_interact(debug, input)
        }
    } else {
        debug.hot = debug.next_hot
        debug.hot_interaction = debug.next_hot_interaction
        
        for transition_index:= input.mouse.left.half_transition_count; transition_index > 1; transition_index -= 1 {
            debug_begin_interact(debug, input)
            debug_end_interact(debug, input)
        }
        
        if input.mouse.left.ended_down {
            debug_begin_interact(debug, input)
        }
    }
}

debug_main_menu :: proc(debug: ^DebugState, input: Input) {
    // menu_items := [?]string {
    //     "Toggle Profiler Pause",
    //     "Mark Loop Point",
    // }
    if debug.font_info == nil do return
    
    mouse_p := input.mouse.p
    
    p := debug.hierarchy.ui_p
    line_advance := get_line_advance(debug.font_info) * debug.font_scale
    depth: f32
    
    spacing_y :: 4
    
    for var := debug.hierarchy.root_group; var != nil;  {
        text: string
        is_hot := var == debug.hot
        color := is_hot ? Blue : White
        
        depth_delta: f32
        defer depth += depth_delta
        
        next: ^DebugVariable
        defer var = next
        
        draw_p: v2
        bounds: Rectangle2
        
        switch value in var.value {
          case DebugVariableThreadList:
            min_corner := p + {depth * 2 * line_advance, -value.dimension.y}
            max_corner := v2{min_corner.x + value.dimension.x, p.y}
            size_p := v2{max_corner.x, min_corner.y}
            bounds = rectangle_min_max(min_corner, max_corner)
            debug_draw_profile(debug, input, bounds)
            
            resize_handle := rectangle_center_diameter(size_p, v2{8, 8})

            handle_color := debug.hot_interaction == .ResizeProfile && is_hot ? Blue : White
            push_rectangle(debug.render_group, resize_handle, handle_color)
        
            if rectangle_contains(resize_handle, mouse_p) {
                debug.next_hot_interaction = .ResizeProfile
                debug.next_hot = var
            } else if rectangle_contains(bounds, mouse_p) {
                debug.next_hot_interaction = .None
                debug.next_hot = var
            }
                        
          case DebugVariableGroup, b32, u32, i32, f32, v2, v3, v4:
            if group, ok := value.(DebugVariableGroup); ok {
                text = fmt.tprintf("%s %v", group.expanded ? "-" : "+",  var.name)
                if group.expanded {
                    next = group.first_child
                    depth_delta += 1
                }
            } else {
                text = fmt.tprintf("%s %v", var.name, value)
            }
                        
            left := p.x + depth*line_advance*2
            top  := p.y
            bounds = debug_measure_text(text)
            bounds = rectangle_add_offset(bounds, v2{left, top - rectangle_get_diameter(bounds).y })

            debug_push_text(text, {left, top} - {0, debug.ascent * debug.font_scale}, color)
            
            if rectangle_contains(bounds, mouse_p) {
                debug.next_hot_interaction = .None
                debug.next_hot = var
            }
        }
        
        p.y = rectangle_get_min(bounds).y - spacing_y
        
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
    }
    
    debug.top_edge = p.y
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
        
        should_write := true
        t: typeid
        switch value in var.value {
          case DebugVariableThreadList: // NOTE(viktor): transient data
            next = var.next
            should_write = false
          case DebugVariableGroup:
            cursor += write(contents[cursor:], fmt.tprintfln("// %s", var.name))
            should_write = false
            
            next = value.first_child
          case b32: t = b32
          case f32: t = f32
          case i32: t = i32
          case u32: t = u32
          case v2:  t = v2
          case v3:  t = v3
          case v4:  t = v4
        }
        
        if should_write {
            cursor += write(contents[cursor:], fmt.tprintfln("%s :%w: %w", var.name, t, var.value))
        }
        
        if next == nil {
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

init_debug_variables :: proc (ctx: ^DebugVariableDefinitionContext) {
    debug_begin_variable_group(ctx, "Profiling")
        debug_add_variable(ctx, DEBUG_Profiling)
        debug_add_variable(ctx, DEBUG_ShowFramerate)
    debug_end_variable_group(ctx)

    debug_begin_variable_group(ctx, "Rendering")
        debug_add_variable(ctx, DEBUG_UseDebugCamera)
        debug_add_variable(ctx, DEBUG_DebugCameraDistance)
    
        debug_add_variable(ctx, DEBUG_RenderSingleThreaded)
        debug_add_variable(ctx, DEBUG_TestWeirdScreenSizes)
        
        debug_begin_variable_group(ctx, "Bounds")
            debug_add_variable(ctx, DEBUG_ShowSpaceBounds)
            debug_add_variable(ctx, DEBUG_ShowGroundChunkBounds)
        debug_end_variable_group(ctx)
        
        debug_begin_variable_group(ctx, "ParticleSystem")
            debug_add_variable(ctx, DEBUG_ParticleSystemTest)
            debug_add_variable(ctx, DEBUG_ParticleGrid)
        debug_end_variable_group(ctx)
        
        debug_begin_variable_group(ctx, "CoordinateSystem")
            debug_add_variable(ctx, DEBUG_CoordinateSystemTest)
            debug_add_variable(ctx, DEBUG_ShowLightingBounceDirection)
            debug_add_variable(ctx, DEBUG_ShowLightingSampling)
        debug_end_variable_group(ctx)
    debug_end_variable_group(ctx)

    debug_begin_variable_group(ctx, "Audio")
        debug_add_variable(ctx, DEBUG_SoundPanningWithMouse)
        debug_add_variable(ctx, DEBUG_SoundPitchingWithMouse)
    debug_end_variable_group(ctx)

    debug_add_variable(ctx, DEBUG_FamiliarFollowsHero)
    debug_add_variable(ctx, DEBUG_HeroJumping)
}

DebugVariableDefinitionContext :: struct {
    arena: ^Arena,
    group: ^DebugVariable,
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

debug_begin_variable_group :: proc(ctx: ^DebugVariableDefinitionContext, group_name: string) -> (result: ^DebugVariable) {
    result = push_variable(ctx, group_name, DebugVariableGroup{})
    ctx.group = result
    
    return result
}

debug_add_variable :: proc(ctx: ^DebugVariableDefinitionContext, value: DebugVariableValue, variable_name := #caller_expression(value)) -> ^DebugVariable {
    return push_variable(ctx, variable_name, value)
}

debug_end_variable_group :: proc(ctx: ^DebugVariableDefinitionContext) {
    assert(ctx.group != nil)
    ctx.group = ctx.group.parent
}

////////////////////////////////////////////////

debug_push_text :: proc(text: string, p: v2, color: v4 = 1) {
    debug := get_debug_state()
    if debug == nil do return
    
    if debug.font != nil {
        text_op(.Draw, debug.render_group, debug.font, debug.font_info, text, p, debug.font_scale, color)
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

debug_push_text_line :: proc(text: string) {
    debug := get_debug_state()
    if debug == nil do return
    
    assert(debug.render_group.inside_render)
    
    debug_push_text(text, {debug.left_edge, debug.top_edge} - {0, debug.ascent * debug.font_scale})
    if debug.font != nil {
        advance_y := get_line_advance(debug.font_info)
        debug.top_edge -= debug.font_scale * advance_y
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