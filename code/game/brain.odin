package game

Brain :: struct {
    id:   BrainId,
    
    // @note(viktor): As the entity also needs to know its brain's kind, we cant fold the kind into the raw_union and make data a union 
    kind: BrainKind,
    using data : struct #raw_union {
        parts:        [16]^Entity,
        hero:         BrainHeroParts,
        monster:      BrainMonster,
        familiar:     BrainFamiliarParts,
    }
}

BrainId :: distinct EntityId

ReservedBrainId :: enum BrainId {
    FirstHero = 1,
    LastHero = FirstHero + len(Input{}.controllers)-1,
    
    FirstFree,
}

BrainKind :: enum {
    None,
    Hero, 
    
    Snake, 
    Monster,
    Familiar,
}

// @todo(viktor): How can this be made fool-proof, so that you cannot assign brain_slot by a different type than the brain_kind
BrainSlot :: struct {
    index: u32,
}

////////////////////////////////////////////////

BrainHeroParts :: struct {
    head, body: ^Entity
}

BrainFamiliarParts :: struct {
    familiar, hero: ^Entity
}

BrainMonster :: struct {
    body: ^Entity,
}

brain_slot_for :: proc($base: typeid, $member : string) -> BrainSlot {
    // @study(viktor): can this be done better by using enumerated arrays?
    return { auto_cast offset_of_by_string(base, member) / size_of(^Entity) }
}

