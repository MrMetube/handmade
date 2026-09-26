package render

/* @todo
    iterate on reducing the generated file count and Api structs and game-static vs. game-dynamic differentiation
      make sure the only game code that can be called from outside is helper code
        check all @(common) procs
        reduce global variables
    
    delete platform_api.odin from render (and game)
    
    reduce the api surface overall for render, game and platform between each other
    
    on reload all allocated textures are lost, we need to realloc them
*/ 

import "base:runtime"
import win "core:sys/windows"

import gpu "./no_graphics_api"

@(common)
Render_State :: struct {
    initialized:  bool,
    backend:      Backend,
    
    // These are CPU-side owners of persistent driver objects. The storage is
    // supplied by the platform and is deliberately not part of the DLL image.
    gl_context: win.HGLRC,
    open_gl:    OpenGL,
    vulkan:     Vulkan,
    
    game: GameApi, // already set by the platform
    platform: Platform_Api,
}

@(common)
Backend :: enum {
    Software,
    OpenGL,
    Vulkan,
}

@(common)
Reload_Action :: enum {
    Reload,
    Shutdown,
}

@(common)
Render_Params :: struct {
    render_queue:     ^WorkQueue,
    frame_allocator:  Allocator,
    window_dimension: v2i,
    software_target:  Bitmap,
    single_threaded:  bool,
}

////////////////////////////////////////////////

render_state: ^Render_State

@(export)
attach :: proc (state: ^Render_State, window: win.HWND, window_dc: win.HDC, backend: Backend) -> bool {
    render_state = state
    
    if render_state.initialized && render_state.backend != backend {
        reload_or_shutdown(.Shutdown)
        /* @todo :BackendSwitching:
            - all work using the old backend must be complete
            - the old backend must release resources that cannot survive the switch
            - the new backend must be initialized before rendering resumes
            - backend-owned handles stored outside the renderer must be invalidated
            - pending texture operations and render commands must not use old handles
            - resident textures and the white texture must have handles for the new backend
        */
        unimplemented("backend switching")
    }
    
    result: bool
    if !render_state.initialized {
        render_state.backend = backend
        switch render_state.backend {
        case .Vulkan:  init_vulkan(&render_state.vulkan, window)
        case .OpenGL:  render_state.gl_context = init_opengl(&render_state.open_gl, window_dc)
        case .Software: // nothing
        }
        
        render_state.initialized = true
        result = true
    } else {
        render_state.backend = backend
        
        // A DLL reload resets package-level dispatch tables, but must not replace
        // the actual graphics context/device or any resource handles.
        switch render_state.backend {
        case .Vulkan:   result = rebind_device(render_state.vulkan.device)
        case .OpenGL:   result = reattach_opengl(window_dc, render_state.gl_context)
        case .Software: result = true
        }
    }
    
    return result
}

@(export)
reload_or_shutdown :: proc (action: Reload_Action) {
    if !render_state.initialized do return
    
    switch render_state.backend {
    case .Vulkan:
        switch action {
        case .Reload:   vk_reload(&render_state.vulkan)
        case .Shutdown: vk_shutdown(&render_state.vulkan)
        }
        
    case .OpenGL:   gl_shutdown(render_state.gl_context, action == .Shutdown)
    case .Software: // nothing
    }
    
    if action == .Shutdown do render_state^ = {}
}

////////////////////////////////////////////////

@(export)
allocate_texture :: proc (bitmap: Bitmap, set_as_nil_texture: bool) -> u32 {
    result: u32
    switch render_state.backend {
    case .Vulkan:   result = vk_allocate_texture(&render_state.vulkan, bitmap, set_as_nil_texture)
    case .OpenGL:   result = gl_allocate_texture(&render_state.open_gl, bitmap)
    case .Software: unimplemented()
    }
    return result
}

@(export)
manage_textures :: proc (last: ^TextureOp) {
    switch render_state.backend {
    case .Vulkan:   vk_manage_textures(&render_state.vulkan, last)
    case .OpenGL:   gl_manage_textures(&render_state.open_gl, last)
    case .Software: unimplemented()
    }
}

////////////////////////////////////////////////

@(export)
render :: proc (commands: ^RenderCommands, draw_region: Rectangle2i, params: Render_Params) {
    commands.clear_color.rgb = square(commands.clear_color.rgb)
    
    switch render_state.backend {
    case .Software:
        software_render_commands(params.render_queue, commands, params.software_target, params.frame_allocator, params.single_threaded)
        if true { unimplemented("differentiate software+opengl from software+vulkan") }
        gl_display_bitmap(&render_state.open_gl, params.software_target, draw_region, commands.clear_color)
        
    case .OpenGL: gl_render_commands(&render_state.open_gl, commands, draw_region, params.window_dimension)
    case .Vulkan: vk_render_commands(&render_state.vulkan, commands, draw_region, params.window_dimension)
    }
}

////////////////////////////////////////////////

end_timed_block :: proc () {
    render_state.game.end_timed_block()
}

@(deferred_none=end_timed_block)
timed_block :: proc (name: string, loc := #caller_location) {
    render_state.game.begin_timed_block(name, loc)
}

@(deferred_out=end_timed_block)
timed_function :: proc (loc := #caller_location) {
    render_state.game.begin_timed_block(loc.procedure, loc)
}

debug_end_data_block :: proc () {
    render_state.game.debug_end_data_block()
}

@(deferred_out=debug_end_data_block)
debug_data_block :: proc (name: string, loc := #caller_location) {
    render_state.game.debug_begin_data_block(name, loc)
}