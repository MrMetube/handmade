package game

import hha "asset_builder"

Assets :: struct {
    tran_state: ^TransientState,
    texture_op_queue: ^TextureOpQueue,
    
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

FontInfo   :: hha.FontInfo
SoundInfo  :: hha.SoundInfo
BitmapInfo :: hha.BitmapInfo

AssetTypeId :: hha.AssetTypeId
AssetTag    :: hha.AssetTag
AssetTagId  :: hha.AssetTagId

AssetFontType :: hha.AssetFontType

AssetState :: enum u8 { Unloaded, Queued, Loaded, Operating }

Asset :: struct {
    using data: hha.AssetData,
    file_index: u32,
    
    header: ^AssetMemoryHeader,
    state:  AssetState,
}

AssetMemoryHeader :: struct {
    next, prev: ^AssetMemoryHeader,
    
    asset_index: u32,
    
    generation_id: AssetGenerationId,
    total_size:    u64,
    
    value: union {
        Bitmap,
        Sound,
        Font,
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
    size:  u64,
    flags: AssetMemoryBlockFlags,
}

AssetVector :: [AssetTagId]f32

AssetFile :: struct {
    handle: PlatformFileHandle,
    // @todo(viktor): if we ever do thread stacks, 
    // then asset_type_array doesnt actually need to be kept here probably.
    header: hha.Header,
    asset_type_array: []hha.AssetType,
    tag_base: u32,
    
    font_bitmap_id_offset: BitmapId,
}

Font :: struct {
    bitmap_id_offset: BitmapId,
    unicode_map: []u16,
    glyphs:      []hha.GlyphInfo,
    advances:    []f32,
}

////////////////////////////////////////////////

@(common)
TextureOpQueue :: struct {
    mutex: TicketMutex,
    
    ops: Deque(TextureOp),
    first_free: ^TextureOp,
}

@(common)
TextureOpAllocate :: struct {
    width, height: i32, 
    data: pmm,
    
    result: ^u32,
}

@(common)
TextureOpDeallocate :: struct {
    handle: u32,
}

@(common)
TextureOp :: struct {
    next: ^TextureOp,
    
    value: union {
        TextureOpAllocate,
        TextureOpDeallocate,
    }
}

////////////////////////////////////////////////

make_assets :: proc(arena: ^Arena, memory_size: u64, tran_state: ^TransientState, texture_op_queue: ^TextureOpQueue) -> (assets: ^Assets) {
    assets = push(arena, Assets)
    
    list_init_sentinel(&assets.memory_sentinel)
    
    insert_block(&assets.memory_sentinel, push(arena, memory_size), memory_size)
    list_init_sentinel(&assets.loaded_asset_sentinel)
    
    assets.tran_state = tran_state
    assets.texture_op_queue = texture_op_queue
    
    for &range in assets.tag_ranges {
        range = 1_000_000_000
    }
    assets.tag_ranges[.FacingDirection] = Tau
    
    read_data_from_file_into_struct :: proc(handle: ^PlatformFileHandle, #any_int position: u64, destination: ^$T) {
        Platform.read_data_from_file(handle, position, size_of(T), destination)
    }
    read_data_from_file_into_slice :: proc(handle: ^PlatformFileHandle, #any_int position: u64, destination: $T/[]$E) {
        Platform.read_data_from_file(handle, position, len(destination) * size_of(E), raw_data(destination))
    }
    
    // @note(viktor): count the null tag and null asset only once and not per HHA file
    total_tag_count:   u32 = 1
    total_asset_count: u32 = 1
    {
            file_group := Platform.begin_processing_all_files_of_type(.AssetFile)
        defer Platform.end_processing_all_files_of_type(&file_group)
        
        // @todo(viktor): which arena?
        assets.files = push(arena, AssetFile, file_group.file_count)
        for &file in assets.files {
            file.handle = Platform.open_next_file(&file_group)
            file.tag_base = total_tag_count
            
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
                // @note(viktor): The first slot in every HHA is a null asset/ null tag
                // so we don't count it as something we will need space for!
                total_asset_count += (file.header.asset_count - 1)
                total_tag_count   += (file.header.tag_count - 1)
            } else {
                unreachable() // @todo(viktor): Eventually, have some way of notifying users of bogus amogus files?
            }
        }
    }
    
    // @note(viktor): Allocate all metadata space
    assets.assets = push(arena, Asset,    total_asset_count)
    assets.tags   = push(arena, AssetTag, total_tag_count)
    
    // @note(viktor): Load tags
    for &file in assets.files {
        // @note(viktor): skip the null tag
        offset := file.header.tags + size_of(hha.AssetTag)
        file_tag_count := file.header.tag_count-1
        read_data_from_file_into_slice(&file.handle, offset, assets.tags[file.tag_base:][:file_tag_count])
    }
    
    asset_count: u32 = 1
    // @note(viktor): reserve and zero out the null tag / null asset
    assets.tags[0]   = {}
    assets.assets[0] = {}
    
    for id in AssetTypeId {
        dest_type := &assets.types[id]
        dest_type.first_asset_index = asset_count

        for &file, file_index in assets.files {
            file.font_bitmap_id_offset = 0
            
            if Platform_no_file_errors(&file.handle) {
                for source_type in file.asset_type_array {
                    if source_type.id == id {
                        if source_type.id == .FontGlyph {
                            file.font_bitmap_id_offset = cast(BitmapId) (asset_count - source_type.first_asset_index)
                        }
                        
                        asset_count_for_type := source_type.one_past_last_index - source_type.first_asset_index
                        hha_memory := begin_temporary_memory(arena)
                        defer end_temporary_memory(hha_memory)
                        
                        hha_asset_array := push(&tran_state.arena, hha.AssetData, asset_count_for_type)
                        read_data_from_file_into_slice(&file.handle, file.header.assets + cast(u64) source_type.first_asset_index * size_of(hha.AssetData), hha_asset_array)
                                                    
                        assets_for_type := assets.assets[asset_count:][:asset_count_for_type]
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
                        
                        
                        asset_count += asset_count_for_type
                        assert(asset_count <= total_asset_count)
                    }
                }
            }
        }

        dest_type.one_past_last_index = asset_count
    }
    
    assert(asset_count == total_asset_count)
    
    return assets
}

////////////////////////////////////////////////

get_asset :: proc(assets: ^Assets, id: u32, generation_id: AssetGenerationId) -> (result: ^AssetMemoryHeader) {
    if is_valid_asset(id) {
        asset := &assets.assets[id]
        
        begin_asset_lock(assets)
        defer end_asset_lock(assets)
        
        if asset.state == .Loaded {
            result = asset.header
            
            list_remove(result)
            list_prepend(&assets.loaded_asset_sentinel, result)
            
            if asset.header.generation_id < generation_id {
                asset.header.generation_id = generation_id
            }
            
            complete_previous_writes_before_future_writes()
        }
    }
    return result
}

// @todo(viktor): optional ok?
get_bitmap :: proc(assets: ^Assets, id: BitmapId, generation_id: AssetGenerationId) -> (result: ^Bitmap) {
    header := get_asset(assets, cast(u32) id, generation_id)
    if header != nil {
        if _, ok := header.value.(Bitmap); ok {
            // @todo(viktor): When Hotreloading this type assertion fails when the debug system draws text
            result = &header.value.(Bitmap)
        }
    }
    return result
}

get_sound :: proc(assets: ^Assets, id: SoundId, generation_id: AssetGenerationId) -> (result: ^Sound) {
    header := get_asset(assets, cast(u32) id, generation_id)
    if header != nil {
        result = &header.value.(Sound)
    }
    return result
}

get_font :: proc(assets: ^Assets, id: FontId, generation_id: AssetGenerationId) -> (result: ^Font) {
    header := get_asset(assets, cast(u32) id, generation_id)
    if header != nil {
        result = &header.value.(Font)
    }
    return result
}

////////////////////////////////////////////////
// Additional Information

is_valid_asset :: proc(id: $T/u32) -> (result: b32) {
    result = id != 0
    return result
}

get_bitmap_info :: proc(assets: ^Assets, id: BitmapId) -> (result: ^BitmapInfo) {
    if is_valid_asset(id) {
        result = &assets.assets[id].info.bitmap
    }
    return result
}

get_sound_info :: proc(assets: ^Assets, id: SoundId) -> (result: ^SoundInfo) {
    if is_valid_asset(id) {
        result = &assets.assets[id].info.sound
    }
    return result
}

get_font_info :: proc(assets: ^Assets, id: FontId) -> (result: ^FontInfo) {
    if is_valid_asset(id) {
        result = &assets.assets[id].info.font
    }
    return result
}

get_next_sound_in_chain :: proc(assets: ^Assets, id: SoundId) -> (result: SoundId) {
    switch get_sound_info(assets, id).chain {
    case .None:    result = 0
    case .Advance: result = id + 1
    case .Loop:    result = id
    }
    return result
}

get_horizontal_advance_for_pair :: proc(font: ^Font, info: ^FontInfo, previous_codepoint, codepoint: rune) -> (result: f32) {
    previous_glyph := get_glyph_from_codepoint(font, info, previous_codepoint)
    glyph          := get_glyph_from_codepoint(font, info, codepoint)
    
    result = font.advances[previous_glyph * cast(u16) len(font.glyphs) + glyph]
    
    return result
}

get_baseline :: proc(info: ^FontInfo) -> (result: f32) {
    result = info.ascent
    return result
}

get_line_advance :: proc(info: ^FontInfo) -> (result: f32) {
    result = info.ascent - info.descent + info.linegap
    return result
}

get_bitmap_for_glyph :: proc(font: ^Font, info: ^FontInfo, codepoint: rune) -> (result: BitmapId) {
    glyph := get_glyph_from_codepoint(font, info, codepoint)
    entry := font.glyphs[glyph]
    
    // @todo(viktor): why is this not handled by the null glyph1?!
    if(entry.codepoint == codepoint) {
        result = font.bitmap_id_offset + entry.bitmap
    }
    
    return result
}

get_glyph_from_codepoint :: proc(font: ^Font, info: ^FontInfo, codepoint: rune) -> (result: u16) {
    if codepoint < info.one_past_highest_codepoint {
        result = font.unicode_map[codepoint]
    }
    return result
}

////////////////////////////////////////////////
// Queries

first_sound_from :: proc(assets: ^Assets, id: AssetTypeId) -> (result: SoundId) {
    result = cast(SoundId) first_asset_from(assets, id)
    return result
}
first_bitmap_from :: proc(assets: ^Assets, id: AssetTypeId) -> (result: BitmapId) {
    result = cast(BitmapId) first_asset_from(assets, id)
    return result
}
first_font_from :: proc(assets: ^Assets, id: AssetTypeId) -> (result: FontId) {
    result = cast(FontId) first_asset_from(assets, id)
    return result
}
first_asset_from :: proc(assets: ^Assets, id: AssetTypeId) -> (result: u32) {
    type := assets.types[id]
    
    if type.first_asset_index != type.one_past_last_index {
        result = type.first_asset_index
    }
    
    return result
}

best_match_sound_from :: proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> SoundId {
    return cast(SoundId) best_match_asset_from(assets, id, match_vector, weight_vector)
}
best_match_bitmap_from :: proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> BitmapId {
    return cast(BitmapId) best_match_asset_from(assets, id, match_vector, weight_vector)
}
best_match_font_from :: proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> FontId {
    return cast(FontId) best_match_asset_from(assets, id, match_vector, weight_vector)
}
best_match_asset_from :: proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> (result: u32) {
    type := assets.types[id]

    if type.first_asset_index != type.one_past_last_index {
        
        best_diff := +Infinity
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

random_sound_from :: proc(assets: ^Assets, id: AssetTypeId, series: ^RandomSeries) -> (result: SoundId) {
    result = cast(SoundId) random_asset_from(assets, id, series)
    return result
}
random_bitmap_from :: proc(assets: ^Assets, id: AssetTypeId, series: ^RandomSeries) -> (result: BitmapId) {
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

begin_generation :: proc(assets: ^Assets) -> (result: AssetGenerationId) {
    timed_function()
    begin_asset_lock(assets)
    
    result = assets.next_generation
    assets.next_generation += 1
    assets.in_flight_generations[assets.in_flight_generation_count] = result
    assets.in_flight_generation_count += 1
    
    end_asset_lock(assets)
    
    return result
}

end_generation :: proc(assets: ^Assets, generation: AssetGenerationId) {
    for &in_flight in assets.in_flight_generations[:assets.in_flight_generation_count] {
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
        if ok, _ := atomic_compare_exchange(&assets.memory_operation_lock, 0, 1); ok {
            break
        }
    }
}
end_asset_lock :: proc(assets: ^Assets) {
    complete_previous_writes_before_future_writes()
    volatile_store(&assets.memory_operation_lock, 0)
}

acquire_asset_memory :: proc(assets: ^Assets, asset_index: $Id/u32, div: ^Divider, #any_int alignment: u64 = 4) -> (result: ^AssetMemoryHeader) {
    timed_function()
    size := div.total + size_of(AssetMemoryHeader)
    begin_asset_lock(assets)
    defer end_asset_lock(assets)
    
    block := find_block_for_size(assets, size)
    
    for {
        if block != nil && block.size >= size {
            block.flags += { .Used }
            
            { // :PointerArithmetic
                blocks := cast([^]AssetMemoryBlock) block
                next_block := &blocks[1]
                result = cast(^AssetMemoryHeader) next_block
            }
            
            alignment_offset := cast(umm) result & cast(umm) (alignment - 1)
            if alignment_offset != 0 {
                result = cast(^AssetMemoryHeader) align_pow2(cast(umm) result, cast(umm) (alignment - 1))
            }
            
            if(block.size - (alignment - auto_cast alignment_offset) >= size) {
                remaining_size := block.size - size
                
                BlockSplitThreshhold :: 4 * Kilobyte // @todo(viktor): set this based on the smallest asset size
                
                if remaining_size >= BlockSplitThreshhold {
                    block.size -= remaining_size
                    // :PointerArithmetic
                    insert_block(block, (cast([^]u8)result)[size:], remaining_size)
                }
                break
            }
        } else {
            for it := assets.loaded_asset_sentinel.prev; it != &assets.loaded_asset_sentinel; it = it.prev {
                asset := &assets.assets[it.asset_index]
                if asset.state == .Loaded && generation_has_completed(assets, asset.header.generation_id) {
                    if bitmap, ok := &asset.header.value.(Bitmap); ok {
                        op := TextureOpDeallocate { handle = bitmap.texture_handle }
                        add_texture_op(assets.texture_op_queue, { value = op })
                        
                        bitmap.texture_handle = 0
                    }
                    list_remove(it)
                    
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
        header.asset_index = cast(u32) asset_index
        
        list_prepend(&assets.loaded_asset_sentinel, header)
    }

    return result
}

insert_block :: proc(previous: ^AssetMemoryBlock, memory: pmm, size: u64) -> (result: ^AssetMemoryBlock) {
    assert(size > size_of(AssetMemoryBlock))
    result = cast(^AssetMemoryBlock) memory
    result.size = size - size_of(AssetMemoryBlock)
    
    result.flags = {}
    
    list_prepend(previous, result)
    
    return result
}

find_block_for_size :: proc(assets: ^Assets, size: u64) -> (result: ^AssetMemoryBlock) {
    // @todo(viktor): find best matched block
    // @todo(viktor): this will probably need to be accelarated in the 
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
    if first != &assets.memory_sentinel && second != &assets.memory_sentinel && second != nil {
        if .Used not_in first.flags && .Used not_in second.flags {
            // :PointerArithmetic
            expect_second_memory := &(cast([^]u8) first)[size_of(AssetMemoryBlock) + first.size] 
            if cast(pmm) second == expect_second_memory {
                list_remove(second)
                
                first.size += size_of(AssetMemoryBlock) + second.size
                result = true
            }
        }
    }
    return result
}

////////////////////////////////
// Loading

LoadAssetWork :: struct {
    task:  ^TaskWithMemory,
    asset: ^Asset,
    texture_op_queue: ^TextureOpQueue,
    
    handle:           ^PlatformFileHandle,
    position, amount: u64,
    destination:      pmm,
    
    kind: AssetKind,
}

prefetch_sound  :: proc(assets: ^Assets, id: SoundId)  { load_sound(assets,  id)  }
prefetch_bitmap :: proc(assets: ^Assets, id: BitmapId) { load_bitmap(assets, id, false) }
prefetch_font   :: proc(assets: ^Assets, id: FontId)   { load_font(assets,   id, false) }

load_sound  :: proc(assets: ^Assets, id: SoundId)                  { load_asset(assets, .Sound,  cast(u32) id, false)}
load_bitmap :: proc(assets: ^Assets, id: BitmapId, immediate: b32) { load_asset(assets, .Bitmap, cast(u32) id, immediate)}
load_font   :: proc(assets: ^Assets, id: FontId,   immediate: b32) { load_asset(assets, .Font,   cast(u32) id, immediate)}

get_file :: proc(assets: ^Assets, file_index: u32) -> (result: ^AssetFile) {
    result = &assets.files[file_index]
    return result
}

get_file_handle_for :: proc(assets: ^Assets, file_index: u32) -> (result: ^PlatformFileHandle) {
    result = &get_file(assets, file_index).handle
    return result
}

add_texture_op :: proc (queue: ^TextureOpQueue, source: TextureOp) {
    begin_ticket_mutex(&queue.mutex)
    defer end_ticket_mutex(&queue.mutex)
    
    // @todo(viktor): Can we devise a soft failure case for running out of ops?
    assert(queue.first_free != nil)
    
    dest := list_pop_head(&queue.first_free)
    dest ^= source
    assert(dest.next == nil)
    
    deque_prepend(&queue.ops, dest)
}

load_asset_work_immediatly :: proc(work: ^LoadAssetWork) {
    timed_function()
    
    Platform.read_data_from_file(work.handle, work.position, work.amount, work.destination)
    
    if Platform_no_file_errors(work.handle) {
        switch work.kind {
          case .Sound: // @note(viktor): nothing to do
          case .Bitmap:
            bitmap := &work.asset.header.value.(Bitmap)
            
            op := TextureOpAllocate {
                width = bitmap.width, 
                height = bitmap.height, 
                data = raw_data(bitmap.memory),
                
                result = &bitmap.texture_handle,
            }
            
            add_texture_op(work.texture_op_queue, { value = op })
            
          case .Font: 
            font := work.asset.header.value.(Font)
            info := work.asset.info.font
            for glyph_index in 1..<info.glyph_count {
                glyph := &font.glyphs[glyph_index]
                assert(glyph.codepoint < info.one_past_highest_codepoint)
                font.unicode_map[glyph.codepoint] = cast(u16) glyph_index
            }
        }
    }
    
    if !Platform_no_file_errors(work.handle) {
        zero(work.destination, work.amount)
    }
    
    // @todo(viktor): when can we know that the texture is loaded
    work.asset.state = .Loaded
}

do_load_asset_work : PlatformWorkQueueCallback : proc(data: pmm) {
    work := cast(^LoadAssetWork) data
    
    load_asset_work_immediatly(work)
    
    end_task_with_memory(work.task)
}

AssetKind :: enum {Font, Bitmap, Sound}
load_asset :: proc(assets: ^Assets, kind: AssetKind, id: u32, immediate: b32) {
    immediate := immediate 
    immediate ||= LoadAssetsSingleThreaded
    
    if is_valid_asset(id) {
        asset := &assets.assets[id]
        if ok, _ := atomic_compare_exchange(&asset.state, AssetState.Unloaded, AssetState.Queued); ok {
            task: ^TaskWithMemory
            if !immediate {
                task = begin_task_with_memory(assets.tran_state) 
            }
            
            if immediate || task != nil {
                memory, memory_size := allocate_asset_memory(assets, kind, id, asset)

                work := LoadAssetWork {
                    task = task,
                    texture_op_queue = assets.texture_op_queue,
                    
                    handle = get_file_handle_for(assets, asset.file_index),
                    
                    position    = asset.data_offset, 
                    amount      = memory_size,
                    destination = memory,
                    
                    asset = asset,
                    kind = kind,
                }
                
                if immediate {
                    load_asset_work_immediatly(&work)
                } else {
                    task_work := push(&task.arena, LoadAssetWork, no_clear())
                    task_work ^= work
                    Platform.enqueue_work(assets.tran_state.low_priority_queue, task_work, do_load_asset_work)
                }
            } else {
                ok, _ = atomic_compare_exchange(&asset.state, AssetState.Queued, AssetState.Unloaded)
                assert(ok)
            }
        } else if immediate {
            for volatile_load(&asset.state) == .Queued {}
        }
    }
}

allocate_asset_memory:: proc(assets: ^Assets, kind: AssetKind, #any_int id: u32, asset: ^Asset) -> (memory: pmm, memory_size: u64 ) {
    timed_function()
    divider: Divider
    switch kind {
      case .Font: // [Header][Glyphs][Advances][UnicodeMap]
        info := asset.data.info.font
        divider_reserve(&divider, hha.GlyphInfo, cast(u64) info.glyph_count)
        divider_reserve(&divider, f32, cast(u64) (info.glyph_count * info.glyph_count))
        memory_size = divider.total
        // @note(viktor): the unicode_map is generate at runtime
        divider_reserve(&divider, u16, info.one_past_highest_codepoint)
      case .Bitmap: // [Header][pixels]
        info := asset.data.info.bitmap
        divider_reserve(&divider, Color, info.dimension.x * info.dimension.y)
        memory_size = divider.total
      case .Sound: // [Header][channels[samples]]
        info := asset.data.info.sound
        for _ in 0..<info.channel_count {
            divider_reserve(&divider, i16, info.sample_count)
        }
        memory_size = divider.total
    }
    
    asset.header = acquire_asset_memory(assets, id, &divider, 16)
    memory = divider_acquire(&divider, asset.header)
    
    switch kind {
      case .Font:
        info := asset.info.font
        
        asset.header.value = Font{
            bitmap_id_offset = get_file(assets, asset.file_index).font_bitmap_id_offset,
        }
        font := &asset.header.value.(Font)
        
        divider_designate(&divider, &font.glyphs)
        divider_designate(&divider, &font.advances)
        divider_designate(&divider, &font.unicode_map)
        divider_hand_over(&divider)
        assert(auto_cast len(font.glyphs) == info.glyph_count)
        assert(auto_cast len(font.advances) == info.glyph_count * info.glyph_count)
        assert(auto_cast len(font.unicode_map) == info.one_past_highest_codepoint)
      case .Bitmap: 
        info := asset.info.bitmap
          
        asset.header.value = Bitmap{
            width  = cast(i32) info.dimension.x,
            height = cast(i32) info.dimension.y,
        
            align_percentage = info.align_percentage,
            width_over_height = cast(f32) info.dimension.x / cast(f32) info.dimension.y,
        }
        bitmap := &asset.header.value.(Bitmap)
        
        divider_designate(&divider, &bitmap.memory)
        divider_hand_over(&divider)
        assert(auto_cast len(bitmap.memory) == bitmap.width * bitmap.height)
      case .Sound: 
        info := asset.info.sound
        
        asset.header.value = Sound{
            channel_count = cast(u8) info.channel_count,
        }
        sound := &asset.header.value.(Sound)
                                
        for &channel in sound.channels[:info.channel_count] {
            divider_designate(&divider, &channel)
        }
        divider_hand_over(&divider)
        assert(auto_cast len(sound.channels[0]) == info.sample_count)
        assert(auto_cast len(sound.channels[1]) == info.sample_count)
    }
    
    
    return memory, memory_size
}

DividerEntry :: struct {
    element: typeid,
    count:   u64,
    slice:   ^[]u8,
}

Divider :: struct {
    memory: []u8,
    total:  u64, 
    
    size_count:  u32,
    slice_count: u32,
    entries:     [4]DividerEntry,
}

divider_acquire :: proc(divider: ^Divider, header: ^AssetMemoryHeader) -> (total_memory: pmm) {
    // :PointerArithmetic
    HeaderSize :: size_of(AssetMemoryHeader)
    total_memory   = ((cast([^]u8) header)[HeaderSize:])
    divider.memory = slice_from_parts(u8, total_memory, header.total_size - HeaderSize)
    
    return total_memory
}

divider_reserve :: proc(divider: ^Divider, $E: typeid, #any_int count: u64) {
    entry := &divider.entries[divider.size_count]
    divider.size_count += 1
    
    entry.count  = count
    entry.element = E
    info := type_info_of(entry.element)
    assert(info.size == size_of(E))
    divider.total += cast(u64) info.size * entry.count
}

divider_designate :: proc(divider: ^Divider, slice: ^[]$E) {
    entry := &divider.entries[divider.slice_count]
    divider.slice_count += 1
    entry.slice = cast(^[]u8) slice
    assert(entry.element == E)
}

divider_hand_over :: proc(divider: ^Divider) {
    // @note(viktor): all the memory after the header should have been divvied up
    assert(divider.slice_count == divider.size_count)
    for entry in divider.entries[:divider.slice_count] {
        #no_bounds_check {
            // :PointerArithmetic
            entry.slice^   = divider.memory[:entry.count]
            info := type_info_of(entry.element)
            divider.memory = divider.memory[cast(u64) info.size * entry.count:]
        }
    }
    assert(cast(u64) len(divider.memory) == 0)
}

