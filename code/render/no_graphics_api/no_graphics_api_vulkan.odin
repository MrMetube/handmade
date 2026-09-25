#+private
#+vet explicit-allocators !unused-procedures
package gpu

import "base:runtime"
import "base:intrinsics"

import "core:slice"

import vk "vendor:vulkan"

////////////////////////////////////////////////

max_instance_extensions       :: 256
max_instance_layers           ::  64
max_physical_devices          ::  32
max_device_extensions         :: 512
max_queue_families            ::  64
max_swapchain_images          ::   8
max_color_attachments         ::   8
max_surface_formats           ::  64
initial_command_context_count ::   2
image_barrier_batch_size      ::  64
gpu_allocation_alignment      ::  16

swapchain_present_mode :: vk.PresentModeKHR.FIFO
   
universal_buffer_usage :: vk.BufferUsageFlags { .SHADER_DEVICE_ADDRESS, .INDEX_BUFFER, .INDIRECT_BUFFER, .TRANSFER_SRC, .TRANSFER_DST }
    
cpu_visible_memory_properties :: vk.MemoryPropertyFlags { .DEVICE_LOCAL, .HOST_VISIBLE, .HOST_COHERENT }
forbidden_memory_properties   :: vk.MemoryPropertyFlags { .LAZILY_ALLOCATED, .PROTECTED, .DEVICE_COHERENT_AMD, .DEVICE_UNCACHED_AMD }

required_queue_flags :: vk.QueueFlags { .GRAPHICS, .COMPUTE }
address_flags :: vk.AddressCommandFlagsKHR { .FULLY_BOUND }
    
////////////////////////////////////////////////

_Device :: struct {
    allocator: runtime.Allocator,
    
    instance: vk.Instance,
    debug_messenger:         vk.DebugUtilsMessengerEXT,
    destroy_debug_messenger: vk.ProcDestroyDebugUtilsMessengerEXT,
    physical_device: vk.PhysicalDevice,
    device:          vk.Device,
    queue:           vk.Queue,
    surface:         vk.SurfaceKHR,
    queue_family:    u32,
    timestamp_query_count: u32,
    memory_properties:   vk.PhysicalDeviceMemoryProperties,
    physical_properties: vk.PhysicalDeviceProperties,
    heap_properties:     vk.PhysicalDeviceDescriptorHeapPropertiesEXT,
    max_timeline_value_difference: u64,
    texture_heap_alignment: u64,
    texture_memory_type: u32,
    fn: struct {
        WriteSamplerDescriptors:         vk.ProcWriteSamplerDescriptorsEXT,
        WriteResourceDescriptors:        vk.ProcWriteResourceDescriptorsEXT,
        CmdBindSamplerHeap:              vk.ProcCmdBindSamplerHeapEXT,
        CmdBindResourceHeap:             vk.ProcCmdBindResourceHeapEXT,
        CmdPushData:                     vk.ProcCmdPushDataEXT,
        CmdBindIndexBuffer:              vk.ProcCmdBindIndexBuffer3KHR,
        CmdDrawIndirect:                 vk.ProcCmdDrawIndirect2KHR,
        CmdDrawIndexedIndirect:          vk.ProcCmdDrawIndexedIndirect2KHR,
        CmdDispatchIndirect:             vk.ProcCmdDispatchIndirect2KHR,
        CmdDrawMeshTasks:                vk.ProcCmdDrawMeshTasksEXT,
        CmdDrawMeshTasksIndirect:        vk.ProcCmdDrawMeshTasksIndirect2EXT,
        CmdCopyMemory:                   vk.ProcCmdCopyMemoryKHR,
        CmdCopyMemoryToImage:            vk.ProcCmdCopyMemoryToImageKHR,
        CmdCopyImageToMemory:            vk.ProcCmdCopyImageToMemoryKHR,
        CmdCopyQueryPoolResultsToMemory: vk.ProcCmdCopyQueryPoolResultsToMemoryKHR,
    },
    caps: DeviceCaps,
    format_features: [Format] vk.FormatFeatureFlags2,
    texture_compression_etc2: bool,
    pending_texture_initializations: TextureInitialization,
    next_command_context: CommandBuffer,
    command_submit_infos: [dynamic] vk.CommandBufferSubmitInfo,
    command_retirement:           vk.Semaphore,
    command_retirement_value:     u64,
    completed_command_retirement: u64,
    swapchain_delete_queue: SwapchainDeleteQueue,
    present_contexts:   [dynamic; max_swapchain_images] PresentContext,
    retired_swapchains: [max_swapchain_images] RetiredSwapchain,
    swapchain:          ^Swapchain,
    acquired_swapchain: ^Swapchain,
    active_command_buffers: u32,
    next_present_context:   u32,
}

_Texture :: struct {
    device:         ^_Device,
    image:          vk.Image,
    width:          u32,
    height:         u32,
    depth:          u32,
    layer_count:    u32,
    type:           TextureType,
    format:         Format,
    initialization: TextureInitialization,
}

_RenderView :: struct {
    device:         ^_Device,
    view:           vk.ImageView,
    width:          u32,
    height:         u32,
    swapchain_view: bool,
}

_PSO :: struct {
    device: ^_Device,
    pso: vk.Pipeline,
    bind_point: vk.PipelineBindPoint,
}

_CommandBuffer :: struct {
    device:                 ^_Device,
    next, previous:         ^_CommandBuffer,
    command_pool:           vk.CommandPool,
    command_buffer:         vk.CommandBuffer,
    timestamp_pool:         vk.QueryPool,
    timestamp_destinations: [dynamic] vk.DeviceAddress,
    retire_value:           u64,
    swapchain:              ^Swapchain,
}

_TimelineSemaphore :: struct {
    device:    ^_Device,
    semaphore: vk.Semaphore,
}

_GpuHeapOwner :: struct {
    device:  ^_Device,
    backing: BackingBuffer,
}

_TextureHeapOwner :: struct {
    device: ^_Device,
    memory: vk.DeviceMemory,
}

Swapchain :: struct {
    device: ^_Device,
    handle: vk.SwapchainKHR,
    images:       [max_swapchain_images] vk.Image,
    render_views: [max_swapchain_images] _RenderView,
    initialized:  [max_swapchain_images] bool,
    image_count: u32,
    image_index: u32,
    width:  u32,
    height: u32,
    format: Format,
    transform:       vk.SurfaceTransformFlagsKHR,
    composite_alpha: vk.CompositeAlphaFlagsKHR,
    present_context:     ^PresentContext,
    transition_commands: CommandBuffer,
    acquired:          bool,
    recreate_required: bool,
}


SwapchainDeleteQueue :: struct {
    entries: [] DeferredSwapchainImage,
    first:   u32,
    count:   u32,
}


DeferredSwapchainImage :: struct {
    retired_value: u64,
    swapchain:     vk.SwapchainKHR,
    view:          vk.ImageView,
}

PresentContext :: struct {
    acquired:        vk.Semaphore,
    rendered:        vk.Semaphore,
    presented:       vk.Fence,
    swapchain:       vk.SwapchainKHR,
    present_pending: bool,
}

RetiredSwapchain :: struct {
    handle: vk.SwapchainKHR,
    views:  [dynamic; max_swapchain_images] vk.ImageView,
}

TextureInitialization :: struct {
    image:        vk.Image,
    aspect_mask:  vk.ImageAspectFlags,
    mip_levels:   u32,
    array_layers: u32,
    
    previous: ^TextureInitialization,
    next:     ^TextureInitialization,
}

BackingBuffer :: struct {
    buffer:  vk.Buffer,
    memory:  vk.DeviceMemory,
    mapped:  rawptr,
    address: vk.DeviceAddress,
}

////////////////////////////////////////////////
// Swapchain

