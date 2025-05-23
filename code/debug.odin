package main

import win "core:sys/windows"

when INTERNAL {

    /* @important:
        These are not for doing anything in the shipping game
        they are blocking and the write doesnt protect against lost data!
    */
    DEBUG_read_entire_file : DebugReadEntireFile : proc(filename: string) -> (result: []u8) {
        handle := win.CreateFileW(win.utf8_to_wstring(filename), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, 0, nil)
        defer win.CloseHandle(handle)

        if handle == win.INVALID_HANDLE {
            return nil // @logging
        }

        file_size : win.LARGE_INTEGER
        if !win.GetFileSizeEx(handle, &file_size) {
            return nil // @logging
        }
        
        file_size_32 := safe_truncate_u64(cast(u64) file_size)
        result_ptr := cast([^]u8) win.VirtualAlloc(nil, cast(uint) file_size_32, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
        if result_ptr == nil {
            return nil // @logging
        }
        result = result_ptr[:file_size_32]

        bytes_read: win.DWORD
        if !win.ReadFile(handle, result_ptr, file_size_32, &bytes_read, nil) || file_size_32 != bytes_read {
            DEBUG_free_file_memory(result)
            return nil // @logging
        }
        
        return result_ptr[:file_size_32]
    }

    DEBUG_write_entire_file : DebugWriteEntireFile : proc(filename: string, memory: []u8) -> b32 {
        handle := win.CreateFileW(win.utf8_to_wstring(filename), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, 0, nil)
        defer win.CloseHandle(handle)

        if handle == win.INVALID_HANDLE {
            return false // @logging
        }

        bytes_written: win.DWORD
        if !win.WriteFile(handle, raw_data(memory), cast(u32) len(memory), &bytes_written, nil) {
            return false // @logging
        }

        return true
    }

    DEBUG_free_file_memory : DebugFreeFileMemory : proc(memory: []u8) {
        if memory != nil {
            win.VirtualFree(raw_data(memory), 0, win.MEM_RELEASE)
        }
    }
    
    DEBUG_get_process_state : DebugGetProcessState : proc(process: DebugExecutingProcess) -> (result: DebugProcessState) {
        handle := cast(win.HANDLE) process.os_handle
        if handle != win.INVALID_HANDLE_VALUE {
            result.started_successfully = true
            
            result.is_running = win.WaitForSingleObject(handle, 0) != win.WAIT_OBJECT_0
            if !result.is_running {
                win.GetExitCodeProcess(handle, cast(^win.DWORD) &result.return_code)
                win.CloseHandle(handle)
            }
        }
        
        return result
    }
    
    DEBUG_execute_system_command : DebugExecuteSystemCommand : proc(directory, command, command_line: string) -> (result: DebugExecutingProcess) {
        STARTF_USESHOWWINDOW :: 0x00000001
        
        startup_info := win.STARTUPINFOW{
            cb          = size_of(win.STARTUPINFOW),
            dwFlags     = STARTF_USESHOWWINDOW,
            wShowWindow = auto_cast win.SW_HIDE,
        }
        process_info := win.PROCESS_INFORMATION{}
        
        if win.CreateProcessW(
            win.utf8_to_wstring(command), 
            win.utf8_to_wstring(command_line), 
            nil, nil, 
            false, 0, 
            nil, win.utf8_to_wstring(directory), 
            &startup_info, &process_info,
        ) {
            result.os_handle = cast(umm) process_info.hProcess
        } else {
            result.os_handle = cast(umm) win.INVALID_HANDLE_VALUE
        }
        
        return result
    }

    when false {
        DebugTimeMarker :: struct {
            output_play_cursor, output_write_cursor: win.DWORD,
            output_location, output_byte_count: win.DWORD,
            flip_play_cursor, flip_write_cursor: win.DWORD,
            expected_frame_boundary_byte: win.DWORD,
        }

        DEBUG_sync_display :: proc(back_buffer: OffscreenBuffer, last_time_markers: []DebugTimeMarker, sound_output: SoundOutput, target_seconds_per_frame: f32) {
            pad: [2]i32 = {100, 20}
            c := f32(back_buffer.width - 2*pad.x) / f32(sound_output.buffer_size)

            bottom, top  := back_buffer.height - pad.y, pad.y
            middle := back_buffer.height/2
            
            draw_cursor :: proc(back_buffer: OffscreenBuffer, cursor: win.DWORD, c: f32, padx, top, bottom: i32, color: OffscreenBufferColor) {
                x := c * f32(cursor)
                DEBUG_draw_vertical(back_buffer, i32(x) + padx, top, bottom, color)
            }

            play_color     := OffscreenBufferColor{r=0xff, g=0xff, b=0xff}
            write_color    := OffscreenBufferColor{r=0xff, g=0x00, b=0x00}
            expected_color := OffscreenBufferColor{r=0xff, g=0xff, b=0x00}
            window_color   := OffscreenBufferColor{r=0xff, g=0x00, b=0xff}

            for marker, i in last_time_markers {
                if i == 0 {
                    draw_cursor(back_buffer, marker.output_location, c, pad.x, middle - pad.y*6, middle - pad.y*5, play_color)
                    draw_cursor(back_buffer, marker.output_location + marker.output_byte_count, c, pad.x, middle - pad.y*6, middle - pad.y*5, write_color)

                    draw_cursor(back_buffer, marker.expected_frame_boundary_byte, c, pad.x, middle - pad.y*4, middle - pad.y*1, expected_color)

                    draw_cursor(back_buffer, marker.output_play_cursor, c, pad.x, middle - pad.y*4, middle - pad.y*3, play_color)
                    draw_cursor(back_buffer, marker.output_write_cursor, c, pad.x, middle - pad.y*4, middle - pad.y*3, write_color)

                    draw_cursor(back_buffer, marker.flip_play_cursor, c, pad.x, middle - pad.y*2, middle - pad.y, play_color)
                    draw_cursor(back_buffer, marker.flip_play_cursor + 480 * sound_output.bytes_per_sample, c, pad.x, middle - pad.y*2, middle - pad.y, window_color)
                    draw_cursor(back_buffer, marker.flip_write_cursor, c, pad.x, middle - pad.y*2, middle - pad.y, write_color)
                } else {
                    draw_cursor(back_buffer, marker.flip_play_cursor, c, pad.x, middle + pad.y-10, middle + pad.y*2, play_color)
                    draw_cursor(back_buffer, marker.flip_write_cursor, c, pad.x, middle + pad.y, middle + pad.y*2+10, write_color)
                }
            }
        }

        DEBUG_draw_vertical :: proc(back_buffer: OffscreenBuffer, x, top, bottom: i32, color: OffscreenBufferColor) {
            top, bottom := top, bottom
            if top < 0 do top = 0
            if bottom > back_buffer.height do bottom = back_buffer.height

            if x >= 0 && x < back_buffer.width {
                for y in top..<bottom {
                    pixel := &back_buffer.memory[y*back_buffer.width + x]
                    pixel^ = color
                }
            }
        }
    }
}