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
atomic_exchange    :: intrinsics.atomic_exchange

read_cycle_counter :: intrinsics.read_cycle_counter

// @todo(viktor): Is this correct? How can I validated this?
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

@(enable_target_feature="sse2")
begin_ticket_mutex :: proc (mutex: ^TicketMutex) {
    ticket := atomic_add(&mutex.ticket, 1)
    for ticket != volatile_load(&mutex.serving) {
        spin_hint()
    }
}

end_ticket_mutex :: proc (mutex: ^TicketMutex) {
    atomic_add(&mutex.serving, 1)
}

spin_hint :: proc() {
    when ODIN_ARCH == .amd64 || ODIN_ARCH == .i386 {
        asm { "pause" , "" } ()
    } else when ODIN_ARCH == .arm32 || ODIN_ARCH == .arm64 {
        asm { "yield", "" } ()
    } else when ODIN_ARCH == .riscv64 || ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 || ODIN_ARCH == .Unknown {
        // no-op fallback
    } else {
        #assert(false, "new microarch was added")
    }
}