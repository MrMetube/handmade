#+vet !unused-procedures
package game

@(common="file") 

import "base:intrinsics"
import "core:simd/x86"

////////////////////////////////////////////////
// Atomics

atomic_compare_exchange :: proc (dst: ^$T, old, new: T) -> (ok: b32, was: T) {
    ok_: bool
    was, ok_ = intrinsics.atomic_compare_exchange_strong(dst, old, new)
    ok = cast(b32) ok_
    return ok, was
}

volatile_load      :: intrinsics.volatile_load
volatile_store     :: intrinsics.volatile_store
atomic_add         :: intrinsics.atomic_add
read_cycle_counter :: intrinsics.read_cycle_counter
atomic_exchange    :: intrinsics.atomic_exchange

// @todo(viktor): Is this correct? How can I validated this?
@(enable_target_feature="sse2,sse")
complete_previous_writes_before_future_writes :: proc () {
    x86._mm_sfence()
    x86._mm_lfence()
}
@(enable_target_feature="sse2")
complete_previous_reads_before_future_reads :: proc () {
    x86._mm_lfence()
}

////////////////////////////////////////////////

TicketMutex :: struct #align(64) {
    ticket:  u64,
    serving: u64,
}

@(enable_target_feature="sse2")
begin_ticket_mutex :: proc (mutex: ^TicketMutex) {
    timed_function()
    
    ticket := atomic_add(&mutex.ticket, 1)
    for ticket != volatile_load(&mutex.serving) {
        x86._mm_pause()
    }
}

end_ticket_mutex :: proc (mutex: ^TicketMutex) {
    atomic_add(&mutex.serving, 1)
}