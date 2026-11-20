package game

light_element_limit :: 32 * 1024

LightingSolution :: struct {
    boxes:            [dynamic; light_element_limit] LightingBox,
    points:           [] LightingPoint,
    emission_color_0: [] v3,
    
    box_ref_count: u16,
    box_table:     [light_element_limit] u16,
    
    sorting_a, sorting_b: [light_element_limit] u16,
    
    root_box_index: u16,
    
    emission_color_1:           [light_element_limit] v3,
    average_direction_to_light: [light_element_limit] v3,
    
    last_is_valid:  bool,
    last_emission:  [light_element_limit] v3,
    last_direction: [light_element_limit] v3,
    
    using stats: struct {
        number_of_times_a_point_got_used_as_an_origin:         u32,
        number_of_times_a_box_got_considered_for_intersection: u32,
        number_of_total_rays_cast:                             u32,
    }
}

////////////////////////////////////////////////

LightingBox :: struct {
    // @speed separately store center,radius to maximize cache line usage
    // read in cast_ray on every iteration
    center: v3,
    radius: v3,
    
    transparency: f32,
    
    // written in cast_ray only rarely
    light_index: [7] u16,
    kid_count: u16,
    first_kid: u16,
    
    _pad: [2] u8,
}

LightingPoint :: struct {
    p:             v3,
    reflect_color: v3,
    n:             v3,
}

////////////////////////////////////////////////

LightingTextures :: struct {
    values: [light_element_limit] LightingValue,
}

@(common, shader)
LightingValue :: struct {
    p: v3,
    c: v3,
    d: v2, 
    // @note z is recoverable through |d.xyz| = 1
    // => sqrt(x²+y²+z²) = 1 => x²+y²+z² = 1 => z² = 1-x²-y² => +/-z = sqrt(1-x²-y²)
    // The sign of z is stored in c.r(color values are always positive, so the sign-bit is not used).
}

////////////////////////////////////////////////

lighting_test :: proc (group: ^RenderGroup, solution: ^LightingSolution) {
    timed_function()
    
    commands := group.commands
    
    solution.box_ref_count  = 0
    point_count := cast(u32) len(commands.light_points)
    solution.points           = commands.light_points[:]
    solution.emission_color_0 = commands.emission_color_0[:point_count]
    clear(&solution.boxes)
    append(&solution.boxes, ..commands.light_boxes[:])
    
    solution.stats = {}
    
    // @speed Just ping-pong these if we end up using it!
    copy(solution.last_direction[:point_count], solution.average_direction_to_light[:])
    zero(solution.average_direction_to_light[:point_count])
    
    build_spatial_partition_for_lighting(solution)
    
    {
        debug_data_block("Renderer")
        debug_data_block("Lighting")
        
        box_count := cast(u32) len(commands.light_boxes)
        debug_record_value(&box_count,   "Command Light Boxes")
        debug_record_value(&point_count, "Command Light Points")
        
        box_count   = cast(u32) len(solution.boxes)
        point_count = cast(u32) len(solution.points)
        debug_record_value(&box_count,   "Command Light Boxes")
        debug_record_value(&point_count, "Command Light Points")
    }
    
    compute_light_propagation(solution)
    
    copy(solution.last_emission[:point_count], solution.emission_color_0[:])
    
    {
        debug_data_block("Renderer")
        debug_data_block("Lighting")
        
        debug_record_value(&solution.number_of_times_a_point_got_used_as_an_origin,         "number of times a point got used as an origin")
        debug_record_value(&solution.number_of_total_rays_cast,                             "number of total rays cast")
        debug_record_value(&solution.number_of_times_a_box_got_considered_for_intersection, "number of times a box got considered for intersection")
        // 1.5k, 30k, 4.5M
    }
}

