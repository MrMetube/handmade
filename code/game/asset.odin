package game

import "base:intrinsics"
import hha "asset_builder"

Assets :: struct {
    tran_state: ^TransientState,
    
    next_generation:            AssetGenerationId,
    in_flight_generation_count: u32,
    in_flight_generations:      [32]AssetGenerationId,    
    
    memory_operation_lock: u32,
    memory_sentinel: AssetMemoryBlock,
    
    loaded_asset_sentinel: AssetMemoryHeader,
        
    files: []AssetFile,

    types:  [AssetTypeId]AssetType,
    assets: []Asset,
    tags:   []AssetTag,
    
    tag_ranges: [AssetTagId]f32,
}

FontId   :: hha.FontId
SoundId  :: hha.SoundId
BitmapId :: hha.BitmapId

AssetTypeId :: hha.AssetTypeId
AssetTag    :: hha.AssetTag
AssetTagId  :: hha.AssetTagId

AssetState :: enum u8 { Unloaded, Queued, Loaded, Operating }

Asset :: struct {
    using data: hha.AssetData,
    file_index: u32,
    
    header: ^AssetMemoryHeader,
    
    state:         AssetState,
}

AssetMemoryHeader :: struct {
    next, prev:  ^AssetMemoryHeader,
    asset_index: u32,
    
    generation_id: AssetGenerationId,
    total_size:    u64,
    as: struct #raw_union {
        bitmap: Bitmap,
        sound:  Sound,
        font:   Font,
    },
}

AssetGenerationId :: distinct u32

AssetType :: struct {
    first_asset_index:   u32,
    one_past_last_index: u32,
}

AssetMemoryBlockFlags :: bit_set[enum u64 {
    Used,
}]

AssetMemoryBlock :: struct {
    prev, next: ^AssetMemoryBlock,
    size:       u64,
    flags:      AssetMemoryBlockFlags,
}

AssetVector :: [AssetTagId]f32

AssetFile :: struct {
    handle: PlatformFileHandle,
    // TODO(viktor): if we ever do thread stacks, 
    // then asset_type_array doesnt actually need to be kept here probably.
    header: hha.Header,
    asset_type_array: []hha.AssetType,
    tag_base: u32,
}

Font :: struct {
    codepoints: []BitmapId,
    horizontal_advance: []f32,
}

////////////////////////////////////////////////

