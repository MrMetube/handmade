package render

import "base:runtime"
import win "core:sys/windows"
import "core:dynlib"

import game "../game"
import gpu "./no_graphics_api"

Renderer_State_Version :: 1

@(common)
Renderer_State :: struct {
    version:      u32,
    size:         u32,
    initialized:  bool,
    use_vulkan:   bool,
    
    // These are CPU-side owners of persistent driver objects. The storage is
    // supplied by the platform and is deliberately not part of the DLL image.
    gl_context: win.HGLRC,
    open_gl:    OpenGL,
    vulkan:     Vulkan,
}

renderer_state: ^Renderer_State

bind_renderer_state :: proc (memory: [] u8) -> bool {
    if memory == nil || len(memory) < size_of(Renderer_State) do return false
    
    renderer_state = cast(^Renderer_State) raw_data(memory)
    open_gl = &renderer_state.open_gl
    vulkan  = &renderer_state.vulkan
    return true
}

// @todo struct for all lose params
@(export)
attach :: proc (memory: [] u8, window: win.HWND, window_dc: win.HDC, platform_api: game.Platform_Api, use_vulkan: bool) -> bool {
    if !bind_renderer_state(memory) do return false
    
    // Layout changes need an explicit migration. Refuse the reload rather than
    // interpreting live driver state with a different struct definition.
    if renderer_state.initialized &&
       (renderer_state.version != Renderer_State_Version ||
        renderer_state.size != size_of(Renderer_State) ||
        renderer_state.use_vulkan != use_vulkan) {
        return false
    }
    
    game.set_platform_api_in_the_statically_linked_game_code(platform_api)
    
    if !renderer_state.initialized {
        renderer_state.version = Renderer_State_Version
        renderer_state.size = cast(u32) size_of(Renderer_State)
        renderer_state.use_vulkan = use_vulkan
        
        if use_vulkan {
            init_vulkan(window)
        } else {
            renderer_state.gl_context = init_opengl(window_dc)
        }
        renderer_state.initialized = true
        return true
    }
    
    // A DLL reload resets package-level dispatch tables, but must not replace
    // the actual graphics context/device or any resource handles.
    if use_vulkan {
        return rebind_device(vulkan.device)
    }
    return reattach_opengl(window_dc, renderer_state.gl_context)
}


