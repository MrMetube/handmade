package tools

import "base:intrinsics"

import "core:fmt"
import "core:math"
import "core:os"


// ---------------------- ---------------------- ----------------------
// Implementation
// ---------------------- ---------------------- ----------------------

Out: os.Handle

HUUGE :: 4096

type_count:  u32
asset_count: u32
tag_count:   u32
asset_types:   [AssetTypeId]hhaAssetType
assets:  [HUUGE]Asset
tags:    [HUUGE]hhaTag
tag_ranges: [AssetTagId]f32

DEBUG_asset_type: ^hhaAssetType
DEBUG_asset: ^Asset

Sound :: struct {
    channel_count: u32,
    channels: [2][]i16, // 1 or 2 channels of samples
}

Bitmap :: struct {
    memory:        []ByteColor,
    width, height: i32, 
    
    pitch: i32,
    
    align_percentage:  [2]f32,
    width_over_height: f32,
}

BitmapId :: distinct u32
SoundId  :: distinct u32

Asset :: struct {
    // TODO(viktor): should this just be a slice into the assets.tags?
    first_tag_index:         u32,
    one_past_last_tag_index: u32,
    
    using as: struct #raw_union { 
        bitmap: AssetBitmapInfo, 
        sound: AssetSoundInfo
    }
}

AssetState :: enum {
    Unloaded, Queued, Loaded, Locked, 
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

AssetBitmapInfo :: struct {
    align_percentage: [2]f32,
    file_name:        string,
}

AssetSoundInfo :: struct {
    file_name:       string,
    
    first_sample_index: u32,
    sample_count:       u32,
    
    next_id_to_play: SoundId,
}

AssetVector :: [AssetTagId]f32

main :: proc() {
    
    asset_count = 1
    tag_count = 1
    
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
        last_index: SoundId
        
        begin_asset_type(.Music)
        for first_sample_index: u32; first_sample_index < total_sample_count; first_sample_index += section {
            sample_count :u32= total_sample_count - first_sample_index
            if sample_count > section {
                sample_count = section
            }
            
            this_index := add_sound_asset("../assets/Light Ambience 1.wav", first_sample_index, sample_count)
            if last_index != 0 {
                assets[last_index].sound.next_id_to_play = this_index
            }
            last_index = this_index
        }
        
        // add_sound_asset("../assets/Light Ambience 2.wav")
        // add_sound_asset("../assets/Light Ambience 3.wav")
        // add_sound_asset("../assets/Light Ambience 4.wav")
        // add_sound_asset("../assets/Light Ambience 5.wav")
        end_asset_type()
    }   
    
    
    err: os.Error
    file_name: string
    Out, _ = os.open("test.hha", os.O_RDWR)
    if err != nil {
        fmt.eprint("Error: could not open file %v because of %v", file_name, err)
        os.exit(1)
    }
    defer os.close(Out)
    
    header := hhaHeader {
        magic_value = MagicValue,
        version     = Version,
        
        tag_count   = tag_count,
        asset_type_count = asset_count,// TODO(viktor): compute this, sparseness
        asset_count = asset_count,
    }
        
    tags_size        := header.tag_count        * size_of(hhaTag)
    asset_types_size := header.asset_type_count * size_of(hhaAssetType)
    assets_size      := header.asset_count      * size_of(hhaAsset)
    
    header.tags        = size_of(header)
    header.asset_types = header.tags        + cast(u64) tags_size
    header.assets      = header.asset_types + cast(u64) asset_types_size
    
    
    os.write_ptr(Out, &header,                   size_of(header))
    os.write_ptr(Out, &tags[0],                  cast(int) tags_size)
    os.write_ptr(Out, &asset_types[auto_cast 0], cast(int) asset_types_size)
    // os.write_ptr(Out, assets,                    cast(int) assets_size)
}

begin_asset_type :: proc(id: AssetTypeId) {
    assert(DEBUG_asset_type == nil)
    assert(DEBUG_asset == nil)
    
    DEBUG_asset_type = &asset_types[id]
    DEBUG_asset_type.id = auto_cast id
    DEBUG_asset_type.first_asset_index   = auto_cast asset_count
    DEBUG_asset_type.one_past_last_index = DEBUG_asset_type.first_asset_index
}

add_bitmap_asset :: proc(filename: string, align_percentage: v2 = {0.5, 0.5}) -> (result: BitmapId) {
    assert(DEBUG_asset_type != nil)
    
    result = cast(BitmapId) DEBUG_asset_type.one_past_last_index
    DEBUG_asset_type.one_past_last_index += 1
    
    asset := &assets[result]
    asset.first_tag_index = tag_count
    asset.one_past_last_tag_index = asset.first_tag_index
    
    asset.bitmap.align_percentage = align_percentage
    asset.bitmap.file_name        = filename
    
    DEBUG_asset = asset
    
    return result
}

