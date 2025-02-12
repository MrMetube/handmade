package game

import "base:intrinsics"
import "base:runtime"
import "core:simd/x86"
import "core:hash"

INTERNAL :: #config(INTERNAL, false)

////////////////////////////////////////////////
// Common Game Definitions
// 

v2 :: [2]f32
v3 :: [3]f32
v4 :: [4]f32

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
    
    width, height: i32, 
}

InputButton :: struct {
    half_transition_count: u32,
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

    mouse: struct {
        using _buttons_array_and_enum : struct #raw_union {
            buttons: [5]InputButton,
            using _buttons_enum : struct {
                left, 
                right, 
                middle,
                extra1, 
                extra2: InputButton,
            },
        },
        p:     v2,
        wheel: f32,
    },

    controllers: [5]InputController,
}
#assert(size_of(Input{}.mouse._buttons_array_and_enum.buttons) == size_of(Input{}.mouse._buttons_array_and_enum._buttons_enum))

GameMemory :: struct {
    reloaded_executable: b32,
    // NOTE: REQUIRED to be cleared to zero at startup
    permanent_storage: []u8,
    transient_storage: []u8,
    debug_storage:     []u8,

    high_priority_queue: ^PlatformWorkQueue,
    low_priority_queue:  ^PlatformWorkQueue,
    
    Platform_api: PlatformAPI,
}


////////////////////////////////////////////////
// Common Debug Definitions

TimedBlock :: struct {
    record_index: u32, 
    hit_count:    i64
}

DebugCode :: struct {
    read_entire_file:       DebugReadEntireFile,
    write_entire_file:      DebugWriteEntireFile,
    free_file_memory:       DebugFreeFileMemory,
    execute_system_command: DebugExecuteSystemCommand,
    get_process_state:      DebugGetProcessState,
}

DebugProcessState :: struct {
    started_successfully: b32,
    is_running:           b32,
    return_code:          i32,
}

DebugExecutingProcess :: struct {
    os_handle: uintpointer,
}

DebugReadEntireFile       :: #type proc(filename: string) -> (result: []u8)
DebugWriteEntireFile      :: #type proc(filename: string, memory: []u8) -> b32
DebugFreeFileMemory       :: #type proc(memory: []u8)
DebugExecuteSystemCommand :: #type proc(directory, command, command_line: string) -> DebugExecutingProcess
DebugGetProcessState      :: #type proc(process: DebugExecutingProcess) -> DebugProcessState

////////////////////////////////////////////////
// Platform API

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
    
    debug: DebugCode,
}

PlatformWorkQueueCallback :: #type proc(data: rawpointer)
PlatformEnqueueWork       :: #type proc(queue: ^PlatformWorkQueue, callback: PlatformWorkQueueCallback, data: rawpointer)
PlatformCompleteAllWork   :: #type proc(queue: ^PlatformWorkQueue)

PlatformAllocateMemory   :: #type proc(size: u64) -> rawpointer
PlatformDeallocateMemory :: #type proc(memory:rawpointer)

PlatformFileType   :: enum { AssetFile }
PlatformFileHandle :: struct { no_errors:  b32, _platform: rawpointer }
PlatformFileGroup  :: struct { file_count: u32, _platform: rawpointer }

PlatformBeginProcessingAllFilesOfType :: #type proc(type: PlatformFileType) -> PlatformFileGroup
PlatformEndProcessingAllFilesOfType   :: #type proc(file_group: ^PlatformFileGroup)
PlatformOpenNextFile                  :: #type proc(file_group: ^PlatformFileGroup) -> PlatformFileHandle
PlatformReadDataFromFile              :: #type proc(handle: ^PlatformFileHandle, #any_int position, amount: u64, destination: rawpointer)
PlatformMarkFileError                 :: #type proc(handle: ^PlatformFileHandle, error_message: string)

Platform_no_file_errors :: #force_inline proc(handle: ^PlatformFileHandle) -> b32 { 
    return handle.no_errors
}

////////////////////////////////////////////////
// Utilities

Kilobyte :: runtime.Kilobyte
Megabyte :: runtime.Megabyte
Gigabyte :: runtime.Gigabyte
Terabyte :: runtime.Terabyte

// TODO(viktor): this is shitty with if expressions even if there is syntax for if-value-ok
atomic_compare_exchange :: #force_inline proc "contextless" (dst: ^$T, old, new: T) -> (was: T, ok: b32) {
    ok_: bool
    was, ok_ = intrinsics.atomic_compare_exchange_strong(dst, old, new)
    ok = cast(b32) ok_
    return was, ok
}

volatile_load      :: intrinsics.volatile_load
volatile_store     :: intrinsics.volatile_store
atomic_add         :: intrinsics.atomic_add
read_cycle_counter :: intrinsics.read_cycle_counter
atomic_exchange    :: intrinsics.atomic_exchange

@(enable_target_feature="sse")
complete_previous_writes_before_future_writes :: proc "contextless" () {
    x86._mm_sfence()
}
@(enable_target_feature="sse2")
complete_previous_reads_before_future_reads :: proc "contextless" () {
    x86._mm_lfence()
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