package game

Particle_Cache :: struct {
    infos:   [MaxParticleSystemCount] Particle_System_Info,
    systems: [MaxParticleSystemCount] Particle_System,
}
MaxParticleSystemCount :: 64
MaxParticleCount :: 4096
Particle_System_Info :: struct {
    frames_since_considered_active: u32,
    id:                             EntityId,
}
Particle_System :: struct {
    p:     #soa [4096] v3,
    color: #soa [4096] v4,
    t:     [4096] f32,
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