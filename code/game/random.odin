#+vet !unused-procedures
#+no-instrumentation
package game

import "base:intrinsics"

RandomSeries :: struct { state: lane_u32 }

////////////////////////////////////////////////

seed_random_series :: proc { seed_random_series_cycle_counter, seed_random_series_manual }
seed_random_series_cycle_counter :: proc() -> (result: RandomSeries) {
    return seed_random_series(intrinsics.read_cycle_counter())
}
seed_random_series_manual :: proc(#any_int seed: u32) -> (result: RandomSeries) {
    result = { state = seed }
    for i in u32(0)..<LaneWidth {
        (cast(^[LaneWidth] u32) &result.state)[i] ~= (i + 58564) * seed
    }
    return 
}

////////////////////////////////////////////////

next_random_lane_u32 :: proc (series: ^RandomSeries) ->  (x: lane_u32) {
    // @note(viktor): Reference xor_shift from https://en.wikipedia.org/wiki/Xorshift
    x = series.state 
        
    x ~= shift_left(x,  13)
    x ~= shift_right(x, 17)
    x ~= shift_left(x,  5)
    
    series.state = x
    
    return x
}
next_random_u32 :: proc (series: ^RandomSeries) ->  (result: u32) {
    next_random_lane_u32(series)
    return extract(series.state, 0)
}

////////////////////////////////////////////////

// @todo(viktor): handle that this may want to be called with doubles and that those probably want to not be upcast from floats
// @todo(viktor): make this handling of arrays with unique random values more systemic for use with integer vectors
random_unilateral :: proc(series: ^RandomSeries, $T: typeid) -> (result: T) #no_bounds_check {
    when intrinsics.type_is_array(T) {
        E :: intrinsics.type_elem_type(T)
        #unroll for i in 0..<len(T) {
            result[i] = random_unilateral(series, E)
        }
    } else {
        value := next_random_lane_u32(series)
        unilateral := cast(lane_f32) (shift_right(value, 1)) / cast(lane_f32) (max(u32) >> 1)
        when intrinsics.type_is_simd_vector(T) {
            result = cast(T) unilateral
        } else {
            result = cast(T) extract(unilateral, 0)
        }
    }
    
    // @todo(viktor): why are all results less than 0.001 ?
    return result
}

random_bilateral :: proc(series: ^RandomSeries, $T: typeid) -> (result: T) {
    result = random_unilateral(series, T) * 2 - 1
    return result
}

////////////////////////////////////////////////

random_between :: proc(series: ^RandomSeries, $T: typeid, min, max: T) -> (result: T) {
    assert(min <= max)
         when T == i32 || T == u32 do return random_between_integer(series, T, min, max)
    else when T == f32             do return random_between_float(series, min, max)
    else do #assert(false)
}

random_between_integer :: proc(series: ^RandomSeries, $T: typeid, min, max: T) -> (result: T) 
where size_of(T) <= size_of(u32) {
    span := cast(u32) ((max+1)-min)
    result = min + cast(T) (next_random_u32(series) % span)

    return result
}

random_between_float :: proc(series: ^RandomSeries, min, max: f32) -> (result: f32) {
    value := random_unilateral(series, f32)
    range := max - min
    result = min + value * range
    
    return result
}

////////////////////////////////////////////////

random_pointer :: proc { random_pointer_slice, random_pointer_array }
random_pointer_array :: proc(series: ^RandomSeries, data: [dynamic] $T) -> (result: ^T) { return random_pointer_slice(series, data[:]) }
random_pointer_slice :: proc(series: ^RandomSeries, data: []        $T) -> (result: ^T) {
    index := random_index(series, data)
    result = &data[index]
    return result
}

random_value :: proc { random_value_slice, random_value_array }
random_value_array :: proc(series: ^RandomSeries, data: [dynamic] $T) -> (result: T) { return random_value_slice(series, data[:]) }
random_value_slice :: proc(series: ^RandomSeries, data: []        $T) -> (result: T) {
    index := random_index(series, data)
    result = data[index]
    return result
}

random_index :: proc { random_index_slice, random_index_array }
random_index_array :: proc(series: ^RandomSeries, data: [dynamic] $T) -> (result: i32) { return random_index_slice(series, data[:]) }
random_index_slice :: proc(series: ^RandomSeries, data: []        $T) -> (result: i32) {
    assert(len(data) != 0)
    result = random_between(series, i32, 0, cast(i32) len(data)-1)
    return result
}