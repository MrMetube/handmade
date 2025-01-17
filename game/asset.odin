package game

import "base:intrinsics"
import hha "asset_builder"

Assets :: struct {
    tran_state: ^TransientState,
    arena: Arena,
    
    files: []AssetFile,
    
    types:   [AssetTypeId]AssetType,
    assets:  []Asset,
    slots:   []AssetSlot,
    tags:    []AssetTag,
    
    tag_ranges: [AssetTagId]f32,
}

SoundId     :: hha.SoundId
BitmapId    :: hha.BitmapId
AssetTypeId :: hha.AssetTypeId
AssetTag    :: hha.AssetTag
AssetTagId  :: hha.AssetTagId

AssetState :: enum { Unloaded, Queued, Loaded, Locked }

AssetSlot :: struct {
    state:  AssetState,
    
    using as : struct #raw_union {
        bitmap: ^Bitmap,
        sound:  ^Sound,
    },
}

Asset :: struct {
    using data: hha.AssetData,
    file_index: u32,
}

AssetType :: struct {
    first_asset_index:   u32,
    one_past_last_index: u32,
}

AssetVector :: [AssetTagId]f32

AssetFile :: struct {
    handle: ^PlatformFileHandle,
    // TODO(viktor): if  we ever do thread stacks, 
    // then asset_type_array doesnt actually need to be kept here probably.
    header: hha.Header,
    asset_type_array: []hha.AssetType,
    tag_base: u32,
}

