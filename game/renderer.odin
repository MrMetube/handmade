package game

import "core:fmt"

RenderGroup :: struct {
    default_basis: ^RenderBasis,
    meters_to_pixels: f32,
    
    push_buffer: []u8,
    push_buffer_size: u32,
}

EnvironmentMap :: struct {
    LOD: [4]LoadedBitmap,
}

RenderBasis :: struct {
    p: v3,
}

// NOTE(viktor): RenderGroupEntry is a "compact discriminated union"
RenderGroupEntryHeader :: struct {
    type: typeid
}

RenderGroupEntryBasis :: struct {
    basis: ^RenderBasis,
    offset: v3,
}

RenderGroupEntryClear :: struct {
    color: v4,
}

RenderGroupEntrySaturation :: struct {
    level: f32
}

RenderGroupEntryBitmap :: struct {
    using rendering_basis: RenderGroupEntryBasis,
    
    alpha: f32,
    bitmap: LoadedBitmap,
    bitmap_focus: [2]i32,
}

RenderGroupEntryRectangle :: struct {
    using rendering_basis: RenderGroupEntryBasis,
    
    color: v4,
    dim: v2,
}

RenderGroupEntryCoordinateSystem :: struct {
    origin, x_axis, y_axis: v2,
    color: v4,
    texture, normal: LoadedBitmap,
    
    top, middle, bottom: EnvironmentMap,
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
    header_size := cast(u32) size_of(RenderGroupEntryHeader)
    size := cast(u32) size_of(T) + header_size
    if group.push_buffer_size + size < auto_cast len(group.push_buffer) {
        header := cast(^RenderGroupEntryHeader) &group.push_buffer[group.push_buffer_size]
        header.type = typeid_of(T)
        
        result = cast(^T) &group.push_buffer[group.push_buffer_size + header_size]
        
        group.push_buffer_size += size
    } else {
        unreachable()
    }
    
    return result
}

push_bitmap :: #force_inline proc(group: ^RenderGroup, offset:= v3{}, alpha: f32 = 1) -> (result: ^RenderGroupEntryBitmap) {
    result = push_render_element(group, RenderGroupEntryBitmap)
    
    if result != nil {
        result.basis        = group.default_basis
        result.alpha        = alpha
        result.offset.xy    = {offset.x, -offset.y} * group.meters_to_pixels
        result.offset.z     = offset.z
    }
    
    return result
}

