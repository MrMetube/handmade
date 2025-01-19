package main

import "core:fmt"
import "core:mem"
import win "core:sys/windows"

PlatformFileHandle :: struct {
    // NOTE(viktor): must be kept in sync with game.PlatformFileHandle
    no_errors: b32,
    handle: win.HANDLE,
}

File :: struct {
}

PlatformFileGroup  :: []File


begin_processing_all_files_of_type : PlatformBeginProcessingAllFilesOfType : proc(file_extension: string) -> (result: PlatformFileGroup) {
    result = { {}, {}, {} }
    return result
}
end_processing_all_files_of_type : PlatformEndProcessingAllFilesOfType : proc(file_group: PlatformFileGroup) {
    // unimplemented()
}
open_file : PlatformOpenFile : proc(file_group: PlatformFileGroup, #any_int index: u32) -> (result: ^PlatformFileHandle) {
    filename: string 
    switch index {
        case 0: filename = "hero.hha"
        case 1: filename = "non_hero.hha"
        case 2: filename = "sounds.hha"
    }
    
    // TODO(viktor): if we want someday, make an actual arena for windows platform layer
    err: mem.Allocator_Error
    result, err  = new(PlatformFileHandle)
    if err == nil {
        result.handle = win.CreateFileW(win.utf8_to_wstring(filename), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, 0, nil)
        result.no_errors = result.handle != win.INVALID_HANDLE
    } else {
        unreachable()
    }

    return result

}
read_data_from_file : PlatformReadDataFromFile : proc(handle: ^PlatformFileHandle, #any_int position, amount: u64, destination: rawpointer) {
    if Platform_no_file_errors(handle) {
        overlap_info:=win.OVERLAPPED{
            Offset     = cast(u32) (position         & 0xFFFFFFFF),
            OffsetHigh = cast(u32) ((amount >> 32) & 0xFFFFFFFF),
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
mark_file_error : PlatformMarkFileError : proc(handle: ^PlatformFileHandle, error_message: string) {
    when INTERNAL {
        fmt.println("FILE ERROR:", error_message)
    }
    handle.no_errors = false
}