make_game_assets :: proc(arena: ^Arena, memory_size: u64, tran_state: ^TransientState) -> (assets: ^Assets) {
    assets = push(arena, Assets)
    sub_arena(&assets.arena, arena, memory_size)
    assets.tran_state = tran_state
    
    for &range in assets.tag_ranges {
        range = 100_000_000
    }
    assets.tag_ranges[.FacingDirection] = Tau
    
    read_data_from_file_into_struct :: #force_inline proc(handle: ^PlatformFileHandle, #any_int position: u64, destination: ^$T) {
        Platform.read_data_from_file(handle, position, size_of(T), destination)
    }
    read_data_from_file_into_slice :: #force_inline proc(handle: ^PlatformFileHandle, #any_int position: u64, destination: $T/[]$E) {
        Platform.read_data_from_file(handle, position, len(destination) * size_of(E), raw_data(destination))
    }
    
    // NOTE(viktor): count the null tag and null asset only once and not per HHA file
    tag_count  : u32 = 1
    asset_count: u32 = 1
    {
        file_group := Platform.begin_processing_all_files_of_type("hha")
        
        // TODO(viktor): which arena?
        assets.files = push(arena, AssetFile, len(file_group))
        for &file, index in assets.files {
            file.handle = Platform.open_file(file_group, index)
            file.tag_base = tag_count
            
            file.header = {}
            read_data_from_file_into_struct(file.handle, 0, &file.header)
            
            file.asset_type_array = push(arena, hha.AssetType, file.header.asset_type_count)
            read_data_from_file_into_slice(file.handle, file.header.asset_types, file.asset_type_array)

            if file.header.magic_value != hha.MagicValue { 
                Platform.mark_file_error(file.handle, "HHA file has an invalid magic value")
            }
            
            if file.header.version > hha.Version {
                Platform.mark_file_error(file.handle, "HHA file has a invalid or higher version than supported")
            }
            
            if Platform_no_file_errors(file.handle) {
                // NOTE(viktor): The first slot in every HHA is a null asset/ null tag
                // so we don't count it as something we will need space for!
                asset_count += (file.header.asset_count - 1)
                tag_count   += (file.header.tag_count - 1)
            } else {
                unreachable() // TODO(viktor): Eventually, have some way of notifying users of bogus amogus files?
            }
        }
        
        Platform.end_processing_all_files_of_type(file_group)
    }
    
    // NOTE(viktor): Allocate all metadata space
    assets.slots  = push(arena, AssetSlot, asset_count)
    assets.assets = push(arena, Asset,     asset_count)
    assets.tags   = push(arena, AssetTag,  tag_count)
    
    // NOTE(viktor): Load tags
    for &file in assets.files {
        // NOTE(viktor): skip the null tag
        offset := file.header.tags + size_of(hha.AssetTag)
        file_tag_count := file.header.tag_count-1
        read_data_from_file_into_slice(file.handle, offset, assets.tags[file.tag_base:][:file_tag_count])
    }
    
    loaded_asset_count: u32 = 1
    // NOTE(viktor): reserve and zero out the null tag / null asset
    // assets.tags[0]   = {}
    // assets.assets[0] = {}
    
    for id in AssetTypeId {
        dest_type := &assets.types[id]
        dest_type.first_asset_index = loaded_asset_count

        for file, file_index in assets.files {
            if Platform_no_file_errors(file.handle) {
                for source_type, source_index in file.asset_type_array {
                    if source_type.id == id {
                        asset_count_for_type := source_type.one_past_last_index - source_type.first_asset_index
                        hha_memory := begin_temporary_memory(arena)
                        defer end_temporary_memory(hha_memory)
                        
                        hha_asset_array := push(&tran_state.arena, hha.AssetData, asset_count_for_type)
                        read_data_from_file_into_slice(file.handle, file.header.assets + cast(u64) source_type.first_asset_index * size_of(hha.AssetData), hha_asset_array)
                                                    
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

get_bitmap :: #force_inline proc(assets: ^Assets, id: BitmapId) -> (result: ^Bitmap) {
    if is_valid_bitmap(id) {
        slot := assets.slots[id]
        if slot.state  == .Loaded || slot.state == .Locked {
            complete_previous_reads_before_future_reads()
            result = slot.bitmap
        }
    }
    return result
}

get_sound :: #force_inline proc(assets: ^Assets, id: SoundId) -> (result: ^Sound) {
    if is_valid_sound(id) {
        slot := assets.slots[id]
        if slot.state  == .Loaded || slot.state == .Locked {
            complete_previous_reads_before_future_reads()
            result = slot.sound
        }
    }
    return result
}
get_sound_info :: proc(assets: ^Assets, id: SoundId) -> (result: ^hha.Sound) {
    if is_valid_sound(id) {
        result = &assets.assets[id].sound
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

is_valid_bitmap :: #force_inline proc(id: BitmapId) -> (result: b32) {
    result = id != BitmapId(0)
    return result
}
is_valid_sound :: #force_inline proc(id: SoundId) -> (result: b32) {
    result = id != SoundId(0)
    return result
}

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

// TODO(viktor): are these even needed?
best_match_sound_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> (result: SoundId) {
    result = cast(SoundId) best_match_asset_from(assets, id, match_vector, weight_vector)
    return result
}
best_match_bitmap_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> (result: BitmapId) {
    result = cast(BitmapId) best_match_asset_from(assets, id, match_vector, weight_vector)
    return result
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
        result = random_between_u32(series, type.first_asset_index, type.one_past_last_index)
    }
    
    return result
}


get_file_handle_for :: #force_inline proc(assets:^Assets, file_index: u32) -> (result: ^PlatformFileHandle) {
    result = assets.files[file_index].handle
    return result
}


prefetch_sound  :: proc(assets: ^Assets, id: SoundId)  { load_sound(assets,  id) }
prefetch_bitmap :: proc(assets: ^Assets, id: BitmapId) { load_bitmap(assets, id) }

LoadAssetWork :: struct {
    task:        ^TaskWithMemory,
    asset_slot:  ^AssetSlot,
    final_state: AssetState, 
    
    handle: ^PlatformFileHandle,
    position, amount: u64,
    destination:  rawpointer,
}

do_load_asset_work : PlatformWorkQueueCallback : proc(data: rawpointer) {
    work := cast(^LoadAssetWork) data
    
    Platform.read_data_from_file(work.handle, work.position, work.amount, work.destination)
    
    complete_previous_writes_before_future_writes()
    
    // TODO(viktor): should we actually fill in bogus amongus data in here and set to final state anyway?
    if Platform_no_file_errors(work.handle) {
        work.asset_slot.state = work.final_state
    }
    
    end_task_with_memory(work.task)
}

load_sound :: proc(assets: ^Assets, id: SoundId) {
    if is_valid_sound(id) {
        if _, ok := atomic_compare_exchange(&assets.slots[id].state, AssetState.Unloaded, AssetState.Queued); ok {
            if task := begin_task_with_memory(assets.tran_state); task != nil {
                asset := assets.assets[id]
                info  := asset.sound
                
                sound := push(&assets.arena, Sound)
                sound.channel_count = info.channel_count
                
                total_sample_count := info.sample_count * sound.channel_count
                memory_size := total_sample_count * size_of(i16)
                samples := push(&assets.arena, i16, total_sample_count, alignment = 8)
                for &channel, index in sound.channels[:sound.channel_count] {
                    channel = samples[info.sample_count * auto_cast index:][:info.sample_count]
                }
                
                work := push(&task.arena, LoadAssetWork)
                work^ = {
                    task = task,
                    final_state = .Loaded,
                    
                    handle = get_file_handle_for(assets, asset.file_index),
                    
                    position = asset.data_offset, 
                    amount = cast(u64) memory_size,
                    destination = raw_data(samples),
                    
                    asset_slot = &assets.slots[id],
                }
                work.asset_slot.sound = sound
                
                Platform.enqueue_work(assets.tran_state.low_priority_queue, do_load_asset_work, work)
            } else {
                _, ok = atomic_compare_exchange(&assets.slots[id].state, AssetState.Queued, AssetState.Unloaded)
                assert(auto_cast ok)
            }
        }
    }
}

load_bitmap :: proc(assets: ^Assets, id: BitmapId) {
    if is_valid_bitmap(id) {
        if _, ok := atomic_compare_exchange(&assets.slots[id].state, AssetState.Unloaded, AssetState.Queued); ok {
            if task := begin_task_with_memory(assets.tran_state); task != nil {
                asset := assets.assets[id]
                info  := asset.bitmap

                bitmap_size := info.dimension.x * info.dimension.y
                memory_size := bitmap_size * size_of(ByteColor)
                
                bitmap := push(&assets.arena, Bitmap)
                bitmap^ = {
                    memory = push(&assets.arena, ByteColor, bitmap_size, alignment = 16),
                    width  = cast(i32) info.dimension.x, 
                    height = cast(i32) info.dimension.y,
                    
                    pitch = cast(i32) info.dimension.x,
                    
                    align_percentage = info.align_percentage,
                    width_over_height = cast(f32) info.dimension.x / cast(f32) info.dimension.y,
                }
                
                work := push(&task.arena, LoadAssetWork)
                work^ = {
                    task = task,
                    final_state = .Loaded,
                    
                    handle = get_file_handle_for(assets, asset.file_index),
                    
                    position = asset.data_offset, 
                    amount = cast(u64) memory_size,
                    destination = raw_data(bitmap.memory),
                    
                    asset_slot = &assets.slots[id],
                }
                work.asset_slot.bitmap = bitmap

                Platform.enqueue_work(assets.tran_state.low_priority_queue, do_load_asset_work, work)
            } else {
                _, ok = atomic_compare_exchange(&assets.slots[id].state, AssetState.Queued, AssetState.Unloaded)
                assert(auto_cast ok)
            }
        }
    }
}