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
    entity.p = InvalidP
}

make_entity_spatial :: #force_inline proc(entity: ^Entity, p, dp: v3) {
    entity.flags -= {.Nonspatial}
    entity.p = p
    entity.dp = dp
}

get_entity_ground_point :: proc { get_entity_ground_point_, get_entity_ground_point_with_p }
get_entity_ground_point_ :: #force_inline proc(entity: ^Entity) -> (result: v3) {
    result = get_entity_ground_point(entity, entity.p)

    return result
}

get_entity_ground_point_with_p :: #force_inline proc(entity: ^Entity, for_entity_p: v3) -> (result: v3) {
    result = for_entity_p

    return result
}