add_sound_asset :: proc(filename: string, first_sample_index: u32 = 0, sample_count: u32 = 0) -> (result: SoundId) {
    assert(DEBUG_asset_type != nil)
    
    result = cast(SoundId) DEBUG_asset_type.one_past_last_index
    DEBUG_asset_type.one_past_last_index += 1
    
    asset := &assets[result]
    asset.first_tag_index = tag_count
    asset.one_past_last_tag_index = asset.first_tag_index
    
    asset.sound.file_name          = filename
    asset.sound.first_sample_index = first_sample_index
    asset.sound.sample_count       = sample_count
    
    DEBUG_asset = asset
    
    return result
}

add_tag :: proc(id: AssetTagId, value: f32) {
    assert(DEBUG_asset_type != nil)
    assert(DEBUG_asset != nil)
    
    DEBUG_asset.one_past_last_tag_index += 1
    
    tag := &tags[asset_count]
    asset_count += 1
    
    tag.id = auto_cast id
    tag.value = value
}

end_asset_type :: proc() {
    assert(DEBUG_asset_type != nil)
    
    asset_count = DEBUG_asset_type.one_past_last_index
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

DEBUG_load_wav :: proc (file_name: string, section_first_sample_index, section_sample_count: u32) -> (result: Sound) {
    contents, _ := os.read_entire_file(file_name)
    
    WAVE_Header :: struct #packed {
        riff:    u32,
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
        id:   WAVE_Chunk_ID,
        size: u32,
    }
    
    WAVE_fmt :: struct #packed {
        format_tag:            WAVE_Format,
        n_channels:            u16,
        n_samples_per_seconds: u32,
        avg_bytes_per_sec:     u32,
        block_align:           u16,
        bits_per_sample:       u16,
        cb_size:               u16,
        valid_bits_per_sample: u16,
        channel_mask:          u32,
        sub_format:            [16]u8,
    }

    RiffIterator :: struct {
        at:   [^]u8,
        stop: rawpointer,
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
        
        channel_count:    u32
        sample_data:      [^]i16
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
        if section_sample_count != 0 {
            assert(section_first_sample_index + section_sample_count <= sample_count)
            
            result.channels[0] = result.channels[0][section_first_sample_index:][:section_sample_count]
            result.channels[1] = result.channels[1][section_first_sample_index:][:section_sample_count]
        }
        
        if section_first_sample_index + section_sample_count == sample_count {
            // TODO(viktor): all sounds have to be padded with their subsequent sound
            // out to 8 samples past their end
            for &channel in result.channels {
                channel = (raw_data(channel))[:sample_count+8]
                
                for sample_index in sample_count..<sample_count+8 {
                    channel[sample_index] = 0
                } 
            }
        }
    }
    
    return result
}


// ---------------------- ---------------------- ----------------------
// File format
// ---------------------- ---------------------- ----------------------



MagicValue : u32 : 'h' << 0 | 'h' << 8 | 'a' << 16 | 'f' << 24
Version    : u32 : 0

hhaHeader :: struct #packed {
    magic_value: u32,
    version:     u32, 
    
    tag_count:        u32,
    asset_type_count: u32,
    asset_count:      u32,
    
    tags:        u64, // [tag_count]hhaTag
    assets:      u64, // [asset_count]hhaAsset
    asset_types: u64, // [asset_type_count]hhaAssetTypeEntry
    
    
}

hhaTag :: struct #packed {
    id:    u32,
    value: f32,
}

hhaAsset :: struct #packed {
    data_offset: u64,
    
    first_tag_index:     u32,
    one_past_last_index: u32,
    
    using as : struct #raw_union {
        bitmap: hhaBitmap,
        sound:  hhaSound,
    }
}

hhaAssetType :: struct #packed {
    id: u32,
    
    first_asset_index:   u32,
    one_past_last_index: u32,
}

hhaBitmap :: struct #packed {
    dimension:        [2]u32,
    align_percentage: [2]f32,
}

hhaSound :: struct #packed {
    first_sample_index: u32,
    sample_count:       u32,
    
    next_id_to_play: u32,
}
















// ---------------------- ---------------------- ----------------------
// Copypasta
// ---------------------- ---------------------- ----------------------


rawpointer :: rawptr
uintpointer :: uintptr

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


@(require_results) safe_ratio_n :: #force_inline proc(numerator, divisor, n: f32) -> f32 {
    ratio := n

    if divisor != 0 {
        ratio = numerator / divisor
    }

    return ratio
}
@(require_results) safe_ratio_0 :: #force_inline proc(numerator, divisor: f32) -> f32 { return safe_ratio_n(numerator, divisor, 0) }
