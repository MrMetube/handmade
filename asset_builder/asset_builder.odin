package asset_builder

import "base:intrinsics"

import "core:fmt"
import "core:math"
import "core:os"

Out: os.Handle

AssetType :: struct {
    // NOTE(viktor): A range within the assets.assets
    // TODO(viktor): should this just be a slice into the assets.assets?
    first_asset_index:   u32,
    one_past_last_index: u32,
}

Asset :: struct {
    data_offset: u32,
    // TODO(viktor): should this just be a slice into the assets.tags?
    first_tag_index:         u32,
    one_past_last_tag_index: u32,
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

AssetTagId :: enum {
    FacingDirection, // NOTE(viktor): angle in radians
}

AssetTag :: struct {
    id:    AssetTagId,
    value: f32,
}
 
AssetState :: enum {
    Unloaded, Queued, Loaded, Locked, 
}

AssetBitmapInfo :: struct {
    align_percentage: [2]f32,
    file_name:        string,
}

AssetSoundInfo :: struct {
    file_name:       string,
    
    first_sample_index: u32,
    sample_count:       u32,
    
    next_id_to_play: u32,
}

HUUGE :: 4096

bitmap_infos: [HUUGE]AssetBitmapInfo
sound_infos:  [HUUGE]AssetSoundInfo
types:   [AssetTypeId]AssetType
assets:  [HUUGE]Asset
tags:    [HUUGE]AssetTag
tag_ranges: [AssetTagId]f32

DEBUG_used_bitmap_count: u32
DEBUG_used_sound_count: u32
DEBUG_used_asset_count: u32
DEBUG_used_tag_count: u32
DEBUG_asset_type: ^AssetType
DEBUG_asset: ^Asset

Bitmap :: struct {
    memory:        []ByteColor,
    width, height: i32, 
    
    pitch: i32,
    
    align_percentage:  [2]f32,
    width_over_height: f32,
}

main :: proc() {
    
    {
        begin_asset_type(.Shadow)
        add_bitmap_asset("../assets/shadow.bmp", {0.5, -0.4})
        end_asset_type()
            
        begin_asset_type(.Arrow)
        add_bitmap_asset("../assets/arrow.bmp" )
        end_asset_type()
        
        begin_asset_type(.Stair)
        add_bitmap_asset("../assets/stair.bmp")
        end_asset_type()

        begin_asset_type(.Rock)
        add_bitmap_asset("../assets/rocks1.bmp")
        add_bitmap_asset("../assets/rocks2.bmp")
        add_bitmap_asset("../assets/rocks3.bmp")
        add_bitmap_asset("../assets/rocks4.bmp")
        add_bitmap_asset("../assets/rocks5.bmp")
        add_bitmap_asset("../assets/rocks7.bmp")
        end_asset_type()
        
        // TODO(viktor): alignment percentages for these
        begin_asset_type(.Grass)
        add_bitmap_asset("../assets/grass11.bmp")
        add_bitmap_asset("../assets/grass12.bmp")
        add_bitmap_asset("../assets/grass21.bmp")
        add_bitmap_asset("../assets/grass22.bmp")
        add_bitmap_asset("../assets/grass31.bmp")
        add_bitmap_asset("../assets/grass32.bmp")
        add_bitmap_asset("../assets/flower1.bmp")
        add_bitmap_asset("../assets/flower2.bmp")
        end_asset_type()
        
        // add_bitmap_asset(result, "../assets/rocks6a.bmp")
        // add_bitmap_asset(result, "../assets/rocks6b.bmp")
        
        // add_bitmap_asset(result, "../assets/rocks8a.bmp")
        // add_bitmap_asset(result, "../assets/rocks8b.bmp")
        // add_bitmap_asset(result, "../assets/rocks8c.bmp")
        
        begin_asset_type(.Cape)
        add_bitmap_asset("../assets/cape_left.bmp",  {0.36, 0.01})
        add_tag(.FacingDirection, Pi)
        add_bitmap_asset("../assets/cape_right.bmp", {0.63, 0.01})
        add_tag(.FacingDirection, 0)
        end_asset_type()
                            
        begin_asset_type(.Head)
        add_bitmap_asset("../assets/head_left.bmp",  {0.36, 0.01})
        add_tag(.FacingDirection, Pi)
        add_bitmap_asset("../assets/head_right.bmp", {0.63, 0.01})
        add_tag(.FacingDirection, 0)
        end_asset_type()
                    
        begin_asset_type(.Body)
        add_bitmap_asset("../assets/body_left.bmp",  {0.36, 0.01})
        add_tag(.FacingDirection, Pi)
        add_bitmap_asset("../assets/body_right.bmp", {0.63, 0.01})
        add_tag(.FacingDirection, 0)
        end_asset_type()
                    
        begin_asset_type(.Sword)
        add_bitmap_asset("../assets/sword_left.bmp",  {0.36, 0.01})
        add_tag(.FacingDirection, Pi)
        add_bitmap_asset("../assets/sword_right.bmp", {0.63, 0.01})
        add_tag(.FacingDirection, 0)
        end_asset_type()
            
        begin_asset_type(.Monster)
        add_bitmap_asset("../assets/orc_left.bmp"     , v2{0.7 , 0})
        add_tag(.FacingDirection, Pi)
        add_bitmap_asset("../assets/orc_right.bmp"    , v2{0.27, 0})
        add_tag(.FacingDirection, 0)
        end_asset_type()
        
        // 
        // NOTE(viktor): Sounds
        // 
        
        begin_asset_type(.Blop)
        add_sound_asset("../assets/blop0.wav")
        add_sound_asset("../assets/blop1.wav")
        add_sound_asset("../assets/blop2.wav")
        end_asset_type()
            
        begin_asset_type(.Drop)
        add_sound_asset("../assets/drop0.wav")
        add_sound_asset("../assets/drop1.wav")
        add_sound_asset("../assets/drop2.wav")
        end_asset_type()
            
        begin_asset_type(.Hit)
        add_sound_asset("../assets/hit0.wav")
        add_sound_asset("../assets/hit1.wav")
        add_sound_asset("../assets/hit2.wav")
        add_sound_asset("../assets/hit3.wav")
        end_asset_type()
                    
        begin_asset_type(.Woosh)
        add_sound_asset("../assets/woosh0.wav")
        add_sound_asset("../assets/woosh1.wav")
        add_sound_asset("../assets/woosh2.wav")
        end_asset_type()
        
        
        sec :: 48000
        section :: 10 * sec
        total_sample_count :: 6_418_285
        last: ^Asset
        
        begin_asset_type(.Music)
        for first_sample_index: u32; first_sample_index < total_sample_count; first_sample_index += section {
            sample_count :u32= total_sample_count - first_sample_index
            if sample_count > section {
                sample_count = section
            }
            
            this := add_sound_asset("../assets/Light Ambience 1.wav", first_sample_index, sample_count)
            if last != nil {
                get_sound_info(last.data_offset).next_id_to_play = this.data_offset
            }
            last = this
        }
        
        // add_sound_asset("../assets/Light Ambience 2.wav")
        // add_sound_asset("../assets/Light Ambience 3.wav")
        // add_sound_asset("../assets/Light Ambience 4.wav")
        // add_sound_asset("../assets/Light Ambience 5.wav")
        end_asset_type()
    }   
    
    
    err: os.Error
    file_name: string
    Out, err = os.open("test.hha", os.O_RDWR)
    if err == nil {
        defer os.close(Out)
        
    } else {
        fmt.eprint("Error: could not open file %v because of %v", file_name, err)
    }
}

begin_asset_type :: proc(id: AssetTypeId) {
    assert(DEBUG_asset_type == nil)
    assert(DEBUG_asset == nil)
    
    DEBUG_asset_type = &types[id]
    DEBUG_asset_type.first_asset_index   = auto_cast DEBUG_used_asset_count
    DEBUG_asset_type.one_past_last_index = DEBUG_asset_type.first_asset_index
}

add_bitmap_asset :: proc(file_name: string, align_percentage: v2 = {0.5, 0.5}) {
    assert(DEBUG_asset_type != nil)
    
    asset := &assets[DEBUG_asset_type.one_past_last_index]
    DEBUG_asset_type.one_past_last_index += 1
    asset.first_tag_index = DEBUG_used_asset_count
    asset.one_past_last_tag_index = asset.first_tag_index
     {
        assert(DEBUG_used_bitmap_count < auto_cast len(bitmap_infos))
        
        id := DEBUG_used_bitmap_count
        DEBUG_used_bitmap_count += 1
        
        info := &bitmap_infos[id]
        info.align_percentage = align_percentage
        info.file_name        = file_name
        
        asset.data_offset = id
    }
    
    DEBUG_asset = asset
}

get_sound_info :: proc(id: u32) -> (result: ^AssetSoundInfo) {
    result = &sound_infos[id]
    return result
}

add_sound_asset :: proc(file_name: string, first_sample_index: u32 = 0, sample_count: u32 = 0) -> (asset: ^Asset) {
    assert(DEBUG_asset_type != nil)
    
    asset = &assets[DEBUG_asset_type.one_past_last_index]
    DEBUG_asset_type.one_past_last_index += 1
    
    asset.first_tag_index = DEBUG_used_asset_count
    asset.one_past_last_tag_index = asset.first_tag_index
    
     {
        assert(DEBUG_used_sound_count < auto_cast len(sound_infos))
        
        id := DEBUG_used_sound_count
        DEBUG_used_sound_count += 1
        
        info := &sound_infos[id]
        info^ = {
            file_name          = file_name,
            first_sample_index = first_sample_index,
            sample_count       = sample_count,
        }
        
        asset.data_offset = id
    }
    
    
    DEBUG_asset = asset
    
    return asset
}

add_tag :: proc(id: AssetTagId, value: f32) {
    assert(DEBUG_asset_type != nil)
    assert(DEBUG_asset != nil)
    
    DEBUG_asset.one_past_last_tag_index += 1
    
    tag := &tags[DEBUG_used_asset_count]
    DEBUG_used_asset_count += 1
    
    tag.id = id
    tag.value = value
}

end_asset_type :: proc() {
    assert(DEBUG_asset_type != nil)
    
    DEBUG_used_asset_count = DEBUG_asset_type.one_past_last_index
    DEBUG_asset_type = nil
    DEBUG_asset = nil
}


DEBUG_load_bmp :: proc (file_name: string, alignment_percentage: v2 = 0.5) -> (result: Bitmap) {
    contents, _ := os.read_entire_file(file_name)
    
    BMPHeader :: struct #packed {
        file_type:      [2]u8,
        file_size:      u32,
        reserved_1:     u16,
        reserved_2:     u16,
        bitmap_offset:  u32,
        size:           u32,
        width:          i32,
        height:         i32,
        planes:         u16,
        bits_per_pixel: u16,

        compression:           u32,
        size_of_bitmap:        u32,
        horizontal_resolution: i32,
        vertical_resolution:   i32,
        colors_used:           u32,
        colors_important:      u32,

        red_mask,
        green_mask,
        blue_mask: u32,
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



// 
// 
//  Copypasta
// 
// 

v2 :: [2]f32
v3 :: [3]f32
v4 :: [4]f32


ByteColor :: [4]u8
Tau :: 6.28318530717958647692528676655900576
Pi  :: 3.14159265358979323846264338327950288

@(require_results) square :: #force_inline proc(x: f32) -> f32 { return x * x}

vec_cast :: proc { 
    cast_vec_2, cast_vec_3, cast_vec_4,
    cast_vec_v2, cast_vec_v3, cast_vec_v4,
}

@(require_results)
cast_vec_2 :: #force_inline proc($T: typeid, x, y: $E) -> [2]T where T != E {
    return {cast(T) x, cast(T) y}
}

@(require_results)
cast_vec_3 :: #force_inline proc($T: typeid, x, y, z: $E) -> [3]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z}
}

