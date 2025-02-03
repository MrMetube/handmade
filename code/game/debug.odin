package game

import "core:fmt"
import "base:runtime"

DebugRecord :: struct {
    using loc: runtime.Source_Code_Location,
    counts:    DebugRecordCounts,
}

DebugRecordCounts :: bit_field i64 {
    hit_count:   i32 | 32,
    cycle_count: i32 | 32,
}

DebugRecords: map[runtime.Source_Code_Location]DebugRecord

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
            
            cycles_per_hit := safe_ratio_0(cast(f32) counts.cycle_count, cast(f32) counts.hit_count)
            when true {
                text := fmt.tprintf("%s %vcy, %vh, %.0f cy/h", record.procedure, counts.cycle_count, counts.hit_count, cycles_per_hit)
            } else {
                text := fmt.tprintf("%s:%d:%d: %s %vcy, %vh, %.0f cy/h", record.file_path, record.line, record.column, record.procedure, cast(i64) record.cycle_count, record.hit_count, cycles_per_hit)
            }
            Debug_text_line(text)
        }
    }
}

@(deferred_out=end_timed_block)
timed_block :: #force_inline proc(loc := #caller_location, #any_int hit_count: i32 = 1) -> (record: ^DebugRecord, start: i64, hit_count_out: i32) { 
    // TODO(viktor): Check the overhead of this
    ok: bool
    record, ok = &DebugRecords[loc]
    if !ok {
        DebugRecords[loc] = {}
        record, ok = &DebugRecords[loc]
        assert(ok)
    }
    
    record.loc = loc
    return record, read_cycle_counter(), hit_count
}

end_timed_block :: #force_inline proc(record: ^DebugRecord, start: i64, hit_count: i32) {
    end := read_cycle_counter()
    counts := DebugRecordCounts{ hit_count = hit_count, cycle_count = cast(i32) (end - start) }
    atomic_add(cast(^i64) &record.counts, transmute(i64) counts)
}