recreate_swapchain :: proc (swapchain: ^Swapchain) -> Error {
    device := swapchain.device
    assert(!swapchain.acquired && device.acquired_swapchain == nil && device.active_command_buffers == 0)
    
    present_mode_info := vk.SurfacePresentModeKHR {
        sType = .SURFACE_PRESENT_MODE_KHR,
        presentMode = swapchain_present_mode,
    }
    
    surface_info := vk.PhysicalDeviceSurfaceInfo2KHR {
        sType = .PHYSICAL_DEVICE_SURFACE_INFO_2_KHR,
        pNext = &present_mode_info,
        surface = device.surface,
    }
    
    capabilities_info := vk.SurfaceCapabilities2KHR { sType = .SURFACE_CAPABILITIES_2_KHR }
    error := error_from_vk(vk.GetPhysicalDeviceSurfaceCapabilities2KHR(device.physical_device, &surface_info, &capabilities_info))
    if error != .none { return error }
    
    capabilities := capabilities_info.surfaceCapabilities
    extent := capabilities.currentExtent
    if extent.width == max(u32) { return .unsupported }
    
    if extent.width == 0 || extent.height == 0 {
        swapchain.width = 0
        swapchain.height = 0
        swapchain.recreate_required = true
        return .none
    }
    
    if .COLOR_ATTACHMENT not_in capabilities.supportedUsageFlags { return .unsupported }
    
    formats: [max_surface_formats] vk.SurfaceFormatKHR
    surface_formats_count: u32
    error = error_from_vk(vk.GetPhysicalDeviceSurfaceFormatsKHR(device.physical_device, device.surface, &surface_formats_count, nil))
    if error != .none { return error }
    if surface_formats_count == 0 || surface_formats_count > auto_cast len(formats) { return .unsupported }
    
    error = error_from_vk(vk.GetPhysicalDeviceSurfaceFormatsKHR(device.physical_device, device.surface, &surface_formats_count, raw_data(&formats)))
    if error != .none { return error }
    
    
    requested_format := to_vk(swapchain.format)
    format_supported: bool
    for it in formats[:surface_formats_count] {
        if (it.format == requested_format || it.format == .UNDEFINED) && it.colorSpace == .SRGB_NONLINEAR {
            format_supported = true
            break
        }
    }
    if !format_supported { return .unsupported }
    
    requested_image_count := cast(u32) len(device.present_contexts)
    if requested_image_count < capabilities.minImageCount {
        requested_image_count = capabilities.minImageCount
    }
    if requested_image_count > capabilities.maxImageCount && capabilities.maxImageCount != 0 {
        requested_image_count = capabilities.maxImageCount
    }
    if requested_image_count == 0 || requested_image_count > max_swapchain_images { return .unsupported }
    
    composite_alpha := choose_composite_alpha(capabilities.supportedCompositeAlpha)
    swapchain_present_mode := swapchain_present_mode
    
    old_handle := swapchain.handle
    new_handle: vk.SwapchainKHR
    error = error_from_vk(vk.CreateSwapchainKHR(device.device, &vk.SwapchainCreateInfoKHR {
        sType = .SWAPCHAIN_CREATE_INFO_KHR,
        pNext = &vk.SwapchainPresentModesCreateInfoKHR {
            sType = .SWAPCHAIN_PRESENT_MODES_CREATE_INFO_KHR,
            presentModeCount = 1,
            pPresentModes    = &swapchain_present_mode,
        },
        surface          = device.surface,
        minImageCount    = requested_image_count,
        imageFormat      = requested_format,
        imageColorSpace  = .SRGB_NONLINEAR,
        imageExtent      = extent,
        imageArrayLayers = 1,
        imageUsage       = { .COLOR_ATTACHMENT },
        imageSharingMode = .EXCLUSIVE,
        preTransform     = capabilities.currentTransform,
        compositeAlpha   = composite_alpha,
        presentMode      = swapchain_present_mode,
        clipped          = true,
        oldSwapchain     = old_handle,
    }, nil, &new_handle))
    if error != .none {
        retire_swapchain_handle(swapchain)
        return error
    }
    
    images: [max_swapchain_images] vk.Image
    image_count: u32
    result := vk.GetSwapchainImagesKHR(device.device, new_handle, &image_count, nil)
    if result != .SUCCESS || image_count == 0 || image_count > max_swapchain_images {
        vk.DestroySwapchainKHR(device.device, new_handle, nil)
        retire_swapchain_handle(swapchain)
        return result == .SUCCESS ? .unsupported : error_from_vk(result)
    }
    result = vk.GetSwapchainImagesKHR(device.device, new_handle, &image_count, raw_data(&images))
    if result != .SUCCESS {
        vk.DestroySwapchainKHR(device.device, new_handle, nil)
        retire_swapchain_handle(swapchain)
        return error_from_vk(result)
    }
    
    views: [max_swapchain_images] vk.ImageView
    for image, index in images[:image_count] {
        result = vk.CreateImageView(device.device, &vk.ImageViewCreateInfo {
            sType = .IMAGE_VIEW_CREATE_INFO,
            image = image,
            viewType = .D2,
            format = requested_format,
            subresourceRange = { aspectMask = { .COLOR }, levelCount = 1, layerCount = 1 },
        }, nil, &views[index])
        
        if result != .SUCCESS {
            for created in views[:index] {
                vk.DestroyImageView(device.device, created, nil)
            }
            vk.DestroySwapchainKHR(device.device, new_handle, nil)
            retire_swapchain_handle(swapchain)
            return error_from_vk(result)
        }
    }
    
    retire_swapchain_handle(swapchain)
    swapchain.handle = new_handle
    swapchain.image_count = image_count
    swapchain.width = extent.width
    swapchain.height = extent.height
    swapchain.transform = capabilities.currentTransform
    swapchain.composite_alpha = composite_alpha
    swapchain.recreate_required = false
    for index in 0..<image_count {
        swapchain.images[index] = images[index]
        swapchain.render_views[index] = {
            device         = device,
            view           = views[index],
            width          = extent.width,
            height         = extent.height,
            swapchain_view = true,
        }
    }
    
    return .none
}

choose_composite_alpha :: proc (supported: vk.CompositeAlphaFlagsKHR) -> vk.CompositeAlphaFlagsKHR {
    choices := [?] vk.CompositeAlphaFlagKHR {
        .OPAQUE,
        .PRE_MULTIPLIED,
        .POST_MULTIPLIED,
        .INHERIT,
    }
    
    for choice in choices {
        if choice in supported {
            return { choice }
        }
    }
    
    panic("surface exposes no composite alpha mode")
}

swapchain_surface_configuration_changed :: proc (swapchain: ^Swapchain) -> bool {
    capabilities: vk.SurfaceCapabilitiesKHR
    error := error_from_vk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(swapchain.device.physical_device, swapchain.device.surface, &capabilities))
    require_error(error)
    
    extent := capabilities.currentExtent
    variable_extent := max(u32)
    result := 
        extent.width == variable_extent || extent.height == variable_extent || 
        extent.width != swapchain.width || extent.height != swapchain.height || 
        capabilities.currentTransform != swapchain.transform || 
        choose_composite_alpha(capabilities.supportedCompositeAlpha) != swapchain.composite_alpha
    return result
}

////////////////////////////////////////////////
// Present Context

create_present_context :: proc (device: ^_Device, present: ^PresentContext) -> Error {
    assert(present.acquired == 0 && present.rendered == 0 && present.presented == 0 && present.swapchain == 0 && !present.present_pending)
    
    error := error_from_vk(vk.CreateSemaphore(device.device, &vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }, nil, &present.acquired))
    if error == .none {
        error = error_from_vk(vk.CreateSemaphore(device.device, &vk.SemaphoreCreateInfo { sType = .SEMAPHORE_CREATE_INFO }, nil, &present.rendered))
        if error == .none {
            error = error_from_vk(vk.CreateFence(device.device, &vk.FenceCreateInfo { sType = .FENCE_CREATE_INFO }, nil, &present.presented))
        }
    }
    
    if error != .none { destroy_present_context(device, present) }
    return error
}

destroy_present_context :: proc (device: ^_Device, present: ^PresentContext) {
    assert(!present.present_pending)
    if device.device != nil {
        vk.DestroySemaphore(device.device, present.acquired,  nil)
        vk.DestroySemaphore(device.device, present.rendered,  nil)
        vk.DestroyFence(device.device,     present.presented, nil)
    }
    present^ = {}
}

poll_present_contexts :: proc (device: ^_Device) {
    for &present in device.present_contexts {
        if !present.present_pending { continue }
        
        result := vk.GetFenceStatus(device.device, present.presented)
        if result == .NOT_READY { continue }
        assert_vk(result)
        
        present.present_pending = false
        finish_present_context(device, &present)
    }
}

wait_present_context :: proc (device: ^_Device, present: ^PresentContext) {
    if !present.present_pending { return }
    assert_vk(vk.WaitForFences(device.device, 1, &present.presented, true, max(u64)))
    
    present.present_pending = false
    finish_present_context(device, present)
}

