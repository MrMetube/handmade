#+private
package hha

import "base:intrinsics"

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
    data:    [HUUGE]AssetData,
    
    sources: [HUUGE]SourceAsset,
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
    scale: f32,
    
    max_glyph_count: u32,
    glyph_count:     u32,
    
    codepoint_count:     u32,
    glyphs:              []GlyphInfo,
    horizontal_advances: []f32,
    
    one_past_highest_codepoint: rune,
    glyph_index_from_codepoint: []u32,
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

make_hha :: proc() -> (hha: ^HHA) {
    hha = new(HHA)
    hha^ = {
        tag_count   = 1,
        asset_count = 1,
        type_count  = 1,
    }
    return hha
}

write_hero :: proc () {
    hha := make_hha()
    defer output_hha_file(`.\hero.hha`, hha)
        
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
}

write_non_hero :: proc () {
    hha := make_hha()
    defer output_hha_file(`.\non_hero.hha`, hha)
    
    begin_asset_type(hha, .Shadow)
    add_bitmap_asset(hha, "../assets/shadow.bmp", {0.5, -0.4})
    end_asset_type(hha)
        
    begin_asset_type(hha, .Stair)
    add_bitmap_asset(hha, "../assets/stair.bmp")
    end_asset_type(hha)

    // @todo(viktor): alignment percentages for these
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
        
    // @todo(viktor): alignment percentages for these
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
}

write_fonts :: proc() {
    hha := make_hha()
    defer output_hha_file(`.\fonts.hha`, hha)
    
    // chinese_font := load_font(`C:\Users\Viktor\Downloads\Noto_Sans_SC\static\NotoSansSC-Regular.ttf`)
    // for c in "贺佳樱我爱你" do add_character_asset(hha, &debug_font, c)
    fonts := [?]struct {type: AssetFontType, font: ^SourceFont}{
        { .Default, load_font(100, `C:\Windows\Fonts\LiberationSans-Regular.ttf`) },
        { .Debug,   load_font(40,  `C:\Users\Viktor\AppData\Local\Microsoft\Windows\Fonts\VictorMono-Bold.otf`) },
    }
    
    begin_asset_type(hha, .FontGlyph)
    for &it in fonts {
        for c in rune(1)..<127 do add_character_asset(hha, it.font, c)
        for c in "°ßöüäÖÜÄ" do add_character_asset(hha, it.font, c)
    }
    end_asset_type(hha)
    
    begin_asset_type(hha, .Font)
    for it in fonts {
        add_font_asset(hha, it.font)
        add_tag(hha, .FontType, cast(f32) it.type)
    }
    end_asset_type(hha)
}

write_sounds :: proc() {
    hha := make_hha()
    defer output_hha_file(`.\sounds.hha`, hha)
    
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
        
        this_index := add_sound_asset(hha, "../assets/Light Ambience 4.wav", first_sample_index, sample_count)
        if first_sample_index + section < total_sample_count {
            hha.data[this_index].info.sound.chain = .Advance
        }
    }
    
    // add_sound_asset("../assets/Light Ambience 2.wav")
    // add_sound_asset("../assets/Light Ambience 4.wav")
    // add_sound_asset("../assets/Light Ambience 5.wav")
    end_asset_type(hha)
}

output_hha_file :: proc(file_name: string, hha: ^HHA) {
    out, err := os.open(file_name, os.O_RDWR + os.O_CREATE)
    if err != nil {
        fmt.eprintln("could not open asset file:", file_name)
        return
    }
    defer os.close(out)
    
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
    
    at := cast(i64) (size_of(header))
    os.write_ptr(out, &header, size_of(header))
    write_slice(out, &at, hha.tags[:header.tag_count])
    write_slice(out, &at, hha.types[:header.asset_type_count])

    at += auto_cast assets_size
    
    context.allocator = context.temp_allocator
    for index in 1..<hha.asset_count {
        src := &hha.sources[index]
        dst := &hha.data[index]
        
        dst.data_offset = auto_cast at
        assert(dst.data_offset == auto_cast at)
        
        defer free_all(context.allocator)
        switch v in src {
          case SourceBitmapInfo:
            info := &dst.info.bitmap
            bitmap := load_bmp(v.filename)
            
            info.dimension = vec_cast(u32, bitmap.width, bitmap.height)
            write_slice(out, &at, bitmap.memory)
          case SourceFontGlyphInfo:
            info := &dst.info.bitmap
            bitmap := load_glyph_bitmap(v.font, v.codepoint, info)
            
            info.dimension = vec_cast(u32, bitmap.width, bitmap.height)
            write_slice(out, &at, bitmap.memory)
          case SourceFontInfo:
            finalize_font_kerning(v.font)
            
            glyph_count := v.font.glyph_count
            
            info := &dst.info.font
            info.one_past_highest_codepoint = v.font.one_past_highest_codepoint
            write_slice(out, &at, v.font.glyphs[:glyph_count])
            
            for glyph_index in 0..<glyph_count {
                start := glyph_index * v.font.max_glyph_count
                write_slice(out, &at, v.font.horizontal_advances[start:][:glyph_count])
            }
          case SourceSoundInfo:
            info := &dst.info.sound
            wav := load_wav(v.filename, v.first_sample_index, info.sample_count)
            
            info.sample_count  = auto_cast len(wav.channels[0])
            info.channel_count = wav.channel_count
            
            for channel in wav.channels[:wav.channel_count] {
                write_slice(out, &at, channel)
            }
        }
    }
    
    at = auto_cast header.assets
    write_slice(out, &at, hha.data[:header.asset_count])
}