build_spatial_partition_for_lighting :: proc (solution: ^LightingSolution) {
    timed_function()
    
    add_box_references :: proc (solution: ^LightingSolution, box_storage_indices: ..u16) -> u16 {
        assert(solution.box_ref_count < len(solution.box_table))
        
        result := solution.box_ref_count
        
        solution.box_ref_count += cast(u16) len(box_storage_indices)
        copy(solution.box_table[result:], box_storage_indices)
        
        return result
    }
    
    add_box_storage :: proc (solution: ^LightingSolution) -> u16 {
        result := safe_truncate(u16, len(solution.boxes))
        _, ok := append_nothing(&solution.boxes)
        assert(ok)
        
        return result
    }
    
    split_box :: proc (solution: ^LightingSolution, parent: ^LightingBox, source_offset, source_count: u16, full_source, full_destination: [] u16, axis_index: u32) {
        source      := full_source[source_offset : source_offset+source_count]
        destination := full_destination[:source_count]
        
        kids := source
        if source_count > 4 {
            for attempt in 0..<3 {
                classifier_direction: v3
                classifier_direction[axis_index] = 1
                
                classifier_boundary := dot(parent.center, classifier_direction)
                
                bounds_a := box_inverted_infinity(Box3)
                bounds_b := box_inverted_infinity(Box3)
                
                count_a, count_b: u16
                end := source_count - 1
                for box_ref in source {
                    box := solution.boxes[box_ref]
                    
                    if dot(box.center, classifier_direction) < classifier_boundary {
                        destination[count_a] = box_ref
                        bounds_a = get_union(bounds_a, box_center_radius(box.center, box.radius))
                        count_a += 1
                    } else {
                        destination[end - count_b] = box_ref
                        bounds_b = get_union(bounds_b, box_center_radius(box.center, box.radius))
                        count_b += 1
                    }
                }
                
                next_axis := (axis_index + 1) % 3
                
                if count_a > 0 && count_b > 0 {
                    kid_a_box_index := add_box_storage(solution)
                    kid_a := &solution.boxes[kid_a_box_index]
                    kid_a^ = {
                        center = get_center(bounds_a),
                        radius = get_radius(bounds_a),
                    }
                    split_box(solution, kid_a, 0, count_a, full_destination, full_source, next_axis)
                    
                    kid_b_box_index := add_box_storage(solution)
                    kid_b := &solution.boxes[kid_b_box_index]
                    kid_b^ = {
                        center = get_center(bounds_b),
                        radius = get_radius(bounds_b),
                    }
                    split_box(solution, kid_b, count_a, count_b, full_destination, full_source, next_axis)
                    
                    kids = { kid_a_box_index, kid_b_box_index }
                    break
                }
            }
        }
        
        parent.kid_count = cast(u16) len(kids)
        parent.first_kid = add_box_references(solution, ..kids)
    }
        
    actual_box_count := safe_truncate(u16, len(solution.boxes))
    
    bounds := box_inverted_infinity(Box3)
    for box, box_index in solution.boxes {
        solution.sorting_a[box_index] = cast(u16) box_index
        bounds = get_union(bounds, box_center_radius(box.center, box.radius))
    }
    
    solution.root_box_index = add_box_references(solution, add_box_storage(solution))
    
    root := get_box(solution, solution.root_box_index)
    root ^= {
        center = get_center(bounds),
        radius = get_radius(bounds),
    }
    
    split_box(solution, root, 0, actual_box_count, solution.sorting_a[:], solution.sorting_b[:], 0)
}

compute_light_propagation :: proc (solution: ^LightingSolution) {
    timed_function()
    
    ////////////////////////////////////////////////
    
    // @todo Before moving on, be sure to index 
    // allocation management in the renderer!!!
    
    ////////////////////////////////////////////////
    
    LightingIterationCount = clamp(LightingIterationCount, 1, 32)
    ray_count := 64
    
    light_retention: f32 = 0.5
    min_emission: f32 = 0 // @todo Tune this to something higher than 0?
    
    source_emission_color      := solution.emission_color_0[:]
    destination_emission_color := solution.emission_color_1[:]
    
    for _ in 0..<LightingIterationCount {
        light_power := (1.0 - light_retention) / cast(f32) ray_count
        for point_index in 1..<cast(u32) len(solution.points) { // @note Point 0 is never used.
            point := &solution.points[point_index]
            emission_color := source_emission_color[point_index]
            
            retained_color := emission_color
            
            if (emission_color.r + emission_color.g + emission_color.b) > min_emission {
                emission_color *= point.reflect_color
                
                solution.number_of_times_a_point_got_used_as_an_origin += 1
                
                series := seed_random_series(1234)
                for _ in 0..<ray_count {
                    emission_direction := sample_hemisphere(&series, point.n)
                    
                    ray := cast_ray(solution, point_index, point.p, emission_direction)
                    
                    if ray.box != nil {
                        ray_p := point.p + ray.t * emission_direction
                        
                        first_point_index         := ray.box.light_index[ray.box_surface_index]
                        one_past_last_point_index := ray.box.light_index[ray.box_surface_index+1]
                        
                        closest_distance_squared := +Infinity
                        closest_point_index: u16
                        for test_index in first_point_index..<one_past_last_point_index {
                            // @todo Day 419: Moving to another room from the starting room triggers this assert, the test_index is larger than the actual point count(but not too large for the array itself).
                            test := solution.points[test_index]
                            distance_squared := length_squared(test.p - ray_p)
                            
                            if closest_distance_squared > distance_squared {
                                closest_distance_squared = distance_squared
                                closest_point_index = test_index
                            }
                        }
                        
                        if closest_point_index != 0 {
                            // @todo inline
                            accumulate_sample :: proc (point: ^LightingPoint, destination_emission_color: ^v3, average_direction_to_light: ^v3, light_color: v3, light_power: f32, normal_to_light: v3) -> v3 {
                                angular_falloff := clamp01(dot(point.n, normal_to_light))
                                
                                power  := light_power * angular_falloff
                                
                                weight := power * length(light_color)
                                result := power * light_color
                                
                                destination_emission_color^ += result
                                average_direction_to_light^ += weight * normal_to_light
                                
                                return result
                            }
                            
                            retained_color -= accumulate_sample(&solution.points[closest_point_index], &destination_emission_color[closest_point_index], &solution.average_direction_to_light[closest_point_index], emission_color, light_power, -emission_direction)
                        }
                    }
                }
            }
            
            destination_emission_color[point_index] += retained_color
        }
        
        for point_index in 1..<len(solution.points) { // @note Point 0 is never used.
            source_emission_color[point_index] = destination_emission_color[point_index]
            destination_emission_color[point_index] = 0
        }
        
        if ray_count > 8 {
            ray_count /= 2
        }
    }
    
    last_emission  := solution.last_emission[:]
    last_direction := solution.last_direction[:]
    if !solution.last_is_valid {
        solution.last_is_valid = true
        last_emission  = solution.emission_color_0[:]
        last_direction = solution.average_direction_to_light[:]
    }
    
    for point_index in 1..<len(solution.points) { // @note Point 0 is never used.
        t :: 1. / 50.
        solution.emission_color_0[point_index]           = linear_blend(last_emission[point_index],  solution.emission_color_0[point_index], t)
        solution.average_direction_to_light[point_index] = normalize_or_zero(linear_blend(last_direction[point_index], normalize_or_zero(solution.average_direction_to_light[point_index]), t))
    }
}