finish_present_context :: proc (device: ^_Device, present: ^PresentContext) {
    assert(!present.present_pending && present.swapchain != 0)
    
    completed_swapchain := present.swapchain
    present.swapchain = 0
    
    for &retired in device.retired_swapchains {
        if retired.handle != completed_swapchain { continue }
        
        // @note iterate all contexts, not just up to len
        for index in 0..<cap(device.present_contexts) {
            #no_bounds_check pending := device.present_contexts[index]
            if pending.present_pending && pending.swapchain == completed_swapchain {
                return
            }
        }
        
        queue_retired_swapchain(device, &retired)
        return
    }
}

retire_swapchain_handle :: proc (swapchain: ^Swapchain) {
    device := swapchain.device
    
    if swapchain.handle == 0 {
        assert(swapchain.image_count == 0)
        swapchain.width = 0
        swapchain.height = 0
        return
    }
    
    poll_present_contexts(device)
    
    retired := RetiredSwapchain { handle = swapchain.handle }
    
    for index in 0..<swapchain.image_count {
        render_view := &swapchain.render_views[index]
        append(&retired.views, render_view.view)
        render_view^ = {}
        swapchain.images[index] = 0
        swapchain.initialized[index] = false
    }
    
    swapchain.image_count = 0
    swapchain.handle = 0
    swapchain.width = 0
    swapchain.height = 0
    
    present_pending: bool
    for &present in device.present_contexts {
        if present.present_pending && present.swapchain == retired.handle {
            present_pending = true
            break
        }
    }
    
    if present_pending {
        queue_retired_swapchain(device, &retired)
        return
    }
    
    for &slot in device.retired_swapchains {
        if slot.handle == 0 {
            slot = retired
            return
        }
    }
    
    for &present in device.present_contexts {
        if present.present_pending && present.swapchain == retired.handle {
            wait_present_context(device, &present)
        }
    }
    queue_retired_swapchain(device, &retired)
}

queue_retired_swapchain :: proc (device: ^_Device, retired: ^RetiredSwapchain) {
    assert(retired.handle != 0 && len(retired.views) != 0)
    assert(device.active_command_buffers == 0, "swapchain retirement is not allowed while a command buffer is recording")
    
    for view in retired.views {
        assert(view != 0)
        enqueue(&device.swapchain_delete_queue, device.command_retirement_value, retired.handle, view)
    }
    retired^ = {}
    collect(&device.swapchain_delete_queue, device, device.completed_command_retirement)
}

enqueue :: proc (queue: ^SwapchainDeleteQueue, retire_value: u64, swapchain: vk.SwapchainKHR, view: vk.ImageView) {
    assert(swapchain != 0 && view != 0)
    capacity := cast(u32) len(queue.entries)
    if queue.count == capacity {
        allocator := context.allocator
        
        old_size := capacity
        capacity = old_size == 0 ? 1 : old_size * 2
        
        new_entries := make([] DeferredSwapchainImage, capacity, allocator) // @todo allocator
        copy(new_entries, queue.entries)
        for index in 0..<queue.first { 
            new_entries[old_size + index] = queue.entries[index]
        }
        
        delete(queue.entries, allocator)
        queue.entries = new_entries
        assert(cast(u32) len(queue.entries) == capacity)
    }
    
    if queue.count != 0 {
        back := modular_add(queue.first, queue.count - 1, capacity)
        assert(queue.entries[back].retired_value <= retire_value, "swapchain deletion retire values must be monotonic")
    }
    
    queue.entries[modular_add(queue.first, queue.count, capacity)] = {
        retired_value = retire_value,
        swapchain = swapchain,
        view = view,
    }
    queue.count += 1
}

collect :: proc (queue: ^SwapchainDeleteQueue, device: ^_Device, completed_value: u64) {
    for queue.count != 0 && queue.entries[queue.first].retired_value <= completed_value {
        entry := &queue.entries[queue.first]
        final_image := queue.count == 1 || queue.entries[modular_add(queue.first, 1, len(queue.entries))].swapchain != entry.swapchain
        
        vk.DestroyImageView(device.device, entry.view, nil)
        if final_image { vk.DestroySwapchainKHR(device.device, entry.swapchain, nil) }
        entry^ = {}
        queue.first = modular_add(queue.first, 1, len(queue.entries))
        queue.count -= 1
    }
    
    if queue.count == 0 {
        queue.first = 0
    }
}

modular_add :: proc (a: $T, b: T, divisor: $D) -> T {
    return (a + b) % cast(T) divisor
}

////////////////////////////////////////////////
// Texture Initialization List

append_texture_initialization :: proc (list: ^TextureInitialization, item: ^TextureInitialization) {
    assert(item.previous == nil && item.next == nil)
    
    item.previous = list.previous
    item.next     = list
    
    list.previous.next = item
    list.previous      = item
}

remove_texture_initialization :: proc (item: ^TextureInitialization) {
    // @todo isnt this a double-linked list? why is there a null here? check the init code again.
    if item.previous != nil { item.previous.next = item.next }
    if item.next     != nil { item.next.previous = item.previous }
    item.previous = nil
    item.next     = nil
}

////////////////////////////////////////////////
// Command Context

acquire_command_context :: proc (device: ^_Device) -> ^_CommandBuffer {
    result := device.next_command_context
    assert(result != nil)
    
    if device.active_command_buffers == 0 && result.retire_value > device.completed_command_retirement {
        poll_present_contexts(device)
    }
    
    if result.device != nil || result.retire_value > device.completed_command_retirement {
        require_error(grow_command_context_pool(device))
        result = device.next_command_context.previous
        assert(result != device.next_command_context && result.next == device.next_command_context && result.retire_value == 0)
    }
    
    if result.retire_value != 0 {
        reset_command_context(device, result)
    }
    device.next_command_context = result.next
    
    return result
}

create_command_contexts :: proc (device: ^_Device) -> Error {
    assert(device.next_command_context == nil && device.command_retirement == 0 && len(device.command_submit_infos) == 0)
    
    error := error_from_vk(vk.CreateSemaphore(device.device, &vk.SemaphoreCreateInfo {
            sType = .SEMAPHORE_CREATE_INFO,
            pNext = &vk.SemaphoreTypeCreateInfo {
                sType = .SEMAPHORE_TYPE_CREATE_INFO, 
                semaphoreType = .TIMELINE,
            },
        }, nil, &device.command_retirement))
    if error != .none { return error }
    
    for _ in 0..<initial_command_context_count {
        error = grow_command_context_pool(device)
        if error != .none {
            destroy_command_contexts(device)
            return error
        }
    }
    
    return .none
}

// @todo inline
create_command_context :: proc (device: ^_Device, commands: ^_CommandBuffer) -> Error {
    assert(commands.next == nil && commands.previous == nil && commands.command_pool == 0 && commands.command_buffer == nil && commands.timestamp_pool == 0 && commands.device == nil && commands.retire_value == 0)
    
    error := error_from_vk(vk.CreateCommandPool(device.device, &vk.CommandPoolCreateInfo {
        sType = .COMMAND_POOL_CREATE_INFO,
        flags = { .TRANSIENT },
        queueFamilyIndex = device.queue_family,
    }, nil, &commands.command_pool))
    if error != .none { return error }
    
    error = error_from_vk(vk.AllocateCommandBuffers(device.device, &vk.CommandBufferAllocateInfo {
        sType = .COMMAND_BUFFER_ALLOCATE_INFO,
        commandPool = commands.command_pool,
        level = .PRIMARY,
        commandBufferCount = 1,
    }, &commands.command_buffer))
    if error != .none {
        destroy_command_context(device, commands)
        return error
    }
    
    if device.timestamp_query_count != 0 {
        error = error_from_vk(vk.CreateQueryPool(device.device, &vk.QueryPoolCreateInfo {
            sType = .QUERY_POOL_CREATE_INFO,
            queryType = .TIMESTAMP,
            queryCount = device.timestamp_query_count,
        }, nil, &commands.timestamp_pool))
        if error != .none {
            destroy_command_context(device, commands)
            return error
        }
        
        commands.timestamp_destinations = make([dynamic] vk.DeviceAddress, 0, device.timestamp_query_count, device.allocator)
    }
    
    return error
}

destroy_command_context :: proc (device: ^_Device, commands: ^_CommandBuffer) {
    if device.device != nil {
        if commands.timestamp_pool != 0 { vk.DestroyQueryPool(device.device, commands.timestamp_pool, nil) }
        if commands.command_pool   != 0 { vk.DestroyCommandPool(device.device, commands.command_pool, nil) }
    }
    
    delete(commands.timestamp_destinations)
    commands^ = {}
}

