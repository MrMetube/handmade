package game

Particle_Cache :: struct {
    infos:   [MaxParticleSystemCount] Particle_System_Info,
    systems: [MaxParticleSystemCount] Particle_System,
}
MaxParticleSystemCount :: 64
MaxParticleCount :: 4096 / len(lane_f32)
Particle_System_Info :: struct {
    frames_since_considered_active: u32,
    id:                             EntityId,
}
Particle_System :: struct {
    p:      #soa [MaxParticleCount] lane_v3,
    dp:     #soa [MaxParticleCount] lane_v3,
    ddp:    #soa [MaxParticleCount] lane_v3,
    color:  #soa [MaxParticleCount] lane_v4,
    dcolor: #soa [MaxParticleCount] lane_v4,
    
    next_4_particles: u32,
    bitmap_id: BitmapId,
}

Particle_Spec :: struct {}

////////////////////////////////////////////////

init_particle_cache :: proc (cache: ^Particle_Cache) {
    zero(cache.infos[:])
}

get_or_create_particle_system :: proc (cache: ^Particle_Cache, id: EntityId, particle_spec: Particle_Spec, create_if_not_found: bool) -> (result: ^Particle_System) {
    if cache == nil do return nil
    
    max_frames_since_active: u32
    
    replace: ^Particle_System
    for &info, index in cache.infos {
        if info.id == id {
            result = &cache.systems[index]
            break
        }
        
        if max_frames_since_active < info.frames_since_considered_active {
            max_frames_since_active = info.frames_since_considered_active
            replace = &cache.systems[index]
        }
    }
    
    if result == nil && create_if_not_found {
        assert(replace != nil)
        
        init_particle_system(cache, replace, id, particle_spec)
        result = replace
    }
    
    return result
}

init_particle_system :: proc (cache: ^Particle_Cache, replace: ^Particle_System, id: EntityId, particle_spec: Particle_Spec) {
    unimplemented()
}

consider_particle_system_active :: proc (cache: ^Particle_Cache, system: ^Particle_System) {
    // :PointerArithmetic
    index := (cast(umm) raw_data(cache.systems[:]) - cast(umm) system) / size_of(Particle_System)
    info := &cache.infos[index]
    info.frames_since_considered_active = 0
}

update_and_render_particle_systems :: proc (cache: ^Particle_Cache, render_group: ^RenderGroup, dt: f32) {
    for index in 0 ..< len(cache.infos) {
        info   := &cache.infos[index]
        system := &cache.systems[index]
        
        info.frames_since_considered_active += 1
    }
}

fountain_test :: proc(system: ^Particle_System, render_group: ^RenderGroup, _world: ^World_Mode, entropy: ^RandomSeries, dt: f32) {
    if !FountainTest do return
    
    head_id := first_bitmap_from(render_group.assets, .Head)
    system.bitmap_id = head_id

    font_id := first_font_from(render_group.assets, .Font)
    font := get_font(render_group.assets, font_id, render_group.generation_id)
    if font == nil {
        load_font(render_group.assets, font_id, false)
    } else {
        font_info := get_font_info(render_group.assets, font_id)
        
        index := system.next_4_particles
        system.next_4_particles += 1
        if system.next_4_particles >= MaxParticleCount {
            system.next_4_particles = 0
        }
        
        system.p[index]      = {random_bilateral(entropy, lane_f32)*0.1, 0, 0}
        system.dp[index]     = {random_bilateral(entropy, lane_f32)*0, (random_unilateral(entropy, lane_f32)*0.4)+7, 0}
        system.ddp[index]    = {0, -9.8, 0}
        system.color[index]  = V4(random_unilateral(entropy, lane_v3), 1)
        system.dcolor[index] = {0,0,0,-0.2}
        
        
        when false {
            for &row in world.cells {
                zero(row[:])
            }
            
            grid_scale :f32= 0.3
            grid_origin:= v3{-0.5 * grid_scale * ParticleCellSize, 0, 0}
            for particle in world.particles {
                p := ( particle.p - grid_origin ) / grid_scale
                x := truncate(i32, p.x)
                y := truncate(i32, p.y)
                
                x = clamp(x, 1, ParticleCellSize-2)
                y = clamp(y, 1, ParticleCellSize-2)
                
                cell := &world.cells[y][x]
                
                density: f32 = particle.color.a
                cell.density                += density
                cell.velocity_times_density += density * particle.dp
            }
            
            if ShowGrid {
                for row, y in world.cells {
                    for cell, x in row {
                        alpha := clamp_01(0.1 * cell.density)
                        color := v4{1,1,1, alpha}
                        position := (vec_cast(f32, x, y, 0) + {0.5,0.5,0})*grid_scale + grid_origin
                        push_rectangle_outline(render_group, rectangle_center_dimension(position.xy, grid_scale), default_flat_transform(), color, 0.05)
                    }
                }
            }
        }
        
        for index in 0..<MaxParticleCount {
            when false {
                p := ( particle.p - grid_origin ) / grid_scale
                x := truncate(i32, p.x)
                y := truncate(i32, p.y)
                
                x = clamp(x, 1, ParticleCellSize-2)
                y = clamp(y, 1, ParticleCellSize-2)
                
                cell := &world.cells[y][x]
                cell_l := &world.cells[y][x-1]
                cell_r := &world.cells[y][x+1]
                cell_u := &world.cells[y+1][x]
                cell_d := &world.cells[y-1][x]
                
                dispersion: v3
                dc : f32 = 0.3
                dispersion += dc * (cell.density - cell_l.density) * v3{-1, 0, 0}
                dispersion += dc * (cell.density - cell_r.density) * v3{ 1, 0, 0}
                dispersion += dc * (cell.density - cell_d.density) * v3{ 0,-1, 0}
                dispersion += dc * (cell.density - cell_u.density) * v3{ 0, 1, 0}
                
                particle_ddp := system.ddp[index] + dispersion
            }
            particle_ddp: lane_v3
            
            // @note(viktor): simulate particle forward in time
            system.p[index]     += particle_ddp * 0.5 * square(dt) + system.dp[index] * dt
            system.dp[index]    += particle_ddp * dt
            system.color[index] += system.dcolor[index] * dt
            // @todo(viktor): should we just clamp colors in the renderer?
            color := clamp_01(system.color[index])
            // if color.a > 0.9 {
            //     color.a = 0.9 * clamp_01_map_to_range(cast(lane_f32) 1, color.a, 0.9)
            // }
            
            // if system.p[index].y < 0 {
            //     coefficient_of_restitution :f32= 0.3
            //     coefficient_of_friction :f32= 0.7
            //     system.p[index].y *= -1
            //     system.dp[index].y *= -coefficient_of_restitution
            //     system.dp[index].x *= coefficient_of_friction
            // }
            
            // @note(viktor): render the particle
            // push_bitmap(render_group, system.bitmap_id, default_flat_transform(), 0.4, system.p[index], color)
        }
    }
}