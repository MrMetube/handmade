package game

import "base:intrinsics"

rawpointer  :: rawptr
uintpointer :: uintptr

Sample :: [2]i16

GameSoundBuffer :: struct {
    samples           : []Sample,
    samples_per_second: u32,
}

ByteColor :: [4]u8
Bitmap :: struct {
    memory :       []ByteColor,
    width, height: i32, 
    
    pitch: i32,
    
    align_percentage:  [2]f32,
    width_over_height: f32,
}

GameInputButton :: struct {
    half_transition_count: i32,
    ended_down :           b32,
}

GameInputController :: struct {
    // TODO: allow outputing vibration
    is_connected: b32,
    is_analog:    b32,

    stick_average: [2]f32,

    using _buttons_array_and_enum : struct #raw_union {
        buttons: [18]GameInputButton,
        using _buttons_enum : struct {
            stick_up , stick_down , stick_left , stick_right ,
            button_up, button_down, button_left, button_right,
            dpad_up  , dpad_down  , dpad_left  , dpad_right  ,

            start, back,
            shoulder_left, shoulder_right,
            thumb_left   , thumb_right:    GameInputButton,
        },
    },
}
#assert(size_of(GameInputController{}._buttons_array_and_enum.buttons) == size_of(GameInputController{}._buttons_array_and_enum._buttons_enum))

GameInput :: struct {
    delta_time: f32,
    reloaded_executable: b32,

    using _mouse_buttons_array_and_enum : struct #raw_union {
        mouse_buttons: [5]GameInputButton,
        using _buttons_enum : struct {
            mouse_left,	mouse_right, 
            mouse_middle,
            mouse_extra1, mouse_extra2 : GameInputButton,
        },
    },
    mouse_position: [2]i32,
    mouse_wheel:    i32,

    controllers: [5]GameInputController,
}
#assert(size_of(GameInput{}._mouse_buttons_array_and_enum.mouse_buttons) == size_of(GameInput{}._mouse_buttons_array_and_enum._buttons_enum))

when INTERNAL {
    DebugCycleCounter :: struct {
        cycle_count: i64,
        hit_count:   i64,
    }

    DebugCycleCounterName :: enum {
        update_and_render,
        render_to_output,
        draw_rectangle_slowly,
        draw_rectangle_quickly,
        test_pixel,
    }
} else {
    DebugCycleCounterName :: enum {}
}

GameMemory :: struct {
    // NOTE: REQUIRED to be cleared to zero at startup
    permanent_storage: []u8,
    transient_storage: []u8,

    high_priority_queue:        ^PlatformWorkQueue,
    low_priority_queue:         ^PlatformWorkQueue,
    
    PLATFORM_enqueue_work:      PlatformEnqueueWork,
    PLATFORM_complete_all_work: PlatformCompleteAllWork,
    
    debug:    DEBUG_code,
    counters: [DebugCycleCounterName]DebugCycleCounter,
}

// TODO(viktor): this should only be in platform.odin
PlatformWorkQueueCallback :: #type proc(data: rawpointer)
PlatformEnqueueWork     :: #type proc(queue: ^PlatformWorkQueue, callback: PlatformWorkQueueCallback, data: rawpointer)
PlatformCompleteAllWork :: #type proc(queue: ^PlatformWorkQueue)

when INTERNAL { 
    DEBUG_code :: struct {
        read_entire_file : DebugReadEntireFile,
        write_entire_file: DebugWriteEntireFile,
        free_file_memory : DebugFreeFileMemory,
    }

    DebugReadEntireFile  :: #type proc(filename: string) -> (result: []u8)
    DebugWriteEntireFile :: #type proc(filename: string, memory: []u8) -> b32
    DebugFreeFileMemory  :: #type proc(memory: []u8)
    
    DEBUG_GLOBAL_memory : ^GameMemory
    
    begin_timed_block  :: #force_inline proc(name: DebugCycleCounterName) -> i64 { return intrinsics.read_cycle_counter()}
    @(deferred_in_out=end_timed_block)
    scoped_timed_block :: #force_inline proc(name: DebugCycleCounterName) -> i64 { return intrinsics.read_cycle_counter()}
    end_timed_block    :: #force_inline proc(name: DebugCycleCounterName, start_cycle_count: i64) {
        #no_bounds_check {
            end_cycle_count := intrinsics.read_cycle_counter()
            counter := &DEBUG_GLOBAL_memory.counters[name]
            counter.cycle_count += end_cycle_count - start_cycle_count
            counter.hit_count   += 1
        }
    }
    
    @(deferred_in_out=end_timed_block_counted)
    scoped_timed_block_counted :: #force_inline proc(name: DebugCycleCounterName, count: i64) -> i64 { return intrinsics.read_cycle_counter()}
    end_timed_block_counted    :: #force_inline proc(name: DebugCycleCounterName, count, start_cycle_count: i64) {
        #no_bounds_check {
            end_cycle_count := intrinsics.read_cycle_counter()
            counter := &DEBUG_GLOBAL_memory.counters[name]
            counter.cycle_count += end_cycle_count - start_cycle_count
            counter.hit_count   += count
        }
    }
    
}