grow_command_context_pool :: proc (device: ^_Device) -> Error {
    commands := new(_CommandBuffer, device.allocator)
    
    error := create_command_context(device, commands)
    if error != .none {
        free(commands, device.allocator)
        return error
    }
    
    append_nothing(&device.command_submit_infos)
    
    if device.next_command_context == nil {
        device.next_command_context = commands
        commands.next     = device.next_command_context
        commands.previous = device.next_command_context
    } else {
        commands.next     = device.next_command_context
        commands.previous = device.next_command_context.previous
        commands.previous.next               = commands
        device.next_command_context.previous = commands
    }
    
    return .none
}

destroy_command_contexts :: proc (device: ^_Device) {
    if device.next_command_context != nil { device.next_command_context.previous.next = nil }
        
    for device.next_command_context != nil {
        commands := device.next_command_context
        device.next_command_context = commands.next
        destroy_command_context(device, commands)
        free(commands, device.allocator)
    }
    delete(device.command_submit_infos)
    device.command_submit_infos = nil
    if device.device != nil && device.command_retirement != 0 { vk.DestroySemaphore(device.device, device.command_retirement, nil) }
    device.command_retirement = 0
    device.command_retirement_value = 0
    device.completed_command_retirement = 0
}

reset_command_context :: proc (device: ^_Device, commands: ^_CommandBuffer) {
    assert(commands.command_pool != 0 && commands.command_buffer != nil && commands.device == nil && commands.retire_value <= device.completed_command_retirement)
    assert_vk(vk.ResetCommandPool(device.device, commands.command_pool, nil))
    commands.retire_value = 0
}

drain_contexts :: proc (device: ^_Device) {
    wait_command_retirement(device, device.command_retirement_value)
    
    for &present in device.present_contexts {
        wait_present_context(device, &present)
    }
    
    for retired in device.retired_swapchains {
        assert(retired.handle == 0)
    }
    
    collect(&device.swapchain_delete_queue, device, device.command_retirement_value)
}

////////////////////////////////////////////////
// Command Retirement

next_command_retirement :: proc (device: ^_Device) -> u64 {
    next := device.command_retirement_value + 1
    if next - device.completed_command_retirement > device.max_timeline_value_difference {
        poll_command_retirement(device)
        if next - device.completed_command_retirement > device.max_timeline_value_difference {
            wait_command_retirement(device, next - device.max_timeline_value_difference)
        }
        assert(next - device.completed_command_retirement <= device.max_timeline_value_difference)
    }
    
    device.command_retirement_value = next
    return next
}

poll_command_retirement :: proc (device: ^_Device) {
    if device.command_retirement == 0 || device.completed_command_retirement == device.command_retirement_value {
        return
    }
    
    completed: u64
    assert_vk(vk.GetSemaphoreCounterValue(device.device, device.command_retirement, &completed))
    assert(completed >= device.completed_command_retirement && completed <= device.command_retirement_value)
    
    if completed == device.completed_command_retirement { return }
    device.completed_command_retirement = completed
    
    reset_retired_command_contexts(device)
    collect(&device.swapchain_delete_queue, device, device.completed_command_retirement)
}

wait_command_retirement :: proc (device: ^_Device, value: u64) {
    assert(value <= device.command_retirement_value)
    if value > device.completed_command_retirement {
        value := value
        assert_vk(vk.WaitSemaphores(device.device, &vk.SemaphoreWaitInfo {
            sType = .SEMAPHORE_WAIT_INFO,
            semaphoreCount = 1,
            pSemaphores    = &device.command_retirement,
            pValues        = &value,
        }, max(u64)))
        
        device.completed_command_retirement = value
    }
    reset_retired_command_contexts(device)
    collect(&device.swapchain_delete_queue, device, device.completed_command_retirement)
}

reset_retired_command_contexts :: proc (device: ^_Device) {
    if device.next_command_context == nil { return }
    
    commands := device.next_command_context
    for {
        
        if commands.retire_value != 0 && commands.retire_value <= device.completed_command_retirement {
            reset_command_context(device, commands)
        }
        commands = commands.next
        
        if commands == device.next_command_context { break }
    }
}

////////////////////////////////////////////////
// Conversions

to_vk :: proc { blend_to_vk, blend_factor_to_vk, load_to_vk, store_to_vk, format_to_vk, compare_to_vk, stencil_to_vk, stages_to_vk, access_to_vk, color_to_vk, index_to_vk, range_to_vk, texture_type_to_vk, filter_to_vk, address_mode_to_vk }

blend_factor_to_vk :: proc (factor: BlendFactor) -> vk.BlendFactor {
    switch factor {
    case .zero:                        return .ZERO
    case .one:                         return .ONE
    case .source_color:                return .SRC_COLOR
    case .one_minus_source_color:      return .ONE_MINUS_SRC_COLOR
    case .destination_color:           return .DST_COLOR
    case .one_minus_destination_color: return .ONE_MINUS_DST_COLOR
    case .source_alpha:                return .SRC_ALPHA
    case .one_minus_source_alpha:      return .ONE_MINUS_SRC_ALPHA
    case .destination_alpha:           return .DST_ALPHA
    case .one_minus_destination_alpha: return .ONE_MINUS_DST_ALPHA
    case .source_alpha_saturate:       return .SRC_ALPHA_SATURATE
    }
    unreachable()
}

blend_to_vk :: proc (op: BlendOp) -> vk.BlendOp {
    switch op {
    case .add:               return.ADD
    case .subtract:          return.SUBTRACT
    case .reverse_subtract:  return.REVERSE_SUBTRACT
    case .minimum:           return.MIN
    case .maximum:           return.MAX
    }
    unreachable()
}

compare_to_vk :: proc (op: CompareOp) -> vk.CompareOp {
    switch op {
    case .never:         return .NEVER
    case .less:          return .LESS
    case .equal:         return .EQUAL
    case .less_equal:    return .LESS_OR_EQUAL
    case .greater:       return .GREATER
    case .not_equal:     return .NOT_EQUAL
    case .greater_equal: return .GREATER_OR_EQUAL
    case .always:        return .ALWAYS
    }
    unreachable()
}

stencil_to_vk :: proc (op: StencilOp) -> vk.StencilOp {
    switch op {
    case .keep:            return .KEEP
    case .zero:            return .ZERO
    case .replace:         return .REPLACE
    case .increment_clamp: return .INCREMENT_AND_CLAMP
    case .decrement_clamp: return .DECREMENT_AND_CLAMP
    case .invert:          return .INVERT
    case .increment_wrap:  return .INCREMENT_AND_WRAP
    case .decrement_wrap:  return .DECREMENT_AND_WRAP
    }
    unreachable()
}
load_to_vk :: proc (op: LoadOp) -> vk.AttachmentLoadOp {
    switch op {
    case .load:    return .LOAD
    case .clear:   return .CLEAR
    case .discard: return .DONT_CARE
    }
    unreachable()
}

store_to_vk :: proc (op: StoreOp) -> vk.AttachmentStoreOp {
    switch op {
    case .store:   return .STORE
    case .discard: return .DONT_CARE
    }
    unreachable()
}

stages_to_vk :: proc (stage: Stages) -> vk.PipelineStageFlags2 {
    result: vk.PipelineStageFlags2
    if .indirect            in stage { result += { .DRAW_INDIRECT } }
    if .index_input         in stage { result += { .INDEX_INPUT } }
    if .vertex              in stage { result += { .VERTEX_SHADER } }
    if .task                in stage { result += { .TASK_SHADER_EXT } }
    if .mesh                in stage { result += { .MESH_SHADER_EXT } }
    if .depth_stencil_tests in stage { result += { .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS } }
    if .fragment            in stage { result += { .FRAGMENT_SHADER } }
    if .color_output        in stage { result += { .COLOR_ATTACHMENT_OUTPUT } }
    if .compute             in stage { result += { .COMPUTE_SHADER } }
    if .transfer            in stage { result += { .COPY} }
    if .host                in stage { result += { .HOST } }
    if .all_commands        in stage { result += { .ALL_COMMANDS } }
    #assert(len(Stage) == 12, "was modified")
    return result
}

