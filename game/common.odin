package game

import "base:intrinsics"

// 
// Common Definitions
// 

rawpointer  :: rawptr
uintpointer :: uintptr

Sample :: [2]i16

GameSoundBuffer :: struct {
    // NOTE(viktor): samples length must be padded to a multiple of 4 samples
    samples:            []Sample,
    samples_per_second: u32,
}

ByteColor :: [4]u8
Bitmap :: struct {
    // TODO(viktor): the length of the slice and either width or height are redundant
    memory: []ByteColor,
    
    align_percentage:  [2]f32,
    width_over_height: f32,
    
    width, height: i16, 
}

InputButton :: struct {
    half_transition_count: i32,
    ended_down:            b32,
}

InputController :: struct {
    // TODO: allow outputing vibration
    is_connected: b32,
    is_analog:    b32,

    stick_average: [2]f32,

    using _buttons_array_and_enum : struct #raw_union {
        buttons: [18]InputButton,
        using _buttons_enum : struct {
            stick_up , stick_down , stick_left , stick_right ,
            button_up, button_down, button_left, button_right,
            dpad_up  , dpad_down  , dpad_left  , dpad_right  ,

            start, back,
            shoulder_left, shoulder_right,
            thumb_left   , thumb_right:    InputButton,
        },
    },
}
#assert(size_of(InputController{}._buttons_array_and_enum.buttons) == size_of(InputController{}._buttons_array_and_enum._buttons_enum))

Input :: struct {
    delta_time: f32,
    reloaded_executable: b32,

    using _mouse_buttons_array_and_enum : struct #raw_union {
        mouse_buttons: [5]InputButton,
        using _buttons_enum : struct {
            mouse_left,	mouse_right, 
            mouse_middle,
            mouse_extra1, mouse_extra2 : InputButton,
        },
    },
    mouse_position: [2]i32,
    mouse_wheel:    i32,

    controllers: [5]InputController,
}
#assert(size_of(Input{}._mouse_buttons_array_and_enum.mouse_buttons) == size_of(Input{}._mouse_buttons_array_and_enum._buttons_enum))

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

    high_priority_queue: ^PlatformWorkQueue,
    low_priority_queue:  ^PlatformWorkQueue,
    
    Platform_api: PlatformAPI,

    debug:    DEBUG_code,
    counters: [DebugCycleCounterName]DebugCycleCounter,
}

PlatformAPI :: struct {
    enqueue_work:      PlatformEnqueueWork,
    complete_all_work: PlatformCompleteAllWork,
    
    allocate_memory:   PlatformAllocateMemory,
    deallocate_memory: PlatformDeallocateMemory,
    
    begin_processing_all_files_of_type: PlatformBeginProcessingAllFilesOfType,
    end_processing_all_files_of_type:   PlatformEndProcessingAllFilesOfType,
    open_next_file:                     PlatformOpenNextFile,
    read_data_from_file:                PlatformReadDataFromFile,
    mark_file_error:                    PlatformMarkFileError,
}

PlatformWorkQueueCallback :: #type proc(data: rawpointer)
PlatformEnqueueWork       :: #type proc(queue: ^PlatformWorkQueue, callback: PlatformWorkQueueCallback, data: rawpointer)
PlatformCompleteAllWork   :: #type proc(queue: ^PlatformWorkQueue)

PlatformAllocateMemory   :: #type proc(size: u64) -> rawpointer
PlatformDeallocateMemory :: #type proc(memory:rawpointer)

PlatformBeginProcessingAllFilesOfType :: #type proc(file_extension: string) -> ^PlatformFileGroup
PlatformEndProcessingAllFilesOfType   :: #type proc(file_group: ^PlatformFileGroup)
PlatformOpenNextFile                  :: #type proc(file_group: ^PlatformFileGroup) -> ^PlatformFileHandle
PlatformReadDataFromFile              :: #type proc(handle: ^PlatformFileHandle, #any_int position, amount: u64, destination: rawpointer)
PlatformMarkFileError                 :: #type proc(handle: ^PlatformFileHandle, error_message: string)

Platform_no_file_errors :: #force_inline proc(handle: ^PlatformFileHandle) -> b32 { 
    return handle.no_errors
}



when INTERNAL { 
    DEBUG_code :: struct {
        read_entire_file:  DebugReadEntireFile,
        write_entire_file: DebugWriteEntireFile,
        free_file_memory:  DebugFreeFileMemory,
    }

    DebugReadEntireFile  :: #type proc(filename: string) -> (result: []u8)
    DebugWriteEntireFile :: #type proc(filename: string, memory: []u8) -> b32
    DebugFreeFileMemory  :: #type proc(memory: []u8)
    
    DEBUG_GLOBAL_memory: ^GameMemory
    
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


// 
// Utilities
// 

kilobytes :: #force_inline proc "contextless" (#any_int value: u64) -> u64 { return value * 1024 }
megabytes :: #force_inline proc "contextless" (#any_int value: u64) -> u64 { return kilobytes(value) * 1024 }
gigabytes :: #force_inline proc "contextless" (#any_int value: u64) -> u64 { return megabytes(value) * 1024 }
terabytes :: #force_inline proc "contextless" (#any_int value: u64) -> u64 { return gigabytes(value) * 1024 }

atomic_compare_exchange :: #force_inline proc "contextless" (dst: ^$T, old, new: T) -> (was: T, ok: b32) {
    ok_: bool
    was, ok_ = intrinsics.atomic_compare_exchange_strong(dst, old, new)
    ok = cast(b32) ok_
    return was, ok
}

complete_previous_writes_before_future_writes :: #force_inline proc "contextless" () {
    // TODO(viktor): what should that actually be
    intrinsics.atomic_thread_fence(.Seq_Cst)
}
complete_previous_reads_before_future_reads :: #force_inline proc "contextless" () {
    // TODO(viktor): what should that actually be
    intrinsics.atomic_thread_fence(.Seq_Cst)
}

align2     :: #force_inline proc "contextless" (value: $T) -> T { return (value +  1) &~  1 }
align4     :: #force_inline proc "contextless" (value: $T) -> T { return (value +  3) &~  3 }
align8     :: #force_inline proc "contextless" (value: $T) -> T { return (value +  7) &~  7 }
align16    :: #force_inline proc "contextless" (value: $T) -> T { return (value + 15) &~ 15 }
align32    :: #force_inline proc "contextless" (value: $T) -> T { return (value + 31) &~ 31 }
align_pow2 :: #force_inline proc "contextless" (value: $T, alignment: T) -> T { return (value + (alignment-1)) &~ (alignment-1) }

swap :: #force_inline proc "contextless" (a, b: ^$T) {
    b^, a^ = a^, b^
}

safe_truncate :: proc{
    safe_truncate_u64,
    safe_truncate_i64,
}

safe_truncate_u64 :: #force_inline proc(value: u64) -> u32 {
    assert(value <= 0xFFFFFFFF)
    return cast(u32) value
}

safe_truncate_i64 :: #force_inline proc(value: i64) -> i32 {
    assert(value <= 0x7FFFFFFF)
    return cast(i32) value
}