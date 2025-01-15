package game

Mixer :: struct {
    permanent_arena:          ^Arena,
    first_playing_sound:      ^PlayingSound,
    first_free_playing_sound: ^PlayingSound,
}

Sound :: struct {
    channel_count: u32,
    channels: [2][]i16, // 1 or 2 channels of samples
}

PlayingSound :: struct {
    next: ^PlayingSound,
    id:   SoundId,
    
    samples_played: i32,
    
    current_volume:   [2]f32,
    target_volume:    [2]f32,
    d_current_volume: [2]f32,
}

init_mixer :: proc(mixer: ^Mixer, arena: ^Arena) {
    mixer^ = {
        permanent_arena = arena
    }
}

play_sound :: proc(mixer: ^Mixer, id: SoundId, volume: [2]f32 = 1) {
    if mixer.first_free_playing_sound == nil {
        mixer.first_free_playing_sound = push(mixer.permanent_arena, PlayingSound)
    }
    
    playing_sound := mixer.first_free_playing_sound
    mixer.first_free_playing_sound = playing_sound.next
    
    // TODO(viktor): should volume default to [0.5,0.5] to be centered?
    playing_sound^ = {
        id = id,
        next = mixer.first_playing_sound,
        
        current_volume   = volume,
        target_volume    = volume,
        d_current_volume = 0,
    }
    
    mixer.first_playing_sound = playing_sound
}

change_volume :: proc(mixer: ^Mixer, sound: ^PlayingSound, fade_duration_in_seconds: f32, volume: [2]f32, ) {
    if fade_duration_in_seconds <= 0 {
        sound.current_volume = volume
        sound.target_volume  = volume
    } else {
        sound.target_volume  = volume
        sound.d_current_volume = (sound.target_volume - sound.current_volume) / fade_duration_in_seconds
    }
}

output_playing_sounds :: proc(mixer: ^Mixer, temporary_arena: ^Arena, assets: ^Assets, sound_buffer: GameSoundBuffer) {
    mixer_memory := begin_temporary_memory(temporary_arena)
    defer end_temporary_memory(mixer_memory)
    
    // NOTE(viktor): clear out the summation channels
    real_channel_0 := push(temporary_arena, f32, len(sound_buffer.samples), clear_to_zero = true)
    real_channel_1 := push(temporary_arena, f32, len(sound_buffer.samples), clear_to_zero = true)

    seconds_per_sample := 1.0 / cast(f32) sound_buffer.samples_per_second
    ChannelCount :: 2
    
    // NOTE(viktor): Sum all sounds
    in_pointer := &mixer.first_playing_sound
    for playing_sound_pointer := &mixer.first_playing_sound; playing_sound_pointer^ != nil;  {
        playing_sound := playing_sound_pointer^
        
        
        channel_cursor: [ChannelCount]u32
        
        sound := get_sound(assets, playing_sound.id)
        
        total_samples_to_mix := cast(u32) len(sound_buffer.samples)
        sound_finished: b32
        for total_samples_to_mix != 0 && !sound_finished {
            if sound != nil {
                info := get_sound_info(assets, playing_sound.id)
                prefetch_sound(assets, info.next_id_to_play)

                volume   := playing_sound.current_volume
                d_volume := seconds_per_sample * playing_sound.d_current_volume
                
                assert(playing_sound.samples_played >= 0)
                
                samples_to_mix := total_samples_to_mix
                samples_in_sound := cast(u32) len(sound.channels[0])
                
                assert(playing_sound.samples_played >= 0)
                samples_remaining_sound := samples_in_sound - cast(u32) playing_sound.samples_played
                if samples_to_mix > samples_remaining_sound {
                    samples_to_mix = samples_remaining_sound
                }
                
                volume_ended: [ChannelCount]b32
                for &ended, index in volume_ended {
                    if d_volume[index] != 0 {
                        volume_delta := playing_sound.target_volume[index] - volume[index]
                        volume_sample_count := cast(u32) (volume_delta / d_volume[index] + 0.5)
                        if samples_to_mix > volume_sample_count {
                            samples_to_mix = volume_sample_count
                            ended = true
                        }
                    }
                }
                
                // TODO(viktor): handle stereo
                for sample_index in cast(u32) playing_sound.samples_played..< cast(u32) playing_sound.samples_played + samples_to_mix {
                    dest_0 := &real_channel_0[channel_cursor[0]]
                    dest_1 := &real_channel_1[channel_cursor[1]]
                    
                    sample_value := cast(f32) sound.channels[0][sample_index]
                    
                    dest_0^ += volume[0] * sample_value
                    dest_1^ += volume[1] * sample_value
                    
                    volume += d_volume
                    
                    channel_cursor += 1
                }
                
                playing_sound.current_volume = volume
                
                // TODO(viktor): this is not correct yet, need to truncate the loop
                for ended, index in volume_ended {
                    if ended {
                        playing_sound.current_volume[index] = playing_sound.target_volume[index]
                        playing_sound.d_current_volume[index] = 0
                    }
                }
                
                assert(total_samples_to_mix >= samples_to_mix)
                playing_sound.samples_played += cast(i32) samples_to_mix
                total_samples_to_mix         -= samples_to_mix

                // TODO(viktor): make playback seamless!
                if cast(u32) playing_sound.samples_played == samples_in_sound {
                    if is_valid_sound(info.next_id_to_play) {
                        playing_sound.id = info.next_id_to_play
                        playing_sound.samples_played = 0
                    } else {
                        sound_finished = true
                    }
                }
            } else {
                load_sound(assets, playing_sound.id)
                break
            }
        }        
        if sound_finished {
            playing_sound_pointer^         = playing_sound.next
            playing_sound.next             = mixer.first_free_playing_sound
            mixer.first_free_playing_sound = playing_sound
        } else {
            playing_sound_pointer = &playing_sound.next
        }
    }
    
    { // NOTE(viktor): convert to 16bit and write into output sound buffer
        source_0 := real_channel_0
        source_1 := real_channel_1
        
        source_0_cursor: u32
        source_1_cursor: u32
        for sample_index in 0..<len(sound_buffer.samples) {
            dest := &sound_buffer.samples[sample_index]
            
            dest^ = {
                cast(i16) (source_0[source_0_cursor] + 0.5),
                cast(i16) (source_1[source_1_cursor] + 0.5),
            } 
            
            source_0_cursor += 1
            source_1_cursor += 1
        }
    }
}