make_assets :: proc(arena: ^Arena, memory_size: u64, tran_state: ^TransientState) -> (assets: ^Assets) {
    assets = push(arena, Assets, clear_to_zero = true)
    
    assets.memory_sentinel.next = &assets.memory_sentinel 
    assets.memory_sentinel.prev = &assets.memory_sentinel 
    
    insert_block(&assets.memory_sentinel, push(arena, memory_size), memory_size)
    
    assets.tran_state = tran_state
    
    assets.loaded_asset_sentinel.next = &assets.loaded_asset_sentinel
    assets.loaded_asset_sentinel.prev = &assets.loaded_asset_sentinel
    
    for &range in assets.tag_ranges {
        range = 1_000_000_000
    }
    assets.tag_ranges[.FacingDirection] = Tau
    
    read_data_from_file_into_struct :: #force_inline proc(handle: ^PlatformFileHandle, #any_int position: u64, destination: ^$T) {
        Platform.read_data_from_file(handle, position, size_of(T), destination)
    }
    read_data_from_file_into_slice :: #force_inline proc(handle: ^PlatformFileHandle, #any_int position: u64, destination: $T/[]$E) {
        Platform.read_data_from_file(handle, position, len(destination) * size_of(E), raw_data(destination))
    }
    
    // NOTE(viktor): count the null tag and null asset only once and not per HHA file
    tag_count:   u32 = 1
    asset_count: u32 = 1
    {
        file_group := Platform.begin_processing_all_files_of_type(.AssetFile)
        
        // TODO(viktor): which arena?
        assets.files = push(arena, AssetFile, file_group.file_count)
        for &file, index in assets.files {
            file.handle = Platform.open_next_file(&file_group)
            file.tag_base = tag_count
            
            file.header = {}
            read_data_from_file_into_struct(&file.handle, 0, &file.header)
            
            file.asset_type_array = push(arena, hha.AssetType, file.header.asset_type_count)
            read_data_from_file_into_slice(&file.handle, file.header.asset_types, file.asset_type_array)

            if file.header.magic_value != hha.MagicValue { 
                Platform.mark_file_error(&file.handle, "HHA file has an invalid magic value")
            }
            
            if file.header.version > hha.Version {
                Platform.mark_file_error(&file.handle, "HHA file has a invalid or higher version than supported")
            }
            
            if Platform_no_file_errors(&file.handle) {
                // NOTE(viktor): The first slot in every HHA is a null asset/ null tag
                // so we don't count it as something we will need space for!
                asset_count += (file.header.asset_count - 1)
                tag_count   += (file.header.tag_count - 1)
            } else {
                unreachable() // TODO(viktor): Eventually, have some way of notifying users of bogus amogus files?
            }
        }
        
        Platform.end_processing_all_files_of_type(&file_group)
    }
    
    // NOTE(viktor): Allocate all metadata space
    assets.assets = push(arena, Asset,    asset_count)
    assets.tags   = push(arena, AssetTag, tag_count)
    
    // NOTE(viktor): Load tags
    for &file in assets.files {
        // NOTE(viktor): skip the null tag
        offset := file.header.tags + size_of(hha.AssetTag)
        file_tag_count := file.header.tag_count-1
        read_data_from_file_into_slice(&file.handle, offset, assets.tags[file.tag_base:][:file_tag_count])
    }
    
    loaded_asset_count: u32 = 1
    // NOTE(viktor): reserve and zero out the null tag / null asset
    assets.tags[0]   = {}
    assets.assets[0] = {}
    
    for id in AssetTypeId {
        dest_type := &assets.types[id]
        dest_type.first_asset_index = loaded_asset_count

        for &file, file_index in assets.files {
            if Platform_no_file_errors(&file.handle) {
                for source_type, source_index in file.asset_type_array {
                    if source_type.id == id {
                        asset_count_for_type := source_type.one_past_last_index - source_type.first_asset_index
                        hha_memory := begin_temporary_memory(arena)
                        defer end_temporary_memory(hha_memory)
                        
                        hha_asset_array := push(&tran_state.arena, hha.AssetData, asset_count_for_type)
                        read_data_from_file_into_slice(&file.handle, file.header.assets + cast(u64) source_type.first_asset_index * size_of(hha.AssetData), hha_asset_array)
                                                    
                        assets_for_type := assets.assets[loaded_asset_count:][:asset_count_for_type]
                        for &asset, asset_index in assets_for_type {
                            hha_asset := hha_asset_array[asset_index]
                            
                            asset.file_index = auto_cast file_index
                            
                            asset.data = hha_asset
                            if asset.first_tag_index == 0 {
                                asset.one_past_last_tag_index = 0
                            } else {
                                asset.first_tag_index         += (file.tag_base - 1)
                                asset.one_past_last_tag_index += (file.tag_base - 1)
                            }
                        }
                        
                        
                        loaded_asset_count += asset_count_for_type
                        assert(loaded_asset_count <= asset_count)
                    }
                }
            }
        }

        dest_type.one_past_last_index = loaded_asset_count
    }
    
    assert(loaded_asset_count == asset_count)
    
    return assets
}

////////////////////////////////////////////////

get_asset :: #force_inline proc(assets: ^Assets, id: u32, generation_id: AssetGenerationId) -> (result: ^AssetMemoryHeader) {
    if is_valid_asset(id) {
        asset := &assets.assets[id]
        
        begin_asset_lock(assets)
        defer end_asset_lock(assets)
        
        if asset.state == .Loaded {
            result = asset.header
            
            remove_asset_header_from_list(result)
            insert_asset_header_at_front(assets, result)
            
            if asset.header.generation_id < generation_id {
                asset.header.generation_id = generation_id
            }
            
            complete_previous_writes_before_future_writes()
        }
    }
    return result
}

get_bitmap :: #force_inline proc(assets: ^Assets, id: BitmapId, generation_id: AssetGenerationId) -> (result: ^Bitmap) {
    header := get_asset(assets, cast(u32) id, generation_id)
    if header != nil {
        result = &header.as.bitmap
    }
    return result
}

get_sound :: #force_inline proc(assets: ^Assets, id: SoundId, generation_id: AssetGenerationId) -> (result: ^Sound) {
    header := get_asset(assets, cast(u32) id, generation_id)
    if header != nil {
        result = &header.as.sound
    }
    return result
}

get_font :: #force_inline proc(assets: ^Assets, id: FontId, generation_id: AssetGenerationId) -> (result: ^Font) {
    header := get_asset(assets, cast(u32) id, generation_id)
    if header != nil {
        result = &header.as.font
    }
    return result
}

