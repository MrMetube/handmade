package game

// TODO: COPYPASTA from debug

DEBUG_code :: struct {
    read_entire_file  : proc_DEBUG_read_entire_file,
    write_entire_file : proc_DEBUG_write_entire_file,
    free_file_memory  : proc_DEBUG_free_file_memory,
}

proc_DEBUG_read_entire_file  :: #type proc(filename: string) -> (result: []u8)
proc_DEBUG_write_entire_file :: #type proc(filename: string, memory: []u8) -> b32
proc_DEBUG_free_file_memory  :: #type proc(memory: []u8)

// TODO: Copypasta END