#+vet explicit-allocators !unused-procedures
package gpu

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:dynlib"
import win "core:sys/windows"
import vk "vendor:vulkan"

Validation     :: true
SyncValidation :: true

u32x2 :: [2] u32
u32x3 :: [3] u32

Device            :: ^_Device
Texture           :: ^_Texture
RenderView        :: ^_RenderView
PSO               :: ^_PSO
CommandBuffer     :: ^_CommandBuffer
TimelineSemaphore :: ^_TimelineSemaphore
GpuHeapOwner      :: ^_GpuHeapOwner
TextureHeapOwner  :: ^_TextureHeapOwner

////////////////////////////////////////////////

Error :: enum u8 {
    none,
    unsupported,
    device_lost,
    driver_error,
}

MemoryType :: enum u8 {
    cpu_visible,
    gpu_only,
    readback,
    texture_descriptor_heap,
    sampler_descriptor_heap,
}

GpuRange :: struct {
    gpu:           rawptr,
    size_in_bytes: u64,
}

GpuCpuRange :: struct ($T: typeid) {
    cpu: []  T,
    gpu: [^] T,
    size_in_bytes: u64,
}

GpuHeap :: struct {
    range: GpuCpuRange(u8),
    owner: GpuHeapOwner,
}

TextureHeap :: struct {
    size_in_bytes:  u64,
    owner: TextureHeapOwner,
}

TimelinePoint :: struct {
    semaphore: TimelineSemaphore,
    value:     u64,
}

Format :: enum u8 {
    r8_srgb,
    rg8_srgb,
    rgba8_srgb,
    bgra8_srgb,

    rgba4_unorm,
    r5g5b5a1_unorm,
    r5g6b5_unorm,

    r8_unorm,
    rg8_unorm,
    rgba8_unorm,
    bgra8_unorm,
    r16_unorm,
    rg16_unorm,
    rgba16_unorm,

    r8_uint,
    rg8_uint,
    rgba8_uint,
    bgra8_uint,
    r16_uint,
    rg16_uint,
    rgba16_uint,
    r32_uint,
    rg32_uint,
    rgb32_uint,
    rgba32_uint,

    r16_float,
    rg16_float,
    rgba16_float,
    r32_float,
    rg32_float,
    rgb32_float,
    rgba32_float,

    rgb10a2_unorm,
    rg11b10_float,

    d16_unorm,
    d24_unorm_s8_uint,
    d32_float,
    s8_uint,
    d32_float_s8_uint,

    eac_rg,
    astc_4x4_srgb,
    astc_4x4_unorm,
    bc3_srgb,
    bc3_unorm,
    bc5_rg,
    bc6h_ufloat,
    bc6h_sfloat,
    bc7_srgb,
    bc7_unorm,

    undefined, // Must remain last; preceding values are concrete texture formats.
}

TextureFormatInfo :: struct {
    block_extent:    u32x2,
    bytes_per_block: u32,
    depth:   bool,
    stencil: bool,
}

TextureType :: enum u8 {
    one_d,
    two_d,
    three_d,
    cube,
    two_d_array,
    cube_array,
}

TextureUsage :: bit_set[TextureUsageFlag; u32]
TextureUsageFlag :: enum u8 {
    sampled,
    storage,
    color_attachment,
    depth_stencil_attachment,
    transfer_source,
    transfer_destination,
}

TextureDescriptorType :: enum u8 {
    sampled,
    storage,
}

TextureAspect :: enum u8 {
    automatic,
    color,
    depth,
    stencil,
}

Filter :: enum u8 {
    nearest,
    linear,
}

AddressMode :: enum u8 {
    repeat,
    mirrored_repeat,
    clamp_to_edge,
}

CompareOp :: enum u8 {
    never,
    less,
    equal,
    less_equal,
    greater,
    not_equal,
    greater_equal,
    always,
}

CullMode :: enum u8 {
    none,
    clockwise,
    counter_clockwise,
}

BlendFactor :: enum u8 {
    zero,
    one,
    source_color,
    one_minus_source_color,
    destination_color,
    one_minus_destination_color,
    source_alpha,
    one_minus_source_alpha,
    destination_alpha,
    one_minus_destination_alpha,
    source_alpha_saturate,
}

BlendOp :: enum u8 {
    add,
    subtract,
    reverse_subtract,
    minimum,
    maximum,
}

IndexType :: enum u8 {
    uint16,
    uint32,
}

LoadOp :: enum u8 {
    load,
    clear,
    discard,
}

StoreOp :: enum u8 {
    store,
    discard,
}

StencilOp :: enum u8 {
    keep,
    zero,
    replace,
    increment_clamp,
    decrement_clamp,
    invert,
    increment_wrap,
    decrement_wrap,
}

// Ordered by Vulkan's logical execution order where stages are comparable.
// A barrier's before execution scope includes the selected and logically earlier
// stages; its after execution scope includes the selected and logically later
// stages. Vertex and task/mesh are alternative graphics branches, depth_stencil_tests
// spans early and late tests around fragment, compute and transfer are separate
// pipelines, host is a pseudo-stage, and none/all_commands are special masks.
Stages :: bit_set[Stage; u64]
Stage :: enum u64 {
    indirect            = 0,
    index_input         = 1,
    vertex              = 2,
    task                = 3,
    mesh                = 4,
    depth_stencil_tests = 5,
    fragment            = 6,
    color_output        = 7,
    compute             = 8,
    transfer            = 9,
    host                = 10, // Barrier destination only, paired with host_read.
    all_commands        = 11, // All GPU command stages; excludes host.
}

Access :: bit_set[AccessFlag; u64]
AccessFlag :: enum u64 {
    transfer_read       = 0,
    transfer_write      = 1,
    shader_read         = 2,
    shader_write        = 3,
    color_read          = 4,
    color_write         = 5,
    depth_stencil_read  = 6,
    depth_stencil_write = 7,
    indirect_read       = 8,
    index_read          = 9,
    host_read           = 10,
    descriptor_read     = 11,
}

DeviceCaps :: struct {
    device_name: string,
    max_push_data_size: u64,
    // Common element size for suballocating TextureHeap storage; every SizeAlign::align divides this value.
    texture_heap_alignment:           u64,
    texture_descriptor_size_in_bytes: u64,
    sampler_descriptor_size_in_bytes: u64,
    timestamp_period_in_ns:   f32,
    sub_texel_precision_bits: u32,  // Fractional filtering precision, for conservative sampled-field bounds.
    texture_compression_bc:   bool,
    texture_compression_astc: bool,
    storage_input_output16:   bool,
}

SwapchainFrame :: struct {
    render_view: RenderView,
    extent:      u32x2,
}

TextureDesc :: struct {
    type:           TextureType,
    extent:         u32x3,
    mip_levels:     u32,
    layer_count:    u32, // Vulkan array layers; cube faces are individual layers.
    format:         Format,
    mutable_format: bool, // Allow format-compatible descriptor views, but could lose DCC.
    usage:          TextureUsage,
}

texture_desc :: proc (
    type:           TextureType = .two_d,
    extent:         u32x3 = {1,1,1},
    mip_levels:     u32 = 1,
    layer_count:    u32 = 1,
    format:         Format = .rgba8_unorm,
    mutable_format: bool = false,
    usage:          TextureUsage = { .sampled },
) -> TextureDesc { return { type, extent, mip_levels, layer_count, format, mutable_format, usage } }

TextureCopyDesc :: struct {
    mip_level:         u32,
    base_slice:        u32,   // Physical array slice; cube faces are individual slices.
    slice_count:       u32,   // Zero selects every remaining physical slice.
    offset:            u32x3,
    extent:            u32x3, // Zero components select the remaining mip extent.
    row_pitch_bytes:   u64,   // Zero is tightly packed.
    slice_pitch_bytes: u64,   // Zero is tightly packed.
}

BlendComponentState :: struct {
    source:      BlendFactor,
    destination: BlendFactor,
    operation:   BlendOp,
}

blend_component_state :: proc (source: BlendFactor = .one, destination: BlendFactor = .zero, operation: BlendOp = .add) -> BlendComponentState {
    return { source, destination, operation }
}

BlendState :: struct {
    enabled: bool,
    color:   BlendComponentState,
    alpha:   BlendComponentState,
}

blend_state :: proc (enabled: bool = false, color: BlendComponentState = { .one, .zero, .add }, alpha: BlendComponentState = { .one, .zero, .add }) -> BlendState {
    return { enabled, color, alpha }
}

// @naming
ColorMask :: bit_set[enum u8 {
	r = 0,
	g = 1,
	b = 2,
	a = 3,
}; u8]

ColorTargetDesc :: struct {
    format:     Format,
    blend:      BlendState,
    write_mask: ColorMask,
}

color_target_desc :: proc (format: Format = .undefined, blend: BlendState = { enabled = false,  color = { .one, .zero, .add }, alpha = { .one, .zero, .add }}, write_mask: ColorMask = { .r, .g, .b, .a }) -> ColorTargetDesc {
    return { format, blend, write_mask }
}

RasterizationState :: struct {
    cull: CullMode,
    depth_bias_constant: f32,
    depth_bias_clamp:    f32,
    depth_bias_slope:    f32,
}

StencilFaceState :: struct {
    compare:    CompareOp,
    fail:       StencilOp,
    pass:       StencilOp,
    depth_fail: StencilOp,
    reference:  u8,
}

stencil_face_state :: proc (compare: CompareOp = .always, fail: StencilOp = .keep, pass: StencilOp = .keep, depth_fail: StencilOp = .keep, reference: u8 = 0) -> StencilFaceState {
    return { compare, fail, pass, depth_fail, reference }
}

ColorAttachment :: struct {
    render_view: RenderView,
    load:        LoadOp,
    store:       StoreOp,
    clear:       [4] f32,
}

color_attachment :: proc (render_view: RenderView = nil, load: LoadOp = .load, store: StoreOp = .store, clear: [4] f32 = {0,0,0,1}) -> ColorAttachment {
    return { render_view, load, store, clear }
} 

DepthAttachment :: struct {
    render_view: RenderView,
    load:  LoadOp,
    store: StoreOp,
    clear: f32,
}

depth_attachment :: proc (render_view: RenderView = nil, load: LoadOp = .load, store: StoreOp = .store, clear: f32 = 1) -> DepthAttachment {
    return { render_view, load, store, clear }
}

StencilAttachment :: struct {
    render_view: RenderView,
    load:  LoadOp,
    store: StoreOp,
    clear: u8,
}

stencil_attachment :: proc (render_view: RenderView = nil, load: LoadOp = .load, store: StoreOp = .store, clear: u8 = 0) -> StencilAttachment {
    return { render_view, load, store, clear }
}

////////////////////////////////////////////////

// A windowed device and every call using it must remain on the native
// window's message-pump thread. The window must outlive the device.