// TODO(viktor): dont be a setter return the pointer and let the caller do the work
// But do keep the non-zero default values 
push_rectangle :: #force_inline proc(group: ^RenderGroup, dim: v2, offset:v3, color: v4) {
    entry := push_render_element(group, RenderGroupEntryRectangle)

    if entry != nil {
        half_dim := group.meters_to_pixels * entry.dim * 0.5

        entry.basis     = group.default_basis
        entry.offset.xy = {offset.x, -offset.y} * group.meters_to_pixels + half_dim * {-1,1}
        entry.dim       = dim * group.meters_to_pixels
        entry.offset.z  = offset.z
        entry.color     = color
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

coordinate_system :: #force_inline proc(group: ^RenderGroup, color: v4 = 1) -> (result: ^RenderGroupEntryCoordinateSystem) {
    result = push_render_element(group, RenderGroupEntryCoordinateSystem)

    if result != nil {
        result.color = color
    }
    
    return result
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

saturation :: proc(group: ^RenderGroup, level: f32) {
    entry := push_render_element(group, RenderGroupEntrySaturation)
    if entry != nil {
        entry.level = level
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
        header := cast(^RenderGroupEntryHeader) &group.push_buffer[base_address]
        base_address += size_of(RenderGroupEntryHeader)
        data := &group.push_buffer[base_address]
        
        switch header.type {
        case RenderGroupEntryClear:
            entry := cast(^RenderGroupEntryClear) data
            base_address += auto_cast size_of(entry^)
            
            draw_rectangle(target, screen_center, screen_size, entry.color)
        case RenderGroupEntrySaturation:
            entry := cast(^RenderGroupEntrySaturation) data
            base_address += auto_cast size_of(entry^)
            
            change_saturation(target, entry.level)
        case RenderGroupEntryRectangle:
            entry := cast(^RenderGroupEntryRectangle) data
            base_address += auto_cast size_of(entry^)
        when false {
            p := get_render_entity_basis_p(group, entry, screen_center)
            draw_rectangle(target, p, entry.dim, entry.color)
        }            
        case RenderGroupEntryBitmap:
            entry := cast(^RenderGroupEntryBitmap) data
            base_address += auto_cast size_of(entry^)
        when false {
            p := get_render_entity_basis_p(group, entry, screen_center)
            draw_bitmap(target, entry.bitmap, p, clamp_01(entry.alpha), entry.bitmap_focus)
        }
        case RenderGroupEntryCoordinateSystem:
            entry := cast(^RenderGroupEntryCoordinateSystem) data
            base_address += auto_cast size_of(entry^)
            
            draw_rectangle_slowly(target, entry.origin, entry.x_axis, entry.y_axis, entry.texture, entry.normal, entry.color, entry.top, entry.middle, entry.bottom)
            
            p := entry.origin
            x := p + entry.x_axis
            y := p + entry.y_axis
            size := v2{10, 10}
            
            draw_rectangle(target, p, size, Red)
            draw_rectangle(target, x, size, Red * 0.7)
            draw_rectangle(target, y, size, Red * 0.7)
            
        case:
            fmt.panicf("Unhandled Entry: %v", header.type)
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

    src_row := bitmap.start + bitmap.pitch * src_top + src_left
    dst_row := left + top * buffer.width
    for _ in top..< bottom  {
        src_index := src_row
        dst_index := dst_row
        defer dst_row += buffer.pitch
        defer src_row += bitmap.pitch
        
        for _ in left..< right  {
            src := bitmap.memory[src_index]
            dst := &buffer.memory[dst_index]
            defer src_index += 1
            defer dst_index += 1
            
            texel := vec_cast(f32, src)
            texel = srgb_255_to_linear_1(texel)
            texel *= alpha
            
            pixel := vec_cast(f32, dst^)
            pixel = srgb_255_to_linear_1(pixel)
            
            result := (1 - texel.a) * pixel + texel
            result = linear_1_to_srgb_255(result)
            
            dst^ = vec_cast(u8, result + 0.5)
        }
    }
}

change_saturation :: proc(buffer: LoadedBitmap, level: f32 ) {
    dst_row: i32
    for _ in 0..< buffer.height  {
        dst_index := dst_row
        defer dst_row += buffer.pitch
        
        for _ in 0..< buffer.width  {
            dst := &buffer.memory[dst_index]
            defer dst_index += 1
            
            pixel := vec_cast(f32, dst^)
            pixel = srgb_255_to_linear_1(pixel)
            
            // TODO(viktor): convert to hsv, adjust and convert back
            average := (1.0/3.0) * pixel.r + pixel.g + pixel.b
            delta := pixel.rgb - average
            
            result := V4(average + level * delta, pixel.a)
            result = linear_1_to_srgb_255(result)
            
            dst^ = vec_cast(u8, result + 0.5)
        }
    }
}

draw_rectangle_slowly :: proc(buffer: LoadedBitmap, origin, x_axis, y_axis: v2, texture, normal_map: LoadedBitmap, color: v4, top, middle, bottom: EnvironmentMap) {
    // NOTE(viktor): premultiply color
    color := color
    color.rgb *= color.a
    
    min, max: [2]i32 = max(i32), min(i32)
    for p in ([?]v2{origin, origin + x_axis, origin + y_axis, origin + x_axis + y_axis}) {
        p_floor := floor(p)
        p_ceil := ceil(p)
        
        if p_floor.x < min.x do min.x = p_floor.x
        if p_floor.y < min.y do min.y = p_floor.y
        if p_ceil.x  > max.x do max.x = p_ceil.x
        if p_ceil.y  > max.y do max.y = p_ceil.y
    }
    
    width_max      := buffer.width-1
    height_max     := buffer.height-1
    inv_width_max  := 1 / cast(f32) width_max
    inv_height_max := 1 / cast(f32) height_max
    
    max.x = clamp(max.x, 0, width_max)
    max.y = clamp(max.x, 0, height_max)
    min.x = clamp(min.x, 0, width_max)
    min.y = clamp(min.y, 0, height_max)
    
    inv_x_len_squared := 1 / length_squared(x_axis)
    inv_y_len_squared := 1 / length_squared(y_axis)
    
    for y in min.y..=max.y {
        for x in min.x..=max.x {
            pixel_p := vec_cast(f32, x, y)
            delta := pixel_p - origin
            edge0 := dot(delta                  , -perpendicular(x_axis))
            edge1 := dot(delta - x_axis         , -perpendicular(y_axis))
            edge2 := dot(delta - x_axis - y_axis,  perpendicular(x_axis))
            edge3 := dot(delta - y_axis         ,  perpendicular(y_axis))
            
            if edge0 < 0 && edge1 < 0 && edge2 < 0 && edge3 < 0 {
                screen_space_uv := pixel_p * {inv_width_max, inv_height_max}

                u := dot(delta, x_axis) * inv_x_len_squared
                v := dot(delta, y_axis) * inv_y_len_squared
                
                // TODO(viktor): this epsilon should not exists
                EPSILON :: 0.000001
                assert(u + EPSILON >= 0 && u - EPSILON <= 1)
                assert(v + EPSILON >= 0 && v - EPSILON <= 1)
                
                // TODO(viktor): formalize texture boundaries
                t := v2{u,v} * vec_cast(f32, texture.width-2, texture.height-2)
                s := vec_cast(i32, t)
                f := t - vec_cast(f32, s)
                
                assert(s.x >= 0 && s.x < texture.width)
                assert(s.y >= 0 && s.y < texture.height)

                t00, t01, t10, t11 := sample_bilinear(texture, s)
                
                t00 = srgb_255_to_linear_1(t00)
                t01 = srgb_255_to_linear_1(t01)
                t10 = srgb_255_to_linear_1(t10)
                t11 = srgb_255_to_linear_1(t11)
                
                texel := blend_bilinear(t00, t01, t10, t11, f)
                
                if normal_map.memory != nil {
                    normal := blend_bilinear(sample_bilinear(normal_map, s), f)
                    normal = unscale_and_bias(normal)
                    // TODO(viktor): do we really need this
                    normal = normalize(normal)
                    
                    // NOTE(viktor): the eye-vector is always assumed to be [0, 0, 1]
                    // This is just a simplified version of the reflection -e + 2 * dot(e, n) * n
                    bounce_direction := 2 * normal.z * normal.xyz
                    bounce_direction.z -= 1
                    
                    far_map: EnvironmentMap
                    t_environment := bounce_direction.y
                    t_far_map: f32
                    if  t_environment < -0.5 {
                        far_map = bottom
                        t_far_map = -1 - 2 * t_environment
                        bounce_direction.y = -bounce_direction.y
                    } else if t_environment > 0.5 {
                        far_map = top
                        t_far_map = (t_environment - 0.5) * 2
                    }

                    light_color := v3{} // TODO(viktor): how do we sample from the middle environment m?ap
                    if t_far_map > 0 {
                        far_map_color := sample_environment_map(screen_space_uv, bounce_direction, normal.w, far_map)
                        light_color = lerp(light_color, far_map_color, t_far_map)
                    }

                    texel.rgb += texel.a * light_color.rgb
                }

                texel *= color
                texel.rgb = clamp_01(texel.rgb)

                dst := &buffer.memory[buffer.start + y * buffer.pitch + x]
                pixel := srgb_255_to_linear_1(vec_cast(f32, dst^))
                
                
                blended := (1 - texel.a) * pixel + texel
                blended = linear_1_to_srgb_255(blended)
                
                dst^ = vec_cast(u8, blended)
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
            dst := &buffer.memory[buffer.start + y*buffer.pitch + x]
            src := color * 255

            dst.r = cast(u8) lerp(cast(f32) dst.r, src.r, clamp_01(color.a))
            dst.g = cast(u8) lerp(cast(f32) dst.g, src.g, clamp_01(color.a))
            dst.b = cast(u8) lerp(cast(f32) dst.b, src.b, clamp_01(color.a))
            // TODO(viktor): compute this
            dst.a = cast(u8) src.a
        }
    }
}

sample :: #force_inline proc(texture: LoadedBitmap, p: [2]i32) -> (result: v4) {
    texel := texture.memory[texture.start + p.y * texture.pitch + p.x]
    result = vec_cast(f32, texel)
    
    return result
}

sample_bilinear :: #force_inline proc(texture: LoadedBitmap, p: [2]i32) -> (s00, s01, s10, s11: v4) {
    s00 = sample(texture, p + {0, 0})
    s01 = sample(texture, p + {1, 0})
    s10 = sample(texture, p + {0, 1})
    s11 = sample(texture, p + {1, 1})
    
    return s00, s01, s10, s11
}
                    
sample_environment_map :: #force_inline proc(screen_space_uv: v2, sample_direction: v3, roughness: f32, environment_map: EnvironmentMap) -> (result: v3) {
    assert(environment_map.LOD[0].memory != nil)
    
    lod_index := cast(i32) (roughness * cast(f32) (len(environment_map.LOD)-1) + 0.5)
    lod := environment_map.LOD[lod_index]
    lod_size := vec_cast(f32, lod.width, lod.height)
    
    assert(sample_direction.y > 0)
    distance_from_map_in_z :: 1
    uvs_per_meter :: 0.01
    c := (uvs_per_meter * distance_from_map_in_z) / sample_direction.y
    // TODO(viktor): make sure we know what direction z should go in y
    offset := c * sample_direction.xz
    uv := screen_space_uv + offset
    uv = clamp_01(uv)
    
    t        := uv * (lod_size - 2)
    index    := vec_cast(i32, t)
    fraction := t - vec_cast(f32, index)
    
    assert(index.x >= 0 && index.x < lod.width)
    assert(index.y >= 0 && index.y < lod.height)
    
    l00,l01,l10,l11 := sample_bilinear(lod, index)
    
    l00 = srgb_255_to_linear_1(l00)
    l01 = srgb_255_to_linear_1(l01)
    l10 = srgb_255_to_linear_1(l10)
    l11 = srgb_255_to_linear_1(l11)
    
    result = blend_bilinear(l00,l01,l10,l11, fraction).rgb
    
    return result
}

blend_bilinear :: #force_inline proc(s00, s01, s10, s11: v4, t: v2) -> (result: v4) {
    result = lerp( lerp(s00, s01, t.x), lerp(s10, s11, t.x), t.y )
    
    return result
}