access_to_vk :: proc (access: Access) -> vk.AccessFlags2 {
    result: vk.AccessFlags2
    if .transfer_read       in access { result += { .TRANSFER_READ } }
    if .transfer_write      in access { result += { .TRANSFER_WRITE } }
    if .shader_read         in access { result += { .SHADER_READ } }
    if .shader_write        in access { result += { .SHADER_WRITE } }
    if .color_read          in access { result += { .COLOR_ATTACHMENT_READ } }
    if .color_write         in access { result += { .COLOR_ATTACHMENT_WRITE } }
    if .depth_stencil_read  in access { result += { .DEPTH_STENCIL_ATTACHMENT_READ } }
    if .depth_stencil_write in access { result += { .DEPTH_STENCIL_ATTACHMENT_WRITE } }
    if .indirect_read       in access { result += { .INDIRECT_COMMAND_READ } }
    if .index_read          in access { result += { .INDEX_READ } }
    if .host_read           in access { result += { .HOST_READ } }
    if .descriptor_read     in access { result += { .DESCRIPTOR_BUFFER_READ_EXT } }
    #assert(len(AccessFlag) == 12, "was modified")
    return result
}
 
color_to_vk :: proc (mask: ColorMask) -> vk.ColorComponentFlags {
    result: vk.ColorComponentFlags
    if .r in mask { result += { .R } }
    if .g in mask { result += { .G } }
    if .b in mask { result += { .B } }
    if .a in mask { result += { .A } }
    return result
}

index_to_vk :: proc (type: IndexType) -> vk.IndexType {
    switch type {
    case .uint16: return .UINT16
    case .uint32: return .UINT32
    }
    unreachable()
}

filter_to_vk :: proc (filter: Filter) -> vk.Filter {
    switch filter {
    case .nearest: return .NEAREST
    case .linear:  return .LINEAR
    }
    unreachable()
}

address_mode_to_vk :: proc (mode: AddressMode) -> vk.SamplerAddressMode {
    switch mode {
    case .repeat: return .REPEAT
    case .mirrored_repeat: return .MIRRORED_REPEAT
    case .clamp_to_edge: return .CLAMP_TO_EDGE
    }
    unreachable()
}

range_to_vk :: proc (range: GpuRange) -> vk.DeviceAddressRangeKHR {
    result := vk.DeviceAddressRangeKHR {
        address = transmute(vk.DeviceAddress) range.gpu,
        size    = cast(vk.DeviceSize) range.size_in_bytes,
    }
    return result
}

texture_type_to_vk :: proc (type: TextureType) -> vk.ImageType {
    switch type {
    case .one_d:                                   return .D1
    case .two_d, .cube, .two_d_array, .cube_array: return .D2
    case .three_d:                                 return .D3
    }
    unreachable()
}
view_to_vk :: proc (type: TextureType) -> vk.ImageViewType {
    switch type {
    case .one_d:       return .D1
    case .two_d:       return .D2
    case .three_d:     return .D3
    case .cube:        return .CUBE
    case .two_d_array: return .D2_ARRAY
    case .cube_array:  return .CUBE_ARRAY
    }
    unreachable()
}

format_to_vk :: proc (format: Format) -> vk.Format {
    switch format {
    case .r8_srgb:           return .R8_SRGB
    case .rg8_srgb:          return .R8G8_SRGB
    case .rgba8_srgb:        return .R8G8B8A8_SRGB
    case .bgra8_srgb:        return .B8G8R8A8_SRGB
    case .rgba4_unorm:       return .R4G4B4A4_UNORM_PACK16
    case .r5g5b5a1_unorm:    return .R5G5B5A1_UNORM_PACK16
    case .r5g6b5_unorm:      return .R5G6B5_UNORM_PACK16
    case .r8_unorm:          return .R8_UNORM
    case .rg8_unorm:         return .R8G8_UNORM
    case .rgba8_unorm:       return .R8G8B8A8_UNORM
    case .bgra8_unorm:       return .B8G8R8A8_UNORM
    case .r16_unorm:         return .R16_UNORM
    case .rg16_unorm:        return .R16G16_UNORM
    case .rgba16_unorm:      return .R16G16B16A16_UNORM
    case .r8_uint:           return .R8_UINT
    case .rg8_uint:          return .R8G8_UINT
    case .rgba8_uint:        return .R8G8B8A8_UINT
    case .bgra8_uint:        return .B8G8R8A8_UINT
    case .r16_uint:          return .R16_UINT
    case .rg16_uint:         return .R16G16_UINT
    case .rgba16_uint:       return .R16G16B16A16_UINT
    case .r32_uint:          return .R32_UINT
    case .rg32_uint:         return .R32G32_UINT
    case .rgb32_uint:        return .R32G32B32_UINT
    case .rgba32_uint:       return .R32G32B32A32_UINT
    case .r16_float:         return .R16_SFLOAT
    case .rg16_float:        return .R16G16_SFLOAT
    case .rgba16_float:      return .R16G16B16A16_SFLOAT
    case .r32_float:         return .R32_SFLOAT
    case .rg32_float:        return .R32G32_SFLOAT
    case .rgb32_float:       return .R32G32B32_SFLOAT
    case .rgba32_float:      return .R32G32B32A32_SFLOAT
    case .rgb10a2_unorm:     return .A2B10G10R10_UNORM_PACK32
    case .rg11b10_float:     return .B10G11R11_UFLOAT_PACK32
    case .d16_unorm:         return .D16_UNORM
    case .d24_unorm_s8_uint: return .D24_UNORM_S8_UINT
    case .d32_float:         return .D32_SFLOAT
    case .s8_uint:           return .S8_UINT
    case .d32_float_s8_uint: return .D32_SFLOAT_S8_UINT
    case .eac_rg:            return .EAC_R11G11_UNORM_BLOCK
    case .astc_4x4_srgb:     return .ASTC_4x4_SRGB_BLOCK
    case .astc_4x4_unorm:    return .ASTC_4x4_UNORM_BLOCK
    case .bc3_srgb:          return .BC3_SRGB_BLOCK
    case .bc3_unorm:         return .BC3_UNORM_BLOCK
    case .bc5_rg:            return .BC5_UNORM_BLOCK
    case .bc6h_ufloat:       return .BC6H_UFLOAT_BLOCK
    case .bc6h_sfloat:       return .BC6H_SFLOAT_BLOCK
    case .bc7_srgb:          return .BC7_SRGB_BLOCK
    case .bc7_unorm:         return .BC7_UNORM_BLOCK
    case .undefined:         return .UNDEFINED
    }
    unreachable()
}

////////////////////////////////////////////////
// Miscellania