////////////////////////////////////////////////
// Additional Information

is_valid_asset :: #force_inline proc(id: $T/u32) -> (result: b32) {
    result = id != 0
    return result
}

get_bitmap_info :: proc(assets: ^Assets, id: BitmapId) -> (result: ^hha.BitmapInfo) {
    if is_valid_asset(id) {
        result = &assets.assets[id].info.bitmap
    }
    return result
}

get_sound_info :: proc(assets: ^Assets, id: SoundId) -> (result: ^hha.SoundInfo) {
    if is_valid_asset(id) {
        result = &assets.assets[id].info.sound
    }
    return result
}

get_font_info :: proc(assets: ^Assets, id: FontId) -> (result: ^hha.FontInfo) {
    if is_valid_asset(id) {
        result = &assets.assets[id].info.font
    }
    return result
}

get_next_sound_in_chain :: #force_inline proc(assets: ^Assets, id: SoundId) -> (result: SoundId) {
    switch get_sound_info(assets, id).chain {
    case .None:    result = 0
    case .Advance: result = id + 1
    case .Loop:    result = id
    }
    return result
}

get_horizontal_advance_for_pair :: proc(font: ^Font, previous_codepoint, codepoint: rune) -> (result: f32) {
    previous_codepoint := previous_codepoint
    codepoint          := codepoint
    
    previous_codepoint = get_clamped_codepoint(font, previous_codepoint)
    codepoint          = get_clamped_codepoint(font, codepoint)
    
    codepoint_count := cast(rune) len(font.codepoints)
    result = font.horizontal_advance[previous_codepoint * codepoint_count + codepoint]
    
    return result
}

get_line_advance :: proc(info: ^hha.FontInfo) -> (result: f32) {
    result = info.line_advance
    return result
}

get_bitmap_for_glyph :: proc(font: ^Font, codepoint: rune) -> (result: BitmapId) {
    codepoint := codepoint
    codepoint = get_clamped_codepoint(font, codepoint)
    
    result = font.codepoints[codepoint]
    return result
}

get_clamped_codepoint :: proc(font: ^Font, desired: rune) -> (result: rune) {
    if desired < cast(rune) len(font.codepoints) {
        result = desired
    }
    return result
}

////////////////////////////////////////////////
// Queries

first_sound_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId) -> (result: SoundId) {
    result = cast(SoundId) first_asset_from(assets, id)
    return result
}
first_bitmap_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId) -> (result: BitmapId) {
    result = cast(BitmapId) first_asset_from(assets, id)
    return result
}
first_asset_from :: proc(assets: ^Assets, id: AssetTypeId) -> (result: u32) {
    type := assets.types[id]
    
    if type.first_asset_index != type.one_past_last_index {
        result = type.first_asset_index
    }
    
    return result
}

best_match_sound_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> SoundId {
    return cast(SoundId) best_match_asset_from(assets, id, match_vector, weight_vector)
}
best_match_bitmap_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> BitmapId {
    return cast(BitmapId) best_match_asset_from(assets, id, match_vector, weight_vector)
}
best_match_font_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> FontId {
    return cast(FontId) best_match_asset_from(assets, id, match_vector, weight_vector)
}
best_match_asset_from :: proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> (result: u32) {
    type := assets.types[id]

    if type.first_asset_index != type.one_past_last_index {
        
        best_diff := max(f32)
        for asset, asset_index in assets.assets[type.first_asset_index:type.one_past_last_index] {
    
            total_weight_diff: f32
            for tag in assets.tags[asset.first_tag_index:asset.one_past_last_tag_index] {
                a := match_vector[tag.id]
                b := tag.value
                
                range := assets.tag_ranges[tag.id]
                d1 := abs((a - range * sign(a)) - b)
                d2 := abs(a - b)
                
                difference := min(d1, d2)
                weighted := weight_vector[tag.id] * difference
                
                total_weight_diff += weighted
            }
            
            if total_weight_diff < best_diff {
                best_diff = total_weight_diff
                result = type.first_asset_index + cast(u32) asset_index
            }
        }
    }
    
    return result
}