@(require_results)
cast_vec_4 :: #force_inline proc($T: typeid, x, y, z, w: $E) -> [4]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z, cast(T) w}
}

@(require_results)
cast_vec_v2 :: #force_inline proc($T: typeid, v:[2]$E) -> [2]T where T != E {
    return vec_cast(T, v.x, v.y)
}

@(require_results)
cast_vec_v3 :: #force_inline proc($T: typeid, v:[3]$E) -> [3]T where T != E {
    return vec_cast(T, v.x, v.y, v.z)
}

@(require_results)
cast_vec_v4 :: #force_inline proc($T: typeid, v:[4]$E) -> [4]T where T != E {
    return vec_cast(T, v.x, v.y, v.z, v.w)
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
    result.r = math.sqrt(linear.r)
    result.g = math.sqrt(linear.g)
    result.b = math.sqrt(linear.b)
    result.a = linear.a

    return result
}
@(require_results)
linear_1_to_srgb_255 :: #force_inline proc(linear: v4) -> (result: v4) {
    result = linear_to_srgb(linear)
    result *= 255

    return result
}


safe_ratio_n :: proc { safe_ratio_n_1, safe_ratio_n_2, safe_ratio_n_3 }
@(require_results) safe_ratio_n_1 :: #force_inline proc(numerator, divisor, n: f32) -> f32 {
    ratio := n

    if divisor != 0 {
        ratio = numerator / divisor
    }

    return ratio
}
@(require_results) safe_ratio_n_2 :: #force_inline proc(numerator, divisor, n: v2) -> v2 {
    ratio := n

    if divisor != 0 {
        ratio = numerator / divisor
    }

    return ratio
}
@(require_results) safe_ratio_n_3 :: #force_inline proc(numerator, divisor, n: v3) -> v3 {
    ratio := n

    if divisor != 0 {
        ratio = numerator / divisor
    }

    return ratio
}

safe_ratio_0 :: proc { safe_ratio_0_1, safe_ratio_0_2, safe_ratio_0_3 }
@(require_results) safe_ratio_0_1 :: #force_inline proc(numerator, divisor: f32) -> f32 { return safe_ratio_n(numerator, divisor, 0) }
@(require_results) safe_ratio_0_2 :: #force_inline proc(numerator, divisor: v2)  -> v2  { return safe_ratio_n(numerator, divisor, 0) }
@(require_results) safe_ratio_0_3 :: #force_inline proc(numerator, divisor: v3)  -> v3  { return safe_ratio_n(numerator, divisor, 0) }

safe_ratio_1 :: proc { safe_ratio_1_1, safe_ratio_1_2, safe_ratio_1_3 }
@(require_results) safe_ratio_1_1 :: #force_inline proc(numerator, divisor: f32) -> f32 { return safe_ratio_n(numerator, divisor, 1) }
@(require_results) safe_ratio_1_2 :: #force_inline proc(numerator, divisor: v2)  -> v2  { return safe_ratio_n(numerator, divisor, 1) }
@(require_results) safe_ratio_1_3 :: #force_inline proc(numerator, divisor: v3)  -> v3  { return safe_ratio_n(numerator, divisor, 1) }
