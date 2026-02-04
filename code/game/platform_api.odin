package game

////////////////////////////////////////////////
// Shared Definitions

// @hack :WorkQueueDefinition - We should only need a pointer to the queue in the game and render dlls
WorkQueue :: struct {}

@(common) PlatformFileType   :: enum { AssetFile }
@(common) PlatformFileHandle :: struct { no_errors:  b32, _platform: pmm }
@(common) PlatformFileGroup  :: struct { file_count: u32, _platform: pmm }

@(common) Platform_no_file_errors :: proc (handle: ^PlatformFileHandle) -> b32 { return handle.no_errors }

////////////////////////////////////////////////

@(common) Platform_Memory_Block :: struct {
    storage: [] u8,
    allocation_flags: Platform_Allocation_Flags,
    
    // For Arenas
    used: umm,
    arena_previous_block: ^Platform_Memory_Block,
}

@(common) 
Platform_Allocation_Flags :: bit_set [Platform_Allocation_Flag; u64]
Platform_Allocation_Flag :: enum { 
    not_restored,
    check_overflow,
    check_underflow,
}

@(common) BoundsCheck :: Platform_Allocation_Flags { .check_overflow, .check_underflow }

@(common) Debug_Platform_Memory_Stats :: struct {
    block_count: u64,
    total_size:  umm,
    total_used:  umm,
}

// @todo(viktor): This is a hack, because we link with the game translation unit twice. once at compile time and once at runtime. the compiletime PlatformApi is never able to be set otherwise
@(common) set_platform_api_in_the_statically_linked_game_code :: proc (api: Platform_Api) {
    Platform = api
}
