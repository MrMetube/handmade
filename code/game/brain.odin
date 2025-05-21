package game

Brain :: struct {
    id:   BrainId,
    
    kind: BrainKind, // Is this just a Discrimenated Union?
    using data : struct #raw_union {
        parts :       [16]^Entity,
        hero:         BrainHeroParts,
        familiar:     BrainFamiliarParts,
        floaty_thing: ^Entity,
    }
}

BrainId :: distinct EntityId

BrainHeroParts :: struct {
    head, body: ^Entity
}

BrainFamiliarParts :: struct {
    familiar, hero: ^Entity
}

ReservedBrainId :: enum BrainId {
    FirstHero = 1,
    LastHero = FirstHero + len(Input{}.controllers)-1,
    
    FirstFree,
}

BrainKind :: enum {
    Hero, 
    
    Snake, 
    Monster,
    Familiar,
    FloatyThingForNow,
}

BrainSlot :: struct {
    index: u32,
}

brain_slot_for :: proc($base: typeid, $member : string) -> BrainSlot {
    // @study(viktor): can this be done better by using enumerated arrays?
    return { auto_cast offset_of_by_string(base, member) / size_of(^Entity) }
}

execute_brain :: proc(input: Input, region: ^SimRegion, brain: ^Brain) {
    dt := input.delta_time
    
    switch brain.kind {
      case .Hero:
        // @todo(viktor): Check that they're not deleted what do we do?
        head := brain.hero.head
        body := brain.hero.body
        
        head.move_spec.normalize_accelaration = true
        head.move_spec.drag = 5
        head.move_spec.speed = 30
        
        controller_index := brain.id - cast(BrainId) ReservedBrainId.FirstHero
        controller := input.controllers[controller_index]
        
        ddp: v3
        if controller.is_analog {
            // @note(viktor): Use analog movement tuning
            ddp.xy = controller.stick_average
        } else {
            // @note(viktor): Use digital movement tuning
            if is_down(controller.stick_left) {
                ddp.y  = 0
                ddp.x -= 1
            }
            if is_down(controller.stick_right) {
                ddp.y  = 0
                ddp.x += 1
            }
            if is_down(controller.stick_up) {
                ddp.x  = 0
                ddp.y += 1
            }
            if is_down(controller.stick_down) {
                ddp.x  = 0
                ddp.y -= 1
            }
            
            if !is_down(controller.stick_left) && !is_down(controller.stick_right) {
                ddp.x = 0
                if is_down(controller.stick_up)   do ddp.y =  1
                if is_down(controller.stick_down) do ddp.y = -1
            }
            if !is_down(controller.stick_up) && !is_down(controller.stick_down) {
                ddp.y = 0
                if is_down(controller.stick_left)  do ddp.x = -1
                if is_down(controller.stick_right) do ddp.x =  1
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
        
        exited: b32
        if was_pressed(controller.back) {
            exited = true
        }
        
        when false do if was_pressed(controller.start) {
            standing_on, ok := get_closest_traversable(camera_sim_region, head.p, {.Unoccupied} )
            if ok {
                add_hero(world, camera_sim_region, standing_on)
            }
        }
        
        if exited {
            delete_entity(body)
            delete_entity(head)
        } else {
            if head != nil && dfacing.x != 0  {
                head.facing_direction = atan2(dfacing.y, dfacing.x)
            } else {
                // @note(viktor): leave the facing direction what it was
            }
            
            if head != nil {
                traversable_reference, ok := get_closest_traversable(region, head.p)
                if ok {
                    if body != nil {
                        if body.movement_mode == .Planted {
                            head_delta := body.p - head.p
                            head_distance := length(head_delta)
                            
                            max_head_distance :f32= 0.4
                            t_head_distance := clamp_01_to_range(0, head_distance, max_head_distance)
                            body.ddt_bob = t_head_distance * -30
                           
                            if traversable_reference != body.occupying {
                                body.came_from = body.occupying
                                if transactional_occupy(body, &body.occupying, traversable_reference) {
                                    body.movement_mode = .Hopping
                                    body.t_movement = 0
                                }
                            }
                        }
                    }
                    
                    traversable := get_sim_space_traversable(traversable_reference)
                    closest_p := traversable.p
                    
                    if body != nil {
                        spring_active := length_squared(ddp) == 0
                        if spring_active {
                            for i in 0..<3 {
                                head_spring := 400 * (closest_p[i] - head.p[i]) + 20 * (- head.dp[i])
                                ddp[i] += dt*head_spring
                            }
                        }
                    }
                }
                
                head.ddp = ddp
            }
            
            if head != nil && body != nil {
                body.facing_direction = head.facing_direction
            }
        }
        
        if body != nil {
            head_delta :v3
            if head != nil {
                head_delta = head.p - body.p
            }
            // @todo(viktor): reenable this stretching?
            body.y_axis = v2{0, 1} + 1 * head_delta.xy
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
                if test.type == .HeroBody {
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
        
        familiar.move_spec.normalize_accelaration = true
        familiar.move_spec.drag = 8
        familiar.move_spec.speed = 50
        
      case .FloatyThingForNow:
        floaty_thing := brain.floaty_thing
        floaty_thing.t_bob += dt
        if floaty_thing.t_bob > Tau do floaty_thing.t_bob -= Tau
        floaty_thing.p.z += 0.05 * cos(floaty_thing.t_bob)
      
      case .Monster:
        
      case .Snake:
        
    }
}