create_raster_pso :: proc (device: Device, task_spirv, first_stage_spirv, fragment_spriv: [] u32, color_targets: [] ColorTargetDesc, depth_format, stencil_format: Format, rasterization_state: RasterizationState, mesh: bool) -> PSO {
    assert(device != nil, "PSO creation called with a null device")
    assert(color_targets != nil && len(color_targets) <= max_color_attachments, "color targets must fit the wrappers's attachment array")
    
    stages := [?] vk.PipelineShaderStageCreateInfo {
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            pNext = &vk.ShaderModuleCreateInfo {
                sType = .SHADER_MODULE_CREATE_INFO,
                codeSize = len(task_spirv) * size_of(u32),
                pCode    = raw_data(task_spirv),
            },
            stage = { .TASK_EXT },
            pName = "taskMain",
        },
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            pNext = &vk.ShaderModuleCreateInfo {
                sType = .SHADER_MODULE_CREATE_INFO,
                codeSize = len(first_stage_spirv) * size_of(u32),
                pCode    = raw_data(first_stage_spirv),
            },
            stage = mesh ? { .MESH_EXT } : { .VERTEX },
            pName = mesh ? "meshMain" : "vertexMain",
        },
        {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            pNext = &vk.ShaderModuleCreateInfo {
                sType = .SHADER_MODULE_CREATE_INFO,
                codeSize = len(fragment_spriv) * size_of(u32),
                pCode    = raw_data(fragment_spriv),
            },
            stage = { .FRAGMENT },
            pName = "fragmentMain",
        },
    }
    
    color_formats: [dynamic; max_color_attachments] vk.Format
    for target in color_targets {
        append(&color_formats, to_vk(target.format))
    }
    
    color_attachments: [dynamic; max_color_attachments] vk.PipelineColorBlendAttachmentState
    for target in color_targets {
        append(&color_attachments, vk.PipelineColorBlendAttachmentState {
            blendEnable = cast(b32) target.blend.enabled,
            srcColorBlendFactor = to_vk(target.blend.color.source),
            dstColorBlendFactor = to_vk(target.blend.color.destination),
            colorBlendOp        = to_vk(target.blend.color.operation),
            srcAlphaBlendFactor = to_vk(target.blend.alpha.source),
            dstAlphaBlendFactor = to_vk(target.blend.alpha.destination),
            alphaBlendOp        = to_vk(target.blend.alpha.operation),
            colorWriteMask      = to_vk(target.write_mask),
        })
    }
    
    dynamic_states := [?] vk.DynamicState {
        .VIEWPORT_WITH_COUNT,
        .SCISSOR_WITH_COUNT,
        .DEPTH_TEST_ENABLE,
        .DEPTH_WRITE_ENABLE,
        .DEPTH_COMPARE_OP,
        .STENCIL_TEST_ENABLE,
        .STENCIL_OP,
        .STENCIL_COMPARE_MASK,
        .STENCIL_WRITE_MASK,
        .STENCIL_REFERENCE,
    }
    
    result := new(_PSO, device.allocator)
    result^ = { device = device, bind_point = .GRAPHICS }
    require_vk(vk.CreateGraphicsPipelines(device.device, 0, 1, &vk.GraphicsPipelineCreateInfo {
        sType = .GRAPHICS_PIPELINE_CREATE_INFO,
        pNext = &vk.PipelineCreateFlags2CreateInfo {
            sType = .PIPELINE_CREATE_FLAGS_2_CREATE_INFO,
            pNext = &vk.PipelineRenderingCreateInfo {
                sType = .PIPELINE_RENDERING_CREATE_INFO,
                colorAttachmentCount    = cast(u32) len(color_targets),
                pColorAttachmentFormats = len(color_targets) != 0 ? raw_data(&color_formats) : nil,
                depthAttachmentFormat   = to_vk(depth_format),
                stencilAttachmentFormat = to_vk(stencil_format),
            },
            flags = { .DESCRIPTOR_HEAP_EXT },
        },
        stageCount = 1 + (task_spirv != nil ? 1 : 0) + (fragment_spriv != nil ? 1 : 0),
        pStages    = &stages[task_spirv != nil ? 0 : 1],
        pVertexInputState   = mesh ? nil : &vk.PipelineVertexInputStateCreateInfo { sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO },
        pInputAssemblyState = mesh ? nil : &vk.PipelineInputAssemblyStateCreateInfo {
            sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            topology = .TRIANGLE_LIST,
        },
        pViewportState = &vk.PipelineViewportStateCreateInfo { sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO },
        pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
            sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            polygonMode             = .FILL,
            cullMode                = rasterization_state.cull == .none ? {} : { .BACK },
            frontFace               = rasterization_state.cull == .counter_clockwise ? .CLOCKWISE : .COUNTER_CLOCKWISE,
            depthBiasEnable         = rasterization_state.depth_bias_constant != 0 || rasterization_state.depth_bias_clamp != 0 || rasterization_state.depth_bias_slope != 0,
            depthBiasConstantFactor = rasterization_state.depth_bias_constant,
            depthBiasClamp          = rasterization_state.depth_bias_clamp,
            depthBiasSlopeFactor    = rasterization_state.depth_bias_slope,
            lineWidth               = 1,
        },
        pMultisampleState = &vk.PipelineMultisampleStateCreateInfo {
            sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            rasterizationSamples = { ._1 },
        },
        pDepthStencilState = &vk.PipelineDepthStencilStateCreateInfo { sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO },
        pColorBlendState = &vk.PipelineColorBlendStateCreateInfo {
            sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            attachmentCount = cast(u32) len(color_targets),
            pAttachments    = len(color_targets) != 0 ? raw_data(&color_attachments) : nil,
        },
        pDynamicState = &vk.PipelineDynamicStateCreateInfo {
            sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            dynamicStateCount = cast(u32) len(dynamic_states),
            pDynamicStates    = raw_data(&dynamic_states),
        },
        basePipelineIndex = -1,
    }, nil, &result.pso))
    
    return result
}

record_image_barriers :: proc (command_buffer: vk.CommandBuffer, barriers: ..vk.ImageMemoryBarrier2) {
    assert(command_buffer != nil && len(barriers) != 0, "image barrier batch is invalid")
    vk.CmdPipelineBarrier2(command_buffer, &vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        imageMemoryBarrierCount = cast(u32) len(barriers),
        pImageMemoryBarriers    = raw_data(barriers),
    })
}

submit_commands :: proc (commands: [] ^_CommandBuffer, device: ^_Device, completion: TimelinePoint, wait_semaphore: vk.Semaphore, signal_semaphore: vk.Semaphore) {
    completion_semaphore := completion.semaphore
    assert(completion_semaphore != nil && completion_semaphore.device == device && completion_semaphore.semaphore != 0, "submission completion requires a live timeline semaphore owned by the device")
    assert(commands != nil)
    assert(device.active_command_buffers == cast(u32) len(commands), #procedure + " must consume every begun command buffer")
    assert(device.pending_texture_initializations.next == &device.pending_texture_initializations, "pending texture transitions were not recorded")
    
    assert(len(device.command_submit_infos) >= len(commands))
    clear(&device.command_submit_infos)
    
    for current in commands {
        assert(current != nil && current.device == device, "command buffer batch contains invalid handle")
        for address, timestamp in current.timestamp_destinations {
            device.fn.CmdCopyQueryPoolResultsToMemory(current.command_buffer, current.timestamp_pool, cast(u32) timestamp, 1, &vk.StridedDeviceAddressRangeKHR { address = address, size = size_of(u64), stride = size_of(u64) }, address_flags, { ._64, .WAIT })
        }
        
        if len(current.timestamp_destinations) != 0 {
            barrier(current, { .transfer }, { .transfer_write }, { .host }, { .host_read })
        }
        assert_vk(vk.EndCommandBuffer(current.command_buffer))
        
        current.device = nil
        assert(device.active_command_buffers != 0)
        device.active_command_buffers -= 1
        
        append(&device.command_submit_infos, vk.CommandBufferSubmitInfo {
            sType = .COMMAND_BUFFER_SUBMIT_INFO,
            commandBuffer = current.command_buffer,
            deviceMask = 1,
        })
    }
    assert(device.active_command_buffers == 0)
    
    retirement := next_command_retirement(device)
    wait_info := vk.SemaphoreSubmitInfo {
        sType = .SEMAPHORE_SUBMIT_INFO,
        semaphore = wait_semaphore,
        stageMask = { .ALL_COMMANDS },
    }
    work_signal_infos := [?] vk.SemaphoreSubmitInfo {
        {
            sType = .SEMAPHORE_SUBMIT_INFO,
            semaphore = completion_semaphore.semaphore,
            value     = completion.value,
            stageMask = { .ALL_COMMANDS },
        },
        {
            sType = .SEMAPHORE_SUBMIT_INFO,
            semaphore = signal_semaphore,
            stageMask = { .ALL_COMMANDS },
        },
    }
    retirement_signal_info := vk.SemaphoreSubmitInfo {
        sType = .SEMAPHORE_SUBMIT_INFO,
        semaphore = device.command_retirement,
        value     = retirement,
        stageMask = { .ALL_COMMANDS },
    }
    submit_infos := [?] vk.SubmitInfo2 {
        {
            sType = .SUBMIT_INFO_2,
            waitSemaphoreInfoCount = wait_semaphore != 0 ? 1 : 0,
            pWaitSemaphoreInfos = wait_semaphore != 0 ? &wait_info : nil,
            commandBufferInfoCount = cast(u32) len(commands),
            pCommandBufferInfos = raw_data(device.command_submit_infos),
            signalSemaphoreInfoCount = signal_semaphore != 0 ? 2 : 1,
            pSignalSemaphoreInfos = raw_data(&work_signal_infos),
        },
        {
            sType = .SUBMIT_INFO_2,
            signalSemaphoreInfoCount = 1,
            pSignalSemaphoreInfos = &retirement_signal_info,
        },
    }
    assert_vk(vk.QueueSubmit2(device.queue, 2, raw_data(&submit_infos), 0))
    
    for &current in commands {
        current.retire_value = retirement
        current.swapchain = nil
    }
}

emit_root_data :: proc (commands: ^_CommandBuffer, root: [] u8, loc := #caller_location) {
    if root == nil { return }
    
    assert(len(root) <= 256, loc = loc)
    assert(commands.device != nil)
    
    commands.device.fn.CmdPushData(commands.command_buffer, &vk.PushDataInfoEXT {
        sType = .PUSH_DATA_INFO_EXT,
        data = {
            address = raw_data(root),
            size    = len(root),
        },
    })
}

allocate_gpu_heap :: proc (device: ^_Device, #any_int size: vk.DeviceSize, memory_type: MemoryType) -> GpuHeap {
    if memory_type == .texture_descriptor_heap || memory_type == .sampler_descriptor_heap {
        return allocate_descriptor_heap(device, size, memory_type)
    }
    
    required, preferred, avoided: vk.MemoryPropertyFlags
    switch memory_type {
    case .texture_descriptor_heap, .sampler_descriptor_heap: unreachable()
    
    case .cpu_visible:
        required = cpu_visible_memory_properties
        
    case .gpu_only:
        required = { .DEVICE_LOCAL }
        avoided  = { .HOST_VISIBLE }
        
    case .readback:
        required = cpu_visible_memory_properties
        preferred = { .HOST_CACHED }
    }
    
    heap := new(_GpuHeapOwner, device.allocator)
    heap.device  = device
    heap.backing = create_backing_buffer(device, size, universal_buffer_usage, required, preferred, avoided)
    
    result := GpuHeap {
        range = {
            cpu           = slice.from_ptr(cast(^u8) heap.backing.mapped, cast(int) size),
            gpu           = transmute([^] u8) heap.backing.address,
            size_in_bytes = cast(u64) size,
        },
        owner = heap,
    }
    return result
}

create_backing_buffer :: proc (device: ^_Device, size: vk.DeviceSize, usage: vk.BufferUsageFlags, required, preferred: vk.MemoryPropertyFlags, avoided: vk.MemoryPropertyFlags = {}) -> BackingBuffer {
    result: BackingBuffer
    require_vk(vk.CreateBuffer(device.device, &vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        size        = size,
        usage       = usage,
        sharingMode = .EXCLUSIVE,
    }, nil, &result.buffer))
    
    requirements: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(device.device, result.buffer, &requirements)
    
    memory_type, has_memory_type := find_memory_type(device, requirements.memoryTypeBits, required, preferred, requirements.size, avoided)
    assert(has_memory_type)
    if !has_memory_type { require_error(.unsupported) }
    
    require_vk(vk.AllocateMemory(device.device, &vk.MemoryAllocateInfo {
        sType = .MEMORY_ALLOCATE_INFO,
        pNext = &vk.MemoryAllocateFlagsInfo {
            sType = .MEMORY_ALLOCATE_FLAGS_INFO,
            flags = { .DEVICE_ADDRESS },
        },
        allocationSize  = requirements.size,
        memoryTypeIndex = memory_type,
    }, nil, &result.memory))
    require_vk(vk.BindBufferMemory(device.device, result.buffer, result.memory, 0))
    
    if .HOST_VISIBLE in required {
        require_vk(vk.MapMemory(device.device, result.memory, 0, auto_cast vk.WHOLE_SIZE, {}, &result.mapped))
    }
    
    result.address = vk.GetBufferDeviceAddress(device.device, &vk.BufferDeviceAddressInfo {
        sType = .BUFFER_DEVICE_ADDRESS_INFO,
        buffer = result.buffer,
    })
    return result
}

