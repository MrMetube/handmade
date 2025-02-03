package game

import "core:fmt"
import "base:runtime"

DebugRecord :: struct {
    using loc: runtime.Source_Code_Location,
    counts:    DebugRecordCounts,
}

DebugRecordCounts :: struct {
    hit_count:   i32,
    cycle_count: i32,
}

DebugRecords: map[runtime.Source_Code_Location]DebugRecord

init_debug_records :: proc() {
    DebugRecords = make_map_cap(type_of(DebugRecords), 512)
    
    // NOTE(viktor): remove the allocator
    raw := cast(^runtime.Raw_Map) &DebugRecords
    raw.allocator = runtime.nil_allocator()
}

overlay_cycle_counters :: proc() {
    when INTERNAL {
        // NOTE(viktor): kerning and unicode test lines
        // Debug_text_line("贺佳樱我爱你")
        // Debug_text_line("AVA: WA ty fi ij `^?'\"")
        // Debug_text_line("0123456789°")
        
        title := "Debug Game Cycle Counts:"
        Debug_text_line(title)
        for _, &record in DebugRecords {
            counts := transmute(DebugRecordCounts) atomic_exchange(cast(^i64) &record.counts, 0)
            if counts.hit_count > 0 {
                cycles_per_hit := safe_ratio_0(cast(f32) counts.cycle_count, cast(f32) counts.hit_count)
                text := fmt.tprintf("%28s(% 4d) % 15vcy, % 10vh, % 12.0f cy/h", record.procedure, record.line, counts.cycle_count, counts.hit_count, cycles_per_hit)
                Debug_text_line(text)
            }
        }
    }
}

@(deferred_out=end_timed_block)
timed_block :: #force_inline proc(loc := #caller_location, #any_int hit_count: i32 = 1) -> (record: ^DebugRecord, start: i64, hit_count_out: i32) { 
    // TODO(viktor): @CompilerBug repro: Why can I use record here, when it is only using the loc?
    // if record not_in DebugRecords {
    // TODO(viktor): Check the overhead of this
    if loc not_in DebugRecords {
        DebugRecords[loc] = {}
    } else {
        record = &DebugRecords[loc]
        record.loc = loc
    }
    return record, read_cycle_counter(), hit_count
}

end_timed_block :: #force_inline proc(record: ^DebugRecord, start: i64, hit_count: i32) {
    if record != nil {
        end := read_cycle_counter()
        counts := DebugRecordCounts{ hit_count = hit_count, cycle_count = cast(i32) (end - start) }
        atomic_add(cast(^i64) &record.counts,  transmute(i64) counts)
    }
}
