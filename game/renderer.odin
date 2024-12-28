package game

import "core:fmt"

RenderGroup :: struct {
    default_basis: ^RenderBasis,
    meters_to_pixels: f32,
    
    push_buffer: []u8,
    push_buffer_size: u32,
}

RenderBasis :: struct {
    p: v3,
}

// NOTE(viktor): RenderGroupEntry is a "compact discriminated union"
// TODO(viktor): remove the header
RenderGroupEntryHeader :: struct {
    type: enum {
        Clear, Rectangle, Bitmap, CoordinateSystem
    }
}

RenderGroupEntryBasis :: struct {
    basis: ^RenderBasis,
    offset: v3,
}

RenderGroupEntryClear :: struct {
    using header: RenderGroupEntryHeader,
    
    color: GameColor,
}

RenderGroupEntryBitmap :: struct {
    using header: RenderGroupEntryHeader,
    
    using rendering_basis: RenderGroupEntryBasis,
    
    alpha: f32,
    bitmap: LoadedBitmap,
    bitmap_focus: [2]i32,
}

RenderGroupEntryRectangle :: struct {
    using header: RenderGroupEntryHeader,
    
    using rendering_basis: RenderGroupEntryBasis,
    
    color: GameColor,
    dim: v2,
}

RenderGroupEntryCoordinateSystem :: struct {
    using header: RenderGroupEntryHeader,
    
    origin, x_axis, y_axis: v2,
    points: []v2,
    color: GameColor,
}


make_render_group :: proc(arena: ^Arena, max_push_buffer_size: u32, meters_to_pixels: f32) -> (result: ^RenderGroup) {
    result = push(arena, RenderGroup)
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
        
        id := typeid_of(T)
        switch id {
        case RenderGroupEntryClear:            result.type = .Clear
        case RenderGroupEntryRectangle:        result.type = .Rectangle
        case RenderGroupEntryBitmap:           result.type = .Bitmap
        case RenderGroupEntryCoordinateSystem: result.type = .CoordinateSystem
        case: fmt.panicf("Unhandled RenderGroupEntry type: %v", type_info_of(id))
        }
    } else {
        unreachable()
    }
    
    return result
}

push_bitmap :: #force_inline proc(group: ^RenderGroup, bitmap: LoadedBitmap, offset := v3{}, alpha: f32 = 1, focus := [2]i32{}) {
    entry := push_render_element(group, RenderGroupEntryBitmap)
    
    if entry != nil {
        entry.basis        = group.default_basis
        entry.bitmap       = bitmap
        entry.offset.xy    = {offset.x, -offset.y} * group.meters_to_pixels
        entry.offset.z     = offset.z
        entry.alpha        = alpha
        entry.bitmap_focus = focus
    }
}

push_rectangle :: #force_inline proc(group: ^RenderGroup, dim: v2, offset:v3, color: GameColor) {
    entry := push_render_element(group, RenderGroupEntryRectangle)

    if entry != nil {
        half_dim := group.meters_to_pixels * entry.dim * 0.5

        entry.basis     = group.default_basis
        entry.offset.xy = {offset.x, -offset.y} * group.meters_to_pixels + half_dim * {-1,1}
        entry.offset.z  = offset.z
        entry.color     = color
        entry.dim       = dim * group.meters_to_pixels
    }
}

push_rectangle_outline :: #force_inline proc(group: ^RenderGroup, dim: v2, offset:v3, color: GameColor, thickness: f32 = 0.1) {
    // NOTE(viktor): Top and Bottom
    push_rectangle(group, {dim.x+thickness, thickness}, offset - {0, dim.y*0.5, 0}, color)
    push_rectangle(group, {dim.x+thickness, thickness}, offset + {0, dim.y*0.5, 0}, color)

    // NOTE(viktor): Left and Right
    push_rectangle(group, {thickness, dim.y-thickness}, offset - {dim.x*0.5, 0, 0}, color)
    push_rectangle(group, {thickness, dim.y-thickness}, offset + {dim.x*0.5, 0, 0}, color)
}

coordinate_system :: #force_inline proc(group: ^RenderGroup, origin, x_axis, y_axis: v2, color: GameColor, points: []v2) {
    entry := push_render_element(group, RenderGroupEntryCoordinateSystem)

    if entry != nil {
        entry.origin = origin
        entry.x_axis = x_axis
        entry.y_axis = y_axis
        
        entry.color = color
        entry.points = points
    }
}

push_hitpoints :: proc(group: ^RenderGroup, entity: ^Entity, offset_y: f32) {
    if entity.hit_point_max > 1 {
        health_size: v2 = 0.1
        spacing_between: f32 = health_size.x * 1.5
        health_x := -0.5 * (cast(f32) entity.hit_point_max - 1) * spacing_between

        for index in 0..<entity.hit_point_max {
            hit_point := entity.hit_points[index]
            color := hit_point.filled_amount == 0 ? Gray : Red
            push_rectangle(group, health_size, {health_x, -offset_y, 0}, color)
            health_x += spacing_between
        }
    }

}

clear :: proc(group: ^RenderGroup, color: v4) {
    entry := push_render_element(group, RenderGroupEntryClear)
    if entry != nil {
        entry.color = color
    }
}

