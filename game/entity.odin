package game

EntityFlag :: enum {
    // TODO(viktor): Collides and Grounded probably can be removed now/soon
    Collides,
    Nonspatial,
    Moveable,
    Grounded,
    Traversable,

    Simulated,
}
EntityFlags :: bit_set[EntityFlag]

make_entity_nonspatial :: #force_inline proc(entity: ^Entity) {
    entity.flags += {.Nonspatial}
    entity.p = INVALID_P
}

make_entity_spatial :: #force_inline proc(entity: ^Entity, p, dp: v3) {
    entity.flags -= {.Nonspatial}
    entity.p = p
    entity.dp = dp
}

get_entity_ground_point :: #force_inline proc(entity: ^Entity) -> (result: v3) {
    result = entity.p

    return result
}
