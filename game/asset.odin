package game

import "base:intrinsics"

Sound :: struct {
    channel_count: u32,
    channels: [2][]i16, // 1 or 2 channels of samples
}

Assets :: struct {
    tran_state: ^TransientState,
    arena: Arena,
    
    bitmaps:      []AssetSlot,
    bitmap_infos: []AssetBitmapInfo,
    sounds:       []AssetSlot,
    sound_infos:  []AssetSoundInfo,

    types:   [AssetTypeId]AssetType,
    assets:  []Asset,
    
    tags:    []AssetTag,
    tag_ranges: [AssetTagId]f32,
    
    
    // TODO(viktor): These should go away once we actually load an asset file
    DEBUG_used_bitmap_count: u32,
    DEBUG_used_sound_count: u32,
    DEBUG_used_asset_count: u32,
    DEBUG_used_tag_count: u32,
    DEBUG_asset_type: ^AssetType,
    DEBUG_asset: ^Asset,
}

AssetId  :: union { SoundId, BitmapId }
SoundId  :: distinct u32
BitmapId :: distinct u32

Asset :: struct {
    // TODO(viktor): should this just be a slice into the assets.tags?
    first_tag_index:         u32,
    one_past_last_tag_index: u32,
    
    id: AssetId,
}

AssetType :: struct {
    // NOTE(viktor): A range within the assets.assets
    // TODO(viktor): should this just be a slice into the assets.assets?
    first_asset_index:   u32,
    one_past_last_index: u32,
}

AssetTypeId :: enum {
    None,
    
    //
    // NOTE(viktor): Bitmaps
    //
    
    Shadow, Wall, Arrow, Stair, 
    
    // variant
    Rock, Grass,
    
    // structured
    Head, Body, Cape, Sword,
    Monster,
    
    //
    // NOTE(viktor): Sounds
    //
    
    // variant
    Blop, Drop, Woosh, Hit,
    Music,
}

AssetState :: enum {
    Unloaded, Queued, Loaded, Locked, 
}

AssetSlot :: struct {
    state:  AssetState,

    using _ : struct #raw_union {
        bitmap: ^Bitmap,
        sound:  ^Sound,
    }
}

AssetTagId :: enum {
    // Smoothness,
    // Flatness,
    FacingDirection, // NOTE(viktor): angle in radians
}

AssetTag :: struct {
    id:    AssetTagId,
    value: f32,
}

AssetBitmapInfo :: struct {
    align_percentage: [2]f32,
    file_name:        string,
}

AssetSoundInfo :: struct {
    file_name:        string,
}

AssetVector :: [AssetTagId]f32