random_sound_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, series: ^RandomSeries) -> (result: SoundId) {
    result = cast(SoundId) random_asset_from(assets, id, series)
    return result
}
random_bitmap_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, series: ^RandomSeries) -> (result: BitmapId) {
    result = cast(BitmapId) random_asset_from(assets, id, series)
    return result
}
random_asset_from :: proc(assets: ^Assets, id: AssetTypeId, series: ^RandomSeries) -> (result: u32) {
    type := assets.types[id]
    
    if type.first_asset_index != type.one_past_last_index {
        result = random_between_u32(series, type.first_asset_index, type.one_past_last_index-1)
    }
    
    return result
}


////////////////////////////////////////////////
// Memory Management

begin_generation :: #force_inline proc(assets: ^Assets) -> (result: AssetGenerationId) {
    begin_asset_lock(assets)
    
    result = assets.next_generation
    assets.next_generation += 1
    assets.in_flight_generations[assets.in_flight_generation_count] = result
    assets.in_flight_generation_count += 1
    
    end_asset_lock(assets)
    
    return result
}

end_generation :: #force_inline proc(assets: ^Assets, generation: AssetGenerationId) {
    for &in_flight, index in assets.in_flight_generations[:assets.in_flight_generation_count] {
        if in_flight == generation {
            assets.in_flight_generation_count -= 1
            if assets.in_flight_generation_count > 0 {
                in_flight = assets.in_flight_generations[assets.in_flight_generation_count]
            }
        }
    }
}

generation_has_completed :: proc(assets: ^Assets, check: AssetGenerationId) -> (result: b32) {
    result = true
    
    for in_flight in assets.in_flight_generations[:assets.in_flight_generation_count] {
        if in_flight == check {
            result = false
            break
        }
    }
    
    return result
}

begin_asset_lock :: proc(assets: ^Assets) {
    for {
        if _, ok := atomic_compare_exchange(&assets.memory_operation_lock, 0, 1); ok {
            break
        }
    }
    
}
end_asset_lock :: proc(assets: ^Assets) {
    complete_previous_writes_before_future_writes()
    assets.memory_operation_lock = 0
}

insert_asset_header_at_front :: #force_inline proc(assets:^Assets, header: ^AssetMemoryHeader) {
    sentinel := &assets.loaded_asset_sentinel
    
    header.prev = sentinel
    header.next = sentinel.next
    
    header.next.prev = header
    header.prev.next = header
}

remove_asset_header_from_list :: proc(header: ^AssetMemoryHeader) {
    header.prev.next = header.next
    header.next.prev = header.prev
    
    header.next = nil
    header.prev = nil
}

acquire_asset_memory :: #force_inline proc(assets: ^Assets, #any_int size: u64, asset_index: u32) -> (result: ^AssetMemoryHeader) {
    block := find_block_for_size(assets, size)
    
    begin_asset_lock(assets)
    defer end_asset_lock(assets)

    for {
        if block != nil && block.size >= size {
            block.flags += { .Used }
            // :PointerArithmetic
            blocks := cast([^]AssetMemoryBlock) block
            next_block := &blocks[1]
            result = cast(^AssetMemoryHeader) next_block
            
            remaining_size := block.size - size
            
            BlockSplitThreshhold := kilobytes(4) // TODO(viktor): set this based on the smallest asset size
            
            if remaining_size >= BlockSplitThreshhold {
                block.size -= remaining_size
                // :PointerArithmetic
                insert_block(block, (cast([^]u8)result)[size:], remaining_size)
            }
            break
        } else {
            for it := assets.loaded_asset_sentinel.prev; it != &assets.loaded_asset_sentinel; it = it.prev {
                asset := &assets.assets[it.asset_index]
                if asset.state == .Loaded && generation_has_completed(assets, asset.header.generation_id) {
                    remove_asset_header_from_list(it)
                    
                    // :PointerArithmetic
                    block = &(cast([^]AssetMemoryBlock) asset.header)[-1]
                    block.flags -= { .Used }
                        
                    if merge_if_possible(assets, block.prev, block) {
                        block = block.prev
                    }
                    merge_if_possible(assets, block, block.next)

                    asset.header = nil
                    asset.state = .Unloaded
                    
                    break
                }
            }
        }
    }
        
    if result != nil {
        asset := &assets.assets[asset_index]
        asset.header = result
        assert(asset.state != .Loaded)
        
        header := asset.header
        header.total_size  = size
        header.asset_index = asset_index
        
        insert_asset_header_at_front(assets, header)
    }

    return result
}

