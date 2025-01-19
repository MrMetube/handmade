package main

import "core:fmt"
import "core:mem"
import win "core:sys/windows"

PlatformFileHandle :: struct {
    // NOTE(viktor): must be kept in sync with game.PlatformFileHandle
    no_errors: b32,
    handle:    win.HANDLE,
}

PlatformFileGroup :: struct {
    // NOTE(viktor): must be kept in sync with game.PlatformFileGroup
    file_count:  u32,
    find_handle: win.HANDLE,
    data:        win.WIN32_FIND_DATAW,
}

begin_processing_all_files_of_type : PlatformBeginProcessingAllFilesOfType : proc(file_extension: string) -> (result: ^PlatformFileGroup) {
    pattern := win.utf8_to_wstring(fmt.tprint("*.", file_extension, sep=""))
    
    // TODO(viktor): :PlatformArena if we want someday, make an actual arena for windows platform layer
    err: mem.Allocator_Error
    result, err = new(PlatformFileGroup)
    if err == nil {
        result.find_handle = win.FindFirstFileW(pattern, &result.data)
        for result.find_handle != win.INVALID_HANDLE_VALUE {
            result.file_count += 1
            if !win.FindNextFileW(result.find_handle, &result.data){
                break
            }
        }
        win.FindClose(result.find_handle)
        
        result.find_handle = win.FindFirstFileW(pattern, &result.data)
    } else {
        unreachable()
    }
    
    return result
}

open_next_file : PlatformOpenNextFile : proc(file_group: ^PlatformFileGroup) -> (result: ^PlatformFileHandle) {
    if file_group.find_handle != win.INVALID_HANDLE_VALUE {
        // TODO(viktor): :PlatformArena if we want someday, make an actual arena for windows platform layer
        err: mem.Allocator_Error
        result, err = new(PlatformFileHandle)
        if err == nil {
            filename := &file_group.data.cFileName[0]
            result.handle = win.CreateFileW(filename, win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, 0, nil)
            result.no_errors = result.handle != win.INVALID_HANDLE_VALUE
        } else {
            unreachable()
        }
        
        if !win.FindNextFileW(file_group.find_handle, &file_group.data){
            win.FindClose(file_group.find_handle)
            file_group.find_handle = win.INVALID_HANDLE_VALUE
        }
    }

    return result

}

read_data_from_file : PlatformReadDataFromFile : proc(handle: ^PlatformFileHandle, #any_int position, amount: u64, destination: rawpointer) {
    if Platform_no_file_errors(handle) {
        overlap_info := win.OVERLAPPED{
            Offset     = cast(u32) (position         & 0xFFFFFFFF),
            OffsetHigh = cast(u32) ((position >> 32) & 0xFFFFFFFF),
        }
        
        bytes_read: u32
        amount_32 := safe_truncate(amount)
        if win.ReadFile(handle.handle, destination, amount_32, &bytes_read, &overlap_info) && cast(u64) bytes_read == amount {
            // NOTE(viktor): File read succeded
        } else {
            mark_file_error(handle, "Read file failed")
        }
    }
}

end_processing_all_files_of_type : PlatformEndProcessingAllFilesOfType : proc(file_group: ^PlatformFileGroup) {
    if file_group != nil {
        win.FindClose(file_group.find_handle)
        free(file_group)
    }
}

mark_file_error : PlatformMarkFileError : proc(handle: ^PlatformFileHandle, error_message: string) {
    when INTERNAL {
        fmt.println("FILE ERROR:", error_message)
    }
    handle.no_errors = false
}