find_memory_type :: proc (device: ^_Device, bits: u32, required, preferred: vk.MemoryPropertyFlags, minimum_heap_size: vk.DeviceSize, avoided: vk.MemoryPropertyFlags = {}) -> (u32, bool) {
    has_best := false
    best_is_avoided := false
    best: u32
    best_score: u32
    best_heap_size: vk.DeviceSize
    
    bitset := transmute(bit_set[cast(u32) 0..<32; u32]) bits
    for i in 0..<device.memory_properties.memoryTypeCount {
        assert((i not_in bitset) == (bits & (1 << i) == 0))
        if (bits & (1 << i)) == 0 { continue }
        if i not_in bitset { continue }
        
        flags := device.memory_properties.memoryTypes[i].propertyFlags
        
        if (flags & required) != required { continue }
        if !is_usable_memory_type(&device.memory_properties, i) { continue }
        
        heap := device.memory_properties.memoryHeaps[device.memory_properties.memoryTypes[i].heapIndex]
        if heap.size < minimum_heap_size { continue }
        
        
        is_avoided := (flags & avoided) != {}
        score := transmute(u32) intrinsics.count_ones(flags & preferred)
        if !has_best || (best_is_avoided && !is_avoided) || (best_is_avoided == is_avoided && (score > best_score || (score == best_score && heap.size > best_heap_size))) {
            best = i
            has_best = true
            best_is_avoided = is_avoided
            best_score = score
            best_heap_size = heap.size
        }
    }
    
    return best, has_best
}

is_usable_memory_type :: proc (properties: ^vk.PhysicalDeviceMemoryProperties, index: u32) -> bool {
    type := &properties.memoryTypes[index]
    if type.propertyFlags & forbidden_memory_properties != {} { return false }
    result := .TILE_MEMORY_QCOM not_in properties.memoryHeaps[type.heapIndex].flags
    return result
}

make_heap_bind_info :: proc (heap: GpuRange, reserved_alignment, reserved_size: vk.DeviceSize) -> vk.BindHeapInfoEXT {
    reserved_offset := align_up(cast(vk.DeviceSize) heap.size_in_bytes, reserved_alignment)
    
    result := vk.BindHeapInfoEXT {
        sType = .BIND_HEAP_INFO_EXT,
        heapRange = {
            address = transmute(vk.DeviceAddress) heap.gpu,
            size    = reserved_offset + reserved_size,
        },
        reservedRangeOffset = reserved_offset,
        reservedRangeSize   = reserved_size,
    }
    
    return result
}

align_up :: proc (value: $T, alignment: T) -> T {
    assert(alignment != 0)
    result := ((value + alignment - 1) / alignment) * alignment
    return result
}

make_texture_copy_region :: proc (texture: ^_Texture, copy: TextureCopyDesc, memory: GpuRange) -> vk.DeviceMemoryImageCopyKHR {
    mip_width  := max(texture.width  >> copy.mip_level, 1)
    mip_height := max(texture.height >> copy.mip_level, 1)
    mip_depth  := max(texture.depth  >> copy.mip_level, 1)
    
    width  := copy.extent.x == 0 ? mip_width  - copy.offset.x : copy.extent.x
    height := copy.extent.y == 0 ? mip_height - copy.offset.y : copy.extent.y
    depth  := copy.extent.z == 0 ? mip_depth  - copy.offset.z : copy.extent.z
    
    divide_up :: proc (value, divisor: u32) -> u32 {
        assert(divisor != 0)
        result := value / divisor + (value % divisor != 0 ? 1 : 0)
        return result
    }
    
    format_info := get_texture_format_info(texture.format)
    row_pitch := copy.row_pitch_bytes == 0 ? cast(u64) divide_up(width, format_info.block_extent.x) * cast(u64) format_info.bytes_per_block : copy.row_pitch_bytes
    assert(copy.slice_pitch_bytes == 0 || row_pitch != 0, "slice pitch conversion requires a non-zero row pitch")
    
    result := vk.DeviceMemoryImageCopyKHR {
        sType = .DEVICE_MEMORY_IMAGE_COPY_KHR,
        addressRange       = to_vk(memory),
        addressFlags       = address_flags,
        addressRowLength   = cast(u32) (copy.row_pitch_bytes / cast(u64) format_info.bytes_per_block * cast(u64) format_info.block_extent.x),
        addressImageHeight = copy.slice_pitch_bytes                                                                                          == 0 ? 0 : cast(u32) (copy.slice_pitch_bytes / row_pitch * cast(u64) format_info.block_extent.x),
        imageSubresource = {
            aspectMask     = image_aspects(texture.format),
            mipLevel       = copy.mip_level,
            baseArrayLayer = copy.base_slice,
            layerCount     = copy.slice_count              == 0 ? texture.layer_count - copy.base_slice : copy.slice_count,
        },
        imageLayout = .GENERAL,
        imageOffset = { ** cast([3] i32) copy.offset },
        imageExtent = { width = width, height = height, depth = depth },
    }
    
    return result
}

image_aspects :: proc (format: Format) -> vk.ImageAspectFlags {
    result: vk.ImageAspectFlags
    format_info := get_texture_format_info(format)
    
    if format_info.depth   { result += { .DEPTH   } }
    if format_info.stencil { result += { .STENCIL } }
    if result == {}        { result  = { .COLOR   } }
    
    return result
}

