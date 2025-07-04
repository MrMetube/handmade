package game

import "core:simd/x86"


@(common) 
Sample :: [2]i16

@(common) 
GameSoundBuffer :: struct {
    // @note(viktor): Samples length must be padded to a multiple of 4 samples.
    samples:            []Sample,
    samples_per_second: u32,
}

Mixer :: struct {
    permanent_arena:          Arena,
    first_playing_sound:      ^PlayingSound,
    first_free_playing_sound: ^PlayingSound,
    
    master_volume: v2,
}

Sound :: struct {
    // @todo(viktor): should channel_count be implicit, or does that make the underlying memory too messy?
    // @todo(viktor): should sample_count be explicit, or does that make the underlying memory too messy?
    channel_count: u8,
    channels: [2][]i16, // 1 or 2 channels of [sample_count]samples
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

init_mixer :: proc(mixer: ^Mixer, parent_arena: ^Arena) {
    mixer.master_volume = 0.2
    sub_arena(&mixer.permanent_arena, parent_arena, 1 * Megabyte)
}

play_sound :: proc(mixer: ^Mixer, id: SoundId, volume: [2]f32 = 1, pitch: f32 = 1) {
    playing_sound := list_pop_head(&mixer.first_free_playing_sound) or_else push(&mixer.permanent_arena, PlayingSound, no_clear())
    
    // @todo(viktor): should volume default to [0.5,0.5] to be centered?
    playing_sound ^= {
        id = id,
        
        d_sample = pitch,
        
        current_volume   = volume,
        target_volume    = volume,
        d_current_volume = 0,
    }
    
    list_push(&mixer.first_playing_sound, playing_sound)
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
    timed_function()
    
    mixer_memory := begin_temporary_memory(temporary_arena)
    defer end_temporary_memory(mixer_memory)
    
    generation_id := begin_generation(assets)
    defer end_generation(assets, generation_id)
    
    seconds_per_sample := 1.0 / cast(f32) sound_buffer.samples_per_second
    ChannelCount :: 2
    
    sample_count := cast(i32) len(sound_buffer.samples)
    assert((sample_count & 3) == 0)
    chunk_count := sample_count / 4
    
    // @todo(viktor): Do we not just want to clear the channels here
    real_channel_0 := push(temporary_arena, f32x4, chunk_count, align_no_clear(16))
    real_channel_1 := push(temporary_arena, f32x4, chunk_count, align_no_clear(16))
    
    // @note(viktor): clear out the summation channels
    #no_bounds_check for i in 0..<len(real_channel_0) {
        real_channel_0[i] = 0
        real_channel_1[i] = 0
    }
    
    // @note(viktor): Sum all sounds
    sum_all_sounds := begin_timed_block("sum_all_sounds")
    for playing_sound_pointer := &mixer.first_playing_sound; playing_sound_pointer^ != nil;  {
        playing_sound := playing_sound_pointer^
        
        real_channel_cursor: [ChannelCount]u32
        
        sound := get_sound(assets, playing_sound.id, generation_id)
        
        total_chunks_to_mix := chunk_count
        
        sound_finished: b32
        for total_chunks_to_mix != 0 && !sound_finished {
            if sound != nil {
                next_sound_in_chain := get_next_sound_in_chain(assets, playing_sound.id)
                prefetch_sound(assets, next_sound_in_chain)
                
                d_sample := playing_sound.d_sample
                d_sample_chunk := 4 * d_sample
                
                volume   := playing_sound.current_volume
                d_volume := seconds_per_sample * playing_sound.d_current_volume
                d_volume_chunk := 4 * d_volume
                // @todo(viktor): go to 8 wide simd
                master_volume_0 := cast(f32x4) mixer.master_volume[0]
                master_volume_1 := cast(f32x4) mixer.master_volume[1]
                
                volume_0 := f32x4 {
                    volume[0] + 0 * d_volume[0],
                    volume[0] + 1 * d_volume[0],
                    volume[0] + 2 * d_volume[0],
                    volume[0] + 3 * d_volume[0],
                }
                volume_1 := f32x4 {
                    volume[1] + 0 * d_volume[1],
                    volume[1] + 1 * d_volume[1],
                    volume[1] + 2 * d_volume[1],
                    volume[1] + 3 * d_volume[1],
                }
                
                chunks_to_mix := total_chunks_to_mix
                // @important @todo(viktor): Fix the alignment of sounds
                // assert(len(sound.channels[0]) & 3 == 0) 
                samples_in_sound := cast(i32) len(sound.channels[0])
                
                real_chunks_remaining_in_sound := cast(f32) (samples_in_sound - round(i32, playing_sound.samples_played)) / d_sample_chunk
                chunks_remaining_in_sound := round(i32, real_chunks_remaining_in_sound)
                if chunks_to_mix > chunks_remaining_in_sound {
                    chunks_to_mix = chunks_remaining_in_sound
                }
                
                volume_ends_at: [ChannelCount]i32
                for &ends_at, index in volume_ends_at {
                    if d_volume_chunk[index] != 0 {
                        volume_delta := playing_sound.target_volume[index] - volume[index]
                        volume_chunk_count := round(i32, 0.125 * volume_delta / d_volume_chunk[index])
                        if chunks_to_mix > volume_chunk_count {
                            chunks_to_mix = volume_chunk_count
                            ends_at = chunks_to_mix
                        }
                    }
                }
                
                // @todo(viktor): handle stereo
                begin_sample_p := playing_sound.samples_played
                end_sample_p := begin_sample_p + d_sample_chunk * cast(f32) chunks_to_mix
                sample_offset := d_sample * f32x4 { 0, 1, 2, 3 }
                for loop_index in 0..<chunks_to_mix {
                    sample_p := begin_sample_p + d_sample_chunk * cast(f32) loop_index
                    // @todo(viktor): actually handle the bounds
                    #no_bounds_check when true {
                        sample_p_offset := sample_p + sample_offset
                        sample_index    := cast(i32x4) sample_p_offset
                        sample_frac     := sample_p_offset - cast(f32x4) sample_index
                        
                        sample_value_f := f32x4{
                            cast(f32) sound.channels[0][(transmute([4]i32) sample_index)[0]],
                            cast(f32) sound.channels[0][(transmute([4]i32) sample_index)[1]],
                            cast(f32) sound.channels[0][(transmute([4]i32) sample_index)[2]],
                            cast(f32) sound.channels[0][(transmute([4]i32) sample_index)[3]],
                        }
                        sample_value_t := f32x4{
                            cast(f32) sound.channels[0][(transmute([4]i32) sample_index)[0] + 1],
                            cast(f32) sound.channels[0][(transmute([4]i32) sample_index)[1] + 1],
                            cast(f32) sound.channels[0][(transmute([4]i32) sample_index)[2] + 1],
                            cast(f32) sound.channels[0][(transmute([4]i32) sample_index)[3] + 1],
                        }
                        sample_value := (1 - sample_frac) * sample_value_f + sample_frac * sample_value_t
                    } else {
                        sample_value := f32x4{
                            cast(f32) sound.channels[0][round(sample_p + 0.0 * d_sample)],
                            cast(f32) sound.channels[0][round(sample_p + 1.0 * d_sample)],
                            cast(f32) sound.channels[0][round(sample_p + 2.0 * d_sample)],
                            cast(f32) sound.channels[0][round(sample_p + 3.0 * d_sample)],
                        }
                    }
                    
                    dest_0 := &real_channel_0[real_channel_cursor[0]]
                    dest_1 := &real_channel_1[real_channel_cursor[1]]
                    
                    d0 := x86._mm_load_ps(auto_cast dest_0)
                    d1 := x86._mm_load_ps(auto_cast dest_1)
                    
                    d0 += master_volume_0 * volume_0 * sample_value
                    d1 += master_volume_1 * volume_1 * sample_value
                    
                    x86._mm_store_ps(cast([^]f32) dest_0, d0)
                    x86._mm_store_ps(cast([^]f32) dest_1, d1)
                    
                    volume_0 += d_volume_chunk[0]
                    volume_1 += d_volume_chunk[1]
                    real_channel_cursor += 1
                }
                
                playing_sound.current_volume[0] = (transmute([4]f32) volume_0)[0]
                playing_sound.current_volume[1] = (transmute([4]f32) volume_1)[0]
                
                for ends_at, index in volume_ends_at {
                    if chunks_to_mix == ends_at {
                        playing_sound.current_volume[index] = playing_sound.target_volume[index]
                        playing_sound.d_current_volume[index] = 0
                    }
                }
                
                playing_sound.samples_played = end_sample_p
                assert(total_chunks_to_mix >= chunks_to_mix)
                total_chunks_to_mix -= chunks_to_mix
                
                if chunks_to_mix == chunks_remaining_in_sound {
                    if is_valid_asset(next_sound_in_chain) {
                        playing_sound.id = next_sound_in_chain
                        assert(playing_sound.samples_played >= cast(f32) sample_count)
                        playing_sound.samples_played -= cast(f32) samples_in_sound
                        if playing_sound.samples_played < 0 {
                            playing_sound.samples_played = 0
                        }
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
            // :ListEntryRemovalInLoop
            list_push(&mixer.first_free_playing_sound, playing_sound)
            playing_sound_pointer ^= playing_sound.next
        } else {
            playing_sound_pointer = &playing_sound.next
        }
    }
    end_timed_block(sum_all_sounds)
    
    { // @note(viktor): convert to 16bit and write into output sound buffer
        timed_block("write_into_sound_buffer")
        // @todo(viktor): maybe no pointer-arithmetic/looping
        source_0 := raw_data(real_channel_0)
        source_1 := raw_data(real_channel_1)
        
        sample_out := cast([^]x86.__m128i)raw_data(sound_buffer.samples)
        for sample_index: i32; sample_index < chunk_count; sample_index += 1 {
        s0 := x86._mm_load_ps(cast([^]f32) source_0)
        s1 := x86._mm_load_ps(cast([^]f32) source_1)
        
        source_0 = source_0[1:]
        source_1 = source_1[1:]
        
        l := x86._mm_cvtps_epi32(s0)
        r := x86._mm_cvtps_epi32(s1)
        
        lr0 := x86._mm_unpacklo_epi32(l, r)
        lr1 := x86._mm_unpackhi_epi32(l, r)
        
        s01 := x86._mm_packs_epi32(lr0, lr1)
        
        sample_out[0] = s01
        sample_out = sample_out[1:]
        }
    }
}