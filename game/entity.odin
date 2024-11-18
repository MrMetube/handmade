package game

update_monster :: #force_inline proc(region:^SimRegion, entity: ^Entity, dt:f32) {

}

update_sword :: #force_inline proc(region:^SimRegion, entity: ^Entity, dt:f32) {
    move_spec := default_move_spec()
    move_spec.normalize_accelaration = false
    move_spec.drag = 0
    move_spec.speed = 0

    old_p := entity.p
    move_entity(region, entity, 0, move_spec, dt)
    distance_traveled := length(entity.p - old_p)
    
    entity.distance_remaining -= distance_traveled
    if entity.distance_remaining < 0 {
		unimplemented("Need to make entities be able to not be there anymore")
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
