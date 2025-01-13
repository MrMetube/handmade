package game

import "base:intrinsics"

Assets :: struct {
    tran_state: ^TransientState,
    arena: Arena,
    
    bitmaps: []AssetSlot,
    sounds:  []AssetSlot,
    types:   [AssetTypeId]AssetType,
    assets:  []Asset,
    tags:    []AssetTag,
    
    // NOTE(viktor): Array'd assets
    grass:           [8]LoadedBitmap,
    player, monster: [2]LoadedBitmap,
    // NOTE(viktor): structured assets
}

Asset :: struct {
    first_tag_index:         u32,
    one_past_last_tag_index: u32,
    slot_id:                 u32,
}

AssetTagId :: enum {
    Smoothness,
    Flatness,
}

AssetTag :: struct {
    id:    u32, // NOTE(viktor): tag id
    value: f32,
}

AssetBitmapInfo :: struct {
    width, height: i32, 
    
    align_percentage:  [2]f32,
    width_over_height: f32,
}

AssetGroup :: struct {
    id: u32,
 
    first_tag_index: u32,
    one_past_last_tag_index: u32,
}

AssetType :: struct {
    first_asset_index:   u32,
    one_past_last_index: u32,
}

SoundId  :: distinct u32
BitmapId :: distinct u32

AssetTypeId :: enum {
    None,
    
    shadow, 
    wall, 
    sword, 
    stair, 
    rock,
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

make_game_assets :: proc(arena: ^Arena, memory_size: u64, tran_state: ^TransientState) -> (result: ^Assets) {
    result = push(arena, Assets)
    
    sub_arena(&result.arena, arena, memory_size)
    
    result.tran_state = tran_state
    
    result.bitmaps = push(arena, AssetSlot, len(AssetTypeId))
    result.sounds  = push(arena, AssetSlot, 1)
    result.tags    = push(arena, AssetTag,  0)
    result.assets  = push(arena, Asset,     len(result.bitmaps))
    
    for &type, index in result.types {
        type.first_asset_index   = auto_cast index
        type.one_past_last_index = auto_cast index+1
        
        asset := &result.assets[type.first_asset_index]
        asset.first_tag_index         = 0
        asset.one_past_last_tag_index = 0
        asset.slot_id                 = type.first_asset_index
    }
    
    // DEBUG_load_bmp(memory.debug.read_entire_file, "../assets/structuredArt.bmp")
    result.player[0]  = DEBUG_load_bmp("../assets/soldier_left.bmp" , v2{  16, 60})
    result.player[1]  = DEBUG_load_bmp("../assets/soldier_right.bmp", v2{  28, 60})
    result.monster[0] = DEBUG_load_bmp("../assets/orc_left.bmp"     , v2{  46, 44})
    result.monster[1] = DEBUG_load_bmp("../assets/orc_right.bmp"    , v2{  18, 44})
    
    result.grass[0] = DEBUG_load_bmp("../assets/grass11.bmp")
    result.grass[1] = DEBUG_load_bmp("../assets/grass12.bmp")
    result.grass[2] = DEBUG_load_bmp("../assets/grass21.bmp")
    result.grass[3] = DEBUG_load_bmp("../assets/grass22.bmp")
    result.grass[4] = DEBUG_load_bmp("../assets/grass31.bmp")
    result.grass[5] = DEBUG_load_bmp("../assets/grass32.bmp")
    result.grass[6] = DEBUG_load_bmp("../assets/flower1.bmp")   
    result.grass[7] = DEBUG_load_bmp("../assets/flower2.bmp")
    
    return result
}

get_bitmap :: #force_inline proc(assets: ^Assets, id: BitmapId) -> (result: ^LoadedBitmap) {
    result = assets.bitmaps[id].bitmap
    
    return result
}

