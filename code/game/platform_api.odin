package game

WorkQueue :: struct {}

@(common) Platform_Allocation_Flags :: bit_set [Platform_Allocation_Flag; u64]
@(common) Platform_Allocation_Flag :: enum { NotRestored }

@(common) PlatformFileType   :: enum { AssetFile }
@(common) PlatformFileHandle :: struct { no_errors:  b32, _platform: pmm }
@(common) PlatformFileGroup  :: struct { file_count: u32, _platform: pmm }

@(common) Platform_no_file_errors :: proc (handle: ^PlatformFileHandle) -> b32 { return handle.no_errors }