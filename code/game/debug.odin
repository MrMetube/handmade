package game

import "core:fmt"
import "base:runtime"
import "base:intrinsics"

DebugRecords :: map[runtime.Source_Code_Location]DebugRecord

GameDebugRecords: DebugRecords

DebugState :: struct {
    couter_states: [512]DebugCounterState,
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
    using loc: runtime.Source_Code_Location,
    counts: DebugCounterSnapshot,
}

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


init_debug_records :: proc() {
    GameDebugRecords = make_map_cap(type_of(GameDebugRecords), 512)
    
    // NOTE(viktor): remove the allocator
    nil_allocator_proc :: proc(_: rawptr, _: runtime.Allocator_Mode, _, _: int, _: rawptr, _: int, _: runtime.Source_Code_Location) -> ([]byte, runtime.Allocator_Error) {
        unimplemented("and never will be")
    }
    raw := cast(^runtime.Raw_Map) &GameDebugRecords
    raw.allocator = {
		procedure = nil_allocator_proc,
		data = nil,
	}
}

@(deferred_out=end_timed_block)
timed_block :: #force_inline proc(loc := #caller_location, #any_int hit_count: i32 = 1) -> (record: ^DebugRecord, start: i64, hit_count_out: i32) { 
    // NOTE(viktor): this can only happen when the map hasnt been initialized,
    // so one the first render or after a hotreload
    if GameDebugRecords == nil do return
    
    // TODO(viktor): @CompilerBug repro: Why can I use record here, when it is only using the loc?
    // if record not_in GameDebugRecords {
    // TODO(viktor): Check the overhead of this
    if loc not_in GameDebugRecords {
        GameDebugRecords[loc] = {}
    } else {
        record = &GameDebugRecords[loc]
        record.loc = loc
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
