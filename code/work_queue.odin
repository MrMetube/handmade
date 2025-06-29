package main

import "base:runtime"
import "core:thread"
import win "core:sys/windows"

PlatformWorkQueue :: struct {
    semaphore_handle: win.HANDLE,
    
    completion_goal, 
    completion_count: u32,
     
    next_entry_to_write, 
    next_entry_to_read:  u32,
    
    entries: [4096]PlatformWorkQueueEntry,
}

PlatformWorkQueueEntry :: struct {
    callback: PlatformWorkQueueCallback,
    data:     pmm,
}

CreateThreadInfo :: struct {
    queue: ^PlatformWorkQueue,
    index: u32,
}

@(private="file") next_thread_index: u32 = 1
@(private="file") infos: [1024]CreateThreadInfo

init_work_queue :: proc(queue: ^PlatformWorkQueue, count: u32) {
    queue.semaphore_handle = win.CreateSemaphoreW(nil, 0, auto_cast count, nil)
    
    for &info in infos[next_thread_index:][:count] {
        info.queue = queue
        info.index = next_thread_index
        next_thread_index += 1
        
        // @note(viktor): When I use the windows call I can at most create 4 threads at once,
        // any more calls to create thread in this call of the init function fail silently
        // A further call for the low_priority_queue then is able to create 4 more threads.
        //     result := win.CreateThread(nil, 0, thread_proc, info, thread_index, nil)
        
        thread.create_and_start_with_data(&info, worker_thread)
    }
}

enqueue_work_or_do_immediatly :: proc(queue: ^PlatformWorkQueue, data: pmm, callback: PlatformWorkQueueCallback) {
    if queue != nil {
        enqueue_work(queue, data, callback)
    } else {
        callback(data)
    }
}

enqueue_work : PlatformEnqueueWork : proc(queue: ^PlatformWorkQueue, data: pmm, callback: PlatformWorkQueueCallback) {
    old_next_entry := queue.next_entry_to_write
    new_next_entry := (old_next_entry + 1) % len(queue.entries)
    assert(new_next_entry != queue.next_entry_to_read, "too many units of work enqueued") 

    entry := &queue.entries[old_next_entry] 
    entry.data     = data
    entry.callback = callback
    
    ok, _ := atomic_compare_exchange(&queue.completion_goal, queue.completion_goal, queue.completion_goal+1)
    assert(ok)
    
    ok, _ = atomic_compare_exchange(&queue.next_entry_to_write, old_next_entry, new_next_entry)
    assert(ok)
    
    win.ReleaseSemaphore(queue.semaphore_handle, 1, nil)
}

complete_all_work :: proc(queue: ^PlatformWorkQueue) {
    if queue == nil do return
    
    for queue.completion_count != queue.completion_goal {
        do_next_work_queue_entry(queue)
    }
    
    ok, _ := atomic_compare_exchange(&queue.completion_goal, queue.completion_goal, 0)
    assert(ok)
    ok, _ = atomic_compare_exchange(&queue.completion_count, queue.completion_count, 0)
    assert(ok)
}

do_next_work_queue_entry :: proc(queue: ^PlatformWorkQueue) -> (should_sleep: b32) {
    old_next_entry := queue.next_entry_to_read
    
    if old_next_entry != queue.next_entry_to_write {
        new_next_entry := (old_next_entry + 1) % len(queue.entries)
        ok, index := atomic_compare_exchange(&queue.next_entry_to_read, old_next_entry, new_next_entry)
    
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

worker_thread :: proc (parameter: pmm) {
    context = runtime.default_context()
    
    info := cast(^CreateThreadInfo) parameter
    queue := info.queue
    context.user_index = cast(int) info.index
    
    for {
        if do_next_work_queue_entry(queue) { 
            INFINITE :: transmute(win.DWORD) cast(i32) -1
            win.WaitForSingleObjectEx(queue.semaphore_handle, INFINITE, false)
        }
    }
}
