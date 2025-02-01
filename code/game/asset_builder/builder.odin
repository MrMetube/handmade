#+private
package hha

import "base:intrinsics"

import "core:c/libc"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import win "core:sys/windows"

import tt "vendor:stb/truetype"

HUUGE :: 4096

HHA :: struct {
    tag_count:   u32,
    type_count:  u32,
    asset_count: u32,
    
    type:        ^AssetType,
    asset_index: u32,
    
    tags:    [HUUGE]AssetTag,
    types:   [HUUGE]AssetType,
    sources: [HUUGE]SourceAsset,
    data:    [HUUGE]AssetData,
}

SourceSound :: struct {
    channel_count: u32,
    channels:      [2][]i16, // 1 or 2 channels of samples
}

SourceBitmap :: struct {
    memory:        [][4]u8,
    width, height: i32, 
}

SourceFont :: struct {
    font:         tt.fontinfo,
    scale_factor: f32,
    
    codepoint_count:          u32,
    codepoints:               []BitmapId,
    horizontal_advances:      []f32,
}

SourceAsset :: union {
    SourceBitmapInfo,
    SourceSoundInfo,
    SourceFontInfo,
    SourceFontGlyphInfo,
}

SourceBitmapInfo :: struct {
    filename: string,
}

SourceSoundInfo :: struct {
    filename:           string,
    first_sample_index: u32,
}

SourceFontInfo :: struct {
    font: ^SourceFont,
}

SourceFontGlyphInfo :: struct {
    font:      ^SourceFont,
    codepoint: rune,
}

main :: proc() {
    write_fonts()
    write_hero()
    write_non_hero()
    write_sounds()
}

init :: proc(hha: ^HHA) {
    hha.tag_count   = 1
    hha.asset_count = 1
    hha.type_count  = 1
    hha.type        = nil
    hha.asset_index = 0
    
    hha.sources = {}
    hha.data    = {}
    hha.tags    = {}
    hha.types   = {}
}

write_hero :: proc () {
    hha := new(HHA)
    init(hha)
        
    begin_asset_type(hha, .Head)
    add_bitmap_asset(hha, "../assets/head_left.bmp",  {0.36, 0.01})
    add_tag(hha, .FacingDirection, Pi)
    add_bitmap_asset(hha, "../assets/head_right.bmp", {0.63, 0.01})
    add_tag(hha, .FacingDirection, 0)
    end_asset_type(hha)

    begin_asset_type(hha, .Body)
    add_bitmap_asset(hha, "../assets/body_left.bmp",  {0.36, 0.01})
    add_tag(hha, .FacingDirection, Pi)
    add_bitmap_asset(hha, "../assets/body_right.bmp", {0.63, 0.01})
    add_tag(hha, .FacingDirection, 0)
    end_asset_type(hha)
    
    begin_asset_type(hha, .Cape)
    add_bitmap_asset(hha, "../assets/cape_left.bmp",  {0.36, 0.01})
    add_tag(hha, .FacingDirection, Pi)
    add_bitmap_asset(hha, "../assets/cape_right.bmp", {0.63, 0.01})
    add_tag(hha, .FacingDirection, 0)
    end_asset_type(hha)
    
    begin_asset_type(hha, .Sword)
    add_bitmap_asset(hha, "../assets/sword_left.bmp",  {0.36, 0.01})
    add_tag(hha, .FacingDirection, Pi)
    add_bitmap_asset(hha, "../assets/sword_right.bmp", {0.63, 0.01})
    add_tag(hha, .FacingDirection, 0)
    end_asset_type(hha)
    
    output_hha_file(`.\hero.hha`, hha)
}

