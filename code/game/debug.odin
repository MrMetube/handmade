package game

import "base:intrinsics"
import "base:runtime"

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
}

DebugRecord :: struct {
    using loc: runtime.Source_Code_Location,
    cycle_count: CycleCount,
    hit_count:   i64,
}

DebugRecords: map[runtime.Source_Code_Location]DebugRecord

CycleCount :: distinct i64
read_cycle_counter :: #force_inline proc() -> CycleCount { return cast(CycleCount) intrinsics.read_cycle_counter() }

@(deferred_out=end_timed_block)
timed_block       :: #force_inline proc(loc := #caller_location, #any_int hit_count: i64 = 1) -> (record: ^DebugRecord) { 
    // TODO(viktor): Check the overhead of this
    ok: bool
    record, ok = &DebugRecords[loc]
    if !ok {
        DebugRecords[loc] = {}
        record, ok = &DebugRecords[loc]
        assert(ok)
    }
    record = &DebugRecords[loc]
    record.loc          = loc
    // TODO(viktor): this is not thread safe
    record.hit_count   += hit_count
    record.cycle_count -= read_cycle_counter()
    
    return record
}
end_timed_block   :: #force_inline proc(record: ^DebugRecord) {
    record.cycle_count += read_cycle_counter()
}
