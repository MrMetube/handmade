package game

import "base:intrinsics"

@(deferred_in_out=end_timed_block)
timed_block       :: #force_inline proc(name: DebugCycleCounterName, #any_int count: i64 = 1) -> (start: CycleCount) { return read_cycle_counter() }

begin_timed_block :: #force_inline proc(name: DebugCycleCounterName, #any_int count: i64 = 1) -> (start: CycleCount) { return read_cycle_counter() }
end_timed_block   :: #force_inline proc(name: DebugCycleCounterName, count: i64 = 1, start: CycleCount) {
    #no_bounds_check {
        end := read_cycle_counter()
        counter := &DEBUG_GLOBAL_memory.counters[name]
        counter.cycle_count += end - start
        counter.hit_count   += count
    }
}
