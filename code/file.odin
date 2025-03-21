package main

import "core:fmt"
import win "core:sys/windows"

FileHandle :: struct {
    handle:    win.HANDLE,
}

FileGroup :: struct {
    find_handle: win.HANDLE,
    data:        win.WIN32_FIND_DATAW,
}

FileExtensions :: [PlatformFileType] string {
    .AssetFile = "hha",
}

begin_processing_all_files_of_type : PlatformBeginProcessingAllFilesOfType : proc(type: PlatformFileType) -> (result: PlatformFileGroup) {
    pattern: [32]win.wchar_t
    pattern[0] = '*'
    pattern[1] = '.'
    
    FileExtensions := FileExtensions
    file_extension := FileExtensions[type]
    assert(len(file_extension) <= 30)
    for r, i in file_extension {
        pattern[i+2] = cast(u16) r
    }
    
    // TODO(viktor): :PlatformArena if we want someday, make an actual arena for windows platform layer
    group, err := new(FileGroup)
    if err == nil {
        group.find_handle = win.FindFirstFileW(&pattern[0], &group.data)
        for group.find_handle != win.INVALID_HANDLE_VALUE {
            result.file_count += 1
            if !win.FindNextFileW(group.find_handle, &group.data){
                break
            }
        }
        win.FindClose(group.find_handle)
        
        group.find_handle = win.FindFirstFileW(&pattern[0], &group.data)
        result._platform = group
    } else {
        unreachable()
    }
    
    return result
}

open_next_file : PlatformOpenNextFile : proc(group: ^PlatformFileGroup) -> (result: PlatformFileHandle) {
    file_group := cast(^FileGroup) group._platform
    
    if file_group.find_handle != win.INVALID_HANDLE_VALUE {
        // TODO(viktor): :PlatformArena if we want someday, make an actual arena for windows platform layer
        file_handle, err := new(FileHandle)

        if err == nil {
            file_handle.handle = win.CreateFileW(&file_group.data.cFileName[0], win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, 0, nil)
            
            result.no_errors = file_handle.handle != win.INVALID_HANDLE_VALUE
            result._platform = file_handle
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

read_data_from_file : PlatformReadDataFromFile : proc(handle: ^PlatformFileHandle, #any_int position, amount: u64, destination: pmm) {
    file_handle := cast(^FileHandle) handle._platform
    if Platform_no_file_errors(handle) {
        overlap_info := win.OVERLAPPED{
            Offset     = safe_truncate_u64(position),
            OffsetHigh = safe_truncate_u64(position >> 32),
        }
        
        bytes_read: u32
        amount_32 := safe_truncate(amount)
        if win.ReadFile(file_handle.handle, destination, amount_32, &bytes_read, &overlap_info) && cast(u64) bytes_read == amount {
            // NOTE(viktor): File read succeded
        } else {
            mark_file_error(handle, "Read file failed")
        }
    }
}

end_processing_all_files_of_type : PlatformEndProcessingAllFilesOfType : proc(group: ^PlatformFileGroup) {
    file_group := cast(^FileGroup) group._platform
    if file_group != nil {
        win.FindClose(file_group.find_handle)
        free(file_group)
        group._platform = nil
    }
}

mark_file_error : PlatformMarkFileError : proc(handle: ^PlatformFileHandle, error_message: string) {
    when INTERNAL {
        fmt.println("FILE ERROR:", error_message)
        
        error_code := win.GetLastError()
        buffer: [1024]u16
        length := win.FormatMessageW(win.FORMAT_MESSAGE_FROM_SYSTEM, nil, error_code, 0, &buffer[0], len(buffer), nil, )
        message, _ := win.utf16_to_utf8(buffer[:length])
        fmt.printfln("ERROR: %s", string(message))
    }
    handle.no_errors = false
}
