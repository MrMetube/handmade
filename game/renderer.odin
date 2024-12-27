package game

RenderGroup :: struct {
    default_basis: ^RenderBasis,
    meters_to_pixels: f32,
    
    // TODO(viktor): pls no raw data, maybe a union once EntityVisiblePiece isnt the only type
    push_buffer: []u8,
    push_buffer_size: u32,
}

RenderBasis :: struct {
    p: v3,
}

EntityVisiblePiece :: struct {
    basis: ^RenderBasis,
    bitmap: ^LoadedBitmap,
    bitmap_focus: [2]i32,
    offset: v3,

    color: GameColor,
    dim: v2,
}


make_render_group :: proc(arena: ^Arena, max_push_buffer_size: u32, meters_to_pixels: f32) -> (result: ^RenderGroup) {
    result = push(arena, RenderGroup)
    result^ = {}
    result.push_buffer = push(arena, u8, max_push_buffer_size)
    
    result.meters_to_pixels = meters_to_pixels
    result.push_buffer_size = 0
    
    result.default_basis = push(arena, RenderBasis)
    result.default_basis.p = {0,0,0}
    
    return result
}

push_render_element :: #force_inline proc(group: ^RenderGroup, $T: typeid) -> (result: ^T) {
    size := cast(u32) size_of(T)
    if group.push_buffer_size + size < auto_cast len(group.push_buffer) {
        result = cast(^T) &group.push_buffer[group.push_buffer_size]
        group.push_buffer_size += size
    } else {
        unreachable()
    }
    
    return result
}

push_piece :: #force_inline proc(group: ^RenderGroup, bitmap: ^LoadedBitmap, dim: v2, offset: v3, color: GameColor, focus: [2]i32) {
    piece := push_render_element(group, EntityVisiblePiece)
    
    piece.basis        = group.default_basis
    piece.bitmap       = bitmap
    piece.offset.xy    = {offset.x, -offset.y} * group.meters_to_pixels
    piece.offset.z     = offset.z
    piece.dim          = dim * group.meters_to_pixels
    piece.color        = color
    piece.bitmap_focus = focus
}

push_bitmap :: #force_inline proc(group: ^RenderGroup, bitmap: ^LoadedBitmap, offset := v3{}, alpha: f32 = 1, focus := [2]i32{}) {
    push_piece(group, bitmap, {}, offset, {1,1,1, alpha}, focus)
}

push_rectangle :: #force_inline proc(group: ^RenderGroup, dim: v2, offset:v3, color: GameColor) {
    push_piece(group, nil, dim, offset, color, {})
}

push_rectangle_outline :: #force_inline proc(group: ^RenderGroup, dim: v2, offset:v3, color: GameColor, thickness: f32 = 0.1) {
    // NOTE(viktor): Top and Bottom
    push_piece(group, nil, {dim.x+thickness, thickness}, offset - {0, dim.y*0.5, 0}, color, {})
    push_piece(group, nil, {dim.x+thickness, thickness}, offset + {0, dim.y*0.5, 0}, color, {})

    // NOTE(viktor): Left and Right
    push_piece(group, nil, {thickness, dim.y-thickness}, offset - {dim.x*0.5, 0, 0}, color, {})
    push_piece(group, nil, {thickness, dim.y-thickness}, offset + {dim.x*0.5, 0, 0}, color, {})
}

push_hitpoints :: proc(group: ^RenderGroup, entity: ^Entity, offset_y: f32) {
    if entity.hit_point_max > 1 {
        health_size: v2 = 0.1
        spacing_between: f32 = health_size.x * 1.5
        health_x := -0.5 * (cast(f32) entity.hit_point_max - 1) * spacing_between/*  + entity.size.x/2 */

        for index in 0..<entity.hit_point_max {
            hit_point := entity.hit_points[index]
            color := hit_point.filled_amount == 0 ? Gray : Red
            push_rectangle(group, health_size, {health_x, -offset_y, 0}, color)
            health_x += spacing_between
        }
    }

}
