package game

@common 
PlatformAPI :: struct {
    enqueue_work:      PlatformEnqueueWork,
    complete_all_work: PlatformCompleteAllWork,
    
    allocate_memory:   PlatformAllocateMemory,
    deallocate_memory: PlatformDeallocateMemory,
    
    begin_processing_all_files_of_type: PlatformBeginProcessingAllFilesOfType,
    end_processing_all_files_of_type:   PlatformEndProcessingAllFilesOfType,
    open_next_file:                     PlatformOpenNextFile,
    read_data_from_file:                PlatformReadDataFromFile,
    mark_file_error:                    PlatformMarkFileError,
    
    debug: DebugCode,
}

@common PlatformWorkQueueCallback :: #type proc(data: rawpointer)
@common PlatformEnqueueWork       :: #type proc(queue: ^PlatformWorkQueue, callback: PlatformWorkQueueCallback, data: rawpointer)
@common PlatformCompleteAllWork   :: #type proc(queue: ^PlatformWorkQueue)

@common PlatformAllocateMemory   :: #type proc(size: u64) -> rawpointer
@common PlatformDeallocateMemory :: #type proc(memory:rawpointer)

@common PlatformFileType   :: enum { AssetFile }
@common PlatformFileHandle :: struct { no_errors:  b32, _platform: rawpointer }
@common PlatformFileGroup  :: struct { file_count: u32, _platform: rawpointer }

@common PlatformBeginProcessingAllFilesOfType :: #type proc(type: PlatformFileType) -> PlatformFileGroup
@common PlatformEndProcessingAllFilesOfType   :: #type proc(file_group: ^PlatformFileGroup)
@common PlatformOpenNextFile                  :: #type proc(file_group: ^PlatformFileGroup) -> PlatformFileHandle
@common PlatformReadDataFromFile              :: #type proc(handle: ^PlatformFileHandle, #any_int position, amount: u64, destination: rawpointer)
@common PlatformMarkFileError                 :: #type proc(handle: ^PlatformFileHandle, error_message: string)

@common
Platform_no_file_errors :: #force_inline proc(handle: ^PlatformFileHandle) -> b32 { 
    return handle.no_errors
}