package hha

MagicValue : u32 : 'h' << 0 | 'h' << 8 | 'a' << 16 | 'f' << 24
Version    : u32 : 0

// 
// @note(viktor): Shared with the assets directly
// 

BitmapId :: distinct u32
SoundId  :: distinct u32
FontId   :: distinct u32

AssetTag :: struct #packed {
    id:    AssetTagId,
    value: f32,
}

AssetType :: struct #packed {
    id: AssetTypeId,
    
    first_asset_index:   u32,
    one_past_last_index: u32,
}

AssetTypeId :: enum u32 {
    None,
    
    // @note(viktor): Bitmaps
    Shadow, 
    Tree, 
    Sword, 
    Rock, 
    
    Grass,
    Tuft,
    Stone,

    Head, 
    Cape,
    Torso,
    
    
    // @note(viktor): Fonts
    Font, 
    FontGlyph,
    
    
    // @note(viktor): Sounds
    Bloop, 
    Crack, 
    Drop, 
    Glide,
    Music, 
    Puhp,
    
    // @note(viktor): Cutscene
    OpeningCutscene
}

AssetFontType :: enum u32 {
    Default = 0,
    Debug   = 10,
}

AssetTagId :: enum u32 {
    Smoothness,
    Flatness,
    
    FacingDirection, // @note(viktor): angle in radians
    
    UnicodeCodepoint,
    FontType,         // @note(viktor): see AssetFontType
    
    ShotIndex,
    LayerIndex,
}

// 
// @note(viktor): HHA specific
// 

Header :: struct #packed {
    magic_value: u32,
    version:     u32, 
    
    tag_count:        u32,
    asset_type_count: u32,
    asset_count:      u32,
    
    // offsets in the file at which data starts
    tags:        u64, // [tag_count]AssetTag
    asset_types: u64, // [asset_type_count]AssetType
    assets:      u64, // [asset_count]AssetData
}

AssetData :: struct #packed {
    data_offset: u64,
    
    first_tag_index:         u32,
    one_past_last_tag_index: u32,
    
    info: struct #raw_union {
        bitmap: BitmapInfo,
        sound:  SoundInfo,
        font:   FontInfo,
    },
}

BitmapInfo :: struct #packed {
    dimension:        [2] u32,
    align_percentage: [2] f32,
    // @note(viktor): Data is:
    //     pixels: [dimension[1]][dimension[2]] [4]u8
}

SoundInfo :: struct #packed {
    sample_count:  u32,
    channel_count: u32,
    chain:         SoundChain,
    // @note(viktor): Data is:
    //     samples: [channel_count][sample_count] i16
}

SoundChain :: enum u32 {
    None, Loop, Advance,
}

FontInfo :: struct #packed {
    one_past_highest_codepoint: rune,
    glyph_count: u32,
    
    ascent:  f32,
    descent: f32,
    linegap: f32,
    
    // @note(viktor): Data is:
    //     glyphs:   [glyph_count] GlyphInfo,
    //     advances: [glyph_count][glyph_count] f32,
}

#assert(size_of(rune) == size_of(u32))
GlyphInfo :: struct #packed {
    codepoint: rune,
    bitmap:    BitmapId,
}