insert_block :: proc(previous: ^AssetMemoryBlock, memory: [^]u8, size: u64) -> (result: ^AssetMemoryBlock) {
    assert(size > size_of(AssetMemoryBlock))
    result = cast(^AssetMemoryBlock) memory
    result.size = size - size_of(AssetMemoryBlock)
    
    result.flags = {}
    
    result.prev = previous
    result.next = previous.next
    
    result.next.prev = result
    result.prev.next = result
    
    return result
}

find_block_for_size :: proc(assets: ^Assets, size: u64) -> (result: ^AssetMemoryBlock) {
    // TODO(viktor): find best matched block
    // TODO(viktor): this will probably need to be accelarated in the 
    // future as the resident asset count grows.
    for it := assets.memory_sentinel.next; it != &assets.memory_sentinel; it = it.next {
        if .Used not_in it.flags {
            if it.size >= size {
                result = it
                break
            }
        }
    }
    
    return result
}

merge_if_possible :: proc(assets: ^Assets, first, second: ^AssetMemoryBlock) -> (result: b32) {
    if first != &assets.memory_sentinel && second != &assets.memory_sentinel {
        if .Used not_in first.flags && .Used not_in second.flags {
            // :PointerArithmetic
            expect_second_memory := &(cast([^]u8) first)[size_of(AssetMemoryBlock) + first.size] 
            if cast(rawpointer) second == expect_second_memory {
                second.next.prev  = second.prev
                second.prev.next = second.next
                
                first.size += size_of(AssetMemoryBlock) + second.size
                result = true
            }
        }
    }
    return result
}

////////////////////////////////
// Loading

prefetch_sound  :: #force_inline proc(assets: ^Assets, id: SoundId)  { load_sound(assets, id)  }
prefetch_bitmap :: #force_inline proc(assets: ^Assets, id: BitmapId) { load_bitmap(assets, id, false) }

LoadAssetWork :: struct {
    task:        ^TaskWithMemory,
    asset:       ^Asset,
    
    handle:           ^PlatformFileHandle,
    position, amount: u64,
    destination:      rawpointer,
}

load_asset_work_immediatly :: proc(work: ^LoadAssetWork) {
    Platform.read_data_from_file(work.handle, work.position, work.amount, work.destination)
    
    complete_previous_writes_before_future_writes()
    
    work.asset.state = .Loaded
    if !Platform_no_file_errors(work.handle) {
        zero(work.destination, work.amount)
    }
}

do_load_asset_work : PlatformWorkQueueCallback : proc(data: rawpointer) {
    work := cast(^LoadAssetWork) data
    
    load_asset_work_immediatly(work)
    
    end_task_with_memory(work.task)
}

get_file_handle_for :: #force_inline proc(assets: ^Assets, file_index: u32) -> (result: ^PlatformFileHandle) {
    result = &assets.files[file_index].handle
    return result
}

load_sound :: proc(assets: ^Assets, id: SoundId) {
    if is_valid_asset(id) {
        asset := &assets.assets[id]
        if _, ok := atomic_compare_exchange(&asset.state, AssetState.Unloaded, AssetState.Queued); ok {
            if task := begin_task_with_memory(assets.tran_state); task != nil {
                info := asset.info.sound
            
                total_sample_count := cast(u64) info.channel_count * cast(u64) info.sample_count
                memory_size := total_sample_count * size_of(i16)
                total := memory_size + size_of(AssetMemoryHeader)
        
                // TODO(viktor): support alignment of 16
                asset.header = acquire_asset_memory(assets, total, cast(u32) id)
                
                sample_memory := pointer_step(asset.header, 1)
                // :PointerArithmetic
                // sample_memory := &(cast([^]AssetMemoryHeader) asset.header)[1]
                assert(sample_memory == &(cast([^]AssetMemoryHeader) asset.header)[1])

                sound := &asset.header.as.sound
                sound.channel_count = cast(u8) info.channel_count
                
                samples := (cast([^]i16) sample_memory)[:total_sample_count]
                for &channel, index in sound.channels[:sound.channel_count] {
                    channel = samples[info.sample_count * auto_cast index:][:info.sample_count]
                }
                                
                work := push(&task.arena, LoadAssetWork)
                work^ = {
                    task = task,
                    
                    handle = get_file_handle_for(assets, asset.file_index),
                    
                    position = asset.data_offset, 
                    amount = memory_size,
                    destination = raw_data(samples),
                    
                    asset = asset,
                }
                
                Platform.enqueue_work(assets.tran_state.low_priority_queue, do_load_asset_work, work)
            } else {
                _, ok = atomic_compare_exchange(&asset.state, AssetState.Queued, AssetState.Unloaded)
                assert(ok)
            }
        }
    }
}

