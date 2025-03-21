package main

import "base:runtime"
import "core:thread"
import "base:intrinsics"
import win "core:sys/windows"

PlatformWorkQueue :: struct {
    semaphore_handle: win.HANDLE,
    
    completion_goal, 
    completion_count: u32,
     
    next_entry_to_write, 
    next_entry_to_read:  u32,
    
    entries: [4096]PlatformWorkQueueEntry,
    
    needs_opengl: b32,
}

PlatformWorkQueueEntry :: struct {
    callback: PlatformWorkQueueCallback,
    data:     pmm,
}

CreateThreadInfo :: struct {
    queue: ^PlatformWorkQueue,
    index: u32,
}

@(private="file") created_thread_count: u32

init_work_queue :: proc(queue: ^PlatformWorkQueue, thread_count: u32) {
    queue.semaphore_handle = win.CreateSemaphoreW(nil, 0, cast(i32) thread_count, nil)
    
    thread_count_before := created_thread_count
    created_thread_count += thread_count
    for thread_index in thread_count_before..<created_thread_count {
        info := new(CreateThreadInfo)
        info^ = {
            queue = queue,
            index = thread_index,
        }
        // NOTE(viktor): When I use the windows call i can at most create 4 threads at once,
        // any more calls to create thread in this call of the init function fail silently
        // A further call for the low_priority_queue then is able to create 4 more threads.
        //     result := win.CreateThread(nil, 0, thread_proc, info, thread_index, nil)
        
        thread.create_and_start_with_data(info, thread_proc)
    }
}

enqueue_work : PlatformEnqueueWork : proc(queue: ^PlatformWorkQueue, callback: PlatformWorkQueueCallback, data: pmm) {
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

complete_all_work : PlatformCompleteAllWork : proc(queue: ^PlatformWorkQueue) {
    for queue.completion_count != queue.completion_goal {
        do_next_work_queue_entry(queue)
    }
    
    _, ok := intrinsics.atomic_compare_exchange_strong(&queue.completion_goal, queue.completion_goal, 0)
    assert(ok)
    _, ok = intrinsics.atomic_compare_exchange_strong(&queue.completion_count, queue.completion_count, 0)
    assert(ok)
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
            
            atomic_add(&queue.completion_count, 1)
        }
    } else {
        should_sleep = true
    }
    
    return should_sleep
}

thread_proc :: proc (parameter: pmm) {
    context = runtime.default_context()
    
    info := cast(^CreateThreadInfo) parameter
    queue := info.queue
    context.user_index = cast(int) info.index
    free(info)
    
    if queue.needs_opengl do create_opengl_context_for_worker_thread()
    
    for {
        if do_next_work_queue_entry(queue) { 
            INFINITE :: transmute(win.DWORD) i32(-1)
            win.WaitForSingleObjectEx(queue.semaphore_handle, INFINITE, false)
        }
    }
}