@(require_results)
unscale_and_bias :: #force_inline proc(normal: v4) -> (result: v4) {
    inv_255: f32 = 1.0 / 255.0

    result.xyz = -1 + 2 * (normal.xyz * inv_255)
    result.w = inv_255 * normal.w
    
    return result
}

// NOTE(viktor): srgb_to_linear and linear_to_srgb assume a gamma of 2 instead of the usual 2.2
@(require_results)
srgb_to_linear :: #force_inline proc(srgb: v4) -> (result: v4) {
    result.r = square(srgb.r)
    result.g = square(srgb.g)
    result.b = square(srgb.b)
    result.a = srgb.a
    
    return result
} 
@(require_results)
srgb_255_to_linear_1 :: #force_inline proc(srgb: v4) -> (result: v4) {
    inv_255: f32 = 1.0 / 255.0
    result = srgb * inv_255
    result = srgb_to_linear(result)
    
    return result
}
                
@(require_results)
linear_to_srgb :: #force_inline proc(linear: v4) -> (result: v4) {
    result.r = square_root(linear.r)
    result.g = square_root(linear.g)
    result.b = square_root(linear.b)
    result.a = linear.a
    
    return result
} 
@(require_results)
linear_1_to_srgb_255 :: #force_inline proc(linear: v4) -> (result: v4) {
    result = linear_to_srgb(linear)
    result *= 255
    
    return result
}