write_slice :: proc(out: os.Handle, at: ^i64, slice: []$T) {
    size := len(slice) * size_of(T)
    written, _ := os.write_at(out, (cast([^]u8) raw_data(slice))[:size], at^)
    at^ += auto_cast written
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
    src  = &hha.sources[asset_index]
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

add_font_asset :: proc(hha: ^HHA, source: ^SourceFont) -> (u32) {
    result, data, src := add_asset(hha)
    
    src^ = SourceFontInfo{ source }
    
    ascent, descent, linegap: i32
    tt.GetFontVMetrics(&source.font, &ascent, &descent, &linegap)
    data.info.font.ascent  = cast(f32) ascent  * source.scale
    data.info.font.descent = cast(f32) descent * source.scale
    data.info.font.linegap = cast(f32) linegap * source.scale
    data.info.font.glyph_count = source.glyph_count
    
    return result
}

add_character_asset :: proc(hha: ^HHA, font: ^SourceFont, codepoint: rune) {
    bitmap_id, data, src := add_asset(hha)
    
    src^ = SourceFontGlyphInfo{
        font      = font,
        codepoint = codepoint,
    }
    
    data.info.bitmap.align_percentage = 0
    
    glyph_index := font.glyph_count
    font.glyph_count += 1
    glyph := &font.glyphs[glyph_index]
    
    glyph.bitmap    = cast(BitmapId) bitmap_id
    glyph.codepoint = codepoint
    
    font.glyph_index_from_codepoint[codepoint] = glyph_index
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

load_font :: proc(pixels: f32, path_to_font: string) -> (result: ^SourceFont) {
    font_file, ok := os.read_entire_file(path_to_font)
    if !ok {
        fmt.println(os.error_string(cast(os.Platform_Error) win.GetLastError()))
        assert(false)
    }
    
    result = new(SourceFont)
    ok = auto_cast tt.InitFont(&result.font, raw_data(font_file), 0)
    assert(ok, "Failed to initialize font :(")
    
    result.scale = tt.ScaleForPixelHeight(&result.font, pixels)
    
    MaxCodepoint :: 0x10FFFF
    result.glyph_index_from_codepoint = make([]u32, MaxCodepoint)
    result.one_past_highest_codepoint = 0
    
    // @note(viktor): 4k characters should be more than enough for _anybody_
    result.max_glyph_count = 4 * 1024
    result.glyphs = make([]GlyphInfo, result.max_glyph_count)
    
    // @note(viktor): reserve space for the null glyph
    result.glyph_count = 1
    result.glyphs[0]   = {}

    result.horizontal_advances = make([]f32, result.max_glyph_count*result.max_glyph_count)

    return result
}

finalize_font_kerning :: proc(font: ^SourceFont) {
    assert(font.scale != 0)
    kerning_count := tt.GetKerningTableLength(&font.font)
    kerning_table := make([]tt.kerningentry, kerning_count)
    tt.GetKerningTable(&font.font, raw_data(kerning_table), kerning_count)
    
    for entry in kerning_table {
        first  := font.glyph_index_from_codepoint[entry.glyph1]
        second := font.glyph_index_from_codepoint[entry.glyph2]
        
        count := font.max_glyph_count
        if 0 < first && first < count && 0 < second && second < count {
            font.horizontal_advances[first * count + second] += cast(f32) entry.advance * font.scale
        }
        
    }
}

load_glyph_bitmap :: proc(font: ^SourceFont, codepoint: rune, info: ^BitmapInfo) -> (result: SourceBitmap) {
    assert(font.scale != 0)
    glyph_index := font.glyph_index_from_codepoint[codepoint]
    assert(glyph_index != 0)
    
    if font.one_past_highest_codepoint <= codepoint {
        font.one_past_highest_codepoint = codepoint + 1
    }
    
    w, h, xoff, yoff: i32
    // @todo(viktor): works after odin dev-225-01
    // mono_bitmap := tt.GetCodepointBitmap(&font.font, 0, font.scale_factor, codepoint, &w, &h, &xoff, &yoff)[:w*h]
    _mono_bitmap := tt.GetCodepointBitmap(&font.font, 0, font.scale, codepoint, &w, &h, &xoff, &yoff)
    mono_bitmap := _mono_bitmap[:w*h]
    defer tt.FreeBitmap(raw_data(mono_bitmap), nil)
    
    // @note(viktor): add an apron for bilinear blending
    result.width  = w+2
    result.height = h+2
    result.memory = make([][4]u8, result.width*result.height)
    
    for y in 0..<h {
        for x in 0..<w {
            src  := mono_bitmap[(h-1 - y) * w + x]
            dest := &result.memory[(y+1) * result.width + x+1]
            
            dest^ = premuliply_alpha(255, 255, 255, src)
        }
    }
    
    info.dimension = vec_cast(u32, result.width, result.height)
    info.align_percentage.x = (1) / cast(f32) result.width
    info.align_percentage.y = (1 + cast(f32) (yoff + h)) / cast(f32) result.height
    
    advanceWidth, leftSideBearing: i32
    tt.GetCodepointHMetrics(&font.font, codepoint, &advanceWidth, &leftSideBearing)
    for other_glyph_index in 1..<font.max_glyph_count {
        current_other := &font.horizontal_advances[glyph_index * font.max_glyph_count + other_glyph_index]
        current_other^ += cast(f32) (advanceWidth) * font.scale
        // other_current := &font.horizontal_advances[other_glyph_index * font.max_glyph_count + glyph_index]
        // other_current^ += cast(f32) (-leftSideBearing) * font.scale_factor
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

    // @note(viktor): If you are using this generically for some reason,
    // please remember that BMP files CAN GO IN EITHER DIRECTION and
    // the height will be negative for top-down.
    // (Also, there can be compression, etc., etc ... DON'T think this
    // a complete implementation)
    // @note(viktor): pixels listed bottom up
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
        stop: pmm,
    }
    
    if len(contents) > 0 {
        headers := cast([^]WAVE_Header) &contents[0]
        header := headers[0]
        // :PointerArithmetic
        behind_header := cast([^]u8) &headers[1]
        
        assert(header.riff == cast(u32) WAVE_Chunk_ID.RIFF)
        assert(header.wave_id == cast(u32) WAVE_Chunk_ID.WAVE)
        
        parse_chunk_at :: proc(at: pmm, stop: pmm) -> (result: RiffIterator) {
            result.at    = cast([^]u8) at
            result.stop  = stop
            
            return result
        }
        
        is_valid_riff_iter :: proc(it: RiffIterator) -> (result: b32) {
            at := cast(uintpointer) it.at
            stop := cast(uintpointer) it.stop
            result = at < stop 
            
            return result
        }
        
        next_chunk :: proc(it: RiffIterator) -> (result: RiffIterator) {
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
        
        get_chunk_data :: proc(it: RiffIterator) -> (result: pmm) {
            result = &it.at[size_of(WAVE_Chunk)]
            return result
        }
        
        get_chunk_size :: proc(it: RiffIterator) -> (result: u32) {
            chunk := cast(^WAVE_Chunk)it.at
            result = chunk.size
            
            return result
        }
        
        get_type :: proc(it: RiffIterator) -> (result: WAVE_Chunk_ID) {
            chunk := cast(^WAVE_Chunk)it.at
            result = chunk.id
            return result
        }
        
        channel_count:    u32
        sample_data:      [^]i16
        sample_data_size: u32
        
        for it := parse_chunk_at(behind_header, cast(pmm) &behind_header[header.size - 4]); is_valid_riff_iter(it); it = next_chunk(it) {
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
            // @important @todo(viktor): all sounds have to be padded with their subsequent sound
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


pmm :: rawptr
uintpointer :: uintptr

v2 :: [2]f32
v4 :: [4]f32

Pi  :: 3.14159265358979323846264338327950288

vec_cast :: proc { 
    cast_vec_2, cast_vec_4,
    cast_vec_v4,
}

@(require_results)
cast_vec_2 :: proc($T: typeid, x, y: $E) -> [2]T where T != E {
    return {cast(T) x, cast(T) y}
}

@(require_results)
cast_vec_4 :: proc($T: typeid, x, y, z, w: $E) -> [4]T where T != E {
    return {cast(T) x, cast(T) y, cast(T) z, cast(T) w}
}

@(require_results)
cast_vec_v4 :: proc($T: typeid, v:[4]$E) -> [4]T where T != E {
    return vec_cast(T, v.x, v.y, v.z, v.w)
}


@(require_results)
srgb_255_to_linear_1 :: proc(srgb: v4) -> (result: v4) {
    // @note(viktor): srgb_to_linear and linear_to_srgb assume a gamma of 2 instead of the usual 2.2
    @(require_results)
    srgb_to_linear :: proc(srgb: v4) -> (result: v4) {
        @(require_results) square :: proc(x: f32) -> f32 { return x * x}
        
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
linear_1_to_srgb_255 :: proc(linear: v4) -> (result: v4) {
    @(require_results)
    linear_to_srgb :: proc(linear: v4) -> (result: v4) {
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