image_memory_requirements :: proc (device: ^_Device, image_info: vk.ImageCreateInfo) -> vk.MemoryRequirements {
    image_info := image_info
    
    requirements := vk.MemoryRequirements2 { sType = .MEMORY_REQUIREMENTS_2 }
    vk.GetDeviceImageMemoryRequirements(device.device, &vk.DeviceImageMemoryRequirements {
        sType = .DEVICE_IMAGE_MEMORY_REQUIREMENTS,
        pCreateInfo = &image_info,
    }, &requirements)
    
    return requirements.memoryRequirements
}

required_format_features :: proc (usage: TextureUsage) -> vk.FormatFeatureFlags2 {
    result: vk.FormatFeatureFlags2
    
    if .sampled                  in usage { result += { .SAMPLED_IMAGE } }
    if .storage                  in usage { result += { .STORAGE_IMAGE, .STORAGE_READ_WITHOUT_FORMAT, .STORAGE_WRITE_WITHOUT_FORMAT } }
    if .color_attachment         in usage { result += { .COLOR_ATTACHMENT } }
    if .depth_stencil_attachment in usage { result += { .DEPTH_STENCIL_ATTACHMENT } }
    if .transfer_source          in usage { result += { .TRANSFER_SRC } }
    if .transfer_destination     in usage { result += { .TRANSFER_DST } }
    
    return result
}

prepare_texture :: proc (device: ^_Device, desc: TextureDesc, result: ^PreparedTexture) {
    result^ = {}
    
    usage: vk.ImageUsageFlags
    if .sampled                  in desc.usage { usage += { .SAMPLED } }
    if .storage                  in desc.usage { usage += { .STORAGE } }
    if .color_attachment         in desc.usage { usage += { .COLOR_ATTACHMENT } }
    if .depth_stencil_attachment in desc.usage { usage += { .DEPTH_STENCIL_ATTACHMENT } }
    if .transfer_source          in desc.usage { usage += { .TRANSFER_SRC } }
    if .transfer_destination     in desc.usage { usage += { .TRANSFER_DST } }
    
    format := to_vk(desc.format)
    sampled_features := required_format_features({ .sampled })
    storage_features := required_format_features({ .storage })
    
    view_format_count: u32 = 1
    result.view_formats[0] = format
    
    compatible_view_formats :: proc (image_format, view_format: Format) -> bool {
        if image_format == view_format { return true }
        
        image := get_texture_format_info(image_format)
        view  := get_texture_format_info(view_format)
        if image.depth || image.stencil || view.depth || view.stencil { return false }
        
        if image.block_extent.x == 1 && view.block_extent.x == 1 {
            return image.bytes_per_block != 0 && image.bytes_per_block == view.bytes_per_block
        }
        
        result :=   (image_format == .astc_4x4_unorm && view_format == .astc_4x4_srgb) ||
                    (image_format == .astc_4x4_srgb  && view_format == .astc_4x4_unorm) ||
                    (image_format == .bc3_unorm      && view_format == .bc3_srgb) ||
                    (image_format == .bc3_srgb       && view_format == .bc3_unorm) ||
                    (image_format == .bc6h_ufloat    && view_format == .bc6h_sfloat) ||
                    (image_format == .bc6h_sfloat    && view_format == .bc6h_ufloat) ||
                    (image_format == .bc7_unorm      && view_format == .bc7_srgb) ||
                    (image_format == .bc7_srgb       && view_format == .bc7_unorm)
        return result
    }
    
    for view_format: Format; desc.mutable_format && cast(int) view_format < len(Format); view_format += cast(Format) 1 {
        if view_format == desc.format || !compatible_view_formats(desc.format, view_format) {
            continue
        }
        
        view_features := device.format_features[view_format]
        sampled := .sampled in desc.usage && (view_features & sampled_features) == sampled_features
        storage := .storage in desc.usage && (view_features & storage_features) == storage_features
        if !sampled && !storage { continue }
        
        result.view_formats[view_format_count] = to_vk(view_format)
        view_format_count += 1
    }
    
    image_flags: vk.ImageCreateFlags
    if desc.type == .cube || desc.type == .cube_array { image_flags += { .CUBE_COMPATIBLE } }
    if view_format_count > 1                          { image_flags += { .MUTABLE_FORMAT  } }
    
    result.format_list = {
        sType = .IMAGE_FORMAT_LIST_CREATE_INFO,
        viewFormatCount = view_format_count,
        pViewFormats    = raw_data(&result.view_formats),
    }
    result.image_info = {
        sType = .IMAGE_CREATE_INFO,
        pNext = view_format_count > 1 ? &result.format_list : nil,
        flags         = image_flags,
        imageType     = to_vk(desc.type),
        format        = format,
        extent        = { ** desc.extent },
        mipLevels     = desc.mip_levels,
        arrayLayers   = desc.layer_count,
        samples       = { ._1 },
        tiling        = .OPTIMAL,
        usage         = usage,
        sharingMode   = .EXCLUSIVE,
        initialLayout = .UNDEFINED,
    }
}

allocate_descriptor_heap :: proc (device: ^_Device, size: vk.DeviceSize, memory: MemoryType) -> GpuHeap {
    assert(memory == .texture_descriptor_heap || memory == .sampler_descriptor_heap)
    
    properties   := device.heap_properties
    texture_heap := memory == .texture_descriptor_heap
    
    resource_alignment := max(properties.imageDescriptorAlignment, properties.bufferDescriptorAlignment)
    reserved_alignment := texture_heap ? resource_alignment : properties.samplerDescriptorAlignment
    heap_alignment     := texture_heap ? properties.resourceHeapAlignment : properties.samplerHeapAlignment
    reserved_size      := texture_heap ? properties.minResourceHeapReservedRange : properties.minSamplerHeapReservedRange
    
    reserved_offset      := align_up(size, reserved_alignment)
    bind_size            := reserved_offset + reserved_size
    allocation_alignment := max(heap_alignment, gpu_allocation_alignment)
    alignment_padding    := allocation_alignment - 1
    backing_size         := bind_size + alignment_padding
    
    heap := new(_GpuHeapOwner, device.allocator)
    heap.device = device
    heap.backing = create_backing_buffer(device, backing_size, universal_buffer_usage + { .DESCRIPTOR_HEAP_EXT }, cpu_visible_memory_properties, {})
    
    gpu_address := align_up(heap.backing.address, cast(vk.DeviceAddress) allocation_alignment)
    allocation_offset := gpu_address - heap.backing.address
    
    result := GpuHeap {
        range = {
            cpu           = slice.from_ptr(cast(^u8) heap.backing.mapped, cast(int) size)[allocation_offset:],
            gpu           = transmute([^] u8) heap.backing.address,
            size_in_bytes = cast(u64) size,
        },
        owner = heap,
    }
    return result
}

// @todo inline?
query_timeline_value :: proc (semaphore: ^_TimelineSemaphore) -> u64 {
    value: u64
    assert_vk(vk.GetSemaphoreCounterValue(semaphore.device.device, semaphore.semaphore, &value))
    return value
}

////////////////////////////////////////////////
// Error handling

error_from_vk :: proc (result: vk.Result) -> Error {
    #partial switch result {
    case .SUCCESS: return .none
    case .ERROR_OUT_OF_HOST_MEMORY, .ERROR_OUT_OF_DEVICE_MEMORY, .ERROR_TOO_MANY_OBJECTS: panic("out of memory")
    case .ERROR_DEVICE_LOST: return .device_lost
    case .ERROR_LAYER_NOT_PRESENT, .ERROR_EXTENSION_NOT_PRESENT, .ERROR_FEATURE_NOT_PRESENT, .ERROR_INCOMPATIBLE_DRIVER, .ERROR_FORMAT_NOT_SUPPORTED:
        return .unsupported
    case: return.driver_error
    }
    unreachable()
}

require_vk :: proc (result: vk.Result) {
    if result == .SUCCESS { return }
    
    panic("unexpected Vulkan failure")
}

abort_vk :: proc (result: vk.Result) -> ! {
    assert(result == .SUCCESS, "unexpected Vulkan failure")
    runtime.exit(1)
}

require_error :: proc (error: Error) {
    if error == .none { return }
    
    panic("unexpected graphics API failure")
}

assert_vk :: proc (result: vk.Result) {
    assert(result == .SUCCESS, "unexpected Vulkan failure")
}