// Rendering and raster PSOs accept at most eight color attachments. A render pass needs at least one attachment to infer its area.
// All resource destruction is immediate. Destroy resources only when no recorded or executing GPU frame uses them.
// The optional NoGraphicsAPIUtility DeleteQueue can defer destruction until a submitted frame completes.
// Wait for all submitted frames to drain before destroying the device.
create_device :: proc (
    window:                        rawptr = nil, 
    swapchain_format:              Format = .undefined, 
    desired_swapchain_image_count: u32    = 2,          // 1..8 presentation contexts
    timestamp_query_count:         u32    = 256,        // Per command buffer; zero disables timestamps.
    allocator := context.allocator,
    ) -> (Device, Error) {
    presentation := window != nil
    assert(desired_swapchain_image_count != 0 && desired_swapchain_image_count <= max_swapchain_images, "swapchain image count must fit the wrapper's presentation context array")
    
    if ODIN_OS != .Windows { return nil, .unsupported }
    
    if ODIN_OS == .Windows {
        // @leak once all the load_proc_addresses are done we dont need the GetInstanceProcAddr anymore
        vulkan_library, ok := dynlib.load_library("vulkan-1.dll", allocator = context.temp_allocator)
        if !ok { return nil, .unsupported }
        
        address, found := dynlib.symbol_address(vulkan_library, "vkGetInstanceProcAddr", allocator = context.temp_allocator)
        assert(found)
        
        vk.load_proc_addresses_global(address)
    }
    
    loader_version : u32 = vk.API_VERSION_1_0
    error := error_from_vk(vk.EnumerateInstanceVersion(&loader_version))
    if error != .none { return nil, error }
    if loader_version < vk.API_VERSION_1_4 { return nil, .unsupported }
    
    device := new(_Device, allocator)
    device.allocator = allocator
    device.texture_heap_alignment = 16
    device.texture_memory_type = vk.MAX_MEMORY_TYPES
    device.pending_texture_initializations.next     = &device.pending_texture_initializations
    device.pending_texture_initializations.previous = &device.pending_texture_initializations
    
    device.timestamp_query_count = timestamp_query_count
    resize(&device.present_contexts, presentation ? desired_swapchain_image_count : 0)
    
    debug_callback :: proc "system" (severity: vk.DebugUtilsMessageSeverityFlagsEXT, messageTypes: vk.DebugUtilsMessageTypeFlagsEXT, pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> b32 {
        context = runtime.default_context()
        if .WARNING in severity || .ERROR in severity {
            // Keep the library callback dependency-free. Applications can still install
            // their own messenger; this one makes validation failures debugger-visible.
            fmt.eprintf("NoGraphicsAPI validation: %s\n", pCallbackData.pMessage)
        }
        return false
    }
    
    fail_device_creation :: proc (device: ^^_Device, error: Error) -> (Device, Error) {
        free(device^, device^.allocator)
        return nil, error
    }
    
    _enumerate_instance_extensions :: proc (values: ^[$N] vk.ExtensionProperties, count: ^u32) -> Error {
        count^ = len(values)
        result := vk.EnumerateInstanceExtensionProperties(nil, count, raw_data(values))
        
        error := result == .INCOMPLETE ? Error.unsupported : error_from_vk(result)
        return error
    }
    _enumerate_instance_layers :: proc (values: ^[$N] vk.LayerProperties, count: ^u32) -> Error {
        count^ = len(values)
        result := vk.EnumerateInstanceLayerProperties(count, raw_data(values))
        
        error := result == .INCOMPLETE ? Error.unsupported : error_from_vk(result)
        return error
    }
    _enumerate_physical_devices :: proc (instance: vk.Instance, values: ^[$N] vk.PhysicalDevice, count: ^u32) -> Error {
        count^ = len(values)
        result := vk.EnumeratePhysicalDevices(instance, count, raw_data(values))
        
        error := result == .INCOMPLETE ? Error.unsupported : error_from_vk(result)
        return error
    }
    _enumerate_device_extensions :: proc (physical_device: vk.PhysicalDevice, values: ^[$N] vk.ExtensionProperties, count: ^u32) -> Error {
        count^ = len(values)
        result := vk.EnumerateDeviceExtensionProperties(physical_device, nil, count, raw_data(values))
        
        error := result == .INCOMPLETE ? Error.unsupported : error_from_vk(result)
        return error
    }    
    has_name :: proc { has_name_ext, has_name_layer }
    has_name_ext :: proc (values: [] vk.ExtensionProperties, name: cstring) -> bool {
        for &value in values {
            if (cast(cstring) &value.extensionName[0]) == name {
                return true
            }
        }
        return false
    }
    has_name_layer :: proc (values: [] vk.LayerProperties, name: cstring) -> bool {
        for &value in values {
            if (cast(cstring) &value.layerName[0]) == name {
                return true
            }
        }
        return false
    }
    
    _instance_extensions: [max_instance_extensions] vk.ExtensionProperties
    _instance_extensions_count: u32
    error = _enumerate_instance_extensions(&_instance_extensions, &_instance_extensions_count)
    instance_extensions := _instance_extensions[:_instance_extensions_count]
    if error != .none { return fail_device_creation(&device, error) }
    
    khr_surface_maintenance1: bool
    ext_surface_maintenance1: bool
    when ODIN_OS == .Windows {
        khr_surface_maintenance1 = presentation && has_name(instance_extensions, vk.KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME)
        ext_surface_maintenance1 = presentation && has_name(instance_extensions, vk.EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME)
        if presentation && (
            !has_name(instance_extensions, vk.KHR_SURFACE_EXTENSION_NAME) ||
            !has_name(instance_extensions, vk.KHR_WIN32_SURFACE_EXTENSION_NAME) ||
            !has_name(instance_extensions, vk.KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME) ||
            (!khr_surface_maintenance1 && !ext_surface_maintenance1)
        ) {
            return fail_device_creation(&device, .unsupported)
        }
    }
    
    debug_utils_available: bool
    validation_available:  bool
    if Validation {
        _layers: [max_instance_layers] vk.LayerProperties
        _layers_count: u32
        error = _enumerate_instance_layers(&_layers, &_layers_count)
        layers := _layers[:_layers_count]
        if error != .none { return fail_device_creation(&device, error) }
        
        debug_utils_available = has_name(instance_extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
        validation_available  = has_name(layers, "VK_LAYER_KHRONOS_validation")
        
        
    }
    
    enabled_instance_extensions: [dynamic; 6] cstring
    enabled_layers:              [dynamic; 1] cstring
    if Validation {
        if debug_utils_available { append(&enabled_instance_extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME) }
        if validation_available  { append(&enabled_layers, "VK_LAYER_KHRONOS_validation") }
    }
    
    when ODIN_OS == .Windows {
        if presentation {
            append(&enabled_instance_extensions, vk.KHR_SURFACE_EXTENSION_NAME)
            append(&enabled_instance_extensions, vk.KHR_WIN32_SURFACE_EXTENSION_NAME)
            append(&enabled_instance_extensions, vk.KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME)
            if khr_surface_maintenance1 { append(&enabled_instance_extensions, vk.KHR_SURFACE_MAINTENANCE_1_EXTENSION_NAME) }
            if ext_surface_maintenance1 { append(&enabled_instance_extensions, vk.EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME) }
        }
    }
    
    error = error_from_vk(vk.CreateInstance(&vk.InstanceCreateInfo {
        sType = .INSTANCE_CREATE_INFO,
        pApplicationInfo = &vk.ApplicationInfo {
            sType = .APPLICATION_INFO,
            pApplicationName   = "NoGraphicsAPI application",
            applicationVersion = vk.MAKE_API_VERSION(0,0,1,0),
            pEngineName        = "NoGraphicsAPI",
            engineVersion      = vk.MAKE_API_VERSION(0,0,1,0),
            apiVersion         = vk.API_VERSION_1_4,
        },
        enabledLayerCount       = cast(u32) len(enabled_layers),
        ppEnabledLayerNames     = len(enabled_layers) != 0 ? raw_data(&enabled_layers) : nil,
        enabledExtensionCount   = cast(u32) len(enabled_instance_extensions),
        ppEnabledExtensionNames = len(enabled_instance_extensions) != 0 ? raw_data(&enabled_instance_extensions) : nil,
    }, nil, &device.instance))
    if error != .none { return fail_device_creation(&device, error) }
    
    vk.load_proc_addresses_instance(device.instance)
    
    if ODIN_DEBUG {
        if debug_utils_available {
            create_debug := cast(vk.ProcCreateDebugUtilsMessengerEXT) vk.GetInstanceProcAddr(device.instance, "vkCreateDebugUtilsMessengerEXT")
            device.destroy_debug_messenger = auto_cast vk.GetInstanceProcAddr(device.instance, "vkDestroyDebugUtilsMessengerEXT")
            if create_debug == nil || device.destroy_debug_messenger == nil {
                return fail_device_creation(&device, .driver_error)
            }
            
            validation_features: vk.ValidationFeaturesEXT
            if SyncValidation {
                enabled_validation_features: [dynamic; 1] vk.ValidationFeatureEnableEXT
                if SyncValidation { append(&enabled_validation_features, vk.ValidationFeatureEnableEXT.SYNCHRONIZATION_VALIDATION ) }
                
                validation_features = {
                    sType = .VALIDATION_FEATURES_EXT,
                    enabledValidationFeatureCount = cast(u32) len(enabled_validation_features),
                    pEnabledValidationFeatures    = raw_data(&enabled_validation_features),
                }
            }
            
            error = error_from_vk(create_debug(device.instance, &vk.DebugUtilsMessengerCreateInfoEXT {
                sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                pNext = SyncValidation ? &validation_features : nil,
                
                messageSeverity = { .VERBOSE, .WARNING, .ERROR },
                messageType     = { .GENERAL, .VALIDATION, .PERFORMANCE },
                pfnUserCallback = debug_callback,
            }, nil, &device.debug_messenger))
            if error != .none { return fail_device_creation(&device, error) }
        }
    }
    
    when ODIN_OS == .Windows {
        if presentation {
            error = error_from_vk(vk.CreateWin32SurfaceKHR(device.instance, &vk.Win32SurfaceCreateInfoKHR {
                sType = .WIN32_SURFACE_CREATE_INFO_KHR,
                hinstance = cast(win.HINSTANCE) win.GetModuleHandleW(nil),
                hwnd      = cast(win.HWND) window,
            }, nil, &device.surface))
            if error != .none { return fail_device_creation(&device, error) }
        }
    }
    
    _physical_devices: [max_physical_devices] vk.PhysicalDevice
    _physical_devices_count: u32
    error = _enumerate_physical_devices(device.instance, &_physical_devices, &_physical_devices_count)
    physical_devices := _physical_devices[:_physical_devices_count]
    if error != .none { return fail_device_creation(&device, error) }
    
    inspect_candidate :: proc (physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR, khr_surface_maintenance1: bool, ext_surface_maintenance1: bool, candidate: ^Candidate) -> Error {
        _extensions: [max_device_extensions] vk.ExtensionProperties
        _extensions_count: u32
        error := _enumerate_device_extensions(physical_device, &_extensions, &_extensions_count)
        extensions := _extensions[:_extensions_count]
        if error != .none { return error }
        
        unified_image_layouts_extension := has_name(extensions, vk.KHR_UNIFIED_IMAGE_LAYOUTS_EXTENSION_NAME)
        
        required_extensions := [] cstring {
            vk.EXT_DESCRIPTOR_HEAP_EXTENSION_NAME,
            vk.KHR_DEVICE_ADDRESS_COMMANDS_EXTENSION_NAME,
            vk.KHR_SHADER_UNTYPED_POINTERS_EXTENSION_NAME,
            vk.EXT_MESH_SHADER_EXTENSION_NAME,
        }
        
        for required in required_extensions {
            if !has_name(extensions, required) {
                return .unsupported
            }
        }
        
        khr_swapchain_maintenance1 := khr_surface_maintenance1 && has_name(extensions, vk.KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME)
        ext_swapchain_maintenance1 := ext_surface_maintenance1 && has_name(extensions, vk.EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME)
        
        if surface != 0 && !has_name(extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME) || (!khr_swapchain_maintenance1 && !ext_swapchain_maintenance1) {
            return .unsupported
        }
        
        result := Candidate { physical_device = physical_device }
        result.vulkan12_properties.sType = .PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES
        result.heap_properties.sType = .PHYSICAL_DEVICE_DESCRIPTOR_HEAP_PROPERTIES_EXT
        result.heap_properties.pNext = &result.vulkan12_properties
        properties2 := vk.PhysicalDeviceProperties2 {
            sType = .PHYSICAL_DEVICE_PROPERTIES_2,
            pNext = &result.heap_properties,
        }
        vk.GetPhysicalDeviceProperties2(physical_device, &properties2)
        result.properties = properties2.properties
        result.heap_properties.pNext = nil
        result.vulkan12_properties.pNext = nil
        if result.properties.apiVersion < vk.API_VERSION_1_4 { return .unsupported }
        
        vk.GetPhysicalDeviceMemoryProperties(physical_device, &result.memory_properties)
        cpu_visible_memory: bool
        for index in 0..<result.memory_properties.memoryTypeCount {
            if is_usable_memory_type(&result.memory_properties, index) && (result.memory_properties.memoryTypes[index].propertyFlags >= cpu_visible_memory_properties) {
                cpu_visible_memory = true
                break
            }
        }
        if !cpu_visible_memory { return .unsupported }
        
        features: QueriedFeatures
        queried_features(&features, surface != 0, unified_image_layouts_extension)
        vk.GetPhysicalDeviceFeatures2(physical_device, &features.core)
        
        required_features := 
            features.core.features.shaderInt16 &&
            features.core.features.samplerAnisotropy &&
            features.core.features.depthBiasClamp &&
            features.core.features.independentBlend &&
            features.core.features.fragmentStoresAndAtomics &&
            features.core.features.vertexPipelineStoresAndAtomics &&
            features.core.features.shaderStorageImageReadWithoutFormat &&
            features.core.features.shaderStorageImageWriteWithoutFormat &&
            features.core.features.multiDrawIndirect &&
            features.core.features.drawIndirectFirstInstance &&
            features.vulkan11.storageBuffer16BitAccess &&
            features.vulkan11.storagePushConstant16 &&
            features.vulkan11.shaderDrawParameters &&
            features.vulkan12.shaderFloat16 &&
            features.vulkan12.scalarBlockLayout &&
            features.vulkan12.bufferDeviceAddress &&
            features.vulkan12.timelineSemaphore &&
            features.vulkan13.synchronization2 &&
            features.vulkan13.dynamicRendering &&
            features.vulkan13.maintenance4 &&
            features.vulkan14.maintenance5 &&
            features.descriptor_heap.descriptorHeap &&
            features.address_commands.deviceAddressCommands &&
            features.untyped_pointers.shaderUntypedPointers &&
            features.mesh_shader.meshShader &&
            (features.core.features.textureCompressionBC || features.core.features.textureCompressionASTC_LDR) &&
            (surface != 0 || features.swapchain_maintenance1.swapchainMaintenance1)
        if !required_features { return .unsupported }
        
        result.unified_image_layouts    = unified_image_layouts_extension && features.unified_image_layouts.unifiedImageLayouts
        result.image_cube_array         = cast(bool) features.core.features.imageCubeArray
        result.texture_compression_bc   = cast(bool) features.core.features.textureCompressionBC
        result.texture_compression_astc = cast(bool) features.core.features.textureCompressionASTC_LDR
        result.texture_compression_etc2 = cast(bool) features.core.features.textureCompressionETC2
        result.storage_input_output16   = cast(bool) features.vulkan11.storageInputOutput16
        result.khr_swapchain_mantenance1 = khr_swapchain_maintenance1
        
        available_queue_count: u32
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &available_queue_count, nil)
        if available_queue_count > max_queue_families { return .unsupported }

        queues: [dynamic; max_queue_families] vk.QueueFamilyProperties
        queue_count := available_queue_count
        resize(&queues, queue_count)
        vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, raw_data(&queues))
        
        queue_family := queue_count
        for queue, index in queues {
            if queue.queueCount == 0 || queue.timestampValidBits != 64 || (queue.queueFlags & required_queue_flags) != required_queue_flags { continue }
            
            presentation_supported: b32 = true
            if surface != 0 {
                presentation_error := error_from_vk(vk.GetPhysicalDeviceSurfaceSupportKHR(physical_device, cast(u32) index, surface, &presentation_supported))
                if presentation_error != .none { return presentation_error }
            }
            
            if presentation_supported {
                queue_family = cast(u32) index
                break
            }
        }
        if queue_family == queue_count { return .unsupported }
        
        result.queue_family = queue_family
        candidate^ = result
        return .none
    }
    
    Candidate :: struct {
        physical_device:           vk.PhysicalDevice,
        queue_family:              u32,
        properties:                vk.PhysicalDeviceProperties,
        memory_properties:         vk.PhysicalDeviceMemoryProperties,
        unified_image_layouts:     bool,
        image_cube_array:          bool,
        texture_compression_bc:    bool,
        texture_compression_astc:  bool,
        texture_compression_etc2:  bool,
        storage_input_output16:    bool,
        khr_swapchain_mantenance1: bool,
        heap_properties:           vk.PhysicalDeviceDescriptorHeapPropertiesEXT,
        vulkan12_properties:       vk.PhysicalDeviceVulkan12Properties,
    }
    selected: Candidate
    has_selected: bool
    for physical_device in physical_devices {
        candidate: Candidate
        error = inspect_candidate(physical_device, device.surface, khr_surface_maintenance1, ext_surface_maintenance1, &candidate)
        if error == .unsupported { continue }
        if error != .none { return fail_device_creation(&device, error) }
        
        if !has_selected || candidate.properties.deviceType == .DISCRETE_GPU {
            selected = candidate
            has_selected = true
        }
        
        if candidate.properties.deviceType == .DISCRETE_GPU { break }
    }
    if !has_selected { return fail_device_creation(&device, error) }
    
    device.physical_device               = selected.physical_device
    device.queue_family                  = selected.queue_family
    device.physical_properties           = selected.properties
    device.heap_properties               = selected.heap_properties
    device.max_timeline_value_difference = selected.vulkan12_properties.maxTimelineSemaphoreValueDifference
    device.heap_properties.pNext         = nil
    device.memory_properties             = selected.memory_properties
    
    optimal_format_features :: proc (physical_device: vk.PhysicalDevice, format: Format) -> vk.FormatFeatureFlags2 {
        properties3 := vk.FormatProperties3 { sType = .FORMAT_PROPERTIES_3 }
        properties2 := vk.FormatProperties2 {
            sType = .FORMAT_PROPERTIES_2,
            pNext = &properties3,
        }
        vk.GetPhysicalDeviceFormatProperties2(physical_device, to_vk(format), &properties2)
        
        return properties3.optimalTilingFeatures
    }
    
    for &it, format in device.format_features {
        it = optimal_format_features(device.physical_device, format)
    }
    
    QueriedFeatures :: struct {
        core:                   vk.PhysicalDeviceFeatures2,
        vulkan11:               vk.PhysicalDeviceVulkan11Features,
        vulkan12:               vk.PhysicalDeviceVulkan12Features,
        vulkan13:               vk.PhysicalDeviceVulkan13Features,
        vulkan14:               vk.PhysicalDeviceVulkan14Features,
        descriptor_heap:        vk.PhysicalDeviceDescriptorHeapFeaturesEXT,
        address_commands:       vk.PhysicalDeviceDeviceAddressCommandsFeaturesKHR,
        untyped_pointers:       vk.PhysicalDeviceShaderUntypedPointersFeaturesKHR,
        unified_image_layouts:  vk.PhysicalDeviceUnifiedImageLayoutsFeaturesKHR,
        mesh_shader:            vk.PhysicalDeviceMeshShaderFeaturesEXT,
        swapchain_maintenance1: vk.PhysicalDeviceSwapchainMaintenance1FeaturesKHR,
    }
    
    queried_features :: proc (q: ^QueriedFeatures, presentation: bool, include_unified_image_layouts: bool) {
        q.core.sType                   = .PHYSICAL_DEVICE_FEATURES_2
        q.vulkan11.sType               = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
        q.vulkan12.sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
        q.vulkan13.sType               = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
        q.vulkan14.sType               = .PHYSICAL_DEVICE_VULKAN_1_4_FEATURES
        q.descriptor_heap.sType        = .PHYSICAL_DEVICE_DESCRIPTOR_HEAP_FEATURES_EXT
        q.address_commands.sType       = .PHYSICAL_DEVICE_DEVICE_ADDRESS_COMMANDS_FEATURES_KHR
        q.untyped_pointers.sType       = .PHYSICAL_DEVICE_SHADER_UNTYPED_POINTERS_FEATURES_KHR
        q.unified_image_layouts.sType  = .PHYSICAL_DEVICE_UNIFIED_IMAGE_LAYOUTS_FEATURES_KHR
        q.mesh_shader.sType            = .PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT
        q.swapchain_maintenance1.sType = .PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR
        
        q.core.pNext                  = &q.vulkan11
        q.vulkan11.pNext              = &q.vulkan12
        q.vulkan12.pNext              = &q.vulkan13
        q.vulkan13.pNext              = &q.vulkan14
        q.vulkan14.pNext              = &q.descriptor_heap
        q.descriptor_heap.pNext       = &q.address_commands
        q.address_commands.pNext      = &q.untyped_pointers
        q.untyped_pointers.pNext      = include_unified_image_layouts ? &q.unified_image_layouts : &q.mesh_shader
        q.unified_image_layouts.pNext = &q.mesh_shader
        q.mesh_shader.pNext           = presentation ? &q.swapchain_maintenance1 : nil
    }
    
    enabled_features: QueriedFeatures
    queried_features(&enabled_features, presentation, selected.unified_image_layouts)
    device.texture_compression_etc2 = selected.texture_compression_etc2
    enabled_features.core.features.imageCubeArray                       = cast(b32) selected.image_cube_array
    enabled_features.core.features.samplerAnisotropy                    = true
    enabled_features.core.features.shaderInt16                          = true
    enabled_features.core.features.depthBiasClamp                       = true
    enabled_features.core.features.independentBlend                     = true
    enabled_features.core.features.textureCompressionBC                 = cast(b32) selected.texture_compression_bc
    enabled_features.core.features.textureCompressionASTC_LDR           = cast(b32) selected.texture_compression_astc
    enabled_features.core.features.textureCompressionETC2               = cast(b32) selected.texture_compression_etc2
    enabled_features.core.features.fragmentStoresAndAtomics             = true
    enabled_features.core.features.vertexPipelineStoresAndAtomics       = true
    enabled_features.core.features.shaderStorageImageReadWithoutFormat  = true
    enabled_features.core.features.shaderStorageImageWriteWithoutFormat = true
    enabled_features.core.features.multiDrawIndirect                    = true
    enabled_features.core.features.drawIndirectFirstInstance            = true
    enabled_features.vulkan11.storageBuffer16BitAccess                  = true
    enabled_features.vulkan11.storagePushConstant16                     = true
    enabled_features.vulkan11.storageInputOutput16                      = cast(b32) selected.storage_input_output16
    enabled_features.vulkan11.shaderDrawParameters                      = true
    enabled_features.vulkan12.shaderFloat16                             = true
    enabled_features.vulkan12.scalarBlockLayout                         = true
    enabled_features.vulkan12.timelineSemaphore                         = true
    enabled_features.vulkan12.bufferDeviceAddress                       = true
    enabled_features.vulkan13.synchronization2                          = true
    enabled_features.vulkan13.dynamicRendering                          = true
    enabled_features.vulkan13.maintenance4                              = true
    enabled_features.vulkan14.maintenance5                              = true
    enabled_features.descriptor_heap.descriptorHeap                     = true
    enabled_features.address_commands.deviceAddressCommands             = true
    enabled_features.untyped_pointers.shaderUntypedPointers             = true
    enabled_features.unified_image_layouts.unifiedImageLayouts          = cast(b32) selected.unified_image_layouts
    enabled_features.mesh_shader.taskShader                             = true
    enabled_features.mesh_shader.meshShader                             = true
    enabled_features.swapchain_maintenance1.swapchainMaintenance1       = true

    enabled_device_extensions: [dynamic; 7] cstring
    append(&enabled_device_extensions, vk.EXT_DESCRIPTOR_HEAP_EXTENSION_NAME)
    append(&enabled_device_extensions, vk.KHR_DEVICE_ADDRESS_COMMANDS_EXTENSION_NAME)
    append(&enabled_device_extensions, vk.KHR_SHADER_UNTYPED_POINTERS_EXTENSION_NAME)
    if selected.unified_image_layouts {
        append(&enabled_device_extensions, vk.KHR_UNIFIED_IMAGE_LAYOUTS_EXTENSION_NAME)
    }
    append(&enabled_device_extensions, vk.EXT_MESH_SHADER_EXTENSION_NAME)
    
    if ODIN_OS == .Windows {
        if presentation {
            append(&enabled_device_extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
            append(&enabled_device_extensions, selected.khr_swapchain_mantenance1 ? vk.KHR_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME : vk.EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME)
        }
    }
    
    queue_priority: f32 = 1
    error = error_from_vk(vk.CreateDevice(device.physical_device, &vk.DeviceCreateInfo{
        sType = .DEVICE_CREATE_INFO,
        pNext = &enabled_features.core,
        queueCreateInfoCount = 1,
        pQueueCreateInfos = &vk.DeviceQueueCreateInfo {
            sType = .DEVICE_QUEUE_CREATE_INFO,
            queueFamilyIndex = device.queue_family,
            queueCount       = 1,
            pQueuePriorities = &queue_priority,
        },
        enabledExtensionCount   = cast(u32) len(enabled_device_extensions),
        ppEnabledExtensionNames = raw_data(&enabled_device_extensions),
    }, nil, &device.device))
    if error != .none { return fail_device_creation(&device, error) }
    
    vk.load_proc_addresses_device(device.device)
    
    buffer_memory_requirements :: proc (device: ^_Device, usage: vk.BufferUsageFlags) -> vk.MemoryRequirements {
        result := vk.MemoryRequirements2 { sType = .MEMORY_REQUIREMENTS_2 }
        vk.GetDeviceBufferMemoryRequirements(device.device, &vk.DeviceBufferMemoryRequirements {
            sType = .DEVICE_BUFFER_MEMORY_REQUIREMENTS,
            pCreateInfo = &vk.BufferCreateInfo {
                sType = .BUFFER_CREATE_INFO,
                size = 1,
                usage = usage,
                sharingMode = .EXCLUSIVE,
            },
        }, &result)
        return result.memoryRequirements
    }
    
    supports_gpu_heap_memory :: proc (device: ^_Device) -> bool {
        ordinary := buffer_memory_requirements(device, universal_buffer_usage)
        found: bool
        if _, found = find_memory_type(device, ordinary.memoryTypeBits, cpu_visible_memory_properties, {}, ordinary.size); !found {
            if _, found = find_memory_type(device, ordinary.memoryTypeBits, { .DEVICE_LOCAL }, {}, ordinary.size, { .HOST_VISIBLE }); !found {
                return found
            }
        }
        
        descriptor := buffer_memory_requirements(device, universal_buffer_usage + { .DESCRIPTOR_HEAP_EXT })
        _, found = find_memory_type(device, descriptor.memoryTypeBits, cpu_visible_memory_properties, {}, descriptor.size, )
        return found
    }
    
    select_texture_memory_type :: proc (device: ^_Device) -> bool {
        color_features := device.format_features[.rgba8_unorm]
        if .SAMPLED_IMAGE not_in color_features { return false }
        
        // Probes cover DCC-capable color, broad 3D, and sampled depth layouts.
        // Resource Memory Association makes the color mask common to ordinary optimal-tiled images. Intersect every public depth/stencil format below.
        probe_2d_size := min(device.physical_properties.limits.maxImageDimension2D, 2028)
        color_usage := vk.ImageUsageFlags { .SAMPLED }
        if .COLOR_ATTACHMENT in color_features {
            color_usage += { .COLOR_ATTACHMENT }
        }

        supports_image_create_info :: proc (device: ^_Device, image_info: vk.ImageCreateInfo, output: ^vk.ImageFormatProperties = nil) -> bool {
            properties := vk.ImageFormatProperties2 { sType = .IMAGE_FORMAT_PROPERTIES_2 }
            result := vk.GetPhysicalDeviceImageFormatProperties2(device.physical_device, &vk.PhysicalDeviceImageFormatInfo2 {
                sType = .PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
                format = image_info.format,
                type   = image_info.imageType,
                tiling = image_info.tiling,
                usage  = image_info.usage,
                flags  = image_info.flags,
            }, &properties)
            
            if result == .ERROR_FORMAT_NOT_SUPPORTED { return false }
            require_vk(result)
            
            if output != nil {
                output^ = properties.imageFormatProperties
            }
            
            fits := fits_image_format_properties(image_info, properties.imageFormatProperties)
            return fits
        } 

        fits_image_format_properties :: proc (image_info: vk.ImageCreateInfo, properties: vk.ImageFormatProperties) -> bool {
            result := image_info.extent.width <= properties.maxExtent.width && 
                      image_info.extent.height <= properties.maxExtent.height && 
                      image_info.extent.depth <= properties.maxExtent.depth && 
                      image_info.mipLevels <= properties.maxMipLevels && 
                      image_info.arrayLayers <= properties.maxArrayLayers
            return result
        }
        
        include_texture_heap_alignment :: proc (device: ^_Device, requirements: vk.MemoryRequirements) {
            if device.texture_heap_alignment < cast(u64) requirements.alignment {
                device.texture_heap_alignment = cast(u64) requirements.alignment
            }
        }
        
        image_info := vk.ImageCreateInfo {
            sType = .IMAGE_CREATE_INFO,
            imageType = .D2,
            format = .R8G8B8A8_UNORM,
            extent = { width = probe_2d_size, height = probe_2d_size, depth = 1 },
            mipLevels = 1,
            arrayLayers = 1,
            samples = { ._1 },
            tiling = .OPTIMAL,
            usage = color_usage,
            sharingMode = .EXCLUSIVE,
            initialLayout = .UNDEFINED,
        }
        if !supports_image_create_info(device, image_info) {
            image_info.usage = { .SAMPLED }
            if !supports_image_create_info(device, image_info) {
                return false
            }
        }
                
        color_requirements := image_memory_requirements(device, image_info)
        memory_type_bits := color_requirements.memoryTypeBits
        
        broad_features := device.format_features[.rgba32_float]
        broad_required_features := required_format_features({ .sampled, .storage, .transfer_destination })
        
        if (broad_features & broad_required_features) == broad_required_features {
            probe_3d_size := min(device.physical_properties.limits.maxImageDimension3D, 2048)
            image_info.imageType = .D3
            image_info.format = .R32G32B32A32_SFLOAT
            image_info.extent = { width = probe_3d_size, height = probe_3d_size, depth = probe_3d_size < 4 ? probe_3d_size : 4 }
            image_info.usage = { .SAMPLED, .STORAGE, .TRANSFER_DST }
            if supports_image_create_info(device, image_info) {
                include_texture_heap_alignment(device, image_memory_requirements(device, image_info))
            }
        }
        
        depth_stencil_formats := [?] Format {
            .d16_unorm,
            .d24_unorm_s8_uint,
            .d32_float,
            .s8_uint,
            .d32_float_s8_uint,
        }
        storage_features := required_format_features({.storage})
        
        for format in depth_stencil_formats {
            features := device.format_features[format]
            
            format_info := get_texture_format_info(format)
            combined := format_info.depth && format_info.stencil
            
            compatibility_usage: vk.ImageUsageFlags
            if false {}
            else if .SAMPLED_IMAGE            in features             { compatibility_usage = { .SAMPLED } }
            else if .DEPTH_STENCIL_ATTACHMENT in features             { compatibility_usage = { .DEPTH_STENCIL_ATTACHMENT } }
            else if (features & storage_features) == storage_features { compatibility_usage = { .STORAGE } }
            else if !combined && .TRANSFER_SRC in features { compatibility_usage = { .TRANSFER_SRC } }
            else if !combined && .TRANSFER_DST in features { compatibility_usage = { .TRANSFER_DST } }
            
            if compatibility_usage != {} {
                image_info.imageType = .D2
                image_info.format = to_vk(format)
                image_info.extent = { width = 1, height = 1, depth = 1 }
                image_info.mipLevels = 1
                image_info.usage = compatibility_usage
                
                compatibility_properties: vk.ImageFormatProperties
                if supports_image_create_info(device, image_info, &compatibility_properties) {
                    image_info.extent = { width = 512, height = 512, depth = 1 }
                    
                    if .SAMPLED_IMAGE in features && .DEPTH_STENCIL_ATTACHMENT in features {
                        image_info.usage = { .SAMPLED, .DEPTH_STENCIL_ATTACHMENT }
                    }
                    
                    supported := image_info.usage == compatibility_usage ? fits_image_format_properties(image_info, compatibility_properties) : supports_image_create_info(device, image_info)
                    
                    if !supported && image_info.usage != compatibility_usage {
                        image_info.usage = compatibility_usage
                        supported = fits_image_format_properties(image_info, compatibility_properties)
                    }
                    
                    if !supported {
                        image_info.extent = { width = 1, height = 1, depth = 1 }
                        image_info.usage = compatibility_usage
                    }
                    
                    requirements := image_memory_requirements(device, image_info)
                    
                    memory_type_bits &= requirements.memoryTypeBits
                    include_texture_heap_alignment(device, requirements)
                }
            }
        }
        
        found: bool
        device.texture_memory_type, found = find_memory_type(device, memory_type_bits, { .DEVICE_LOCAL }, {}, 1, { .HOST_VISIBLE })
        return found
    }
    
    vk.GetDeviceQueue(device.device, device.queue_family, 0, &device.queue)
    if !supports_gpu_heap_memory(device) || !select_texture_memory_type(device) {
        return fail_device_creation(&device, .unsupported)
    }
    
    device.fn.WriteSamplerDescriptors         = auto_cast vk.GetDeviceProcAddr(device.device, "vkWriteSamplerDescriptorsEXT")
    device.fn.WriteResourceDescriptors        = auto_cast vk.GetDeviceProcAddr(device.device, "vkWriteResourceDescriptorsEXT")
    device.fn.CmdBindSamplerHeap              = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdBindSamplerHeapEXT")
    device.fn.CmdBindResourceHeap             = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdBindResourceHeapEXT")
    device.fn.CmdPushData                     = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdPushDataEXT")
    device.fn.CmdBindIndexBuffer              = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdBindIndexBuffer3KHR")
    device.fn.CmdDrawIndirect                 = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdDrawIndirect2KHR")
    device.fn.CmdDrawIndexedIndirect          = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdDrawIndexedIndirect2KHR")
    device.fn.CmdDispatchIndirect             = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdDispatchIndirect2KHR")
    device.fn.CmdDrawMeshTasks                = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdDrawMeshTasksEXT")
    device.fn.CmdDrawMeshTasksIndirect        = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdDrawMeshTasksIndirect2EXT")
    device.fn.CmdCopyMemory                   = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdCopyMemoryKHR")
    device.fn.CmdCopyMemoryToImage            = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdCopyMemoryToImageKHR")
    device.fn.CmdCopyImageToMemory            = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdCopyImageToMemoryKHR")
    device.fn.CmdCopyQueryPoolResultsToMemory = auto_cast vk.GetDeviceProcAddr(device.device, "vkCmdCopyQueryPoolResultsToMemoryKHR")
    if (device.fn.WriteSamplerDescriptors == nil || device.fn.WriteResourceDescriptors == nil || device.fn.CmdBindSamplerHeap == nil || device.fn.CmdBindResourceHeap == nil || device.fn.CmdPushData == nil || device.fn.CmdBindIndexBuffer == nil || device.fn.CmdDrawIndirect == nil || device.fn.CmdDrawIndexedIndirect == nil || device.fn.CmdDispatchIndirect == nil || device.fn.CmdDrawMeshTasks == nil || device.fn.CmdDrawMeshTasksIndirect == nil || device.fn.CmdCopyMemory == nil || device.fn.CmdCopyMemoryToImage == nil || device.fn.CmdCopyImageToMemory == nil || device.fn.CmdCopyQueryPoolResultsToMemory == nil)
    {
        return fail_device_creation(&device, .driver_error)
    }
    
    error = create_command_contexts(device)
    if error != .none { return fail_device_creation(&device, error) }
    
    for &present in device.present_contexts {
        error = create_present_context(device, &present)
        if error != .none { return fail_device_creation(&device, error) }
    }
    
    device.caps = {
        device_name                      = strings.clone_from(cast(cstring) &device.physical_properties.deviceName[0], allocator),
        max_push_data_size               = cast(u64) device.heap_properties.maxPushDataSize,
        texture_heap_alignment           = device.texture_heap_alignment,
        texture_descriptor_size_in_bytes = cast(u64) device.heap_properties.imageDescriptorSize,
        sampler_descriptor_size_in_bytes = cast(u64) device.heap_properties.samplerDescriptorSize,
        timestamp_period_in_ns           = selected.properties.limits.timestampPeriod,
        sub_texel_precision_bits         = selected.properties.limits.subTexelPrecisionBits,
        texture_compression_bc           = selected.texture_compression_bc,
        texture_compression_astc         = selected.texture_compression_astc,
        storage_input_output16           = selected.storage_input_output16,
    }
    
    if presentation {
        device.swapchain = new(Swapchain, allocator)
        device.swapchain^ = {
            device          = device,
            format          = swapchain_format,
            transform       = { .IDENTITY },
            composite_alpha = { .OPAQUE },
        }
        error = recreate_swapchain(device.swapchain)
        if error != .none { return fail_device_creation(&device, error) }
    }
    
    return device, .none
}

destroy_device :: proc (device: Device) {
    assert(device.active_command_buffers == 0, "device destroyed while a command buffer is active")
    assert(device.acquired_swapchain == nil,   "device destroyed while a swapchain image is acquired")
    
    if device.device != nil {
        drain_contexts(device)
        
        destroy_owned_swapchain: {
            if device.swapchain == nil { break destroy_owned_swapchain }
            swapchain := device.swapchain
            
            assert(swapchain.device == device && !swapchain.acquired && device.acquired_swapchain != swapchain && device.active_command_buffers == 0, "device-ownder swapchain destroyed while its image or command buffer is active")
            retire_swapchain_handle(swapchain)
            
            free(swapchain, device.allocator)
            device.swapchain = nil
        }
        
        // @hack the swapchain and its image views where never moved from the retired_swapchains to the swapchain_delete_queue
        for &retired in device.retired_swapchains {
            if retired.handle == 0 { continue }
            
            queue_retired_swapchain(device, &retired)
        }
        
        collect(&device.swapchain_delete_queue, device, device.command_retirement_value)
        assert(device.swapchain_delete_queue.count == 0)
    }
    
    destroy_command_contexts(device)
    delete(device.swapchain_delete_queue.entries, device.allocator)
    
    for &present in device.present_contexts {
        destroy_present_context(device, &present)
    }
    
    if device.device != nil { vk.DestroyDevice(device.device, nil) }
    if device.instance != nil {
        if device.surface != 0 { vk.DestroySurfaceKHR(device.instance, device.surface, nil) }
        if device.debug_messenger != 0 && device.destroy_debug_messenger != nil { device.destroy_debug_messenger(device.instance, device.debug_messenger, nil) }
        vk.DestroyInstance(device.instance, nil)
    }
    
    device^ = {}
}

get_device_caps :: proc (device: Device) -> DeviceCaps {
    assert(device != nil)
    return device.caps
}

// @todo supports_texture_format
// @todo get_drawable_extent

////////////////////////////////////////////////

create_timeline_semaphore :: proc (device: Device, initial_value: u64 = 0) -> TimelineSemaphore {
    assert(device != nil, #procedure + " called with a null device")
    
    result := new(_TimelineSemaphore, device.allocator)
    result.device = device
    require_vk(vk.CreateSemaphore(device.device, &vk.SemaphoreCreateInfo {
        sType = .SEMAPHORE_CREATE_INFO,
        pNext = &vk.SemaphoreTypeCreateInfo {
            sType = .SEMAPHORE_TYPE_CREATE_INFO,
            semaphoreType = .TIMELINE,
            initialValue = initial_value,
        },
    }, nil, &result.semaphore))
    
    return result
}

destroy_timeline_semaphore :: proc (semaphore: TimelineSemaphore) {
    if semaphore == nil { return }
    assert(semaphore.device != nil)
    vk.DestroySemaphore(semaphore.device.device, semaphore.semaphore, nil)
    free(semaphore, semaphore.device.allocator)
}

timeline_completed_value :: proc (semaphore: TimelineSemaphore) -> u64 {
    assert(semaphore != nil && semaphore.device != nil && semaphore.semaphore != 0, #procedure + " received and invalid semaphore")
    result := query_timeline_value(semaphore)
    return result
}

wait_timeline :: proc (point: TimelinePoint) {
    semaphore := point.semaphore
    assert(semaphore != nil && semaphore.device != nil && semaphore.semaphore != 0, #procedure + " requires a live timeline semaphore")
    
    point := point
    assert_vk(vk.WaitSemaphores(semaphore.device.device, &vk.SemaphoreWaitInfo {
        sType = .SEMAPHORE_WAIT_INFO,
        semaphoreCount = 1,
        pSemaphores = &semaphore.semaphore,
        pValues     = &point.value,
    }, max(u64)))
    
    poll_command_retirement(semaphore.device)
}

wait_idle :: proc (device: Device) {
    assert(device != nil, #procedure + " called with a null device")
    assert(device.active_command_buffers == 0, #procedure + " is not allowed while a command buffer is recording")
    assert(device.acquired_swapchain == nil,   #procedure + " is not allowed while a swapchain image is acquired")
    
    drain_contexts(device)
    device.next_present_context = 0
}

////////////////////////////////////////////////

// @api needing to check .renderview for nil should just be a can_render: bool
acquire :: proc (device: Device) -> SwapchainFrame { // Empty while the drawable extent is zero.
    assert(device != nil && device.swapchain != nil && device.swapchain.device == device && !device.swapchain.acquired && device.acquired_swapchain == nil && device.active_command_buffers == 0, #procedure + " received a device without an available swapchain")
    
    swapchain := device.swapchain
    present_context: ^PresentContext
    
    for {
        if swapchain.handle == 0 || swapchain.recreate_required {
            require_error(recreate_swapchain(swapchain))
            drawable := swapchain.handle != 0 && swapchain.width != 0 && swapchain.height != 0
            if !drawable { return {} }
        }
        
        if present_context == nil {
            present_context = &device.present_contexts[device.next_present_context]
            wait_present_context(device, present_context)
            assert(!present_context.present_pending && present_context.swapchain == 0)
        }
        
        image_index: u32
        acquire_result := vk.AcquireNextImageKHR(device.device, swapchain.handle, max(u64), present_context.acquired, 0, &image_index)
        if acquire_result == .ERROR_OUT_OF_DATE_KHR {
            swapchain.recreate_required = true
            continue
        }
        if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR { abort_vk(acquire_result) }
        
        assert(image_index < swapchain.image_count, "swapchain returned an invalid image index")
        swapchain.image_index = image_index
        swapchain.present_context = present_context
        swapchain.acquired = true
        swapchain.recreate_required = acquire_result == .SUBOPTIMAL_KHR && swapchain_surface_configuration_changed(swapchain)
        device.acquired_swapchain = swapchain
        
        result := SwapchainFrame {
            render_view = &swapchain.render_views[image_index],
            extent      = { swapchain.width, swapchain.height },
        }
        return result
    }
    unreachable()
}

submit_and_present :: proc (device: Device, commands: [] CommandBuffer, completion: TimelinePoint) {
    has_swapchain := device != nil && device.swapchain != nil && device.swapchain.device == device
    assert(has_swapchain, #procedure + " received a device without a swapchain")
    
    swapchain := device.swapchain
    assert(commands != nil)
    
    first_commands := commands[0]
    last_commands  := commands[len(commands)-1]
    assert(first_commands != nil && first_commands.device != nil && last_commands != nil && last_commands.device == first_commands.device)
    
    command_device := first_commands.device
    assert(swapchain.acquired && command_device == device && first_commands.swapchain == swapchain && swapchain.transition_commands == first_commands && swapchain.present_context != nil, #procedure + " received an invalid swapchain command buffer batch")
    
    if ODIN_DEBUG {
        for buffer in commands[1:] {
            assert(buffer.swapchain == nil, "only the first command buffer may own the swapchain transition") 
        }
    }
    
    owner := device
    present_context := swapchain.present_context
    record_image_barriers(last_commands.command_buffer, vk.ImageMemoryBarrier2 {
        sType = .IMAGE_MEMORY_BARRIER_2,
        srcStageMask = { .ALL_COMMANDS },
        srcAccessMask = { .MEMORY_WRITE },
        dstStageMask = {},
        oldLayout = .GENERAL,
        newLayout = .PRESENT_SRC_KHR,
        srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
        image = swapchain.images[swapchain.image_index],
        subresourceRange = {
            aspectMask = { .COLOR },
            levelCount = 1,
            layerCount = 1,
        },
    })
    
    assert(!present_context.present_pending && present_context.swapchain == 0)
    assert_vk(vk.ResetFences(owner.device, 1, &present_context.presented))
    swapchain.transition_commands = nil
    submit_commands(commands, command_device, completion, present_context.acquired, present_context.rendered)
    swapchain.initialized[swapchain.image_index] = true
    
    result := vk.QueuePresentKHR(owner.queue, &vk.PresentInfoKHR {
        sType = .PRESENT_INFO_KHR,
        pNext = &vk.SwapchainPresentFenceInfoKHR {
            sType = .SWAPCHAIN_PRESENT_FENCE_INFO_KHR,
            swapchainCount = 1,
            pFences        = &present_context.presented,
        },
        waitSemaphoreCount = 1,
        pWaitSemaphores    = &present_context.rendered,
        swapchainCount     = 1,
        pSwapchains        = &swapchain.handle,
        pImageIndices      = &swapchain.image_index,
    })
    
    present_context.present_pending = true
    present_context.swapchain = swapchain.handle
    swapchain.present_context = nil
    swapchain.acquired = false
    owner.acquired_swapchain = nil
    owner.next_present_context = modular_add(owner.next_present_context, 1, len(owner.present_contexts))
    if result == .ERROR_OUT_OF_DATE_KHR {
        swapchain.recreate_required = true
    } else if result == .SUBOPTIMAL_KHR {
        swapchain.recreate_required ||= swapchain_surface_configuration_changed(swapchain)
    } else if result != .SUCCESS {
        abort_vk(result)
    }
}

////////////////////////////////////////////////

// Every non-null returned pointer is 16-byte aligned. Descriptor heaps are exact allocations;
// cpu_visible, gpu_only, and readback heaps are raw blocks for application-side suballocation.
create_gpu_heap :: proc (device: Device, byte_count: u64, memory_type: MemoryType = .cpu_visible) -> GpuHeap {
    assert(device != nil)
    result := allocate_gpu_heap(device, byte_count, memory_type)
    return result
}

destroy_gpu_heap :: proc (heap: GpuHeap) {
    if heap.owner == nil { return }
    assert(heap.owner.device != nil)
    
    device  := heap.owner.device
    backing := heap.owner.backing
    
    if backing.mapped != nil { vk.UnmapMemory(device.device, backing.memory) }
    vk.DestroyBuffer(device.device, backing.buffer, nil)
    vk.FreeMemory(device.device,    backing.memory, nil)
    
    free(heap.owner, device.allocator)
}

gpu_range :: proc { gpu_range_from_gpu_cpu_range, gpu_range_from_heap }
gpu_range_from_gpu_cpu_range ::proc (range: GpuCpuRange($T)) -> GpuRange { return { gpu = range.gpu, size_in_bytes = range.size_in_bytes } }
gpu_range_from_heap :: proc (heap: GpuHeap) -> GpuRange { return gpu_range(heap.range) }

////////////////////////////////////////////////

// Texture heaps use one device-selected GPU-only memory type and must outlive every placed texture.
// Placements must satisfy get_texture_size_align(), remain non-overlapping, and not be reused before the timeline point covering their last use completes.
// DeviceCaps::texture_heap_alignment can be used as a common allocator element size, avoiding per-placement leading alignment padding.

create_texture_heap :: proc (device: Device, #any_int byte_count: u64) -> TextureHeap {
    assert(device != nil, #procedure + " called with a null device")
    
    owner := new(_TextureHeapOwner, device.allocator)
    owner.device = device
    
    require_vk(vk.AllocateMemory(device.device, &vk.MemoryAllocateInfo {
        sType = .MEMORY_ALLOCATE_INFO,
        allocationSize  = cast(vk.DeviceSize) byte_count,
        memoryTypeIndex = device.texture_memory_type,
    }, nil, &owner.memory))
    
    result := TextureHeap {
        size_in_bytes = byte_count,
        owner         = owner,
    }
    return result
}

destroy_texture_heap :: proc (heap: TextureHeap) {
    if heap.owner == nil { return }
    
    vk.FreeMemory(heap.owner.device.device, heap.owner.memory, nil)
    free(heap.owner, heap.owner.device.allocator)
}

PreparedTexture :: struct {
    view_formats: [len(vk.Format)] vk.Format,
    format_list: vk.ImageFormatListCreateInfo,
    image_info:  vk.ImageCreateInfo,
} // @placement

get_texture_size_align :: proc (device: Device, desc: TextureDesc) -> (size: u64, align: u64) {
    assert(device != nil, #procedure + " called with a null device")
    
    texture: PreparedTexture
    prepare_texture(device, desc, &texture)
    requirements := image_memory_requirements(device, texture.image_info)
    
    size, align = cast(u64) requirements.size, cast(u64) requirements.alignment
    return size, align
}

create_texture :: proc (device: Device, desc: TextureDesc, heap: TextureHeap, offset: u64) -> Texture {
    owner := heap.owner
    assert(device != nil && owner != nil && owner.device == device && owner.memory != 0, #procedure + " requires a texture heap from the same device")
    assert(device.active_command_buffers == 0, #procedure + " is not allowed while a command buffer is recording")
    
    texture: PreparedTexture
    prepare_texture(device, desc, &texture)
    
    result := new(_Texture, device.allocator)
    
    result^ = _Texture {
        device         = device,
        image          = 0,
        width          = desc.extent.x,
        height         = desc.extent.y,
        depth          = desc.extent.z,
        layer_count    = desc.layer_count,
        type           = desc.type,
        format         = desc.format,
        initialization = {},
    }
    
    require_vk(vk.CreateImage(device.device, &texture.image_info, nil, &result.image))
    require_vk(vk.BindImageMemory(device.device, result.image, owner.memory, cast(vk.DeviceSize) offset))
    
    result.initialization = {
        image        = result.image,
        aspect_mask  = image_aspects(desc.format),
        mip_levels   = desc.mip_levels,
        array_layers = desc.layer_count,
    }
    append_texture_initialization(&device.pending_texture_initializations, &result.initialization)
    
    return result
}

destroy_texture :: proc (texture: Texture) {
    remove_texture_initialization(&texture.initialization)
    vk.DestroyImage(texture.device.device, texture.image, nil)
    
    free(texture, texture.device.allocator)
}

create_render_view :: proc (texture: Texture,     
    mip_level: u32 = 0,
    slice:     u32 = 0, // Physical array slice; cube faces are individual slices.
    ) -> RenderView {
    assert(texture != nil && texture.device != nil)
    
    width  := max(texture.width  >> mip_level, 1)
    height := max(texture.height >> mip_level, 1)
    
    device := texture.device
    result := new(_RenderView, device.allocator)
    result^ = {
        device = device,
        width  = width,
        height = height,
    }
    
    require_vk(vk.CreateImageView(device.device, &vk.ImageViewCreateInfo {
        sType = .IMAGE_VIEW_CREATE_INFO,
        image = texture.image,
        viewType = .D2,
        format = to_vk(texture.format),
        subresourceRange = {
            aspectMask     = image_aspects(texture.format),
            baseMipLevel   = mip_level,
            levelCount     = 1,
            baseArrayLayer = slice,
            layerCount     = 1,
        },
    }, nil, &result.view))
    
    return result
}

destroy_render_view :: proc (render_view: RenderView) {
    if render_view == nil { return }
    assert(!render_view.swapchain_view, "swapchain render views are owned by their swapchain")
    
    vk.DestroyImageView(render_view.device.device, render_view.view, nil)
    free(render_view, render_view.device.allocator)
}

write_texture_descriptor :: proc (device: Device, cpu_destination: rawptr, texture: Texture, type: TextureDescriptorType, 
    format:      Format        = .undefined, // Undefined inherits the texture format.
    aspect:      TextureAspect = .automatic, // Automatic selects color, or depth before stencil.
    base_mip:    u32           = 0,
    mip_count:   u32           = 0, // Zero selects every remaining mip level.
    base_layer:  u32           = 0, // Vulkan array layer; cube faces are individual layers.
    layer_count: u32           = 0, // Vulkan array layers; zero selects every remaining layer.
) {
    assert(device != nil && texture != nil)
    
    descriptor_aspect: vk.ImageAspectFlags
    switch aspect {
    case .color:   descriptor_aspect = { .COLOR }
    case .depth:   descriptor_aspect = { .DEPTH }
    case .stencil: descriptor_aspect = { .STENCIL }
    
    case .automatic:
        format_info := get_texture_format_info(texture.format)
        switch {
        case format_info.depth:   descriptor_aspect = { .DEPTH }
        case format_info.stencil: descriptor_aspect = { .STENCIL }
        case:                     descriptor_aspect = { .COLOR }
        }
    }
    
    descriptor_info := vk.ResourceDescriptorInfoEXT {
        sType = .RESOURCE_DESCRIPTOR_INFO_EXT,
        type  = type == .sampled ? .SAMPLED_IMAGE : .STORAGE_IMAGE,
        data = { pImage = &vk.ImageDescriptorInfoEXT {
            sType = .IMAGE_DESCRIPTOR_INFO_EXT,
            pView = &vk.ImageViewCreateInfo {
                sType = .IMAGE_VIEW_CREATE_INFO,
                pNext = &vk.ImageViewUsageCreateInfo {
                    sType = .IMAGE_VIEW_USAGE_CREATE_INFO,
                    usage = type == .sampled ? { .SAMPLED } : { .STORAGE },
                },
                image    = texture.image,
                viewType = view_to_vk(texture.type),
                format   = to_vk(format == .undefined ? texture.format : format),
                subresourceRange = {
                    aspectMask     = descriptor_aspect,
                    baseMipLevel   = base_mip,
                    levelCount     = mip_count    == 0 ? vk.REMAINING_MIP_LEVELS : mip_count,
                    baseArrayLayer = base_layer,
                    layerCount     = layer_count  == 0 ? vk.REMAINING_ARRAY_LAYERS : layer_count,
                },
            },
            layout = .GENERAL,
        } },
    }
    destination := vk.HostAddressRangeEXT {
        address = cpu_destination,
        size    = cast(int) device.heap_properties.imageDescriptorSize,
    }
    assert_vk(device.fn.WriteResourceDescriptors(device.device, 1, &descriptor_info, &destination))
}

write_sampler_descriptor :: proc (device: Device, cpu_destination: rawptr, 
    min_filter:      Filter      = .linear,
    mag_filter:      Filter      = .linear,
    mip_filter:      Filter      = .linear,
    address_u:       AddressMode = .repeat,
    address_v:       AddressMode = .repeat,
    address_w:       AddressMode = .repeat,
    anisotropic:     bool        = false, // Uses the API's fixed 4x profile.
    compare_enabled: bool        = false,
    compare:         CompareOp   = .less_equal,
) {
    assert(device != nil)
    
    sampler_info := vk.SamplerCreateInfo {
        sType = .SAMPLER_CREATE_INFO,
        magFilter        = to_vk(mag_filter),
        minFilter        = to_vk(min_filter),
        mipmapMode       = cast(vk.SamplerMipmapMode) to_vk(mip_filter),
        addressModeU     = to_vk(address_u),
        addressModeV     = to_vk(address_v),
        addressModeW     = to_vk(address_w),
        anisotropyEnable = cast(b32) anisotropic,
        maxAnisotropy    = anisotropic ? 4 : 1,
        compareEnable    = cast(b32) compare_enabled,
        compareOp        = to_vk(compare),
        maxLod           = vk.LOD_CLAMP_NONE,
    }
    
    destination := vk.HostAddressRangeEXT {
        address = cpu_destination,
        size    = cast(int) device.heap_properties.imageDescriptorSize,
    }
    assert_vk(device.fn.WriteSamplerDescriptors(device.device, 1, &sampler_info, &destination))
}

////////////////////////////////////////////////

create_graphics_pso :: proc (
    device: Device,
    vertex_spirv:   [] u32,
    fragment_spirv: [] u32 = nil, // Empty omits the fragment stage, for depth-only rasterization.
    
    color_targets:  [] ColorTargetDesc,
    depth_format:   Format             = .undefined,
    stencil_format: Format             = .undefined,
    rasterization:  RasterizationState = {},
    ) -> PSO { return create_raster_pso(device, nil, vertex_spirv, fragment_spirv, color_targets, depth_format, stencil_format, rasterization, false) }

create_mesh_pso :: proc (
    device: Device, 
    task_spirv:     [] u32 = nil, // Empty launches mesh workgroups directly; otherwise draws launch taskMain workgroups.
    mesh_spirv:     [] u32,
    fragment_spirv: [] u32 = nil, // Empty omits the fragment stage, for depth-only rasterization.
    color_targets:  [] ColorTargetDesc,
    depth_format:   Format = .undefined,
    stencil_format: Format = .undefined,
    rasterization:  RasterizationState = {},
    ) -> PSO { return create_raster_pso(device, task_spirv, mesh_spirv, fragment_spirv, color_targets, depth_format, stencil_format, rasterization, true) }

create_compute_pso :: proc (device: Device, compute_spirv: [] u32) -> PSO {
    assert(device != nil, #procedure + " called with a null device")
    
    result := new(_PSO, device.allocator)
    result.device     = device
    result.bind_point = .COMPUTE
    
    require_vk(vk.CreateComputePipelines(device.device, 0, 1, &vk.ComputePipelineCreateInfo {
        sType = .COMPUTE_PIPELINE_CREATE_INFO,
        pNext = &vk.PipelineCreateFlags2CreateInfo {
            sType = .PIPELINE_CREATE_FLAGS_2_CREATE_INFO,
            flags = { .DESCRIPTOR_HEAP_EXT },
        },
        stage = vk.PipelineShaderStageCreateInfo {
            sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
            pNext = &vk.ShaderModuleCreateInfo {
                sType = .SHADER_MODULE_CREATE_INFO,
                codeSize = len(compute_spirv) * size_of(u32),
                pCode    = raw_data(compute_spirv),
            },
            stage = { .COMPUTE },
            pName = "computeMain",
        },
        basePipelineIndex = -1,
    }, nil, &result.pso))
    
    return result
}

destroy_pso :: proc (pso: PSO) {
    if pso == nil { return }
    if pso.device != nil && pso.pso != 0 {
        vk.DestroyPipeline(pso.device.device, pso.pso, nil)
    }
    free(pso, pso.device.allocator)
}

////////////////////////////////////////////////

// Create textures before beginning commands. The first begun command buffer initializes them and must be submitted first.
// Every begun command buffer must be included exactly once in the next submit or submit_and_present call.
begin_commands :: proc (device: Device) -> CommandBuffer {
    assert(device != nil, #procedure + " called with a null device")
    result := acquire_command_context(device)
    
    assert_vk(vk.BeginCommandBuffer(result.command_buffer, &vk.CommandBufferBeginInfo {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = { .ONE_TIME_SUBMIT },
    }))
    
    result.device = device
    clear(&result.timestamp_destinations)
    
    if result.timestamp_pool != 0 {
        vk.CmdResetQueryPool(result.command_buffer, result.timestamp_pool, 0, device.timestamp_query_count)
    }
    
    if device.pending_texture_initializations.next != &device.pending_texture_initializations {
        barriers: [dynamic; image_barrier_batch_size] vk.ImageMemoryBarrier2
        for device.pending_texture_initializations.next != &device.pending_texture_initializations {
            initialization := device.pending_texture_initializations.next
            remove_texture_initialization(initialization)
            
            append(&barriers, vk.ImageMemoryBarrier2 {
                sType = .IMAGE_MEMORY_BARRIER_2,
                srcStageMask        = {},
                dstStageMask        = { .ALL_COMMANDS },
                dstAccessMask       = { .MEMORY_READ, .MEMORY_WRITE },
                oldLayout           = .UNDEFINED,
                newLayout           = .GENERAL,
                srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
                image               = initialization.image,
                subresourceRange    = { 
                    aspectMask = initialization.aspect_mask,
                    levelCount = initialization.mip_levels,
                    layerCount = initialization.array_layers,
                },
            })
            
            if len(barriers) == cap(barriers) {
                record_image_barriers(result.command_buffer, ..barriers[:])
                clear(&barriers)
            }
        }
        
        if len(barriers) != 0 {
            record_image_barriers(result.command_buffer, ..barriers[:])
        }
    }
    
    if device.acquired_swapchain != nil && device.acquired_swapchain.transition_commands == nil {
        swapchain := device.acquired_swapchain
        assert(swapchain.device == device && swapchain.acquired && swapchain.present_context != nil && swapchain.image_index < swapchain.image_count, "the acquired swapchain state is invalid")
        
        record_image_barriers(result.command_buffer, vk.ImageMemoryBarrier2 {
            sType = .IMAGE_MEMORY_BARRIER_2,
            srcStageMask        = {},
            dstStageMask        = { .ALL_COMMANDS },
            dstAccessMask       = { .MEMORY_READ, .MEMORY_WRITE },
            oldLayout           = swapchain.initialized[swapchain.image_index] ? .PRESENT_SRC_KHR : .UNDEFINED,
            newLayout           = .GENERAL,
            srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
            image               = swapchain.images[swapchain.image_index],
            subresourceRange    = { aspectMask = { .COLOR }, levelCount = 1, layerCount = 1 },
        })
        result.swapchain = swapchain
        swapchain.transition_commands = result
    }
    
    device.active_command_buffers += 1
    return result
}

submit :: proc (commands: [] CommandBuffer, completion: TimelinePoint) {
    assert(commands != nil)
    first := commands[0]
    assert(first != nil && first.device != nil)
    device := first.device
    assert(device.acquired_swapchain == nil, "an acquired swapchain frame must be submitted with submit_and_present")
    
    if ODIN_DEBUG {
        for command in commands {
            assert(command.swapchain == nil, "swapchain command buffers must be submitted with submit_and_present")
        }
    }
    
    submit_commands(commands, device, completion, 0, 0)
}

////////////////////////////////////////////////

set_texture_descriptor_heap :: proc (commands: CommandBuffer, heap: GpuRange) {
    assert(commands != nil && commands.device != nil)
    
    properties := commands.device.heap_properties
    
    bind_info := make_heap_bind_info(heap, max(properties.imageDescriptorAlignment, properties.bufferDescriptorAlignment), properties.minResourceHeapReservedRange)
    commands.device.fn.CmdBindResourceHeap(commands.command_buffer, &bind_info)
}

set_sampler_descriptor_heap :: proc (commands: CommandBuffer, heap: GpuRange) {
    assert(commands != nil && commands.device != nil)
    
    properties := commands.device.heap_properties
    
    bind_info := make_heap_bind_info(heap, properties.samplerDescriptorAlignment, properties.minSamplerHeapReservedRange)
    commands.device.fn.CmdBindSamplerHeap(commands.command_buffer, &bind_info)
}

////////////////////////////////////////////////

copy_memory :: proc (commands: CommandBuffer, source: GpuRange, destination: GpuRange) {
    assert(commands != nil && commands.device != nil)
    
    commands.device.fn.CmdCopyMemory(commands.command_buffer, &vk.CopyDeviceMemoryInfoKHR {
        sType = .COPY_DEVICE_MEMORY_INFO_KHR,
        regionCount = 1,
        pRegions    = &vk.DeviceMemoryCopyKHR {
            sType = .DEVICE_MEMORY_COPY_KHR,
            srcRange = to_vk(source),
            srcFlags = address_flags,
            dstRange = to_vk(destination),
            dstFlags = address_flags,
        },
    })
}

copy_memory_to_texture :: proc (commands: CommandBuffer, source: GpuRange, destination: Texture, copy: TextureCopyDesc = {}) {
    assert(commands != nil && commands.device != nil && destination != nil)
    
    region := make_texture_copy_region(destination, copy, source)
    
    commands.device.fn.CmdCopyMemoryToImage(commands.command_buffer, &vk.CopyDeviceMemoryImageInfoKHR {
        sType = .COPY_DEVICE_MEMORY_IMAGE_INFO_KHR,
        image       = destination.image,
        regionCount = 1,
        pRegions    = &region,
    })
}

copy_texture_to_memory :: proc (commands: CommandBuffer, source: Texture, destination: GpuRange, copy: TextureCopyDesc = {}) {
    assert(commands != nil && commands.device != nil && source != nil)
    
    region := make_texture_copy_region(source, copy, destination)
    
    commands.device.fn.CmdCopyImageToMemory(commands.command_buffer, &vk.CopyDeviceMemoryImageInfoKHR {
        sType = .COPY_DEVICE_MEMORY_IMAGE_INFO_KHR,
        image       = source.image,
        regionCount = 1,
        pRegions    = &region,
    })
}

////////////////////////////////////////////////

barrier :: proc { barrier_before_after, barrier_both }
barrier_both :: proc (commands: CommandBuffer, stages: Stages, access: Access) {
    barrier(commands, stages, access, stages, access)
}
barrier_before_after :: proc (commands: CommandBuffer, before: Stages, before_access: Access, after: Stages, after_access: Access) {
    assert(commands != nil)
    
    vk.CmdPipelineBarrier2(commands.command_buffer, &vk.DependencyInfo {
        sType = .DEPENDENCY_INFO,
        memoryBarrierCount = 1,
        pMemoryBarriers = &vk.MemoryBarrier2 {
            sType = .MEMORY_BARRIER_2,
            srcStageMask  = to_vk(before),
            srcAccessMask = to_vk(before_access),
            dstStageMask  = to_vk(after),
            dstAccessMask = to_vk(after_access),
        },
    })
}

////////////////////////////////////////////////

// Up to DeviceDesc::timestamp_query_count markers per command buffer. stage must map to a single GPU pipeline stage.
// Destinations must be 8-byte aligned and distinct until submission completes.
// Results are copied at command-buffer end; read mapped readback memory only after submission completes.

write_timestamp :: proc (commands: CommandBuffer, gpu_destination: ^u64, stages: Stages) {
    assert(commands != nil && commands.device != nil)
    append(&commands.timestamp_destinations, transmute(vk.DeviceAddress) gpu_destination)
    vk.CmdWriteTimestamp2(commands.command_buffer, to_vk(stages), commands.timestamp_pool, cast(u32) len(commands.timestamp_destinations)-1)
}

////////////////////////////////////////////////

// @note depth and stencil may be zero-initialized, because their values are only used when render_view is not nil
begin_render_pass :: proc (commands: CommandBuffer, colors: [] ColorAttachment = nil, depth: DepthAttachment = {}, stencil: StencilAttachment = {}) {
    assert(commands != nil && colors != nil && len(colors) < max_color_attachments)
    area_view: RenderView
    if len(colors) != 0 { area_view = colors[0].render_view }
    if area_view == nil { area_view = depth.render_view }
    if area_view == nil { area_view = stencil.render_view }
    assert(area_view != nil, #procedure + " requires an attachment to determine the render area")
    
    color_attachments: [dynamic; max_color_attachments] vk.RenderingAttachmentInfo
    for attachment in colors {
        assert(attachment.render_view != nil)
        append(&color_attachments, vk.RenderingAttachmentInfo {
            sType = .RENDERING_ATTACHMENT_INFO,
            imageView   = attachment.render_view.view,
            imageLayout = .GENERAL,
            loadOp      = to_vk(attachment.load),
            storeOp     = to_vk(attachment.store),
            clearValue  = { color = { float32 = attachment.clear } },
        })
    }
    
    depth_attachment := vk.RenderingAttachmentInfo {
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView   = depth.render_view != nil ? depth.render_view.view : 0,
        imageLayout = .GENERAL,
        loadOp      = to_vk(depth.load),
        storeOp     = to_vk(depth.store),
        clearValue  = { depthStencil = { depth = depth.clear } },
    }
    
    stencil_attachment := vk.RenderingAttachmentInfo {
        sType = .RENDERING_ATTACHMENT_INFO,
        imageView   = stencil.render_view != nil ? stencil.render_view.view : 0,
        imageLayout = .GENERAL,
        loadOp      = to_vk(stencil.load),
        storeOp     = to_vk(stencil.store),
        clearValue  = { depthStencil = { stencil = cast(u32) stencil.clear } },
    }
    
    vk.CmdBeginRendering(commands.command_buffer, &vk.RenderingInfo {
        sType = .RENDERING_INFO,
        renderArea = { extent = { width = area_view.width, height = area_view.height } },
        layerCount = 1,
        colorAttachmentCount = cast(u32) len(colors),
        pColorAttachments    = raw_data(&color_attachments),
        pDepthAttachment     = depth.render_view   != nil ? &depth_attachment   : nil,
        pStencilAttachment   = stencil.render_view != nil ? &stencil_attachment : nil,
    })
    
    set_viewport(commands, width = cast(f32) area_view.width, height = cast(f32) area_view.height)
    set_scissor(commands,  width =           area_view.width, height =           area_view.height)
    set_depth_stencil(commands)
}

end_render_pass :: proc (commands: CommandBuffer) {
    assert(commands != nil)
    vk.CmdEndRendering(commands.command_buffer)
}

////////////////////////////////////////////////

set_viewport :: proc (commands: CommandBuffer, x: f32 = 0, y: f32 = 0, width: f32 = 1, height: f32 = 1, min_depth: f32 = 0, max_depth: f32 = 1) {
    assert(commands != nil)
    vk.CmdSetViewportWithCount(commands.command_buffer, 1, &vk.Viewport {
        x = x,
        y = y,
        width = width,
        height = height,
        minDepth = min_depth,
        maxDepth = max_depth,
    })
}

set_scissor :: proc (commands: CommandBuffer, x: i32 = 0, y: i32 = 0, width: u32 = 1, height: u32 = 1) {
    assert(commands != nil)
    vk.CmdSetScissorWithCount(commands.command_buffer, 1, &vk.Rect2D {
        offset = { x = x, y = y },
        extent = { width = width, height = height },
    })
}

set_depth_stencil :: proc (commands: CommandBuffer, depth_test := false, depth_write := false, depth_compare := CompareOp.less_equal, stencil_test := false, stencil_read_mask: u8 = 0xff, stencil_write_mask: u8 = 0xff, front: StencilFaceState = { .always, .keep, .keep, .keep, 0 }, back: StencilFaceState = { .always, .keep, .keep, .keep, 0 }) {
    assert(commands != nil)
    
    vk.CmdSetDepthTestEnable(commands.command_buffer, cast(b32) depth_test)
    if depth_test {
        vk.CmdSetDepthWriteEnable(commands.command_buffer, cast(b32) depth_write)
        vk.CmdSetDepthCompareOp(commands.command_buffer, to_vk(depth_compare))
    }
    
    vk.CmdSetStencilTestEnable(commands.command_buffer, cast(b32) stencil_test)
    if !stencil_test { return }
    
    vk.CmdSetStencilOp(commands.command_buffer, { .FRONT }, to_vk(front.fail), to_vk(front.pass), to_vk(front.depth_fail), to_vk(front.compare))
    vk.CmdSetStencilOp(commands.command_buffer, { .BACK },  to_vk(back.fail),  to_vk(back.pass),  to_vk(back.depth_fail),  to_vk(back.compare))
    vk.CmdSetStencilCompareMask(commands.command_buffer, { .FRONT, .BACK }, cast(u32) stencil_read_mask)
    vk.CmdSetStencilWriteMask(commands.command_buffer,   { .FRONT, .BACK }, cast(u32) stencil_write_mask)
    vk.CmdSetStencilReference(commands.command_buffer, { .FRONT }, cast(u32) front.reference)
    vk.CmdSetStencilReference(commands.command_buffer, { .BACK },  cast(u32) back.reference)
}

////////////////////////////////////////////////

bind_pso :: proc (commands: CommandBuffer, pso: PSO) {
    assert(commands != nil && pso != nil)
    vk.CmdBindPipeline(commands.command_buffer, pso.bind_point, pso.pso)
}

////////////////////////////////////////////////

byte_slice :: proc { byte_slice_from_pointer, byte_slice_from_slice }
byte_slice_from_pointer :: proc (pointer: ^$T) -> [] u8 {
    bytes  := cast([^] u8) pointer
    length := size_of(T)
    
    result := bytes[:length]
    return result
}
byte_slice_from_slice :: proc (slice: [] $T) -> [] u8 {
    bytes  := cast([^] u8) raw_data(slice)
    length := size_of(T) * len(slice)
    
    result := bytes[:length]
    return result
}

// Draw and dispatch root structures must fit 256 bytes. Larger data belongs in GPU memory referenced by root pointers.
draw :: proc (commands: CommandBuffer, root: [] u8, vertex_count: u32, instance_count: u32 = 1, first_vertex: u32 = 0, first_instance: u32 = 0) {
    assert(commands != nil)
    
    emit_root_data(commands, root)
    
    vk.CmdDraw(commands.command_buffer, vertex_count, instance_count, first_vertex, first_instance)
}

draw_indexed :: proc (commands: CommandBuffer, root: [] u8, indices: GpuRange, type: IndexType, index_count: u32, instance_count: u32 = 1, first_index: u32 = 0, vertex_offset: i32 = 0, first_instance: u32 = 0) {
    assert(commands != nil && commands.device != nil)
    
    emit_root_data(commands, root)
    
    commands.device.fn.CmdBindIndexBuffer(commands.command_buffer, &vk.BindIndexBuffer3InfoKHR {
        sType = .BIND_INDEX_BUFFER_3_INFO_KHR,
        addressRange = to_vk(indices),
        addressFlags = address_flags,
        indexType    = to_vk(type),
    })
    vk.CmdDrawIndexed(commands.command_buffer, index_count, instance_count, first_index, vertex_offset, first_instance)
}

draw_indirect :: proc (commands: CommandBuffer, root: [] u8, arguments: GpuRange, draw_count: u32 = 1, stride: u32 = 0) {
    assert(commands != nil && commands.device != nil)
    
    emit_root_data(commands, root)
    
    commands.device.fn.CmdDrawIndirect(commands.command_buffer, &vk.DrawIndirect2InfoKHR {
        sType = .DRAW_INDIRECT_2_INFO_KHR,
        addressRange = {
            address = to_vk(arguments).address,
            size    = to_vk(arguments).size,
            stride  = stride == 0 ? size_of(vk.DrawIndirectCommand) : cast(vk.DeviceSize) stride,
        },
        addressFlags = address_flags,
        drawCount    = draw_count,
    })
}

draw_indexed_indirect :: proc (commands: CommandBuffer, root: [] u8, indices: GpuRange, type: IndexType, arguments: GpuRange, draw_count: u32 = 1, stride: u32 = 0) {
    assert(commands != nil && commands.device != nil)
    
    emit_root_data(commands, root)
    
    commands.device.fn.CmdBindIndexBuffer(commands.command_buffer, &vk.BindIndexBuffer3InfoKHR {
        sType = .BIND_INDEX_BUFFER_3_INFO_KHR,
        addressRange = to_vk(indices),
        addressFlags = address_flags,
        indexType    = to_vk(type),
    })
    commands.device.fn.CmdDrawIndexedIndirect(commands.command_buffer, &vk.DrawIndirect2InfoKHR {
        sType = .DRAW_INDIRECT_2_INFO_KHR,
        addressRange = {
            address = to_vk(arguments).address,
            size    = to_vk(arguments).size,
            stride  = stride == 0 ? size_of(vk.DrawIndexedIndirectCommand) : cast(vk.DeviceSize) stride,
        },
        addressFlags = address_flags,
        drawCount    = draw_count,
    })
}

dispatch :: proc (commands: CommandBuffer, root: [] u8, group_count: u32x3) {
    assert(commands != nil)
    
    emit_root_data(commands, root)
    
    vk.CmdDispatch(commands.command_buffer, group_count.x, group_count.y, group_count.z)
}

dispatch_indirect :: proc (commands: CommandBuffer, root: [] u8, arguments: GpuRange) {
    assert(commands != nil && commands.device != nil)
    
    emit_root_data(commands, root)
    
    commands.device.fn.CmdDispatchIndirect(commands.command_buffer, &vk.DispatchIndirect2InfoKHR {
        sType = .DISPATCH_INDIRECT_2_INFO_KHR,
        addressRange = to_vk(arguments),
        addressFlags = address_flags,
    })
}

draw_meshlets :: proc (commands: CommandBuffer, root: [] u8, group_count: u32x3) {
    assert(commands != nil && commands.device != nil)
    
    emit_root_data(commands, root)
    
    commands.device.fn.CmdDrawMeshTasks(commands.command_buffer, group_count.x, group_count.y, group_count.z)
}


draw_meshlets_indexed :: proc (commands: CommandBuffer, root: [] u8, arguments: GpuRange, draw_count: u32 = 1, stride: u32 = 0) {
    assert(commands != nil && commands.device != nil)
    
    emit_root_data(commands, root)
    
    commands.device.fn.CmdDrawMeshTasksIndirect(commands.command_buffer, &vk.DrawIndirect2InfoKHR {
        sType = .DRAW_INDIRECT_2_INFO_KHR,
        addressRange = {
            address = to_vk(arguments).address,
            size    = to_vk(arguments).size,
            stride  = stride == 0 ? size_of(vk.DrawMeshTasksIndirectCommandEXT) : cast(vk.DeviceSize) stride,
        },
        addressFlags = address_flags,
        drawCount    = draw_count,
    })
}

////////////////////////////////////////////////

get_texture_format_info :: proc (format: Format) -> TextureFormatInfo {
    switch format {
    case .r8_srgb, .r8_unorm, .r8_uint, .s8_uint:
        return {
            block_extent    = { 1, 1 },
            bytes_per_block = 1,
            depth           = false,
            stencil         = format == .s8_uint,
        }
    
    case .rg8_srgb, .rgba4_unorm, .r5g5b5a1_unorm, .r5g6b5_unorm, .rg8_unorm, .r16_unorm, .rg8_uint, .r16_uint, .r16_float, .d16_unorm:
        return {
            block_extent    = { 1, 1 },
            bytes_per_block = 2,
            depth           = format == .d16_unorm,
            stencil         = false,
        }
    
    case .rgba8_srgb, .bgra8_srgb, .rgba8_unorm, .bgra8_unorm, .rg16_unorm, .rgba8_uint, .bgra8_uint, .rg16_uint, .r32_uint, .rg16_float, .r32_float, .rgb10a2_unorm, .rg11b10_float, .d24_unorm_s8_uint, .d32_float:
        return {
            block_extent    = { 1, 1 },
            bytes_per_block = 4,
            depth           = format == .d24_unorm_s8_uint || format == .d32_float,
            stencil         = format == .d24_unorm_s8_uint,
        }
    
    case .rgba16_unorm, .rgba16_uint, .rg32_uint, .rgba16_float, .rg32_float, .d32_float_s8_uint:
        return {
            block_extent    = { 1, 1 },
            bytes_per_block = 8,
            depth           = format == .d32_float_s8_uint,
            stencil         = format == .d32_float_s8_uint,
        }
    
    case .rgb32_uint, .rgb32_float:
        return {
            block_extent    = { 1, 1 },
            bytes_per_block = 12,
        }
    
    case .rgba32_uint, .rgba32_float:
        return {
            block_extent    = { 1, 1 },
            bytes_per_block = 16,
        }
    
    case .eac_rg, .astc_4x4_srgb, .astc_4x4_unorm, .bc3_srgb, .bc3_unorm, .bc5_rg, .bc6h_ufloat, .bc6h_sfloat, .bc7_srgb, .bc7_unorm:
        return {
            block_extent    = { 4, 4 },
            bytes_per_block = 16,
        }
    case .undefined: return {}
    }
    
    unreachable()
}