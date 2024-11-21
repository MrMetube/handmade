package game

EntityFlag :: enum {
    Collides,
    Nonspatial,

    Simulated,
}
EntityFlags :: bit_set[EntityFlag]

update_monster :: #force_inline proc(region:^SimRegion, entity: ^Entity, dt:f32) {

}

make_entity_nonspatial :: #force_inline proc(entity: ^Entity) {
    entity.flags += {.Nonspatial}
    entity.p = INVALID_P
}

make_entity_spatial :: #force_inline proc(entity: ^Entity, p, dp: v3) {
    entity.flags -= {.Nonspatial}
    entity.p = p
    entity.dp = dp
}

update_sword :: #force_inline proc(region:^SimRegion, entity: ^Entity, dt:f32) {
    if .Nonspatial not_in entity.flags {
        move_spec := default_move_spec()
        move_spec.normalize_accelaration = false
        move_spec.drag = 0
        move_spec.speed = 0

        old_p := entity.p
        move_entity(region, entity, 0, move_spec, dt)
        distance_traveled := length(entity.p - old_p)
        
        // TODO(viktor): need to handle that this can overuse the remaining distance in a frame
        entity.distance_remaining -= distance_traveled
        if entity.distance_remaining < 0 {
                entity.flags += { .Nonspatial }3
        }
    }
}

update_familiar :: #force_inline proc(region:^SimRegion, entity: ^Entity, dt:f32) {
    closest_hero: ^Entity
    closest_hero_dsq := square(10)

	// TODO(viktor): make spatial queries easy for things
    for test_entity_index in 0..<region.entity_count {
		test := &region.entities[test_entity_index]
        if test.type == .Hero {
            dsq := length_squared(test.p.xy - entity.p.xy)
            if dsq < closest_hero_dsq {
                closest_hero_dsq = dsq
                closest_hero = test
            }
        }
    }

    ddp: v2
    if closest_hero != nil && closest_hero_dsq > 1 {
        mpss: f32 = 0.5
        ddp = mpss / square_root(closest_hero_dsq) * (closest_hero.p.xy - entity.p.xy)
    }

    move_spec := default_move_spec()
    move_spec.normalize_accelaration = true
    move_spec.drag = 8
    move_spec.speed = 50
    move_entity(region, entity, ddp, move_spec, dt)
}
