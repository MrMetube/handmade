package main

import "base:runtime"
import "base:intrinsics"
import win "core:sys/windows"

PlatformWorkQueue :: struct { // TODO(viktor): polymorphism?
    semaphore_handle: win.HANDLE,
    
    completion_goal, 
    completion_count: u32,
     
    next_entry_to_write, 
    next_entry_to_read:  u32,
    
    entries: [8000]PlatformWorkQueueEntry
}

PlatformWorkQueueEntry :: struct {
    callback: WorkQueueCallback,
    data:     rawpointer, // TODO(viktor): polymorphism?
}

init_work_queue :: proc(queue: ^PlatformWorkQueue, thread_count: win.LONG) {
    high_queue := PlatformWorkQueue{
        semaphore_handle = win.CreateSemaphoreW(nil, 0, thread_count, nil)
    }
        
    thread_id: win.DWORD
    for _ in 0..<thread_count {
        win.CreateThread(nil, 0, thread_proc, queue, 0, &thread_id)
    }
    
}

add_entry :: proc(queue: ^PlatformWorkQueue, callback: WorkQueueCallback, data: rawpointer) {
    old_next_entry := queue.next_entry_to_write
    new_next_entry := (old_next_entry + 1) % len(queue.entries)
    assert(new_next_entry != queue.next_entry_to_read) 

    entry := &queue.entries[old_next_entry] 
    entry.data     = data
    entry.callback = callback
    
    _, ok := intrinsics.atomic_compare_exchange_strong(&queue.completion_goal, queue.completion_goal, queue.completion_goal+1)
    assert(ok)
    
    _, ok = intrinsics.atomic_compare_exchange_strong(&queue.next_entry_to_write, old_next_entry, new_next_entry)
    assert(ok)
    
    win.ReleaseSemaphore(queue.semaphore_handle, 1, nil)
}

do_next_work_queue_entry :: proc(queue: ^PlatformWorkQueue) -> (should_sleep: b32) {
    old_next_entry := queue.next_entry_to_read
    new_next_entry := (old_next_entry + 1) % len(queue.entries)
    
    if old_next_entry != queue.next_entry_to_write {
        index, ok := intrinsics.atomic_compare_exchange_strong(&queue.next_entry_to_read, old_next_entry, new_next_entry)
    
        if ok {
            assert(index == old_next_entry)
            
            entry := &queue.entries[index]
            entry.callback(entry.data)
            
            old_completion_count := queue.completion_count
            new_completion_count := old_completion_count + 1
            
            intrinsics.atomic_add(&queue.completion_count, 1)
        }
    } else {
        should_sleep = true
    }
    
    return should_sleep
}

complete_all_work :: proc(queue: ^PlatformWorkQueue) {
    for queue.completion_count != queue.completion_goal {
        do_next_work_queue_entry(queue)
    }
    
    _, ok := intrinsics.atomic_compare_exchange_strong(&queue.completion_goal, queue.completion_goal, 0)
    assert(ok)
    _, ok = intrinsics.atomic_compare_exchange_strong(&queue.completion_count, queue.completion_count, 0)
    assert(ok)
}

thread_proc :: proc "stdcall" (parameter: rawpointer) -> win.DWORD {
    context = runtime.default_context()
    
    queue := cast(^PlatformWorkQueue) parameter
    for {
        if do_next_work_queue_entry(queue) { 
            INFINITE :: transmute(win.DWORD) i32(-1)
            win.WaitForSingleObjectEx(queue.semaphore_handle, INFINITE, false)
        }
    }
}