package render

/* @todo
    the renderer hotreload needs to be unshittified and compressed with the game hotreload
    
    iterate on reducing the generated file count and Api structs and game-static vs. game-dynamic differentiation
      make sure the only game code that can be called from outside is helper code
        check all @(common) procs
        reduce global variables
    
    delete platform_api.odin from render (and game)
        
    reduce the api surface overall for render, game and platform between each other
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

////////////////////////////////////////////////

render_state: ^Render_State

// @todo struct for all lose params
@(export)
attach :: proc (state: ^Render_State, window: win.HWND, window_dc: win.HDC, backend: Backend) -> bool {
    render_state = state
    open_gl = &render_state.open_gl
    vulkan  = &render_state.vulkan
    
    // Layout changes need an explicit migration. Refuse the reload rather than
    // interpreting live driver state with a different struct definition.
    // @todo handle backend changed
    if render_state.initialized && render_state.backend != backend {
        reload_or_shutdown(.Shutdown)
        // @incomplete
        return false
    }
    
    result: bool
    if !render_state.initialized {
        render_state.backend = backend
        switch render_state.backend {
        case .Vulkan:  init_vulkan(window)
        case .OpenGL:  render_state.gl_context = init_opengl(window_dc)
        case .Software: // nothing
        }
        
        render_state.initialized = true
        result = true
    } else {
        render_state.backend = backend
        
        // A DLL reload resets package-level dispatch tables, but must not replace
        // the actual graphics context/device or any resource handles.
        switch render_state.backend {
        case .Vulkan:   result = rebind_device(vulkan.device)
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
        case .Reload:   vk_reload()
        case .Shutdown: vk_shutdown()
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
    case .Vulkan:   result = vk_allocate_texture(bitmap, set_as_nil_texture)
    case .OpenGL:   result = gl_allocate_texture(bitmap)
    case .Software: unimplemented()
    }
    return result
}

@(export)
manage_textures :: proc (last: ^TextureOp) {
    switch render_state.backend {
    case .Vulkan:   vk_manage_textures(last)
    case .OpenGL:   gl_manage_textures(last)
    case .Software: unimplemented()
    }
}

////////////////////////////////////////////////

// @todo struct for all lose params
@(export)
render :: proc (commands: ^RenderCommands, render_queue: ^WorkQueue, draw_region: Rectangle2i, frame_allocator: Allocator, window_dimension: v2i, software_target: Bitmap, single_threaded: bool) {
    commands.clear_color.rgb = square(commands.clear_color.rgb)
    
    switch render_state.backend {
    case .Software:
        software_render_commands(auto_cast render_queue, commands, software_target, frame_allocator, single_threaded)
        if true { unimplemented("differentiate software+opengl from software+vulkan") }
        gl_display_bitmap(software_target, draw_region, commands.clear_color)
        
    case .OpenGL: gl_render_commands(commands, draw_region, window_dimension)
    case .Vulkan: vk_render_commands(commands, draw_region, window_dimension)
    }
}

////////////////////////////////////////////////

// @hack for generated game api
GlobalDebugTable: pmm

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