write_non_hero :: proc () {
    hha := new(HHA)
    init(hha)
    
    begin_asset_type(hha, .Shadow)
    add_bitmap_asset(hha, "../assets/shadow.bmp", {0.5, -0.4})
    end_asset_type(hha)
        
    begin_asset_type(hha, .Arrow)
    add_bitmap_asset(hha, "../assets/arrow.bmp" )
    end_asset_type(hha)
    
    begin_asset_type(hha, .Stair)
    add_bitmap_asset(hha, "../assets/stair.bmp")
    end_asset_type(hha)

    // TODO(viktor): alignment percentages for these
    begin_asset_type(hha, .Rock)
    add_bitmap_asset(hha, "../assets/rocks1.bmp")
    add_bitmap_asset(hha, "../assets/rocks2.bmp")
    add_bitmap_asset(hha, "../assets/rocks3.bmp")
    add_bitmap_asset(hha, "../assets/rocks4.bmp")
    add_bitmap_asset(hha, "../assets/rocks5.bmp")
    add_bitmap_asset(hha, "../assets/rocks7.bmp")
    end_asset_type(hha)
    
    // add_bitmap_asset(result, "../assets/rocks6a.bmp")
    // add_bitmap_asset(result, "../assets/rocks6b.bmp")
    
    // add_bitmap_asset(result, "../assets/rocks8a.bmp")
    // add_bitmap_asset(result, "../assets/rocks8b.bmp")
    // add_bitmap_asset(result, "../assets/rocks8c.bmp")
        
    // TODO(viktor): alignment percentages for these
    begin_asset_type(hha, .Grass)
    add_bitmap_asset(hha, "../assets/grass11.bmp")
    add_bitmap_asset(hha, "../assets/grass12.bmp")
    add_bitmap_asset(hha, "../assets/grass21.bmp")
    add_bitmap_asset(hha, "../assets/grass22.bmp")
    add_bitmap_asset(hha, "../assets/grass31.bmp")
    add_bitmap_asset(hha, "../assets/grass32.bmp")
    add_bitmap_asset(hha, "../assets/flower1.bmp")
    add_bitmap_asset(hha, "../assets/flower2.bmp")
    end_asset_type(hha)
    
    begin_asset_type(hha, .Monster)
    add_bitmap_asset(hha, "../assets/orc_left.bmp"     , v2{0.7 , 0})
    add_tag(hha, .FacingDirection, Pi)
    add_bitmap_asset(hha, "../assets/orc_right.bmp"    , v2{0.27, 0})
    add_tag(hha, .FacingDirection, 0)
    end_asset_type(hha)
    
    output_hha_file(`.\non_hero.hha`, hha)
}

write_fonts :: proc() {
    hha := new(HHA)
    init(hha)
    
    // @Leak
    debug_font := load_font(`..\assets\raw\Caladea\Caladea-Regular.ttf`, '~'+1)

    begin_asset_type(hha, .FontGlyph)
    for c in '!'..<'~' {
        debug_font.codepoints[c] = add_character_asset(hha, &debug_font, c)
    }
    end_asset_type(hha)
    
    begin_asset_type(hha, .Font)
    add_font_asset(hha, &debug_font)
    end_asset_type(hha)
    
    output_hha_file(`.\fonts.hha`, hha)
}

write_sounds :: proc() {
    hha := new(HHA)
    init(hha)
    
    begin_asset_type(hha, .Blop)
    add_sound_asset(hha, "../assets/blop0.wav")
    add_sound_asset(hha, "../assets/blop1.wav")
    add_sound_asset(hha, "../assets/blop2.wav")
    end_asset_type(hha)
        
    begin_asset_type(hha, .Drop)
    add_sound_asset(hha, "../assets/drop0.wav")
    add_sound_asset(hha, "../assets/drop1.wav")
    add_sound_asset(hha, "../assets/drop2.wav")
    end_asset_type(hha)
        
    begin_asset_type(hha, .Hit)
    add_sound_asset(hha, "../assets/hit0.wav")
    add_sound_asset(hha, "../assets/hit1.wav")
    add_sound_asset(hha, "../assets/hit2.wav")
    add_sound_asset(hha, "../assets/hit3.wav")
    end_asset_type(hha)
                
    begin_asset_type(hha, .Woosh)
    add_sound_asset(hha, "../assets/woosh0.wav")
    add_sound_asset(hha, "../assets/woosh1.wav")
    add_sound_asset(hha, "../assets/woosh2.wav")
    end_asset_type(hha)
        
    
    sec :: 48000
    section :: 10 * sec
    total_sample_count :: 6_418_285
    
    begin_asset_type(hha, .Music)
    for first_sample_index: u32; first_sample_index < total_sample_count; first_sample_index += section {
        sample_count :u32= total_sample_count - first_sample_index
        if sample_count > section {
            sample_count = section
        }
        
        this_index := add_sound_asset(hha, "../assets/Light Ambience 1.wav", first_sample_index, sample_count)
        if first_sample_index + section < total_sample_count {
            hha.data[this_index].info.sound.chain = .Advance
        }
    }
    
    // add_sound_asset("../assets/Light Ambience 2.wav")
    // add_sound_asset("../assets/Light Ambience 3.wav")
    // add_sound_asset("../assets/Light Ambience 4.wav")
    // add_sound_asset("../assets/Light Ambience 5.wav")
    end_asset_type(hha)
    
    output_hha_file(`.\sounds.hha`, hha)
}

