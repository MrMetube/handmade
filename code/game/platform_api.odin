package game

// @todo(viktor): generate this in the metaprogram
@(common) 
PlatformAPI :: struct {
    enqueue_work:      PlatformEnqueueWork,
    complete_all_work: PlatformCompleteAllWork,
        
    begin_processing_all_files_of_type: PlatformBeginProcessingAllFilesOfType,
    end_processing_all_files_of_type:   PlatformEndProcessingAllFilesOfType,
    open_next_file:                     PlatformOpenNextFile,
    read_data_from_file:                PlatformReadDataFromFile,
    mark_file_error:                    PlatformMarkFileError,
    
    allocate_memory:   PlatformAllocateMemory,
    deallocate_memory: PlatformDeallocateMemory,
}

@(common) PlatformWorkQueueCallback :: #type proc(data: pmm)
@(common) PlatformEnqueueWork       :: #type proc(queue: ^PlatformWorkQueue, data: pmm, callback: PlatformWorkQueueCallback)
@(common) PlatformCompleteAllWork   :: #type proc(queue: ^PlatformWorkQueue)

@(common) PlatformFileType   :: enum { AssetFile }
@(common) PlatformFileHandle :: struct { no_errors:  b32, _platform: pmm }
@(common) PlatformFileGroup  :: struct { file_count: u32, _platform: pmm }

@(common) PlatformBeginProcessingAllFilesOfType :: #type proc(type: PlatformFileType) -> PlatformFileGroup
@(common) PlatformEndProcessingAllFilesOfType   :: #type proc(file_group: ^PlatformFileGroup)
@(common) PlatformOpenNextFile                  :: #type proc(file_group: ^PlatformFileGroup) -> PlatformFileHandle
@(common) PlatformReadDataFromFile              :: #type proc(handle: ^PlatformFileHandle, #any_int position, amount: u64, destination: pmm)
@(common) PlatformMarkFileError                 :: #type proc(handle: ^PlatformFileHandle, error_message: string)

@(common)
Platform_no_file_errors :: proc(handle: ^PlatformFileHandle) -> b32 { 
    return handle.no_errors
}

@(common) PlatformAllocateMemory   :: #type proc(#any_int size: u64) -> (result: pmm)
@(common) PlatformDeallocateMemory :: #type proc(memory: pmm)