make_game_assets :: proc(arena: ^Arena, memory_size: u64, tran_state: ^TransientState) -> (assets: ^Assets) {
    assets = push(arena, Assets)
    sub_arena(&assets.arena, arena, memory_size)
    assets.tran_state = tran_state
    
    assets.bitmaps      = push(arena, AssetSlot,       256*len(AssetTypeId))
    assets.bitmap_infos = push(arena, AssetBitmapInfo, len(assets.bitmaps))
    
    assets.sounds      = push(arena, AssetSlot,      256*len(AssetTypeId))
    assets.sound_infos = push(arena, AssetSoundInfo, len(assets.sounds))
    
    assets.tags    = push(arena, AssetTag,  1024*len(AssetTypeId))
    assets.assets  = push(arena, Asset,     len(assets.bitmaps) + len(assets.sounds))
    
    assets.DEBUG_used_bitmap_count = 1
    assets.DEBUG_used_asset_count  = 1
    
    for &range in assets.tag_ranges {
        range = 100_000_000
    }
    
    assets.tag_ranges[.FacingDirection] = Tau
    
    // 
    // NOTE(Viktor): Bitmaps
    // 
        
    begin_asset_type(assets, .Shadow)
    add_bitmap_asset(assets, "../assets/shadow.bmp", {0.5, -0.4})
    end_asset_type(assets)
        
    begin_asset_type(assets, .Arrow)
    add_bitmap_asset(assets, "../assets/arrow.bmp" )
    end_asset_type(assets)
    
    begin_asset_type(assets, .Stair)
    add_bitmap_asset(assets, "../assets/stair.bmp")
    end_asset_type(assets)

    begin_asset_type(assets, .Rock)
    add_bitmap_asset(assets, "../assets/rocks1.bmp")
    add_bitmap_asset(assets, "../assets/rocks2.bmp")
    add_bitmap_asset(assets, "../assets/rocks3.bmp")
    add_bitmap_asset(assets, "../assets/rocks4.bmp")
    add_bitmap_asset(assets, "../assets/rocks5.bmp")
    add_bitmap_asset(assets, "../assets/rocks7.bmp")
    end_asset_type(assets)
    
    // TODO(viktor): alignment percentages for these
    begin_asset_type(assets, .Grass)
    add_bitmap_asset(assets, "../assets/grass11.bmp")
    add_bitmap_asset(assets, "../assets/grass12.bmp")
    add_bitmap_asset(assets, "../assets/grass21.bmp")
    add_bitmap_asset(assets, "../assets/grass22.bmp")
    add_bitmap_asset(assets, "../assets/grass31.bmp")
    add_bitmap_asset(assets, "../assets/grass32.bmp")
    add_bitmap_asset(assets, "../assets/flower1.bmp")
    add_bitmap_asset(assets, "../assets/flower2.bmp")
    end_asset_type(assets)
    
    // add_bitmap_asset(result, "../assets/rocks6a.bmp")
    // add_bitmap_asset(result, "../assets/rocks6b.bmp")
    
    // add_bitmap_asset(result, "../assets/rocks8a.bmp")
    // add_bitmap_asset(result, "../assets/rocks8b.bmp")
    // add_bitmap_asset(result, "../assets/rocks8c.bmp")
    
    begin_asset_type(assets, .Cape)
    add_bitmap_asset(assets, "../assets/cape_left.bmp",  {0.36, 0.01})
    add_tag(assets, .FacingDirection, Pi)
    add_bitmap_asset(assets, "../assets/cape_right.bmp", {0.63, 0.01})
    add_tag(assets, .FacingDirection, 0)
    end_asset_type(assets)
                        
    begin_asset_type(assets, .Head)
    add_bitmap_asset(assets, "../assets/head_left.bmp",  {0.36, 0.01})
    add_tag(assets, .FacingDirection, Pi)
    add_bitmap_asset(assets, "../assets/head_right.bmp", {0.63, 0.01})
    add_tag(assets, .FacingDirection, 0)
    end_asset_type(assets)
                
    begin_asset_type(assets, .Body)
    add_bitmap_asset(assets, "../assets/body_left.bmp",  {0.36, 0.01})
    add_tag(assets, .FacingDirection, Pi)
    add_bitmap_asset(assets, "../assets/body_right.bmp", {0.63, 0.01})
    add_tag(assets, .FacingDirection, 0)
    end_asset_type(assets)
                
    begin_asset_type(assets, .Sword)
    add_bitmap_asset(assets, "../assets/sword_left.bmp",  {0.36, 0.01})
    add_tag(assets, .FacingDirection, Pi)
    add_bitmap_asset(assets, "../assets/sword_right.bmp", {0.63, 0.01})
    add_tag(assets, .FacingDirection, 0)
    end_asset_type(assets)
        
    begin_asset_type(assets, .Monster)
    add_bitmap_asset(assets, "../assets/orc_left.bmp"     , v2{0.7 , 0})
    add_tag(assets, .FacingDirection, Pi)
    add_bitmap_asset(assets, "../assets/orc_right.bmp"    , v2{0.27, 0})
    add_tag(assets, .FacingDirection, 0)
    end_asset_type(assets)
    
    // 
    // NOTE(viktor): Sounds
    // 
    
    begin_asset_type(assets, .Blop)
    add_sound_asset(assets, "../assets/blop0.wav")
    add_sound_asset(assets, "../assets/blop1.wav")
    add_sound_asset(assets, "../assets/blop2.wav")
    end_asset_type(assets)
        
    begin_asset_type(assets, .Drop)
    add_sound_asset(assets, "../assets/drop0.wav")
    add_sound_asset(assets, "../assets/drop1.wav")
    add_sound_asset(assets, "../assets/drop2.wav")
    end_asset_type(assets)
        
    begin_asset_type(assets, .Hit)
    add_sound_asset(assets, "../assets/hit0.wav")
    add_sound_asset(assets, "../assets/hit1.wav")
    add_sound_asset(assets, "../assets/hit2.wav")
    add_sound_asset(assets, "../assets/hit3.wav")
    end_asset_type(assets)
                
    begin_asset_type(assets, .Woosh)
    add_sound_asset(assets, "../assets/woosh0.wav")
    add_sound_asset(assets, "../assets/woosh1.wav")
    add_sound_asset(assets, "../assets/woosh2.wav")
    end_asset_type(assets)
        
    begin_asset_type(assets, .Music)
    add_sound_asset(assets, "../assets/Light Ambience 1.wav")
    add_sound_asset(assets, "../assets/Light Ambience 2.wav")
    add_sound_asset(assets, "../assets/Light Ambience 3.wav")
    add_sound_asset(assets, "../assets/Light Ambience 4.wav")
    add_sound_asset(assets, "../assets/Light Ambience 5.wav")
    end_asset_type(assets)
    
    
    return assets
}

