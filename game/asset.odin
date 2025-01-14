package game

import "base:intrinsics"

Assets :: struct {
    tran_state: ^TransientState,
    arena: Arena,
    
    bitmaps:      []AssetSlot,
    bitmap_infos: []AssetBitmapInfo,

    sounds:  []AssetSlot,
    types:   [AssetTypeId]AssetType,
    assets:  []Asset,
    tags:    []AssetTag,
    
    
    // NOTE(viktor): structured assets
    monster: [2]LoadedBitmap,
    
    // TODO(viktor): These should go away once we actually load an asset file
    DEBUG_used_bitmap_count: u32,
    DEBUG_used_asset_count: u32,
    DEBUG_used_tag_count: u32,
    DEBUG_asset_type: ^AssetType,
    DEBUG_asset: ^Asset,
}

Asset :: struct {
    // TODO(viktor): should this just be a slice into the assets.tags?
    first_tag_index:         u32,
    one_past_last_tag_index: u32,
    
    slot_id:                 u32, // TODO(viktor): either BitmapId or SoundId
}

AssetType :: struct {
    // NOTE(viktor): A range within the assets.assets
    // TODO(viktor): should this just be a slice into the assets.assets?
    first_asset_index:   u32,
    one_past_last_index: u32,
}

SoundId  :: distinct u32
BitmapId :: distinct u32

AssetTypeId :: enum {
    None,
    
    Shadow, 
    Wall, 
    Arrow, 
    Stair, 
    
    Rock,
    Grass,
    
    Head,
    Body,
    Cape,
    Sword,
}

AssetState :: enum {
    Unloaded, 
    Queued, 
    Loaded, 
    Locked, 
}

AssetSlot :: struct {
    state:      AssetState,
    bitmap:     ^LoadedBitmap,
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

AssetVector :: [AssetTagId]f32

AssetGroup :: struct {
    id: u32,
 
    first_tag_index: u32,
    one_past_last_tag_index: u32,
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
    asset.slot_id = cast(u32) DEBUG_add_bitmap_info(assets, filename, align_percentage)
    
    assets.DEBUG_asset = asset
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

make_game_assets :: proc(arena: ^Arena, memory_size: u64, tran_state: ^TransientState) -> (assets: ^Assets) {
    assets = push(arena, Assets)
    
    sub_arena(&assets.arena, arena, memory_size)
    
    assets.tran_state = tran_state
    
    assets.bitmaps      = push(arena, AssetSlot,       256*len(AssetTypeId))
    assets.bitmap_infos = push(arena, AssetBitmapInfo, len(assets.bitmaps))
    
    assets.DEBUG_used_bitmap_count = 1
    assets.DEBUG_used_asset_count  = 1
    
    assets.sounds  = push(arena, AssetSlot, 1)
    assets.tags    = push(arena, AssetTag,  1024*len(AssetTypeId))
    assets.assets  = push(arena, Asset,     len(assets.bitmaps) + len(assets.sounds))
    
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
        
    assets.monster[0] = DEBUG_load_bmp("../assets/orc_left.bmp"     , v2{0.7 , 0    }) 
    assets.monster[1] = DEBUG_load_bmp("../assets/orc_right.bmp"    , v2{0.27, 0    }) 

    return assets
}

get_bitmap :: #force_inline proc(assets: ^Assets, id: BitmapId) -> (result: ^LoadedBitmap) {
    result = assets.bitmaps[id].bitmap
    
    return result
}

get_first_bitmap_id :: proc(assets: ^Assets, id: AssetTypeId) -> (result: BitmapId) {
    type := assets.types[id]
    
    if type.first_asset_index != type.one_past_last_index {
        asset := assets.assets[type.first_asset_index]
        result = cast(BitmapId) asset.slot_id
    }
    
    return result
}

best_match_asset_from :: proc(assets: ^Assets, id: AssetTypeId, match_vector, weight_vector: AssetVector) -> (result: BitmapId) {
    type := assets.types[id]

    if type.first_asset_index != type.one_past_last_index {
        
        best_diff := max(f32)
        for asset, asset_index in assets.assets[type.first_asset_index:type.one_past_last_index] {
    
            total_weight_diff: f32
            for tag in assets.tags[asset.first_tag_index:asset.one_past_last_tag_index] {
                difference := match_vector[ tag.id] - tag.value
                weighted   := weight_vector[tag.id] * abs(difference)
                
                total_weight_diff += weighted
            }
            
            if total_weight_diff < best_diff {
                best_diff = total_weight_diff
                result = cast(BitmapId) asset.slot_id
            }
        }
    }
    
    return result
}
random_asset_from :: proc(assets: ^Assets, id: AssetTypeId, series: ^RandomSeries) -> (result: BitmapId) {
    type := assets.types[id]
    
    if type.first_asset_index != type.one_past_last_index {
        choices := assets.assets[type.first_asset_index:type.one_past_last_index]
        choice := random_choice(series, choices)
        result = cast(BitmapId) choice.slot_id
    }
    
    return result
}

load_sound :: proc(assets: ^Assets, id: SoundId) {}

load_bitmap :: proc(assets: ^Assets, id: BitmapId) {
    if id != 0 {
        if _, ok := atomic_compare_exchange(&assets.bitmaps[id].state, AssetState.Unloaded, AssetState.Queued); ok {
            if task := begin_task_with_memory(assets.tran_state); task != nil {
                LoadBitmapWork :: struct {
                    task:   ^TaskWithMemory,
                    assets: ^Assets,
                    
                    bitmap:      ^LoadedBitmap,
                    final_state: AssetState, 
                    
                    id:        BitmapId,
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
                work.bitmap      = push(&assets.arena, LoadedBitmap, alignment = 16)
                work.final_state = .Loaded
                
                PLATFORM_enqueue_work(assets.tran_state.low_priority_queue, do_load_bitmap_work, work)
            } else {
                _, ok = atomic_compare_exchange(&assets.bitmaps[id].state, AssetState.Queued, AssetState.Unloaded)
                assert(auto_cast ok)
            }
        }
    }
}


DEBUG_load_bmp :: proc (file_name: string, alignment_percentage: v2 = 0.5) -> (result: LoadedBitmap) {
    contents := DEBUG_read_entire_file(file_name)
    
    BMPHeader :: struct #packed {
        file_type      : [2]u8,
        file_size      : u32,
        reserved_1     : u16,
        reserved_2     : u16,
        bitmap_offset  : u32,
        size           : u32,
        width          : i32,
        height         : i32,
        planes         : u16,
        bits_per_pixel : u16,

        compression           : u32,
        size_of_bitmap        : u32,
        horizontal_resolution : i32,
        vertical_resolution   : i32,
        colors_used           : u32,
        colors_important      : u32,

        red_mask   : u32,
        green_mask : u32,
        blue_mask  : u32,
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
            start  = 0,
            pitch  = header.width,
            width_over_height = safe_ratio_0(cast(f32) header.width, cast(f32) header.height),
            align_percentage = alignment_percentage,
        }

        when false {
            result.start = header.width * (header.height-1)
            result.pitch = -result.pitch
        }
        return result
    }
    
    return {}
}