sample_hemisphere :: proc (series: ^RandomSeries, n: v3) -> v3 {
    // @todo Better hemisphere sampling, probably!
    result := normalize_or_zero(random_bilateral(series, v3))
    
    if dot(result, n) < 0 {
        result = -result
    }
    
    return result
}

RayCastResult :: struct {
    t: f32,
    box: ^LightingBox,
    box_surface_index: u16,
}

cast_ray :: proc (solution: ^LightingSolution, skip_index: u32, ray_origin, ray_direction: v3) -> RayCastResult {
    timed_function()
    result := RayCastResult { t = +Infinity }
    
    cast_ray_recurse(solution, skip_index, ray_origin, ray_direction, get_box(solution, solution.root_box_index), &result)
    
    cast_ray_recurse :: proc (solution: ^LightingSolution, skip_index: u32, ray_origin, ray_direction: v3, root_box: ^LightingBox, result: ^RayCastResult) {
        solution.number_of_total_rays_cast += 1
        /* @note:
        A P     x axis     y axis
        0 0    0,-1, 0    0, 0, 1
        0 1    0, 1, 0    0, 0, 1
        
        1 0    0, 0,-1    1, 0, 0
        1 1    0, 0, 1    1, 0, 0
        
        2 0   -1, 0, 0    0, 1, 0
        2 1    1, 0, 0    0, 1, 0
        */
        
        for box_index in root_box.first_kid ..< root_box.first_kid+root_box.kid_count {
            if cast(u32) box_index != skip_index {
                box := get_box(solution, box_index)
                
                solution.number_of_times_a_box_got_considered_for_intersection += 1
                
                if box.kid_count != 0 && contains(box_center_radius(box.center, box.radius), ray_origin) {
                    cast_ray_recurse(solution, skip_index, ray_origin, ray_direction, box, result)
                } else {
                    radius := box.radius
                    #no_bounds_check {
                        axis_loop: for axis in cast(u16) 0..<3 {
                            positive := ray_direction[axis] < 0
                            center := box.center
                            center[axis] += (positive ? 1 : -1) * radius[axis]
                            
                            plane_to_origin := ray_origin - center
                            
                            t := -plane_to_origin[axis] / ray_direction[axis]
                            
                            if t > 0 && result.t > t {
                                x_axis := (axis+1) % 3
                                y_axis := (axis+2) % 3
                                
                                half_width  := radius[x_axis]
                                half_height := radius[y_axis]
                                
                                ray_point := plane_to_origin + t * ray_direction
                                
                                x_check := abs(ray_point[x_axis])
                                y_check := abs(ray_point[y_axis])
                                
                                if x_check <= half_width && y_check <= half_height {
                                    if box.kid_count == 0 {
                                        result.t = t
                                        result.box = box
                                        result.box_surface_index = (axis << 1) | (positive ? 1 : 0)
                                    } else {
                                        cast_ray_recurse(solution, skip_index, ray_origin, ray_direction, box, result)
                                    }
                                    
                                    break axis_loop
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    return result
}

get_box :: proc (solution: ^LightingSolution, box_index: u16) -> ^LightingBox {
    result := &solution.boxes[solution.box_table[box_index]]
    return result
}