get_bitmap :: #force_inline proc(assets: ^Assets, id: BitmapId) -> (result: ^Bitmap) {
    result = assets.bitmaps[id].bitmap
    return result
}

get_sound :: #force_inline proc(assets: ^Assets, id: SoundId) -> (result: ^Sound) {
    result = assets.sounds[id].sound
    return result
}

first_sound_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId) -> (result: SoundId) {
    result = first_asset_from(assets, id).(SoundId)
    return result
}
first_bitmap_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId) -> (result: BitmapId) {
    result = first_asset_from(assets, id).(BitmapId)
    return result
}
first_asset_from :: proc(assets: ^Assets, id: AssetTypeId) -> (result: AssetId) {
    type := assets.types[id]
    
    if type.first_asset_index != type.one_past_last_index {
        asset := assets.assets[type.first_asset_index]
        result = asset.id
    }
    
    return result
}

best_match_sound_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> (result: SoundId) {
    result = best_match_asset_from(assets, id, match_vector, weight_vector).(SoundId)
    return result
}
best_match_bitmap_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> (result: BitmapId) {
    result = best_match_asset_from(assets, id, match_vector, weight_vector).(BitmapId)
    return result
}
best_match_asset_from :: proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> (result: AssetId) {
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
                result = asset.id
            }
        }
    }
    
    return result
}

random_sound_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, series: ^RandomSeries) -> (result: SoundId) {
    result = random_asset_from(assets, id, series).(SoundId)
    return result
}
random_bitmap_from :: #force_inline proc(assets: ^Assets, id: AssetTypeId, series: ^RandomSeries) -> (result: BitmapId) {
    result = random_asset_from(assets, id, series).(BitmapId)
    return result
}
random_asset_from :: proc(assets: ^Assets, id: AssetTypeId, series: ^RandomSeries) -> (result: AssetId) {
    type := assets.types[id]
    
    if type.first_asset_index != type.one_past_last_index {
        choices := assets.assets[type.first_asset_index:type.one_past_last_index]
        choice := random_choice(series, choices)
        result = choice.id
    }
    
    return result
}

load_sound :: proc(assets: ^Assets, id: SoundId) {
    if id != 0 {
        if _, ok := atomic_compare_exchange(&assets.sounds[id].state, AssetState.Unloaded, AssetState.Queued); ok {
            if task := begin_task_with_memory(assets.tran_state); task != nil {
                LoadSoundWork :: struct {
                    task:   ^TaskWithMemory,
                    assets: ^Assets,
                    
                    sound: ^Sound,
                    final_state: AssetState, 
                    
                    id: SoundId,
                }
                        
                do_load_sound_work : PlatformWorkQueueCallback : proc(data: rawpointer) {
                    work := cast(^LoadSoundWork) data
                 
                    info := work.assets.sound_infos[work.id]
                    work.sound^ = DEBUG_load_wav(info.file_name)
                    
                    complete_previous_writes_before_future_writes()
                    
                    slot := &work.assets.sounds[work.id]
                    slot.sound = work.sound
                    slot.state = work.final_state
                    
                    end_task_with_memory(work.task)
                }

                work := push(&assets.arena, LoadSoundWork)
                
                work.assets      = assets
                work.id          = id
                work.task        = task
                work.sound       = push(&assets.arena, Sound)
                work.final_state = .Loaded
                
                PLATFORM_enqueue_work(assets.tran_state.low_priority_queue, do_load_sound_work, work)
            } else {
                _, ok = atomic_compare_exchange(&assets.sounds[id].state, AssetState.Queued, AssetState.Unloaded)
                assert(auto_cast ok)
            }
        }
    }
}

