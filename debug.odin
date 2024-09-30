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

}