output_hha_file :: proc(file_name: string, hha: ^HHA) {
    out := libc.fopen(strings.clone_to_cstring(file_name), "wb")
    if out == nil {
        fmt.eprintln("could not open asset file:", file_name)
        return
    }
    defer libc.fclose(out)
    
    header := Header {
        magic_value = MagicValue,
        version     = Version,
        
        tag_count        = hha.tag_count,
        asset_type_count = hha.type_count,
        asset_count      = hha.asset_count,
    }
    
    tags_size        := header.tag_count        * size_of(AssetTag)
    asset_types_size := header.asset_type_count * size_of(AssetType)
    assets_size      := header.asset_count      * size_of(AssetData)
    
    header.tags        = size_of(header)
    header.asset_types = header.tags        + cast(u64) tags_size
    header.assets      = header.asset_types + cast(u64) asset_types_size
    
    
    libc.fwrite(&header,                 size_of(header),             1, out)
    libc.fwrite(raw_data(hha.tags[:]),   cast(uint) tags_size,        1, out)
    libc.fwrite(raw_data(hha.types[:]),  cast(uint) asset_types_size, 1, out)
    
    libc.fseek(out, cast(i32) assets_size, .CUR)
    context.allocator = context.temp_allocator
    for index in 1..<hha.asset_count {
        src := &hha.sources[index]
        dst := &hha.data[index]
        
        dst.data_offset = auto_cast libc.ftell(out)
        
        defer free_all(context.allocator)
        switch v in src {
          case SourceBitmapInfo:
            info := &dst.info.bitmap
            bitmap := load_bmp(v.filename)
            
            info.dimension = vec_cast(u32, bitmap.width, bitmap.height)
            libc.fwrite(&bitmap.memory[0], cast(uint) (info.dimension.x * info.dimension.y) * size_of([4]u8), 1, out)
          case SourceFontGlyphInfo:
            info := &dst.info.bitmap
            bitmap := load_glyph_bitmap(v.font, v.codepoint, info)
            
            libc.fwrite(&bitmap.memory[0], cast(uint) (info.dimension.x * info.dimension.y) * size_of([4]u8), 1, out)
          case SourceFontInfo:
            info := &dst.info.font
            
            codepoint_count := cast(u64) info.codepoint_count
            codepoints_size := codepoint_count * size_of(BitmapId)
            horizontal_advance_size := codepoint_count * codepoint_count * size_of(f32)
            
            libc.fwrite(&v.font.codepoints[0],          cast(uint) codepoints_size, 1, out)
            libc.fwrite(&v.font.horizontal_advances[0], cast(uint) horizontal_advance_size, 1, out)
          case SourceSoundInfo:
            info := &dst.info.sound
            wav := load_wav(v.filename, v.first_sample_index, info.sample_count)
            
            info.sample_count  = auto_cast len(wav.channels[0])
            info.channel_count = wav.channel_count
            
            for channel in wav.channels[:wav.channel_count] {
                libc.fwrite(&channel[0], cast(uint) info.sample_count * size_of(i16), 1, out)
            }
        }
    }
    
    libc.fseek(out, cast(i32) header.assets, .SET)
    libc.fwrite(raw_data(hha.data[:]), cast(uint) assets_size, 1, out)
}

begin_asset_type :: proc(hha: ^HHA, id: AssetTypeId) {
    assert(hha.type == nil)
    assert(hha.asset_index == 0)
    
    hha.type = &hha.types[hha.type_count]
    hha.type_count += 1
    hha.type.id = id
    hha.type.first_asset_index   = auto_cast hha.asset_count
    hha.type.one_past_last_index = hha.type.first_asset_index
}

add_asset :: proc(hha: ^HHA) -> (asset_index: u32, data: ^AssetData, src: ^SourceAsset) {
    assert(hha.type != nil)
    
    asset_index = hha.type.one_past_last_index
    hha.type.one_past_last_index += 1
    src = &hha.sources[asset_index]
    data = &hha.data[asset_index]
    
    data.first_tag_index         = hha.tag_count
    data.one_past_last_tag_index = data.first_tag_index
    
    hha.asset_index = asset_index
    
    return
}

add_bitmap_asset :: proc(hha: ^HHA, filename: string, align_percentage: v2 = {0.5, 0.5}) -> (u32) {
    result, data, src := add_asset(hha)
    
    src^ = SourceBitmapInfo{ filename }
    
    data.info.bitmap.align_percentage = align_percentage
    
    return result
}

