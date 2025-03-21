package game

@common 
PlatformAPI :: struct {
    enqueue_work:      PlatformEnqueueWork,
    complete_all_work: PlatformCompleteAllWork,
    
    allocate_memory:   PlatformAllocateMemory,
    deallocate_memory: PlatformDeallocateMemory,
    
    allocate_texture:   PlatformAllocateTexture,
    deallocate_texture: PlatformDeallocateTexture,
        
    begin_processing_all_files_of_type: PlatformBeginProcessingAllFilesOfType,
    end_processing_all_files_of_type:   PlatformEndProcessingAllFilesOfType,
    open_next_file:                     PlatformOpenNextFile,
    read_data_from_file:                PlatformReadDataFromFile,
    mark_file_error:                    PlatformMarkFileError,

    debug: DebugCode,
}

@common PlatformWorkQueueCallback :: #type proc(data: pmm)
@common PlatformEnqueueWork       :: #type proc(queue: ^PlatformWorkQueue, callback: PlatformWorkQueueCallback, data: pmm)
@common PlatformCompleteAllWork   :: #type proc(queue: ^PlatformWorkQueue)

@common PlatformAllocateMemory   :: #type proc(size: u64) -> pmm
@common PlatformDeallocateMemory :: #type proc(memory: pmm)

@common PlatformAllocateTexture   :: #type proc(width, height: i32, data: pmm) -> pmm
@common PlatformDeallocateTexture :: #type proc(texture: pmm)

@common PlatformFileType   :: enum { AssetFile }
@common PlatformFileHandle :: struct { no_errors:  b32, _platform: pmm }
@common PlatformFileGroup  :: struct { file_count: u32, _platform: pmm }

@common PlatformBeginProcessingAllFilesOfType :: #type proc(type: PlatformFileType) -> PlatformFileGroup
@common PlatformEndProcessingAllFilesOfType   :: #type proc(file_group: ^PlatformFileGroup)
@common PlatformOpenNextFile                  :: #type proc(file_group: ^PlatformFileGroup) -> PlatformFileHandle
@common PlatformReadDataFromFile              :: #type proc(handle: ^PlatformFileHandle, #any_int position, amount: u64, destination: pmm)
@common PlatformMarkFileError                 :: #type proc(handle: ^PlatformFileHandle, error_message: string)

@common
Platform_no_file_errors :: #force_inline proc(handle: ^PlatformFileHandle) -> b32 { 
    return handle.no_errors
}