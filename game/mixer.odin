package game

import "core:simd"
import "core:simd/x86"

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
    
    samples_played: f32,
    d_sample:       f32, 
    
    current_volume:   [2]f32,
    target_volume:    [2]f32,
    d_current_volume: [2]f32,
}

init_mixer :: proc(mixer: ^Mixer, arena: ^Arena) {
    mixer^ = {
        permanent_arena = arena
    }
}

play_sound :: proc(mixer: ^Mixer, id: SoundId, volume: [2]f32 = 1, pitch: f32 = 1) {
    if mixer.first_free_playing_sound == nil {
        mixer.first_free_playing_sound = push(mixer.permanent_arena, PlayingSound)
    }
    
    playing_sound := mixer.first_free_playing_sound
    mixer.first_free_playing_sound = playing_sound.next
    
    // TODO(viktor): should volume default to [0.5,0.5] to be centered?
    playing_sound^ = {
        id = id,
        next = mixer.first_playing_sound,
        
        d_sample = pitch,
        
        current_volume   = volume,
        target_volume    = volume,
        d_current_volume = 0,
    }
    
    mixer.first_playing_sound = playing_sound
}

change_volume :: proc(mixer: ^Mixer, sound: ^PlayingSound, fade_duration_in_seconds: f32, volume: [2]f32) {
    if fade_duration_in_seconds <= 0 {
        sound.current_volume = volume
        sound.target_volume  = volume
    } else {
        sound.target_volume  = volume
        sound.d_current_volume = (sound.target_volume - sound.current_volume) / fade_duration_in_seconds
    }
}

change_pitch :: proc(mixer: ^Mixer, sound: ^PlayingSound, pitch: f32) {
    sound.d_sample = pitch
}