execute_brain :: proc(input: Input, world: ^World, region: ^SimRegion, brain: ^Brain) {
    dt := input.delta_time
    
    switch brain.kind {
      case .None: unreachable()
      case .Hero:
        head := brain.hero.head
        body := brain.hero.body
        
        controller_index := brain.id - cast(BrainId) ReservedBrainId.FirstHero
        con_hero := &world.controlled_heroes[controller_index]
        controller := input.controllers[controller_index]
        
        if was_pressed(controller.back) {
            mark_for_deletion(body)
            mark_for_deletion(head)
            return
        }
        
        con_ddp: v3
        if controller.is_analog {
            // @note(viktor): Use analog movement tuning
            con_ddp.xy = controller.stick_average
        } else {
            // @note(viktor): Use digital movement tuning
            if is_down(controller.stick_left) {
                con_hero.recenter_t = 1
                con_ddp.y  = 0
                con_ddp.x -= 1
            }
            if is_down(controller.stick_right) {
                con_hero.recenter_t = 1
                con_ddp.y  = 0
                con_ddp.x += 1
            }
            if is_down(controller.stick_up) {
                con_hero.recenter_t = 1
                con_ddp.x  = 0
                con_ddp.y += 1
            }
            if is_down(controller.stick_down) {
                con_hero.recenter_t = 1
                con_ddp.x  = 0
                con_ddp.y -= 1
            }
            
            if !is_down(controller.stick_left) && !is_down(controller.stick_right) {
                con_ddp.x = 0
                if is_down(controller.stick_up)   do con_ddp.y =  1
                if is_down(controller.stick_down) do con_ddp.y = -1
            }
            if !is_down(controller.stick_up) && !is_down(controller.stick_down) {
                con_ddp.y = 0
                if is_down(controller.stick_left)  do con_ddp.x = -1
                if is_down(controller.stick_right) do con_ddp.x =  1
            }
        }
        
        dfacing: v2
        if controller.button_up.ended_down {
            dfacing =  {0, 1}
        }
        if controller.button_down.ended_down {
            dfacing = -{0, 1}
        }
        if controller.button_left.ended_down {
            dfacing = -{1, 0}
        }
        if controller.button_right.ended_down {
            dfacing =  {1, 0}
        }
        
        if was_pressed(controller.start) {
            standing_on, ok := get_closest_traversable(region, head.p, {.Unoccupied} )
            if ok {
                add_hero(world, region, standing_on, 0)
            }
        }
        
        if head != nil {
            
            if dfacing.x != 0  {
                head.facing_direction = atan2(dfacing.y, dfacing.x)
            }
            if body != nil {
                body.facing_direction = head.facing_direction
            }

            ////////////////////////////////////////////////

            ddp_length_squared := length_squared(con_ddp)
            if ddp_length_squared > 1 {
                con_ddp *= 1 / square_root(ddp_length_squared)
            }
            
            speed :f32= 30
            drag :f32= 8
            con_ddp *= speed
            
            traversable, ok := get_closest_traversable(region, head.p)
            if ok {
                if body != nil {
                    if body.movement_mode == .Planted {
                        head_delta := body.p - head.p
                        head_distance := length(head_delta)
                        
                        max_head_distance :f32= 0.4
                        t_head_distance := clamp_01_to_range(0, head_distance, max_head_distance)
                        body.ddt_bob = t_head_distance * -30
                        
                        if traversable != body.occupying {
                            body.came_from = body.occupying
                            if transactional_occupy(body, &body.occupying, traversable) {
                                body.movement_mode = .Hopping
                                body.t_movement = 0
                            }
                        }
                    }
                
                    traversable := get_sim_space_traversable(traversable)
                    closest_p := traversable.p
                
                    con_hero.recenter_t = max(0, con_hero.recenter_t - dt)
                    
                    timer_is_up := con_hero.recenter_t == 0
                    no_push := length_squared(con_ddp) < 0.1
                    cp :f32= no_push ? 300 : 25
                    
                    recenter: [3]b32
                    for i in 0..<3 {
                        if no_push || timer_is_up && square(con_ddp[i]) < 0.1 {
                            recenter[i] = true
                            con_ddp[i] += cp * (closest_p[i] - head.p[i]) + 20 * (- head.dp[i])
                        } else {
                            // @todo(viktor): ODE OrdinaryDifferentialEquation here
                            con_ddp[i] += -drag * head.dp[i]
                        }
                    }
                }
            }
            
            head.ddp = con_ddp
        }
        
        if body != nil {
            head_delta :v3
            if head != nil {
                head_delta = head.p - body.p
            }
            
            body.y_axis = (v2{0, 1} + 1 * head_delta.xy)
            // body.x_axis = perpendicular(body.y_axis)
        }
        
      case .Familiar:
        familiar := brain.familiar.familiar
        hero     := brain.familiar.hero
        
        closest_hero_dsq := square(f32(10))
        if hero == nil {
            closest_hero: ^Entity
            
            // @cleanup get_closest_traversable
            for &test in slice(region.entities) {
                if test.brain_kind == .Hero {
                    dsq := length_squared(test.p.xy - familiar.p.xy)
                    if dsq < closest_hero_dsq {
                        closest_hero_dsq = dsq
                        closest_hero = &test
                    }
                }
            }
            
            hero = closest_hero
        }
        
        if FamiliarFollowsHero {
            if hero != nil && closest_hero_dsq > 1 {
                familiar.ddp = square_root(closest_hero_dsq) * (hero.p - familiar.p)
            }
        }
        
        normalize_accelaration := true
        drag :v3= 8
        speed :f32= 50
        
        // @todo(viktor): the code to use this ex-move_spec is in the head code
        
      case .Monster:
        body := brain.monster.body
        if body != nil {
            delta := random_bilateral(&world.game_entropy, v3)
            
            traversable, ok := get_closest_traversable(region, body.p + delta, { .Unoccupied })
            if ok {
                if body.movement_mode == .Planted {
                    distance := length(delta)
                    
                    if abs(distance) < 1.5 {
                        max_distance :f32= 0.4
                        t_distance := clamp_01_to_range(0, distance, max_distance)
                        body.ddt_bob = t_distance * -30
                        
                        if traversable != body.occupying {
                            body.came_from = body.occupying
                            if transactional_occupy(body, &body.occupying, traversable) {
                                body.movement_mode = .Hopping
                                body.t_movement = 0
                            }
                        }
                    }
                }
            }
        }
        
      case .Snake:
        
    }
}