get_first_bitmap_id :: proc(assets: ^Assets, id: AssetTypeId) -> (result: BitmapId) {
    type := &assets.types[id]
    
    if type.first_asset_index != type.one_past_last_index {
        asset := &assets.assets[type.first_asset_index]
        result = cast(BitmapId) asset.slot_id
    }
    
    return result
}

when false {
    pick_best :: proc(infos: []AssetBitmapInfo, tags:[]AssetTag, match_vector, weight_vector: []f32) -> (result: i32) {
        best_diff := max(f32)
        
        for info, index in infos {
            total_weight_diff: f32
            
            for tag_index := info.first_tag_index; tag_index < info.one_past_last_tag_index; tag_index += 1 {
                tag := &tags[tag_index]
                difference :f32= match_vector[tag.id] - tag.value
                weighted   := weight_vector[tag.id] * abs(difference)
                total_weight_diff += weighted
            }
            
            if total_weight_diff < best_diff {
                best_diff = total_weight_diff
                result = auto_cast index
            }
        }
        
        return result
    }
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
                    file_name: string,
                    
                    custom_alignment:   b32,
                    top_down_alignment: v2,
                }
                        
                do_load_bitmap_work : PlatformWorkQueueCallback : proc(data: rawpointer) {
                    data := cast(^LoadBitmapWork) data
                    
                    if data.custom_alignment {
                        data.bitmap^ = DEBUG_load_bmp_custom_alignment(data.file_name, data.top_down_alignment)
                    } else {
                        data.bitmap^ = DEBUG_load_bmp(data.file_name)
                    }
                    
                    complete_previous_writes_before_future_writes()
                    
                    slot := &data.assets.bitmaps[data.id]
                    slot.bitmap = data.bitmap
                    slot.state  = data.final_state
                    
                    end_task_with_memory(data.task)
                }

                work := push(&assets.arena, LoadBitmapWork)
                
                work.assets      = assets
                work.id          = id
                work.task        = task
                work.bitmap      = push(&assets.arena, LoadedBitmap, alignment = 16)
                work.final_state = .Loaded
                
                // TODO(viktor): handle all cases
                #partial switch cast(AssetTypeId)id {
                case .shadow:
                    work.file_name = "../assets/shadow.bmp"
                    work.custom_alignment = true
                    work.top_down_alignment = {  22, 14}
                case .sword:
                    work.file_name = "../assets/arrow.bmp"
                case .wall:
                    work.file_name = "../assets/wall.bmp"
                case .stair:
                    work.file_name = "../assets/stair.bmp"
                }
                
                PLATFORM_enqueue_work(assets.tran_state.low_priority_queue, do_load_bitmap_work, work)
            } else {
                _, ok = atomic_compare_exchange(&assets.bitmaps[id].state, AssetState.Queued, AssetState.Unloaded)
                assert(auto_cast ok)
            }
        }
    }
}


DEBUG_load_bmp :: proc { DEBUG_load_bmp_centered_alignment, DEBUG_load_bmp_custom_alignment }
DEBUG_load_bmp_centered_alignment :: proc (file_name: string) -> (result: LoadedBitmap) {
    result = DEBUG_load_bmp_custom_alignment(file_name, 0)
    result.align_percentage = 0.5
    return result
}
DEBUG_load_bmp_custom_alignment :: proc (file_name: string, topdown_alignment_value: v2) -> (result: LoadedBitmap) {
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
        
        meters_to_pixels :: 42.0
        pixels_to_meters :: 1.0 / meters_to_pixels

        result = {
            memory = pixels, 
            width  = header.width, 
            height = header.height, 
            start  = 0,
            pitch  = header.width,
            width_over_height = safe_ratio_0(cast(f32) header.width, cast(f32) header.height),
        }
        
        align := topdown_alignment_value - vec_cast(f32, i32(0), result.height-1)
        result.align_percentage = safe_ratio_0(align, vec_cast(f32, result.width, result.height))

        when false {
            result.start = header.width * (header.height-1)
            result.pitch = -result.pitch
        }
        return result
    }
    
    return {}
}