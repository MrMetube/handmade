package main

import win "core:sys/windows"

when INTERNAL {
	/* IMPORTANT:
		These are not for doing anything in the shipping game
		they are blocking and the write doesnt protect against lost data!
	*/

	DEBUG_read_entire_file :: proc(filename: string) -> (result: []u8) {
		handle := win.CreateFileW(win.utf8_to_wstring(filename), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, 0, nil)
		defer win.CloseHandle(handle)

		if handle == win.INVALID_HANDLE {
			return nil // TODO Logging
		}

		file_size : win.LARGE_INTEGER
		if !win.GetFileSizeEx(handle, &file_size) {
			return nil // TODO Logging
		}
		
		file_size_32 := safe_truncate_u64(cast(u64) file_size)
		result_ptr := cast([^]u8) win.VirtualAlloc(nil, cast(uint) file_size_32, win.MEM_RESERVE | win.MEM_COMMIT, win.PAGE_READWRITE)
		if result_ptr == nil {
			return nil // TODO Logging
		}
		result = result_ptr[:file_size_32]

		bytes_read: win.DWORD
		if !win.ReadFile(handle, result_ptr, file_size_32, &bytes_read, nil) || file_size_32 != bytes_read {
			DEBUG_free_file_memory(result)
			return nil // TODO Logging
		}
		
		return result_ptr[:file_size_32]
	}

	DEBUG_write_entire_file :: proc(filename: string, memory: []u8) -> b32 {
		handle := win.CreateFileW(win.utf8_to_wstring(filename), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, 0, nil)
		defer win.CloseHandle(handle)

		if handle == win.INVALID_HANDLE {
			return false // TODO Logging
		}

		file_size : win.LARGE_INTEGER
		bytes_written: win.DWORD
		if !win.WriteFile(handle, raw_data(memory), cast(u32) len(memory), &bytes_written, nil) {
			return false // TODO Logging
		}

		return true
	}

	DEBUG_free_file_memory :: proc(memory: []u8) {
		if memory != nil {
			win.VirtualFree(raw_data(memory), 0, win.MEM_RELEASE)
		}
	}

	DebugTimeMarker :: struct {
		play_cursor, write_cursor: win.DWORD
	}

	DEBUG_sync_display :: proc(back_buffer: OffscreenBuffer, last_time_markers: []DebugTimeMarker, sound_output: SoundOutput, target_seconds_per_frame: f32){
		pad: [2]i32 = {100, 20}
		c := f32(back_buffer.width - 2*pad.x) / f32(sound_output.sound_buffer_size_in_bytes)

		bottom, top  := back_buffer.height - pad.y, pad.y
		middle := back_buffer.height/2
		
		draw_cursor :: proc(back_buffer: OffscreenBuffer, cursor: win.DWORD, c: f32, padx, top, bottom: i32, color: OffscreenBufferColor) {
			x := c * f32(cursor)
			DEBUG_draw_vertical(back_buffer, i32(x) + padx, top, bottom, color)
		}

		y := (top + middle - pad.y) / 2
		for x in pad.x..<back_buffer.width-pad.x {
			pixel := &back_buffer.memory[y*back_buffer.width + x]
			pixel^ = OffscreenBufferColor{0xff, 0xff, 0xff, 0xff}
		}
		y = (middle + pad.y + bottom) / 2
		for x in pad.x..<back_buffer.width-pad.x {
			pixel := &back_buffer.memory[y*back_buffer.width + x]
			pixel^ = OffscreenBufferColor{0xff, 0xff, 0xff, 0xff}
		}

		for marker in last_time_markers {
			draw_cursor(back_buffer, marker.play_cursor, c, pad.x, top, middle - pad.y, OffscreenBufferColor{0xFF, 0x00, 0xff, 0xFF})
			draw_cursor(back_buffer, marker.write_cursor, c, pad.x, middle + pad.y, bottom, OffscreenBufferColor{0x00, 0xFF, 0xFF, 0xFF})
		}
	}

	DEBUG_draw_vertical :: proc(back_buffer: OffscreenBuffer, x, top, bottom: i32, color: OffscreenBufferColor) {
		for y in top..<bottom {
			pixel := &back_buffer.memory[y*back_buffer.width + x]
			pixel^ = color
		}
	}

}