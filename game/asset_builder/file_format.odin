package hha

MagicValue : u32 : 'h' << 0 | 'h' << 8 | 'a' << 16 | 'f' << 24
Version    : u32 : 0

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

BitmapId :: distinct u32
SoundId  :: distinct u32

AssetTag :: struct #packed {
    id:    AssetTagId,
    value: f32,
}

AssetData :: struct #packed {
    data_offset: u64,
    
    first_tag_index:         u32,
    one_past_last_tag_index: u32,
    
    using as : struct #raw_union {
        bitmap: Bitmap,
        sound:  Sound,
    }
}

AssetType :: struct #packed {
    id: AssetTypeId,
    
    first_asset_index:   u32,
    one_past_last_index: u32,
}

Bitmap :: struct #packed {
    dimension:        [2]u32,
    align_percentage: [2]f32,
}

Sound :: struct #packed {
    sample_count:    u32,
    channel_count:   u32,
    next_id_to_play: SoundId,
}


AssetTypeId :: enum {
    None,
    // NOTE(viktor): Bitmaps
    Shadow, Wall, Arrow, Stair, 

    Rock, Grass,

    Head, Body, Cape, Sword,
    Monster,
    
    // NOTE(viktor): Sounds
    Blop, Drop, Woosh, Hit,

    Music,
}

AssetTagId :: enum {
    FacingDirection, // NOTE(viktor): angle in radians
}