load_bitmap :: proc(assets: ^Assets, id: BitmapId) {
    if id != 0 {
        if _, ok := atomic_compare_exchange(&assets.bitmaps[id].state, AssetState.Unloaded, AssetState.Queued); ok {
            if task := begin_task_with_memory(assets.tran_state); task != nil {
                LoadBitmapWork :: struct {
                    task:   ^TaskWithMemory,
                    assets: ^Assets,
                    
                    bitmap:      ^Bitmap,
                    final_state: AssetState, 
                    
                    id: BitmapId,
                }
                        
                do_load_bitmap_work : PlatformWorkQueueCallback : proc(data: rawpointer) {
                    work := cast(^LoadBitmapWork) data
                 
                    info := work.assets.bitmap_infos[work.id]
                    work.bitmap^ = DEBUG_load_bmp(info.file_name, info.align_percentage)
                    
                    complete_previous_writes_before_future_writes()
                    
                    slot := &work.assets.bitmaps[work.id]
                    slot.bitmap = work.bitmap
                    slot.state  = work.final_state
                    
                    end_task_with_memory(work.task)
                }

                work := push(&assets.arena, LoadBitmapWork)
                
                work.assets      = assets
                work.id          = id
                work.task        = task
                work.bitmap      = push(&assets.arena, Bitmap, alignment = 16)
                work.final_state = .Loaded
                
                PLATFORM_enqueue_work(assets.tran_state.low_priority_queue, do_load_bitmap_work, work)
            } else {
                _, ok = atomic_compare_exchange(&assets.bitmaps[id].state, AssetState.Queued, AssetState.Unloaded)
                assert(auto_cast ok)
            }
        }
    }
}

begin_asset_type :: proc(assets: ^Assets, id: AssetTypeId) {
    assert(assets.DEBUG_asset_type == nil)
    assert(assets.DEBUG_asset == nil)
    
    assets.DEBUG_asset_type = &assets.types[id]
    assets.DEBUG_asset_type.first_asset_index   = auto_cast assets.DEBUG_used_asset_count
    assets.DEBUG_asset_type.one_past_last_index = assets.DEBUG_asset_type.first_asset_index
}

add_bitmap_asset :: proc(assets: ^Assets, filename: string, align_percentage: v2 = {0.5, 0.5}) {
    assert(assets.DEBUG_asset_type != nil)
    
    asset := &assets.assets[assets.DEBUG_asset_type.one_past_last_index]
    assets.DEBUG_asset_type.one_past_last_index += 1
    asset.first_tag_index = assets.DEBUG_used_asset_count
    asset.one_past_last_tag_index = asset.first_tag_index
    asset.id = DEBUG_add_bitmap_info(assets, filename, align_percentage)
    
    assets.DEBUG_asset = asset
}

DEBUG_add_bitmap_info :: proc(assets: ^Assets, file_name: string, align_percentage: v2) -> (result: BitmapId) {
    assert(assets.DEBUG_used_bitmap_count < auto_cast len(assets.bitmap_infos))
    
    id := cast(BitmapId) assets.DEBUG_used_bitmap_count
    assets.DEBUG_used_bitmap_count += 1
    
    info := &assets.bitmap_infos[id]
    info.align_percentage = align_percentage
    info.file_name        = file_name
    
    return id
}

add_sound_asset :: proc(assets: ^Assets, filename: string) {
    assert(assets.DEBUG_asset_type != nil)
    
    asset := &assets.assets[assets.DEBUG_asset_type.one_past_last_index]
    assets.DEBUG_asset_type.one_past_last_index += 1
    asset.first_tag_index = assets.DEBUG_used_asset_count
    asset.one_past_last_tag_index = asset.first_tag_index
    asset.id = DEBUG_add_sound_info(assets, filename)
    
    assets.DEBUG_asset = asset
}

DEBUG_add_sound_info :: proc(assets: ^Assets, file_name: string) -> (result: SoundId) {
    assert(assets.DEBUG_used_sound_count < auto_cast len(assets.sound_infos))
    
    id := cast(SoundId) assets.DEBUG_used_sound_count
    assets.DEBUG_used_sound_count += 1
    
    info := &assets.sound_infos[id]
    info.file_name = file_name
    
    return id
}