// Rebuild the DLL-local Vulkan dispatch tables for an existing device. The
// instance, logical device, queues, swapchain, and allocations remain owned by
// the persistent renderer state; none of them are recreated during code reload.
rebind_device :: proc (device: gpu.Device) -> bool {
    if device == nil do return false
    
    // @leak
    vulkan_library, ok := dynlib.load_library("vulkan-1.dll", allocator = context.temp_allocator)
    if !ok do return false
    
    address, found := dynlib.symbol_address(vulkan_library, "vkGetInstanceProcAddr", allocator = context.temp_allocator)
    if !found do return false
    
    GetInstanceProcAddr := cast(proc "system" (instance: game.pmm, pName: cstring) -> game.pmm) address
    GetDeviceProcAddr   := cast(proc "system" (device:   game.pmm, pName: cstring) -> game.pmm) GetInstanceProcAddr(device.instance, "vkGetDeviceProcAddr")
    
    device.destroy_debug_messenger            = auto_cast GetInstanceProcAddr(device.instance, "vkDestroyDebugUtilsMessengerEXT")
    device.fn.WriteSamplerDescriptors         = auto_cast GetDeviceProcAddr(device.device, "vkWriteSamplerDescriptorsEXT")
    device.fn.WriteResourceDescriptors        = auto_cast GetDeviceProcAddr(device.device, "vkWriteResourceDescriptorsEXT")
    device.fn.CmdBindSamplerHeap              = auto_cast GetDeviceProcAddr(device.device, "vkCmdBindSamplerHeapEXT")
    device.fn.CmdBindResourceHeap             = auto_cast GetDeviceProcAddr(device.device, "vkCmdBindResourceHeapEXT")
    device.fn.CmdPushData                     = auto_cast GetDeviceProcAddr(device.device, "vkCmdPushDataEXT")
    device.fn.CmdBindIndexBuffer              = auto_cast GetDeviceProcAddr(device.device, "vkCmdBindIndexBuffer3KHR")
    device.fn.CmdDrawIndirect                 = auto_cast GetDeviceProcAddr(device.device, "vkCmdDrawIndirect2KHR")
    device.fn.CmdDrawIndexedIndirect          = auto_cast GetDeviceProcAddr(device.device, "vkCmdDrawIndexedIndirect2KHR")
    device.fn.CmdDispatchIndirect             = auto_cast GetDeviceProcAddr(device.device, "vkCmdDispatchIndirect2KHR")
    device.fn.CmdDrawMeshTasks                = auto_cast GetDeviceProcAddr(device.device, "vkCmdDrawMeshTasksEXT")
    device.fn.CmdDrawMeshTasksIndirect        = auto_cast GetDeviceProcAddr(device.device, "vkCmdDrawMeshTasksIndirect2EXT")
    device.fn.CmdCopyMemory                   = auto_cast GetDeviceProcAddr(device.device, "vkCmdCopyMemoryKHR")
    device.fn.CmdCopyMemoryToImage            = auto_cast GetDeviceProcAddr(device.device, "vkCmdCopyMemoryToImageKHR")
    device.fn.CmdCopyImageToMemory            = auto_cast GetDeviceProcAddr(device.device, "vkCmdCopyImageToMemoryKHR")
    device.fn.CmdCopyQueryPoolResultsToMemory = auto_cast GetDeviceProcAddr(device.device, "vkCmdCopyQueryPoolResultsToMemoryKHR")
    
    return device.fn.WriteSamplerDescriptors != nil &&
           device.fn.WriteResourceDescriptors != nil &&
           device.fn.CmdBindResourceHeap != nil &&
           device.fn.CmdBindSamplerHeap != nil
}

@(export)
allocate_texture :: proc (bitmap: game.Bitmap, set_as_nil_texture: bool) -> u32 {
    result: u32
    if renderer_state.use_vulkan {
        result = vk_allocate_texture(bitmap, set_as_nil_texture)
    } else {
        result = gl_allocate_texture(bitmap)
    }
    return result
}

@(export)
manage_textures :: proc (last: ^game.TextureOp) {
    if renderer_state.use_vulkan {
        vk_manage_textures(last)
    } else {
        gl_manage_textures(last)
    }
}

// @todo struct for all lose params
@(export)
render :: proc (commands: ^game.RenderCommands, render_queue: ^game.WorkQueue, draw_region: game.Rectangle2i, frame_allocator: game.Allocator, window_dimension: game.v2i, software_target: game.Bitmap, use_software_renderer: bool, single_threaded: bool) {
    commands.clear_color.rgb = game.square(commands.clear_color.rgb)
    
    if use_software_renderer {
        game.assert(!renderer_state.use_vulkan, "the software renderer currently presents through OpenGL")
        software_render_commands(render_queue, commands, software_target, frame_allocator, single_threaded)
        gl_display_bitmap(software_target, draw_region, commands.clear_color)
    } else if renderer_state.use_vulkan {
        vk_render_commands(commands, draw_region, window_dimension)
    } else {
        gl_render_commands(commands, draw_region, window_dimension)
    }
}

////////////////////////////////////////////////
// Local profiling wrappers. The imported game package is intentionally used
// normally in this sketch; no generated @common aliases are required here.

end_timed_block :: proc () {
    game.end_timed_block()
}

@(deferred_none=end_timed_block)
timed_block :: proc (name: string, loc := #caller_location) {
    game.begin_timed_block(name, loc)
}

@(deferred_out=end_timed_block)
timed_function :: proc (loc := #caller_location) {
    game.begin_timed_block(loc.procedure, loc)
}

debug_end_data_block :: proc () {
    game.debug_end_data_block()
}

@(deferred_out=debug_end_data_block)
debug_data_block :: proc (name: string, loc := #caller_location) {
    game.debug_begin_data_block(name, loc)
}