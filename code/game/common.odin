package game

import "base:intrinsics"
import "base:runtime"
import "core:simd/x86"
import "core:hash"

INTERNAL :: #config(INTERNAL, false)
TRANSLATION_UNIT :: #config(TRANSLATION_UNIT, -1)

////////////////////////////////////////////////
// Common Game Definitions
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
    
    width, height: i32, 
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

GameMemory :: struct {
    // NOTE: REQUIRED to be cleared to zero at startup
    permanent_storage: []u8,
    transient_storage: []u8,
    debug_storage:     []u8,

    high_priority_queue: ^PlatformWorkQueue,
    low_priority_queue:  ^PlatformWorkQueue,
    
    Platform_api: PlatformAPI,

    debug: DebugCode,
}


////////////////////////////////////////////////
// Common Debug Definitions

when INTERNAL { 
    
    DebugFrameTimestamp :: struct {
        name:    string,
        seconds: f32,
    }
    DebugFrameInfo :: struct {
        total_seconds: f32,
        count:         u32,
        timestamps:    [64]DebugFrameTimestamp
    }

    DebugCode :: struct {
        read_entire_file:  DebugReadEntireFile,
        write_entire_file: DebugWriteEntireFile,
        free_file_memory:  DebugFreeFileMemory,
    }

    DebugReadEntireFile  :: #type proc(filename: string) -> (result: []u8)
    DebugWriteEntireFile :: #type proc(filename: string, memory: []u8) -> b32
    DebugFreeFileMemory  :: #type proc(memory: []u8)
    
    DEBUG_GLOBAL_memory: ^GameMemory
}



////////////////////////////////////////////////

@export
GlobalDebugTable: DebugTable
MaxTranslationUnits :: 2

DebugTable :: struct {
    // @Correctness No attempt is currently made to ensure that the final
    // debug records being written to the event array actually complete
    // their output prior to the swap of the event array index.
    current_events_index: u32,
    events_state:   DebugEventsState,
    events:         [2][16*65536]DebugEvent,
    
    records: [MaxTranslationUnits]DebugRecords,
}

DebugEventsState :: bit_field u64 {
    // @Volatile Later on we transmute this to a u64 to 
    // atomically increment one of the fields
    events_index: u32 | 32,
    array_index:  u32 | 32,
}

DebugEvent  :: struct {
    clock: i64,
    
    thread_index: u16,
    core_index:   u16,
    record_index: u32,
    
    translation_unit: u8,
    type: DebugEventType,
}

DebugEventType :: enum u8 {
    BeginBlock, EndBlock,
}

DebugRecords :: [512]DebugRecord
DebugRecord  :: struct {
    hash:  u32,
    index: u32,
    loc:   runtime.Source_Code_Location,
}

////////////////////////////////////////////////

DebugCounterSnapshot :: struct {
    hit_count:   i64,
    cycle_count: i64,
    depth: u32,
}

////////////////////////////////////////////////

record_debug_event :: #force_inline proc (type: DebugEventType, record_index: u32) {
    events := transmute(DebugEventsState) atomic_add(cast(^u64) &GlobalDebugTable.events_state, 1)
    event := &GlobalDebugTable.events[events.array_index][events.events_index]
    event^ = {
        type         = type,
        clock        = read_cycle_counter(),
        thread_index = cast(u16) context.user_index,
        core_index   = 0,
        translation_unit = TRANSLATION_UNIT,
        record_index = record_index,
    }
}

@(deferred_out=end_timed_block)
timed_block :: #force_inline proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (record_index: u32, hit_count_out: i64) { 
    records := &GlobalDebugTable.records[TRANSLATION_UNIT]
    ok: b32
    // TODO(viktor): Check the overhead of this
    record_index, ok = get(records, loc)
    if !ok {
        record_index = put(records, loc)
    }
    
    record_debug_event(.BeginBlock, record_index)
    
    return record_index, hit_count
}

end_timed_block :: #force_inline proc(record_index: u32, hit_count: i64) {
    // TODO(viktor): record the hit count here
    record_debug_event(.EndBlock, record_index)
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

find :: proc(ht: ^DebugRecords, value: runtime.Source_Code_Location) -> (result: ^DebugRecord, hash_value, hash_index: u32) {
    hash_value = get_hash(ht, value)
    hash_index = hash_value
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
    return result, hash_value, hash_index
}

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

NilHashValue :: 0

put :: proc(ht: ^DebugRecords, value: runtime.Source_Code_Location) -> (hash_index: u32) {
    entry: ^DebugRecord
    hash_value: u32
    entry, hash_value, hash_index = find(ht, value)
    
    entry.hash  = hash_value
    entry.index = hash_index
    entry.loc   = value
    
    return hash_index
}

get :: proc(ht: ^DebugRecords, value: runtime.Source_Code_Location) -> (hash_index: u32, ok: b32) {
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
}

PlatformWorkQueueCallback :: #type proc(data: rawpointer)
PlatformEnqueueWork       :: #type proc(queue: ^PlatformWorkQueue, callback: PlatformWorkQueueCallback, data: rawpointer)
PlatformCompleteAllWork   :: #type proc(queue: ^PlatformWorkQueue)

PlatformAllocateMemory   :: #type proc(size: u64) -> rawpointer
PlatformDeallocateMemory :: #type proc(memory:rawpointer)

PlatformFileType   :: enum { AssetFile }
PlatformFileHandle :: struct{ no_errors:  b32, _platform: rawpointer }
PlatformFileGroup  :: struct{ file_count: u32, _platform: rawpointer }

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