add_tag :: proc(assets: ^Assets, id: AssetTagId, value: f32) {
    assert(assets.DEBUG_asset_type != nil)
    assert(assets.DEBUG_asset != nil)
    
    assets.DEBUG_asset.one_past_last_tag_index += 1
    
    tag := &assets.tags[assets.DEBUG_used_asset_count]
    assets.DEBUG_used_asset_count += 1
    
    tag.id = id
    tag.value = value
}

end_asset_type :: proc(assets: ^Assets) {
    assert(assets.DEBUG_asset_type != nil)
    
    assets.DEBUG_used_asset_count = assets.DEBUG_asset_type.one_past_last_index
    assets.DEBUG_asset_type = nil
    assets.DEBUG_asset = nil
}

DEBUG_load_wav :: proc (file_name: string) -> (result: Sound) {
    contents := DEBUG_read_entire_file(file_name)
    
    WAVE_Header :: struct #packed {
        riff: u32,
        size:    u32,
        wave_id: u32,
    }
    
    WAVE_Format :: enum u16 {
        PCM        = 0x0001,
        IEEE_FLOAT = 0x0003,
        ALAW       = 0x0006,
        MULAW      = 0x0007,
        EXTENSIBLE = 0xfffe,
    }
    
    WAVE_Chunk_ID :: enum u32 {
        None = 0,
        RIFF = 'R' << 0 | 'I' << 8 | 'F' << 16 | 'F' << 24,
        WAVE = 'W' << 0 | 'A' << 8 | 'V' << 16 | 'E' << 24,
        fmt_ = 'f' << 0 | 'm' << 8 | 't' << 16 | ' ' << 24,
        data = 'd' << 0 | 'a' << 8 | 't' << 16 | 'a' << 24,
    }
    
    WAVE_Chunk :: struct #packed {
        id:    WAVE_Chunk_ID,
        size:  u32,
    }
    
    WAVE_fmt :: struct #packed {
        format_tag: WAVE_Format,
        n_channels: u16,
        n_samples_per_seconds: u32,
        avg_bytes_per_sec: u32,
        block_align: u16,
        bits_per_sample: u16,
        cb_size: u16,
        valid_bits_per_sample: u16,
        channel_mask: u32,
        sub_format: [16]u8,
    }

    RiffIterator :: struct {
        at:    [^]u8,
        stop:  rawpointer,
    }
    
    if len(contents) > 0 {
        headers := cast([^]WAVE_Header) &contents[0]
        header := headers[0]
        behind_header := cast([^]u8) &headers[1]
        
        assert(header.riff == cast(u32) WAVE_Chunk_ID.RIFF)
        assert(header.wave_id == cast(u32) WAVE_Chunk_ID.WAVE)
        
        parse_chunk_at :: #force_inline proc(at: rawpointer, stop: rawpointer) -> (result: RiffIterator) {
            result.at    = cast([^]u8) at
            result.stop  = stop
            
            return result
        }
        
        is_valid_riff_iter :: #force_inline proc(it: RiffIterator) -> (result: b32) {
            at := cast(uintpointer) it.at
            stop := cast(uintpointer) it.stop
            result = at < stop 
            
            return result
        }
        
        next_chunk :: #force_inline proc(it: RiffIterator) -> (result: RiffIterator) {
            chunk := cast(^WAVE_Chunk)it.at
            size := chunk.size
            if size % 2 != 0 {
                size += 1
            }
            result.at = cast([^]u8) &it.at[size + size_of(WAVE_Chunk)]
            result.stop = it.stop
            return result
        }
        
        get_chunk_data :: #force_inline proc(it: RiffIterator) -> (result: rawpointer) {
            result = &it.at[size_of(WAVE_Chunk)]
            return result
        }
        
        get_chunk_size :: #force_inline proc(it: RiffIterator) -> (result: u32) {
            chunk := cast(^WAVE_Chunk)it.at
            result = chunk.size
            
            return result
        }
        
        get_type :: #force_inline proc(it: RiffIterator) -> (result: WAVE_Chunk_ID) {
            chunk := cast(^WAVE_Chunk)it.at
            result = chunk.id
            return result
        }
        
        channel_count: u32
        sample_data: [^]i16
        sample_data_size: u32
        
        for it := parse_chunk_at(behind_header, cast(rawpointer) &behind_header[header.size - 4]); is_valid_riff_iter(it); it = next_chunk(it) {
            #partial switch get_type(it) {
            case .fmt_: 
                fmt := cast(^WAVE_fmt) get_chunk_data(it)
                assert(fmt.format_tag == .PCM)
                assert(fmt.n_samples_per_seconds == 48000)
                assert(fmt.bits_per_sample == 16)
                assert(fmt.block_align == size_of(u16) * fmt.n_channels)
                channel_count = cast(u32) fmt.n_channels
            case .data: 
                sample_data = cast([^]i16) get_chunk_data(it)
                sample_data_size = get_chunk_size(it)
            }
        }
        
        assert(sample_data != nil)
        assert(channel_count != 0)
        assert(sample_data_size != 0)
        
        sample_count := sample_data_size / (size_of(u16) * channel_count)
        if channel_count == 1 {
            result.channels[0] = sample_data[:sample_count]
            result.channels[1] = nil
        } else if channel_count == 2 {
            result.channels[0] = sample_data[:sample_count]
            result.channels[1] = sample_data[sample_count:sample_count*2]
            
            for index:u32 ; index < sample_count; index += 1 {
                source := sample_data[2*index]
                sample_data[2*index] = sample_data[index]
                sample_data[index]   = source
            }
        } else {
            assert(false, "invalid channel count in WAV file")
        }
        result.channel_count = channel_count
    }
    
    return result
}