get_render_entity_basis_p :: #force_inline proc(group: ^RenderGroup, entry: RenderGroupEntryBasis, screen_center:v2) -> (result: v2) {
    base_p := entry.basis.p
    z_fudge := 1 + 0.05 * (base_p.z + entry.offset.z)
    
    result = screen_center + group.meters_to_pixels * z_fudge * (base_p.xy) * {1, -1} + entry.offset.xy
    result.y -= group.meters_to_pixels * base_p.z 
    
    return result
}

render_to_output :: proc(group: ^RenderGroup, target: LoadedBitmap) {
    screen_size   := vec_cast(f32, target.width, target.height)
    screen_center := screen_size * 0.5

    for base_address: u32 = 0; base_address < group.push_buffer_size; {
        typeless_entry := cast(^RenderGroupEntryHeader) &group.push_buffer[base_address]
        switch typeless_entry.type {
        case .Clear:
            entry := cast(^RenderGroupEntryClear) typeless_entry
            base_address += auto_cast size_of(entry^)
            
            draw_rectangle(target, screen_center, screen_size, entry.color)
        case .Rectangle:
            entry := cast(^RenderGroupEntryRectangle) typeless_entry
            base_address += auto_cast size_of(entry^)
            
            p := get_render_entity_basis_p(group, entry, screen_center)
            draw_rectangle(target, p, entry.dim, entry.color)
        case .Bitmap:
            entry := cast(^RenderGroupEntryBitmap) typeless_entry
            base_address += auto_cast size_of(entry^)
            
            p := get_render_entity_basis_p(group, entry, screen_center)
            draw_bitmap(target, entry.bitmap, p, clamp_01(entry.alpha), entry.bitmap_focus)
        case .CoordinateSystem:
            entry := cast(^RenderGroupEntryCoordinateSystem) typeless_entry
            base_address += auto_cast size_of(entry^)
            
            p := screen_center + entry.origin
            x := p + entry.x_axis
            y := p + entry.y_axis
            size := v2{10, 10}
            draw_rectangle(target, p, size, entry.color)
            draw_rectangle(target, x, size, entry.color * 0.7)
            draw_rectangle(target, y, size, entry.color * 0.7)
            
            for point in entry.points {
                pp := p + point.x * entry.x_axis + point.y * entry.y_axis
                draw_rectangle(target, pp, size/2, entry.color * 0.4)
            }
        case:
            unreachable()
        }
    }
}

draw_bitmap :: proc(buffer: LoadedBitmap, bitmap: LoadedBitmap, center: v2, c_alpha: f32 = 1, focus := [2]i32{} ) {
    rounded_center := round(center) + focus * {1, -1}

    left   := rounded_center.x - bitmap.width  / 2
    top	   := rounded_center.y - bitmap.height / 2
    right  := left + bitmap.width
    bottom := top  + bitmap.height

    src_left: i32
    src_top : i32
    if left < 0 {
        src_left = -left
        left = 0
    }
    if top < 0 {
        src_top = -top
        top = 0
    }
    bottom = min(bottom, buffer.height)
    right  = min(right,  buffer.width)

    src_row  := bitmap.start + bitmap.pitch * src_top + src_left
    dest_row := left + top * buffer.width
    for _ in top..< bottom  {
        src_index, dest_index := src_row, dest_row
        
        for _ in left..< right  {
            src := bitmap.memory[src_index]
            dst := &buffer.memory[dest_index]
            
            sa := cast(f32) src.a / 255 * c_alpha
            sr := cast(f32) src.r * c_alpha
            sg := cast(f32) src.g * c_alpha
            sb := cast(f32) src.b * c_alpha
            
            da := cast(f32) dst.a / 255
            inv_alpha := 1 - sa
            
            dst.a = cast(u8) (255 * (sa + da - sa * da))
            dst.r = cast(u8) (inv_alpha * cast(f32) dst.r + sr)
            dst.g = cast(u8) (inv_alpha * cast(f32) dst.g + sg)
            dst.b = cast(u8) (inv_alpha * cast(f32) dst.b + sb)
            
            src_index  += 1
            dest_index += 1
        }
        
        dest_row += buffer.pitch
        src_row  += bitmap.pitch
    }
}

draw_rectangle :: proc(buffer: LoadedBitmap, center: v2, size: v2, color: GameColor){
    rounded_center := floor(center)
    rounded_size   := floor(size)
    
    left   := rounded_center.x - rounded_size.x / 2
    top	   := rounded_center.y - rounded_size.y / 2
    right  := left + rounded_size.x
    bottom := top  + rounded_size.y
    
    if left < 0 do left = 0
    if top  < 0 do top  = 0
    if right  > buffer.width  do right  = buffer.width
    if bottom > buffer.height do bottom = buffer.height

    for y in top..<bottom {
        for x in left..<right {
            dst := &buffer.memory[y*buffer.width + x]
            src := color * 255

            dst.r = cast(u8) lerp(cast(f32) dst.r, src.r, clamp_01(color.a))
            dst.g = cast(u8) lerp(cast(f32) dst.g, src.g, clamp_01(color.a))
            dst.b = cast(u8) lerp(cast(f32) dst.b, src.b, clamp_01(color.a))
            // TODO(viktor): compute this
            dst.a = cast(u8) src.a
        }
    }
}