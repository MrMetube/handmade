package game

Particle_Cache :: struct {
    entropy: RandomSeries, // @note(viktor): Not for gameplay, ever!
    fire_system: Particle_System,
}

Particle_System :: struct #align(align_of(lane_Particle)) {
    particles: [4096 / LaneWidth] lane_Particle,
    
    next_lane_particle: u32,
    bitmap_id: BitmapId,
}

lane_Particle :: struct #align(align_of(lane_f32)) {
    p:      lane_v3,
    dp:     lane_v3,
    ddp:    lane_v3,
    color:  lane_v4,
    dcolor: lane_v4,
    
    floor_z: f32,
    chunk_z: i32,
}

////////////////////////////////////////////////

init_particle_cache :: proc (cache: ^Particle_Cache, assets: ^Assets) {
    cache.entropy = seed_random_series(123)
    
    cache.fire_system.bitmap_id = first_bitmap_from(assets, .Head)
}

update_and_render_particle_systems :: proc (cache: ^Particle_Cache, render_group: ^RenderGroup, dt: f32, camera_p: v3) {
    update_and_render_fire(&cache.fire_system, render_group, dt, camera_p)
}

update_and_render_fire :: proc(system: ^Particle_System, render_group: ^RenderGroup, dt: f32, camera_p: v3) {
    timed_function()
    
    transform := default_upright_transform()
    
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
    
    push_sort_barrier(render_group, true)
    defer push_sort_barrier(render_group, false)
    
    for &particle in system.particles {
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
            dc: f32 = 0.3
            dispersion += dc * (cell.density - cell_l.density) * v3{-1, 0, 0}
            dispersion += dc * (cell.density - cell_r.density) * v3{ 1, 0, 0}
            dispersion += dc * (cell.density - cell_d.density) * v3{ 0,-1, 0}
            dispersion += dc * (cell.density - cell_u.density) * v3{ 0, 1, 0}
            
            particle_ddp := system.ddp[index] + dispersion
        }
        particle_ddp: lane_v3
        
        // @note(viktor): simulate particle forward in time
        particle.p     += particle_ddp * 0.5 * square(dt) + particle.dp * dt
        particle.dp    += particle_ddp * dt
        particle.color += particle.dcolor * dt
        // @todo(viktor): should we just clamp colors in the renderer?
        color : lane_v4 = clamp_01(particle.color)
        // if color.a > 0.9 {
        //     color.a = 0.9 * clamp_01_map_to_range(cast(lane_f32) 1, color.a, 0.9)
        // }
        
        // if particle.p.y < 0 {
        //     coefficient_of_restitution :f32= 0.3
        //     coefficient_of_friction :f32= 0.7
        //     particle.p.y *= -1
        //     particle.dp.y *= -coefficient_of_restitution
        //     particle.dp.x *= coefficient_of_friction
        // }
        
        // @note(viktor): render the particles
        transform.floor_z = particle.floor_z - camera_p.z
        transform.chunk_z = particle.chunk_z
        for i in 0..<LaneWidth {
            // @todo(viktor): make a utility for this
            color := v4 {
                (transmute([LaneWidth] f32) color.r)[i], 
                (transmute([LaneWidth] f32) color.g)[i], 
                (transmute([LaneWidth] f32) color.b)[i], 
                (transmute([LaneWidth] f32) color.a)[i],
            }
            p := v3 {
                (transmute([LaneWidth] f32) particle.p.x)[i], 
                (transmute([LaneWidth] f32) particle.p.y)[i], 
                (transmute([LaneWidth] f32) particle.p.z)[i],
            }
            
            transform.offset = -camera_p
            
            if color.a > 0 {
                push_bitmap(render_group, system.bitmap_id, transform, 0.4, p, color)
            }
        }
    }
}

spawn_fire :: proc (cache: ^Particle_Cache, at: v3, floor_z: f32, chunk_z: i32) {
    system  := &cache.fire_system
    entropy := &cache.entropy
    
    at := vec_cast(lane_f32, at)
    
    index := system.next_lane_particle
    system.next_lane_particle += 1
    if system.next_lane_particle >= len(system.particles) {
        system.next_lane_particle = 0
    }
    
    particle := &system.particles[index]
    particle.p      = at + {random_bilateral(entropy, lane_f32)*0.1, 0, 0}
    particle.dp     = {random_bilateral(entropy, lane_f32)*0, (random_unilateral(entropy, lane_f32)*0.4)+7, 0}
    particle.ddp    = {0, -9.8, 0}
    particle.color  = V4(random_unilateral(entropy, lane_v3), 1)
    particle.dcolor = {0,0,0,-0.2}
    
    particle.floor_z = floor_z
    particle.chunk_z = chunk_z
}
