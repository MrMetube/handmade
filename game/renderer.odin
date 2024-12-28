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
    
    color: v4,
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
    
    color: v4,
    dim: v2,
}

RenderGroupEntryCoordinateSystem :: struct {
    using header: RenderGroupEntryHeader,
    
    origin, x_axis, y_axis: v2,
    texture: LoadedBitmap,
    alpha: f32,
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

push_rectangle :: #force_inline proc(group: ^RenderGroup, dim: v2, offset:v3, color: v4) {
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

push_rectangle_outline :: #force_inline proc(group: ^RenderGroup, dim: v2, offset:v3, color: v4, thickness: f32 = 0.1) {
    // NOTE(viktor): Top and Bottom
    push_rectangle(group, {dim.x+thickness, thickness}, offset - {0, dim.y*0.5, 0}, color)
    push_rectangle(group, {dim.x+thickness, thickness}, offset + {0, dim.y*0.5, 0}, color)

    // NOTE(viktor): Left and Right
    push_rectangle(group, {thickness, dim.y-thickness}, offset - {dim.x*0.5, 0, 0}, color)
    push_rectangle(group, {thickness, dim.y-thickness}, offset + {dim.x*0.5, 0, 0}, color)
}

coordinate_system :: #force_inline proc(group: ^RenderGroup, origin, x_axis, y_axis: v2, texture: LoadedBitmap, alpha:f32= 1) {
    entry := push_render_element(group, RenderGroupEntryCoordinateSystem)

    if entry != nil {
        entry.origin = origin
        entry.x_axis = x_axis
        entry.y_axis = y_axis
        
        entry.texture = texture
        entry.alpha   = alpha
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
            
            draw_rectangle_slowly(target, entry.origin, entry.x_axis, entry.y_axis, entry.texture, clamp_01(entry.alpha))
            
            p := entry.origin
            x := p + entry.x_axis
            y := p + entry.y_axis
            size := v2{10, 10}
            
            draw_rectangle(target, p, size, Red)
            draw_rectangle(target, x, size, Red * 0.7)
            draw_rectangle(target, y, size, Red * 0.7)
        case:
            unreachable()
        }
    }
}

draw_bitmap :: proc(buffer: LoadedBitmap, bitmap: LoadedBitmap, center: v2, alpha: f32, focus := [2]i32{} ) {
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
            
            sa := cast(f32) src.a / 255 * alpha
            sr := cast(f32) src.r * alpha
            sg := cast(f32) src.g * alpha
            sb := cast(f32) src.b * alpha
            
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

draw_rectangle_slowly :: proc(buffer: LoadedBitmap, origin, x_axis, y_axis: v2, texture: LoadedBitmap, alpha: f32) {
    min, max: [2]i32 = max(i32), min(i32)
    for p in ([?]v2{origin, origin + x_axis, origin + y_axis, origin + x_axis + y_axis}) {
        p_floor := floor(p)
        p_ceil := ceil(p)
        
        if p_floor.x < min.x do min.x = p_floor.x
        if p_floor.y < min.y do min.y = p_floor.y
        if p_ceil.x  > max.x do max.x = p_ceil.x
        if p_ceil.y  > max.y do max.y = p_ceil.y
    }
    
    max.x = clamp(max.x, 0, buffer.width-1)
    max.y = clamp(max.x, 0, buffer.height-1)
    min.x = clamp(min.x, 0, buffer.width-1)
    min.y = clamp(min.y, 0, buffer.height-1)
    
    inv_x_len_squared := 1 / length_squared(x_axis)
    inv_y_len_squared := 1 / length_squared(y_axis)
    
    for y in min.y..=max.y {
        for x in min.x..=max.x {
            pixel := vec_cast(f32, x, y)
            delta := pixel - origin
            edge0 := dot(delta                  , -perpendicular(x_axis))
            edge1 := dot(delta - x_axis         , -perpendicular(y_axis))
            edge2 := dot(delta - x_axis - y_axis,  perpendicular(x_axis))
            edge3 := dot(delta - y_axis         ,  perpendicular(y_axis))
            
            if edge0 < 0 && edge1 < 0 && edge2 < 0 && edge3 < 0 {
                u := dot(delta, x_axis) * inv_x_len_squared
                v := dot(delta, y_axis) * inv_y_len_squared
                
                // TODO(viktor): this epsilon should not exists
                EPSILON :: 0.000001
                assert(u + EPSILON >= 0 && u - EPSILON <= 1)
                assert(v + EPSILON >= 0 && v - EPSILON <= 1)
                
                uv := v2{u,v}
                // TODO(viktor): formalize texture boundaries
                t  := uv * vec_cast(f32, texture.width-2, texture.height-2)
                s := vec_cast(i32, t)
                f := t - vec_cast(f32, s)
                
                assert(s.x >= 0 && s.x < texture.width)
                assert(s.y >= 0 && s.y < texture.height)
                
                
                raw_texel00 := texture.memory[texture.start + (s.y + 0) * texture.pitch + (s.x + 0)]
                raw_texel01 := texture.memory[texture.start + (s.y + 0) * texture.pitch + (s.x + 1)]
                raw_texel10 := texture.memory[texture.start + (s.y + 1) * texture.pitch + (s.x + 0)]
                raw_texel11 := texture.memory[texture.start + (s.y + 1) * texture.pitch + (s.x + 1)]
                
                texel00 := vec_cast(f32, raw_texel00.r, raw_texel00.g, raw_texel00.b, raw_texel00.a)
                texel01 := vec_cast(f32, raw_texel01.r, raw_texel01.g, raw_texel01.b, raw_texel01.a)
                texel10 := vec_cast(f32, raw_texel10.r, raw_texel10.g, raw_texel10.b, raw_texel10.a)
                texel11 := vec_cast(f32, raw_texel11.r, raw_texel11.g, raw_texel11.b, raw_texel11.a)
                
                texel := vec_cast(u8, lerp( lerp(texel00, texel01, f.x), lerp(texel10, texel11, f.x), f.y) )
                
                pixel := &buffer.memory[buffer.start + y * buffer.pitch + x]
                
                sa   := alpha * cast(f32) texel.a / 255
                srgb := alpha * vec_cast(f32, texel.rgb)
                
                da := cast(f32) pixel.a / 255
                inv_alpha := 1 - sa
                
                pixel.a = cast(u8) (255 * (sa + da - sa * da))
                pixel.r = cast(u8) (inv_alpha * cast(f32) pixel.r + srgb.r)
                pixel.g = cast(u8) (inv_alpha * cast(f32) pixel.g + srgb.g)
                pixel.b = cast(u8) (inv_alpha * cast(f32) pixel.b + srgb.b)
            }
        }
    }
}

draw_rectangle :: proc(buffer: LoadedBitmap, center: v2, size: v2, color: v4){
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
            // TODO(viktor): should use pitch here
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