DEBUG_load_bmp :: proc (file_name: string, alignment_percentage: v2 = 0.5) -> (result: Bitmap) {
    contents := DEBUG_read_entire_file(file_name)
    
    BMPHeader :: struct #packed {
        file_type     : [2]u8,
        file_size     : u32,
        reserved_1    : u16,
        reserved_2    : u16,
        bitmap_offset : u32,
        size          : u32,
        width         : i32,
        height        : i32,
        planes        : u16,
        bits_per_pixel: u16,

        compression          : u32,
        size_of_bitmap       : u32,
        horizontal_resolution: i32,
        vertical_resolution  : i32,
        colors_used          : u32,
        colors_important     : u32,

        red_mask  ,
        green_mask,
        blue_mask : u32,
    }

    // NOTE: If you are using this generically for some reason,
    // please remember that BMP files CAN GO IN EITHER DIRECTION and
    // the height will be negative for top-down.
    // (Also, there can be compression, etc., etc ... DON'T think this
    // a complete implementation)
    // NOTE: pixels listed bottom up
    if len(contents) > 0 {
        header := cast(^BMPHeader) &contents[0]

        assert(header.bits_per_pixel == 32)
        assert(header.height >= 0)
        assert(header.compression == 3)

        red_mask   := header.red_mask
        green_mask := header.green_mask
        blue_mask  := header.blue_mask
        alpha_mask := ~(red_mask | green_mask | blue_mask)

        red_shift   := intrinsics.count_trailing_zeros(red_mask)
        green_shift := intrinsics.count_trailing_zeros(green_mask)
        blue_shift  := intrinsics.count_trailing_zeros(blue_mask)
        alpha_shift := intrinsics.count_trailing_zeros(alpha_mask)
        assert(red_shift   != 32)
        assert(green_shift != 32)
        assert(blue_shift  != 32)
        assert(alpha_shift != 32)
        
        raw_pixels := (cast([^]u32) &contents[header.bitmap_offset])[:header.width * header.height]
        pixels     := transmute([]ByteColor) raw_pixels
        for y in 0..<header.height {
            for x in 0..<header.width {
                c := raw_pixels[y * header.width + x]
                p := &pixels[y * header.width + x]
                
                texel := vec_cast(f32, 
                    vec_cast(u8, 
                        ((c & red_mask)   >> red_shift),
                        ((c & green_mask) >> green_shift),
                        ((c & blue_mask)  >> blue_shift),
                        ((c & alpha_mask) >> alpha_shift),
                    ),
                )
                
                texel = srgb_255_to_linear_1(texel)
                
                texel.rgb = texel.rgb * texel.a
                
                texel = linear_1_to_srgb_255(texel)
                
                p^ = vec_cast(u8, texel + 0.5)
            }
        }
        
        result = {
            memory = pixels, 
            width  = header.width, 
            height = header.height, 
            pitch  = header.width,
            width_over_height = safe_ratio_0(cast(f32) header.width, cast(f32) header.height),
            align_percentage = alignment_percentage,
        }

        return result
    }
    
    return {}
}