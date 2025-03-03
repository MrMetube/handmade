package main

import "base:runtime"
import "core:os"
import "core:fmt"
import win "core:sys/windows"

game: GameApi = stubbed

@(private="file")
stubbed := GameApi {
    debug_frame_end   = proc(memory: ^GameMemory, input: Input, render_commands: ^RenderCommands) {},
    frame_marker      = proc(seconds_elapsed: f32, loc := #caller_location) {},
    begin_timed_block = proc(name: string, loc: runtime.Source_Code_Location = #caller_location, hit_count: i64 = 1) -> (result: TimedBlock)  { return result },
    end_timed_block   = proc(block: TimedBlock) {},
}

@(private="file")
GameApi :: struct {
    update_and_render:    UpdateAndRender,
    output_sound_samples: OutputSoundSamples,
    debug_frame_end:      DebugFrameEnd,
    begin_timed_block:    BeginTimedBlock,
    end_timed_block:      EndTimedBlock,
    frame_marker:         FrameMarker,
}

load_game_lib :: proc(source_dll_name, temp_dll_name, lock_name: win.wstring) -> (is_valid:b32, last_write_time: u64) {
    if game_lib == nil {
        assert(game == stubbed, "game.dll has already been initialized")
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
            game.debug_frame_end      = auto_cast win.GetProcAddress(game_lib, "debug_frame_end")
            game.begin_timed_block    = auto_cast win.GetProcAddress(game_lib, "begin_timed_block")
            game.end_timed_block      = auto_cast win.GetProcAddress(game_lib, "end_timed_block")
            game.frame_marker         = auto_cast win.GetProcAddress(game_lib, "frame_marker")

            is_valid = game.update_and_render != nil && game.output_sound_samples != nil
        } else {
            // @Logging 
            fmt.println("Failed to initialize game api")
            fmt.println(os.error_string(os.get_last_error()))
        }
    }

    if !is_valid {
        game = stubbed
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
    game = stubbed
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
@(private="file") DebugFrameEnd      :: #type proc(memory: ^GameMemory, input: Input, render_commands: ^RenderCommands)

@(private="file") BeginTimedBlock    :: #type proc(name: string, loc: runtime.Source_Code_Location = #caller_location, hit_count: i64 = 1) -> (result: TimedBlock) 
@(private="file") EndTimedBlock      :: #type proc(block: TimedBlock)
@(private="file") FrameMarker        :: #type proc(seconds_elapsed: f32, loc := #caller_location)