add_sound_asset :: proc(hha: ^HHA, filename: string, first_sample_index: u32 = 0, sample_count: u32 = 0) -> (u32) {
    result, data, src := add_asset(hha)
    
    src^ = SourceSoundInfo{
        filename           = filename,
        first_sample_index = first_sample_index,
    }
    
    data.info.sound.chain        = .None
    data.info.sound.sample_count = sample_count
    
    return result
}

add_font_asset :: proc(hha: ^HHA, font: ^SourceFont) -> (u32) {
    result, data, src := add_asset(hha)
    
    data.info.font.codepoint_count = font.codepoint_count
    
    ascent, descent, linegap: i32
    tt.GetFontVMetrics(&font.font, &ascent, &descent, &linegap)
    data.info.font.ascent  = cast(f32) ascent  * font.scale_factor
    data.info.font.descent = cast(f32) descent * font.scale_factor
    data.info.font.linegap = cast(f32) linegap * font.scale_factor
    
    src^ = SourceFontInfo{ font }
    
    return result
}

add_character_asset :: proc(hha: ^HHA, font: ^SourceFont, codepoint: rune) -> (BitmapId) {
    result, data, src := add_asset(hha)
    
    src^ = SourceFontGlyphInfo{
        font      = font,
        codepoint = codepoint,
    }
    
    data.info.bitmap.align_percentage = 0
    
    return cast(BitmapId) result
}

add_tag :: proc(hha: ^HHA, id: AssetTagId, value: f32) {
    assert(hha.type != nil)
    assert(hha.asset_index != 0)
    
    data := &hha.data[hha.asset_index]
    data.one_past_last_tag_index += 1
    
    tag := &hha.tags[hha.tag_count]
    hha.tag_count += 1
    
    tag.id = auto_cast id
    tag.value = value
}

end_asset_type :: proc(hha: ^HHA) {
    assert(hha.type != nil)
    
    hha.asset_count = hha.type.one_past_last_index
    hha.type = nil
    hha.asset_index = 0
}

load_font :: proc(path_to_font: string, codepoint_count: u32) -> (result: SourceFont) {
    font_file, ok := os.read_entire_file(path_to_font)
    if !ok {
        fmt.println(os.error_string(cast(os.Platform_Error) win.GetLastError()))
        assert(false)
    }
    
    ok = auto_cast tt.InitFont(&result.font, raw_data(font_file), 0)
    assert(ok)
    
    // TODO(viktor): how large should the glyphs be rendered?
    pixels : f32 = 150
    result.scale_factor = tt.ScaleForPixelHeight(&result.font, pixels)
    
    result.codepoint_count = codepoint_count
    result.codepoints      = make([]BitmapId, codepoint_count)

    result.horizontal_advances = make([]f32, codepoint_count*codepoint_count)
    for &a in result.horizontal_advances {
        a = 0
    }

    kerning_count := tt.GetKerningTableLength(&result.font)
    kerning_table := make([]tt.kerningentry, kerning_count)
    tt.GetKerningTable(&result.font, raw_data(kerning_table), kerning_count)
    for entry in kerning_table {
        count := cast(rune) codepoint_count
        if 0 < entry.glyph1 && entry.glyph1 < count && 0 < entry.glyph2 && entry.glyph2 < count {
            result.horizontal_advances[entry.glyph1 * count + entry.glyph2] += cast(f32) entry.advance * result.scale_factor
        }
    }
    
    return result
}

load_glyph_bitmap :: proc(font: ^SourceFont, codepoint: rune, info: ^BitmapInfo) -> (result: SourceBitmap) {
    w, h, xoff, yoff: i32
    // TODO(viktor): works after odin dev-2025-01
    // mono_bitmap := tt.GetCodepointBitmap(&font.font, 0, font.scale_factor, codepoint, &w, &h, &xoff, &yoff)[:w*h]
    _mono_bitmap := tt.GetCodepointBitmap(&font.font, 0, font.scale_factor, codepoint, &w, &h, &xoff, &yoff)
    mono_bitmap := _mono_bitmap[:w*h]
    defer tt.FreeBitmap(raw_data(mono_bitmap), nil)
    
    // NOTE(viktor): add an apron for bilinear blending
    result.width  = w+2
    result.height = h+2
    result.memory = make([][4]u8, result.width*result.height)
    for &p in result.memory do p = 0
    
    info.dimension = vec_cast(u32, result.width, result.height)
    
    info.align_percentage.x = (1) / cast(f32) result.width
    info.align_percentage.y = (1 + cast(f32) (yoff + h)) / cast(f32) result.height
    
    for other_codepoint in rune(0)..<cast(rune)font.codepoint_count {
        advance := &font.horizontal_advances[other_codepoint * cast(rune)font.codepoint_count + codepoint]
        advance^ += cast(f32) w
        if other_codepoint != 0 {
            other_advance := &font.horizontal_advances[other_codepoint * cast(rune)font.codepoint_count + codepoint]
            other_advance^ += cast(f32) -xoff
        }
    }
    
    for y in 0..<h {
        for x in 0..<w {
            src  := mono_bitmap[(h-1 - y) * w + x]
            dest := &result.memory[(y+1) * result.width + x+1]
            
            dest^ = premuliply_alpha(255, 255, 255, src)
        }
    }
    
    return result
}