@(enable_target_feature="sse,sse2")
output_playing_sounds :: proc(mixer: ^Mixer, temporary_arena: ^Arena, assets: ^Assets, sound_buffer: GameSoundBuffer) {
    mixer_memory := begin_temporary_memory(temporary_arena)
    defer end_temporary_memory(mixer_memory)
    
    seconds_per_sample := 1.0 / cast(f32) sound_buffer.samples_per_second
    ChannelCount :: 2
    
    sample_count := cast(u32) len(sound_buffer.samples)
    assert((sample_count & 7) == 0)
    sample_count_4 := sample_count / 4
    sample_count_8 := sample_count / 8
    
    real_channel_0 := push(temporary_arena, f32x4, sample_count_8 * 2, clear_to_zero = false, alignment = 16)
    real_channel_1 := push(temporary_arena, f32x4, sample_count_8 * 2, clear_to_zero = false, alignment = 16)
    
    // NOTE(viktor): clear out the summation channels
    #no_bounds_check for i in 0..<len(real_channel_0) {
        real_channel_0[i] = 0
        real_channel_1[i] = 0
    }

    // NOTE(viktor): Sum all sounds
    in_pointer := &mixer.first_playing_sound
    for playing_sound_pointer := &mixer.first_playing_sound; playing_sound_pointer^ != nil;  {
        playing_sound := playing_sound_pointer^
        
        channel_cursor: [ChannelCount]u32
        
        sound := get_sound(assets, playing_sound.id)
        
        total_samples_to_mix_8 := sample_count_8
        
        sound_finished: b32
        for total_samples_to_mix_8 != 0 && !sound_finished {
            if sound != nil {
                info := get_sound_info(assets, playing_sound.id)
                prefetch_sound(assets, info.next_id_to_play)

                volume   := playing_sound.current_volume
                d_volume := seconds_per_sample * playing_sound.d_current_volume
                d_volume_8 := 8 * d_volume
                
                d_sample := playing_sound.d_sample * 0.9
                d_sample_8 := 8 * d_sample
                
                volume_4_0 := f32x4 {
                    volume[0] + 0 * d_volume[0],
                    volume[0] + 1 * d_volume[0],
                    volume[0] + 2 * d_volume[0],
                    volume[0] + 3 * d_volume[0],
                } 
                volume_4_1 := f32x4 {
                    volume[1] + 0 * d_volume[1],
                    volume[1] + 1 * d_volume[1],
                    volume[1] + 2 * d_volume[1],
                    volume[1] + 3 * d_volume[1],
                }
                
                samples_to_mix_8   := total_samples_to_mix_8
                assert(len(sound.channels[0]) & 7 == 0)
                samples_in_sound := cast(u32) len(sound.channels[0])
                samples_in_sound_8 := samples_in_sound / 8
                
                assert(playing_sound.samples_played >= 0)
                real_samples_remaining_sound_8 := (cast(f32) samples_in_sound - playing_sound.samples_played) / d_sample_8
                samples_remaining_sound_8 := cast(u32) (real_samples_remaining_sound_8 + 0.5)
                if samples_to_mix_8 > samples_remaining_sound_8 {
                    samples_to_mix_8 = samples_remaining_sound_8
                }
                
                volume_ended: [ChannelCount]b32
                for &ended, index in volume_ended {
                    if d_volume_8[index] != 0 {
                        volume_delta := playing_sound.target_volume[index] - volume[index]
                        volume_sample_count_8 := cast(u32) (0.125 * volume_delta / d_volume_8[index] + 0.5)
                        if samples_to_mix_8 > volume_sample_count_8 {
                            samples_to_mix_8 = volume_sample_count_8
                            ended = true
                        }
                    }
                }
                
                // TODO(viktor): handle stereo
                sample_p := playing_sound.samples_played
                // TODO(viktor): actually handle the bounds
                for _ in 0..<samples_to_mix_8 {
                    sample_value_0 := f32x4{
                        cast(f32) sound.channels[0][floor(sample_p + 0.0 * d_sample)],
                        cast(f32) sound.channels[0][floor(sample_p + 1.0 * d_sample)],
                        cast(f32) sound.channels[0][floor(sample_p + 2.0 * d_sample)],
                        cast(f32) sound.channels[0][floor(sample_p + 3.0 * d_sample)],
                    }
                    sample_value_1 := f32x4{
                        cast(f32) sound.channels[1][floor(sample_p + 4.0 * d_sample)],
                        cast(f32) sound.channels[1][floor(sample_p + 5.0 * d_sample)],
                        cast(f32) sound.channels[1][floor(sample_p + 6.0 * d_sample)],
                        cast(f32) sound.channels[1][floor(sample_p + 7.0 * d_sample)],
                    }
                    
                    dest_00 := &real_channel_0[channel_cursor[0]]
                    dest_01 := &real_channel_0[channel_cursor[0]+1]
                    dest_10 := &real_channel_1[channel_cursor[1]]
                    dest_11 := &real_channel_1[channel_cursor[1]+1]
                    
                    d0_0 := x86._mm_load_ps(auto_cast dest_00)
                    d0_1 := x86._mm_load_ps(auto_cast dest_01)
                    d1_0 := x86._mm_load_ps(auto_cast dest_10)
                    d1_1 := x86._mm_load_ps(auto_cast dest_11)
                    
                    d0_0 += volume_4_0 * sample_value_0
                    d0_1 += volume_4_0 * sample_value_0
                    d1_0 += volume_4_1 * sample_value_1
                    d1_1 += volume_4_1 * sample_value_1
                    
                    x86._mm_store_ps(cast([^]f32) dest_00, d0_0)
                    x86._mm_store_ps(cast([^]f32) dest_01, d0_1)
                    x86._mm_store_ps(cast([^]f32) dest_10, d1_0)
                    x86._mm_store_ps(cast([^]f32) dest_11, d1_1)
                    
                    volume_4_0 += d_volume_8[0]
                    volume_4_1 += d_volume_8[1]
                    volume     += d_volume_8
                    sample_p   += d_sample_8
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
                
                playing_sound.samples_played = sample_p
                assert(total_samples_to_mix_8 >= samples_to_mix_8)
                total_samples_to_mix_8 -= samples_to_mix_8

                // TODO(viktor): make playback seamless!
                if cast(u32) (playing_sound.samples_played + 0.5) >= samples_in_sound {
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
        
        source_cursor: u32
        for sample_index: u32; sample_index < sample_count_4; sample_index += 4 {
            dest := cast(^x86.__m128i) &sound_buffer.samples[sample_index]
            
            l := x86._mm_cvtps_epi32(source_0[source_cursor])
            r := x86._mm_cvtps_epi32(source_1[source_cursor])
            
            lr0 := x86._mm_unpacklo_epi32(l, r)
            lr1 := x86._mm_unpackhi_epi32(l, r)
            
            s := x86._mm_packs_epi32(lr0, lr1)
            
            dest^ = s
            
            source_cursor += 1
        }
    }
}