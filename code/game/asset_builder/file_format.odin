package hha

MagicValue : u32 : 'h' << 0 | 'h' << 8 | 'a' << 16 | 'f' << 24
Version    : u32 : 0

// 
// NOTE: Shared with the assets directly
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
    
    // NOTE(viktor): Bitmaps
    Shadow, Wall, Arrow, Stair, 
    Rock, Grass,

    Cape, Head, Body, Sword,
    Monster,
    
    // NOTE(viktor): Sounds
    Blop, Drop, Woosh, Hit,
    
    Music,
    
    // NOTE(viktor): Fonts
    Font, FontGlyph,
}

AssetTagId :: enum {
    FacingDirection, // NOTE(viktor): angle in radians
    Codepoint, // NOTE(viktor): utf8 codepoint for font
}

// 
// NOTE: HHA specific
// 

Header :: struct #packed {
    magic_value: u32,
    version:     u32, 
    
    tag_count:        u32,
    asset_type_count: u32,
    asset_count:      u32,
    
    tags:        u64, // [tag_count]AssetTag
    asset_types: u64, // [asset_type_count]AssetType
    assets:      u64, // [asset_count]AssetData
}

AssetData :: struct #packed {
    data_offset: u64,
    
    first_tag_index:         u32,
    one_past_last_tag_index: u32,
    
    info : struct #raw_union {
        bitmap: BitmapInfo,
        sound:  SoundInfo,
        font:   FontInfo,
    }
}

BitmapInfo :: struct #packed {
    dimension:        [2]u32,
    align_percentage: [2]f32,
    // NOTE(viktor): Data is:
    //     pixels: [dimension[1]][dimension[2]] [4]u8
}

SoundInfo :: struct #packed {
    sample_count:  u32,
    channel_count: u32,
    chain:         SoundChain,
    // NOTE(viktor): Data is:
    //     samples: [channel_count][sample_count] i16
}

// TODO(viktor): coult these be polymorphic structs?
// i.e. FontInfo :: struct($codepoint_count: u32) #packed {
FontInfo :: struct #packed {
    codepoint_count: u32,
    ascent:  f32,
    descent: f32,
    linegap: f32,
    // NOTE(viktor): Data is:
    //     codepoint_count:    [codepoint_count] BitmapId,
    //     horizontal_advance: [codepoint_count*codepoint_count] f32,
}

SoundChain :: enum u32 {
    None, Loop, Advance,
}