load_bitmap :: proc(assets: ^Assets, id: BitmapId, immediate: b32) {
    if is_valid_asset(id) {
        asset := &assets.assets[id]
        if _, ok := atomic_compare_exchange(&asset.state, AssetState.Unloaded, AssetState.Queued); ok {
            task: ^TaskWithMemory
            if !immediate {
                task = begin_task_with_memory(assets.tran_state) 
            }
            
            if immediate || task != nil {
                info := asset.info.bitmap
                
                pixel_count := cast(u64) info.dimension.x * cast(u64) info.dimension.y
                memory_size := pixel_count * size_of(ByteColor)
                total := memory_size + size_of(AssetMemoryHeader)
            
                // TODO(viktor): support alignment of 16
                asset.header = acquire_asset_memory(assets, total, cast(u32) id)
                // :PointerArithmetic
                bitmap_memory := &(cast([^]AssetMemoryHeader) asset.header)[1]
                
                bitmap := &asset.header.as.bitmap
                bitmap^ = {
                    memory = (cast([^]ByteColor)bitmap_memory)[:pixel_count],
                    width  = cast(i32) info.dimension.x, 
                    height = cast(i32) info.dimension.y,
                    
                    align_percentage = info.align_percentage,
                    width_over_height = cast(f32) info.dimension.x / cast(f32) info.dimension.y,
                }
                
                work := LoadAssetWork {
                    task = task,
                    
                    handle = get_file_handle_for(assets, asset.file_index),
                    
                    position = asset.data_offset, 
                    amount = memory_size,
                    destination = raw_data(bitmap.memory),
                    
                    asset = asset,
                }
                
                if !immediate {
                    task_work := push(&task.arena, LoadAssetWork)
                    task_work^ = work
                    Platform.enqueue_work(assets.tran_state.low_priority_queue, do_load_asset_work, task_work)
                } else {
                    load_asset_work_immediatly(&work)
                }
            } else {
                _, ok = atomic_compare_exchange(&asset.state, AssetState.Queued, AssetState.Unloaded)
                assert(ok)
            }
        } else if immediate {
            for volatile_load(&asset.state) == .Queued {}
        }
    }
}

load_font :: proc(assets: ^Assets, id: FontId, immediate: b32) {
    // TODO(viktor): merge this preamble and postamble
    if is_valid_asset(id) {
        asset := &assets.assets[id]
        if _, ok := atomic_compare_exchange(&asset.state, AssetState.Unloaded, AssetState.Queued); ok {
            task: ^TaskWithMemory
            if !immediate {
                task = begin_task_with_memory(assets.tran_state) 
            }
            
            if immediate || task != nil {
                info := asset.info.font
                
                codepoint_count := cast(u64) info.codepoint_count
                memory_size := codepoint_count * size_of(BitmapId)
                total := memory_size + size_of(AssetMemoryHeader)
            
                // TODO(viktor): support alignment of 16
                asset.header = acquire_asset_memory(assets, total, cast(u32) id)
                // :PointerArithmetic
                font_memory := &(cast([^]AssetMemoryHeader) asset.header)[1]
                
                codepoints := (cast([^]BitmapId) font_memory)[:info.codepoint_count]
                // :PointerArithmetic
                horizontal_advance_memory := &(raw_data(codepoints))[info.codepoint_count]
                horizontal_advance := (cast([^]f32) horizontal_advance_memory)[:square(info.codepoint_count)]
                
                font := &asset.header.as.font
                font^ = {
                    codepoints         = codepoints,
                    horizontal_advance = horizontal_advance,
                }
                
                work := LoadAssetWork {
                    task = task,
                    
                    handle = get_file_handle_for(assets, asset.file_index),
                    
                    position = asset.data_offset, 
                    amount = memory_size,
                    destination = raw_data(font.codepoints),
                    
                    asset = asset,
                }
                
                if !immediate {
                    task_work := push(&task.arena, LoadAssetWork)
                    task_work^ = work
                    Platform.enqueue_work(assets.tran_state.low_priority_queue, do_load_asset_work, task_work)
                } else {
                    load_asset_work_immediatly(&work)
                }
            } else {
                _, ok = atomic_compare_exchange(&asset.state, AssetState.Queued, AssetState.Unloaded)
                assert(ok)
            }
        } else if immediate {
            for volatile_load(&asset.state) == .Queued {}
        }
    }
}