package game

import gl "vendor:OpenGL"

gl_do_tile_render_work : PlatformWorkQueueCallback : proc(data: rawpointer) {
    timed_function()
    using work := cast(^TileRenderWork) data

    assert(group != nil)
    assert(target.memory != nil)
    assert(group.inside_render)
    
    gl.Viewport(0, 0, target.width, target.height)
    
    // :PointerArithmetic
    sort_entries := (cast([^]TileSortEntry) &group.push_buffer[group.sort_entry_at])[:group.push_buffer_element_count]
    
    for sort_entry in sort_entries {
        header := cast(^RenderGroupEntryHeader) &group.push_buffer[sort_entry.push_buffer_offset]
        //:PointerArithmetic
        entry_data := &group.push_buffer[sort_entry.push_buffer_offset + size_of(RenderGroupEntryHeader)]
        
        switch header.type {
          case RenderGroupEntryClear:
            entry := cast(^RenderGroupEntryClear) entry_data
            
            color := entry.color
            gl.ClearColor(color.r, color.g, color.b, color.a)
            gl.Clear(gl.COLOR_BUFFER_BIT)
            
          case RenderGroupEntryRectangle:
            entry := cast(^RenderGroupEntryRectangle) entry_data
            
            gl_rectangle(entry.rect.min, entry.rect.max, entry.color)
            
          case RenderGroupEntryBitmap:
            entry := cast(^RenderGroupEntryBitmap) entry_data
            
            min := entry.p
            max := min + entry.size
            
            gl_rectangle(min, max, entry.color)
            // TODO(viktor): use the texture
            
          case RenderGroupEntryCoordinateSystem:
          case:
            panic("Unhandled Entry")
        }
    }
}

gl_rectangle :: proc(min, max: v2, color: v4) {
    @static vertex_array_object: u32
    
    vertices := [6]v2{
        min, { max.x, min.y}, max, // Lower triangle
        min, max, {min.x,  max.y}, // Upper triangle
    }
    @static init: b32
    if !init {
        init = true
        gl.GenVertexArrays(1, &vertex_array_object)
    }
    
    gl.BindVertexArray(vertex_array_object)
    
    gl.BufferData(gl.ARRAY_BUFFER, size_of(vertices), &vertices[0], gl.STATIC_DRAW)

    gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of(v2), 0)
    gl.EnableVertexAttribArray(0)
    
    
    gl.BindVertexArray(vertex_array_object)
    gl.DrawArrays(gl.TRIANGLES, 0, 6)
    gl.BindVertexArray(0)
}