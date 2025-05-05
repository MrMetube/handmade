package main

import "base:runtime"
import "core:os"
import "core:fmt"
import win "core:sys/windows"

game := game_stubs

@(private="file")
game_stubs := GameApi {
    debug_frame_end         = proc(_: ^GameMemory, _: Input, _: ^RenderCommands) {},
    frame_marker            = proc(_: f32, _ := #caller_location) {},
    begin_timed_block       = proc(_: string, _ := #caller_location, _: i64 = 1) -> (result: i64, out:string)  { return result, out },
    end_timed_block         = proc(_: i64,_: string) {},
    debug_record_b32        = proc(_:^b32, _:string, _ := #caller_location) {},
    debug_begin_data_block  = proc(name: string, loc := #caller_location) {},
    debug_end_data_block    = proc() {},
}

@(private="file")
GameApi :: struct {
    update_and_render:      UpdateAndRender,
    output_sound_samples:   OutputSoundSamples,
    debug_frame_end:        DebugFrameEnd,
    begin_timed_block:      BeginTimedBlock,
    end_timed_block:        EndTimedBlock,
    frame_marker:           FrameMarker,
    debug_record_b32:       DebugRecordB32,
    debug_begin_data_block: DebugBeginDataBlock,
    debug_end_data_block:   DebugEndDataBlock,
}

load_game_lib :: proc(source_dll_name, temp_dll_name, lock_name: win.wstring) -> (is_valid:b32, last_write_time: u64) {
    if game_lib == nil {
        assert(game == game_stubs, "game.dll has already been initialized")
    } else {
        if !win.FreeLibrary(game_lib) {
            // @Logging 
            fmt.println("Failed to load game.dll")
        }
    }
    
    if !win.GetFileAttributesExW(lock_name, win.GetFileExInfoStandard, nil) {
        win.CopyFileW(source_dll_name, temp_dll_name, false)
        last_write_time = get_last_write_time(source_dll_name)
        game_lib = win.LoadLibraryW(temp_dll_name)

        if (game_lib != nil) {
            game.update_and_render    = auto_cast win.GetProcAddress(game_lib, "update_and_render")
            game.output_sound_samples = auto_cast win.GetProcAddress(game_lib, "output_sound_samples")
            
            is_valid = game.update_and_render != nil && game.output_sound_samples != nil
            
            game.debug_frame_end        = auto_cast win.GetProcAddress(game_lib, "debug_frame_end")
            game.begin_timed_block      = auto_cast win.GetProcAddress(game_lib, "begin_timed_block")
            game.end_timed_block        = auto_cast win.GetProcAddress(game_lib, "end_timed_block")
            game.frame_marker           = auto_cast win.GetProcAddress(game_lib, "frame_marker")
            game.debug_record_b32       = auto_cast win.GetProcAddress(game_lib, "debug_record_b32")
            game.debug_begin_data_block = auto_cast win.GetProcAddress(game_lib, "debug_begin_data_block")
            game.debug_end_data_block   = auto_cast win.GetProcAddress(game_lib, "debug_end_data_block")
        } else {
            // @Logging 
            fmt.println("Failed to initialize game api")
            fmt.println(os.error_string(os.get_last_error()))
        }
    }

    if !is_valid {
        game = game_stubs
    }
    
    return is_valid, last_write_time
}

unload_game_lib :: proc() {
    if game_lib != nil {
        if !win.FreeLibrary(game_lib) {
            // @Logging 
        }
        game_lib = nil
    }
    game = game_stubs
}

get_last_write_time :: proc(filename: win.wstring) -> (last_write_time: u64) {
    FILE_ATTRIBUTE_DATA :: struct {
        dwFileAttributes: win.DWORD,
        ftCreationTime:   win.FILETIME,
        ftLastAccessTime: win.FILETIME,
        ftLastWriteTime:  win.FILETIME,
        nFileSizeHigh:    win.DWORD,
        nFileSizeLow:     win.DWORD,
    }

    file_information: FILE_ATTRIBUTE_DATA
    if win.GetFileAttributesExW(filename, win.GetFileExInfoStandard, &file_information) {
        last_write_time = (cast(u64) (file_information.ftLastWriteTime.dwHighDateTime) << 32) | cast(u64) (file_information.ftLastWriteTime.dwLowDateTime)
    }
    return last_write_time
}

////////////////////////////////////////////////
// Internals

@(private="file")
game_lib: win.HMODULE

@(private="file") UpdateAndRender    :: #type proc(memory: ^GameMemory, input: Input, render_commands: ^RenderCommands)
@(private="file") OutputSoundSamples :: #type proc(memory: ^GameMemory, sound_buffer: GameSoundBuffer)

@(private="file") DebugFrameEnd       :: #type proc(memory: ^GameMemory, input: Input, render_commands: ^RenderCommands)
@(private="file") BeginTimedBlock     :: #type proc(name: string, loc := #caller_location, hit_count: i64 = 1) -> (result: i64, out: string) 
@(private="file") EndTimedBlock       :: #type proc(hit_count: i64, name: string)
@(private="file") FrameMarker         :: #type proc(seconds_elapsed: f32, loc := #caller_location)
@(private="file") DebugRecordB32      :: #type proc(value: ^b32, name: string = #caller_expression(value), loc := #caller_location)
@(private="file") DebugBeginDataBlock :: #type proc(name: string, loc := #caller_location)
@(private="file") DebugEndDataBlock   :: #type proc()