load_bmp :: proc (file_name: string) -> (result: SourceBitmap) {
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
        pixels     := transmute([][4]u8) raw_pixels
        for y in 0..<header.height {
            for x in 0..<header.width {
                c := raw_pixels[y * header.width + x]
                p := &pixels[y * header.width + x]
                
                p^ = premuliply_alpha( 
                    cast(u8) ((c & red_mask)   >> red_shift),
                    cast(u8) ((c & green_mask) >> green_shift),
                    cast(u8) ((c & blue_mask)  >> blue_shift),
                    cast(u8) ((c & alpha_mask) >> alpha_shift),
                ) 
            }
        }
        
        result = {
            memory = pixels, 
            width  = header.width, 
            height = header.height, 
        }

        return result
    }
    
    return {}
}

load_wav :: proc (file_name: string, section_first_sample_index, section_sample_count: u32) -> (result: SourceSound) {
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
        // :PointerArithmetic
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
            // :PointerArithmetic
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
            // TODO(viktor): IMPORTANT(viktor): all sounds have to be padded with their subsequent sound
            // out to 8 samples past their end

            // for &channel in result.channels {
            //     channel = (raw_data(channel))[:sample_count+8]
                
            //     for sample_index in sample_count..<sample_count+8 {
            //         channel[sample_index] = 0
            //     } 
            // }
        }
    }
    
    return result
}

premuliply_alpha :: proc(r, g, b, a: u8) -> (result: [4]u8) {
    texel := vec_cast(f32, r, g, b, a)
    
    texel = srgb_255_to_linear_1(texel)
    
    texel.rgb = texel.rgb * texel.a
    
    texel = linear_1_to_srgb_255(texel)
    
    result = vec_cast(u8, texel + 0.5)
    
    return result
}

// ---------------------- ---------------------- ----------------------
// Copypasta
// ---------------------- ---------------------- ----------------------


rawpointer :: rawptr
uintpointer :: uintptr

v2 :: [2]f32
v4 :: [4]f32

Pi  :: 3.14159265358979323846264338327950288

vec_cast :: proc { 
    cast_vec_2, cast_vec_4,
    cast_vec_v4,
}

@(require_results)
cast_vec_2 :: #force_inline proc($T: typeid, x, y: $E) -> [2]T where T != E {
    return {cast(T) x, cast(T) y}
}

@(require_results)
cast_vec_4 :: #force_inline proc($T: typeid, x, y, z, w: $E) -> [4]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z, cast(T) w}
}

@(require_results)
cast_vec_v4 :: #force_inline proc($T: typeid, v:[4]$E) -> [4]T where T != E {
    return vec_cast(T, v.x, v.y, v.z, v.w)
}


@(require_results)
srgb_255_to_linear_1 :: #force_inline proc(srgb: v4) -> (result: v4) {
    // NOTE(viktor): srgb_to_linear and linear_to_srgb assume a gamma of 2 instead of the usual 2.2
    @(require_results)
    srgb_to_linear :: #force_inline proc(srgb: v4) -> (result: v4) {
        @(require_results) square :: #force_inline proc(x: f32) -> f32 { return x * x}
        
        result.r = square(srgb.r)
        result.g = square(srgb.g)
        result.b = square(srgb.b)
        result.a = srgb.a

        return result
    }

    inv_255: f32 = 1.0 / 255.0
    result = srgb * inv_255
    result = srgb_to_linear(result)

    return result
}


@(require_results)
linear_1_to_srgb_255 :: #force_inline proc(linear: v4) -> (result: v4) {
    @(require_results)
    linear_to_srgb :: #force_inline proc(linear: v4) -> (result: v4) {
        result.r = math.sqrt(linear.r)
        result.g = math.sqrt(linear.g)
        result.b = math.sqrt(linear.b)
        result.a = linear.a

        return result
    }
    
    result = linear_to_srgb(linear)
    result *= 255

    return result
}