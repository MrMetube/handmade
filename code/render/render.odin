package render

import win "core:sys/windows"

@(common)
Render_State :: struct {
    initialized:  bool,
    vulkan:     Vulkan,
    
    game:     GameApi,
    platform: Platform_Api,
}

////////////////////////////////////////////////

render_state: ^Render_State

@(export)
init :: proc (state: ^Render_State, window: win.HWND) {
    assert(!state.initialized)
    
    render_state = state
    render_state.initialized = true
    init_vulkan(&render_state.vulkan, window)
}

@(export)
unload :: proc () {
    assert(render_state.initialized)
    unload_vulkan(&render_state.vulkan)
}

@(export)
hotreload :: proc (state: ^Render_State) {
    render_state = state
    hotreload_vulkan(&render_state.vulkan)
}

@(export)
deinit :: proc () {
    assert(render_state.initialized)
    deinit_vulkan(&render_state.vulkan)
    render_state^ = {}
}

////////////////////////////////////////////////

@(export)
allocate_texture :: proc (bitmap: Bitmap, set_as_nil_texture: bool) -> u32 {
    result := vk_allocate_texture(&render_state.vulkan, bitmap, set_as_nil_texture)
    return result
}

@(export)
manage_textures :: proc (last: ^TextureOp) {
    vk_manage_textures(&render_state.vulkan, last)
}

////////////////////////////////////////////////

@(export)
render :: proc (commands: ^RenderCommands, draw_region: Rectangle2i, window_dimension: iv2) {
    commands.clear_color.rgb = square(commands.clear_color.rgb)
    
    render_commands(&render_state.vulkan, commands, draw_region, window_dimension)
}

////////////////////////////////////////////////

begin_timed_block :: proc (name: string, loc := #caller_location) {
    render_state.game.begin_timed_block(name, loc)
}
end_timed_block :: proc () {
    render_state.game.end_timed_block()
}

@(deferred_none=end_timed_block)
timed_block :: proc (name: string, loc := #caller_location) {
    begin_timed_block(name, loc)
}

@(deferred_out=end_timed_block)
timed_function :: proc (loc := #caller_location) {
    begin_timed_block(loc.procedure, loc)
}

debug_end_data_block :: proc () {
    render_state.game.debug_end_data_block()
}

@(deferred_out=debug_end_data_block)
debug_data_block :: proc (name: string, loc := #caller_location) {
    render_state.game.debug_begin_data_block(name, loc)
}

debug_record_i32 :: proc (value: ^i32, name: string = #caller_expression(value)) {
    render_state.game.debug_record_i32(value, name)
}