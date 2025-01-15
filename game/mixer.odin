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
    
    id:     SoundId,
    volume: [2]f32,
    
    samples_played: i32,
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
        volume = volume,
        next = mixer.first_playing_sound
    }
    
    mixer.first_playing_sound = playing_sound
}

output_playing_sounds :: proc(mixer: ^Mixer, temporary_arena: ^Arena, assets: ^Assets, sound_buffer: GameSoundBuffer) {
    mixer_memory := begin_temporary_memory(temporary_arena)
    defer end_temporary_memory(mixer_memory)
    
    // NOTE(viktor): clear out the summation channels
    real_channel_0 := push(temporary_arena, f32, len(sound_buffer.samples), clear_to_zero = true)
    real_channel_1 := push(temporary_arena, f32, len(sound_buffer.samples), clear_to_zero = true)

    // NOTE(viktor): Sum all sounds
    in_pointer := &mixer.first_playing_sound
    for playing_sound_pointer := &mixer.first_playing_sound; playing_sound_pointer^ != nil;  {
        playing_sound := playing_sound_pointer^
        
        assert(playing_sound.samples_played >= 0)
        
        channel_0_cursor: u32
        channel_1_cursor: u32
        
        sound := get_sound(assets, playing_sound.id)
        
        total_samples_to_mix := cast(i32) len(sound_buffer.samples)
        sound_finished: b32
        for total_samples_to_mix != 0 && !sound_finished {
            if sound != nil {
                info := get_sound_info(assets, playing_sound.id)
                prefetch_sound(assets, info.next_id_to_play)
                // TODO(viktor): handle stereo
                volume_0 := playing_sound.volume[0]
                volume_1 := playing_sound.volume[1]
                
                assert(playing_sound.samples_played >= 0)
                
                samples_to_mix := total_samples_to_mix
                samples_in_sound := cast(i32) len(sound.channels[0])
                samples_remaining_sound := samples_in_sound - playing_sound.samples_played
                if samples_to_mix > samples_remaining_sound {
                    samples_to_mix = samples_remaining_sound
                }
                
                for sample_index in playing_sound.samples_played..< playing_sound.samples_played + samples_to_mix {
                    dest_0 := &real_channel_0[channel_0_cursor]
                    dest_1 := &real_channel_1[channel_1_cursor]
                    
                    sample_value := cast(f32) sound.channels[0][sample_index]
                    
                    dest_0^ += volume_0 * sample_value
                    dest_1^ += volume_1 * sample_value
                    
                    channel_0_cursor += 1
                    channel_1_cursor += 1
                }
                
                assert(total_samples_to_mix >= samples_to_mix)
                playing_sound.samples_played += samples_to_mix
                total_samples_to_mix         -= samples_to_mix

                // TODO(viktor): make playback seamless!
                if playing_sound.samples_played == samples_in_sound {
                    if is_valid_sound(info.next_id_to_play) {
                        playing_sound.id = info.next_id_to_play
                        playing_sound.samples_played = 0
                    } else {
                        sound_finished = true
                    }
                } else {
                    assert(total_samples_to_mix == 0)
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