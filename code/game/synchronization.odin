#+vet !unused-procedures
package game

@(common="file") 

import "base:intrinsics"

////////////////////////////////////////////////
// Atomics

atomic_compare_exchange :: proc (destination: ^$T, old_value, new_value: T) -> (ok: bool, was_value: T) {
    was_value, ok = intrinsics.atomic_compare_exchange_strong(destination, old_value, new_value)
    return ok, was_value
}

volatile_load      :: intrinsics.volatile_load
volatile_store     :: intrinsics.volatile_store
atomic_add         :: intrinsics.atomic_add
atomic_add_explicit :: intrinsics.atomic_add_explicit
atomic_exchange    :: intrinsics.atomic_exchange
atomic_load_explicit  :: intrinsics.atomic_load_explicit
atomic_store_explicit :: intrinsics.atomic_store_explicit

read_cycle_counter :: intrinsics.read_cycle_counter

@(enable_target_feature="sse2,sse")
complete_previous_writes_before_future_writes :: proc () {
    intrinsics.atomic_thread_fence(.Release)
}
@(enable_target_feature="sse2")
complete_previous_reads_before_future_reads :: proc () {
    intrinsics.atomic_thread_fence(.Acquire)
}

// @study(viktor): When would "Sequentially Consistent" ordering be required. Reminder: It ensures not just local order, but global order between all threads and all other "Sequentially Consistent" fences(if I understood it correctly).
compiler_fence :: proc () {
    intrinsics.atomic_signal_fence(.Acq_Rel)
}
compiler_and_cpu_fence :: proc () {
    intrinsics.atomic_thread_fence(.Acq_Rel)
}

////////////////////////////////////////////////

TicketMutex :: struct #align(64) {
    ticket:  u64,
    serving: u64,
}

begin_ticket_mutex :: proc (mutex: ^TicketMutex) {
    ticket := atomic_add_explicit(&mutex.ticket, 1, .Relaxed)
    for ticket != atomic_load_explicit(&mutex.serving, .Acquire) {
        spin_hint()
    }
}

end_ticket_mutex :: proc (mutex: ^TicketMutex) {
    atomic_add_explicit(&mutex.serving, 1, .Release)
}

spin_hint :: #force_inline proc () {
    asm () [#volatile] { pause } ()
}