package main

import win "core:sys/windows"
import "vendor:directx/dxgi"

init_dSound :: proc(window: win.HWND, buffer_size_in_bytes, samples_per_second: u32) {
    assert(GLOBAL_sound_buffer == nil, "DSound has already been initialized")

    dSound_lib := win.LoadLibraryW(win.utf8_to_wstring("dsound.dll"))
    if dSound_lib == nil {
        // TODO Diagnostics
    }

    DirectSoundCreate := cast(ProcDirectSoundCreate) win.GetProcAddress(dSound_lib, "DirectSoundCreate")
    if DirectSoundCreate == nil {
        // TODO Diagnostics
    }

    direct_sound : ^IDirectSound
    if result := DirectSoundCreate(nil, &direct_sound, nil); win.FAILED(result) {
        // TODO Diagnostics
    }

    wave_format: WAVEFORMATEX = {
        wFormatTag      = WAVE_FORMAT_PCM,
        nChannels       = 2,
        nSamplesPerSec  = samples_per_second,
        wBitsPerSample  = size_of(i16) * 8,
        nBlockAlign     = 2 * size_of(i16),
        nAvgBytesPerSec = samples_per_second * 2 * size_of(i16),
    }
    if result := direct_sound->SetCooperativeLevel(window, DSSCL_PRIORITY); win.FAILED(result) {
        // TODO Diagnostics
    }

    fake_sound_buffer_description: DSBUFFERDESC = {
        dwSize  = size_of(DSBUFFERDESC),
        dwFlags = DSBCAPS_PRIMARYBUFFER,
    }
    
    fake_sound_buffer_for_setup: ^IDirectSoundBuffer
    if result := direct_sound->CreateSoundBuffer(&fake_sound_buffer_description, &fake_sound_buffer_for_setup, nil); win.FAILED(result) {
        // TODO Diagnostics
    }
    
    if result := fake_sound_buffer_for_setup->SetFormat(&wave_format); win.FAILED(result) {
        // TODO Diagnostics
    }

    actual_sound_buffer_description := DSBUFFERDESC{
        dwSize        = size_of(DSBUFFERDESC),
        dwFlags       = DSBCAPS_GETCURRENTPOSITION2,
        dwBufferBytes = buffer_size_in_bytes,
        lpwfxFormat   = &wave_format,
    }
    when INTERNAL {
        // TODO(viktor): should this be a setting?
        actual_sound_buffer_description.dwFlags |= DSBCAPS_GLOBALFOCUS
    }
    
    if result := direct_sound->CreateSoundBuffer(&actual_sound_buffer_description, &GLOBAL_sound_buffer, nil); win.FAILED(result) {
        // TODO Diagnostics
    }
}



// ---------------------- Internal stuff



@(private="file")
ProcDirectSoundCreate :: #type proc(lpGuid: win.LPGUID, ppDS: ^^IDirectSound,   pUnkOuter: win.LPUNKNOWN) -> win.HRESULT

//
// -----------------------------------------------------------------
//
// Code below was copied from: 
//   https://gist.githubusercontent.com/jon-lipstate/3d3a21646b6b2d8d5cda5e848d45da84/raw/81efd882725c6dfed1ce6904bc28ad55bf0659f8/dsound.odin
// Note by the author of the code below: 
// 	 Released as Public Domain, Attribution appreciated but not required, Jon Lipstate
// -----------------------------------------------------------------
//


IDirectSound :: struct {
    using lpVtbl: ^IDirectSoundVtbl,
}

IDirectSoundVtbl :: struct {
    using iunknown_vtable: dxgi.IUnknown_VTable,
    CreateSoundBuffer:    proc "stdcall" (
        this: ^IDirectSound,
        pcDSBufferDesc: ^DSBUFFERDESC,
        ppDSBuffer: ^^IDirectSoundBuffer,
        pUnkOuter: rawptr,
    ) -> win.HRESULT,
    GetCaps:              proc "stdcall" (this: ^IDirectSound, pDSCaps: ^DSCAPS) -> win.HRESULT,
    DuplicateSoundBuffer: proc "stdcall" (
        this: ^IDirectSound,
        pDSBufferOriginal: ^IDirectSoundBuffer,
        ppDSBufferDuplicate: ^^IDirectSoundBuffer,
    ) -> win.HRESULT,
    SetCooperativeLevel:  proc "stdcall" (this: ^IDirectSound, hwnd: win.HWND, dwLevel: win.DWORD) -> win.HRESULT,
    Compact:              proc "stdcall" (this: ^IDirectSound) -> win.HRESULT,
    GetSpeakerConfig:     proc "stdcall" (this: ^IDirectSound, pdwSpeakerConfig: ^win.DWORD) -> win.HRESULT,
    SetSpeakerConfig:     proc "stdcall" (this: ^IDirectSound, dwSpeakerConfig: win.DWORD) -> win.HRESULT,
    Initialize:           proc "stdcall" (this: ^IDirectSound, pcGuidDevice: ^win.GUID) -> win.HRESULT,
}

DSBUFFERDESC :: struct {
    dwSize:          win.DWORD,
    dwFlags:         win.DWORD,
    dwBufferBytes:   win.DWORD,
    dwReserved:      win.DWORD,
    lpwfxFormat:     ^WAVEFORMATEX,
    // #if DIRECTSOUND_VERSION >= 0x0700
    guid3DAlgorithm: win.GUID,
    // #endif
}

WAVEFORMATEX :: struct {
    wFormatTag:      win.WORD, /* format type */
    nChannels:       win.WORD, /* number of channels (i.e. mono, stereo...) */
    nSamplesPerSec:  win.DWORD, /* sample rate */
    nAvgBytesPerSec: win.DWORD, /* for buffer estimation */
    nBlockAlign:     win.WORD, /* block size of data */
    wBitsPerSample:  win.WORD, /* number of bits per sample of mono data */
    cbSize:          win.WORD, /* the count in bytes of the size of */
    /* extra information (after cbSize) */
}

IDirectSoundBuffer :: struct {
    using lpVtbl: ^IDirectSoundBufferVtbl,
}
IDirectSoundBufferVtbl :: struct {
    using iunknown_vtable: dxgi.IUnknown_VTable,
    GetCaps:            proc "stdcall" (this: ^IDirectSoundBuffer, pDSBufferCaps: ^DSBCAPS) -> win.HRESULT, //LPDSBCAPS
    GetCurrentPosition: proc "stdcall" (
        this: ^IDirectSoundBuffer,
        pdwCurrentPlayCursor: ^win.DWORD,
        pdwCurrentWriteCursor: ^win.DWORD,
    ) -> win.HRESULT,
    GetFormat:          proc "stdcall" (
        this: ^IDirectSoundBuffer,
        pwfxFormat: ^WAVEFORMATEX,
        dwSizeAllocated: win.DWORD,
        pdwSizeWritten: ^win.DWORD,
    ) -> win.HRESULT,
    GetVolume:          proc "stdcall" (this: ^IDirectSoundBuffer, plVolume: ^win.LONG) -> win.HRESULT,
    GetPan:             proc "stdcall" (this: ^IDirectSoundBuffer, plPan: ^win.LONG) -> win.HRESULT,
    GetFrequency:       proc "stdcall" (this: ^IDirectSoundBuffer, pdwFrequency: ^win.DWORD) -> win.HRESULT,
    GetStatus:          proc "stdcall" (this: ^IDirectSoundBuffer, pdwStatus: ^win.DWORD) -> win.HRESULT,
    Initialize:         proc "stdcall" (
        this: ^IDirectSoundBuffer,
        pDirectSound: ^IDirectSound,
        pcDSBufferDesc: ^DSBUFFERDESC,
    ) -> win.HRESULT,
    Lock:               proc "stdcall" (
        this: ^IDirectSoundBuffer,
        dwOffset: win.DWORD,
        dwBytes: win.DWORD,
        ppvAudioPtr1: ^win.LPVOID,
        pdwAudioBytes1: ^win.DWORD,
        ppvAudioPtr2: ^win.LPVOID,
        pdwAudioBytes2: ^win.DWORD,
        dwFlags: win.DWORD,
    ) -> win.HRESULT,
    Play:               proc "stdcall" (
        this: ^IDirectSoundBuffer,
        dwReserved1: win.DWORD,
        dwPriority: win.DWORD,
        dwFlags: win.DWORD,
    ) -> win.HRESULT,
    SetCurrentPosition: proc "stdcall" (this: ^IDirectSoundBuffer, dwNewPosition: win.DWORD) -> win.HRESULT,
    SetFormat:          proc "stdcall" (this: ^IDirectSoundBuffer, pcfxFormat: ^WAVEFORMATEX) -> win.HRESULT,
    SetVolume:          proc "stdcall" (this: ^IDirectSoundBuffer, lVolume: win.LONG) -> win.HRESULT,
    SetPan:             proc "stdcall" (this: ^IDirectSoundBuffer, lPan: win.LONG) -> win.HRESULT,
    SetFrequency:       proc "stdcall" (this: ^IDirectSoundBuffer, dwFrequency: win.DWORD) -> win.HRESULT,
    Stop:               proc "stdcall" (this: ^IDirectSoundBuffer) -> win.HRESULT,
    Unlock:             proc "stdcall" (
        this: ^IDirectSoundBuffer,
        pvAudioPtr1: win.LPVOID,
        dwAudioBytes1: win.DWORD,
        pvAudioPtr2: win.LPVOID,
        dwAudioBytes2: win.DWORD,
    ) -> win.HRESULT,
    Restore:            proc "stdcall" (this: ^IDirectSoundBuffer) -> win.HRESULT,
}

WAVE_FORMAT_PCM :: 1
DSSCL_PRIORITY :: 0x00000002
DSBCAPS_PRIMARYBUFFER :: 0x00000001
DSBCAPS_GETCURRENTPOSITION2 :: 0x00010000
DSBCAPS_GLOBALFOCUS  :: 0x00008000

DSBPLAY_LOOPING              :: 0x00000001
DSBPLAY_LOCHARDWARE          :: 0x00000002
DSBPLAY_LOCSOFTWARE          :: 0x00000004
DSBPLAY_TERMINATEBY_TIME     :: 0x00000008
DSBPLAY_TERMINATEBY_DISTANCE :: 0x000000010
DSBPLAY_TERMINATEBY_PRIORITY :: 0x000000020


DSCAPS :: struct {
    dwSize:win.DWORD,
    dwFlags:win.DWORD,
    dwMinSecondarySampleRate:win.DWORD,
    dwMaxSecondarySampleRate:win.DWORD,
    dwPrimaryBuffers:win.DWORD,
    dwMaxHwMixingAllBuffers:win.DWORD,
    dwMaxHwMixingStaticBuffers:win.DWORD,
    dwMaxHwMixingStreamingBuffers:win.DWORD,
    dwFreeHwMixingAllBuffers:win.DWORD,
    dwFreeHwMixingStaticBuffers:win.DWORD,
    dwFreeHwMixingStreamingBuffers:win.DWORD,
    dwMaxHw3DAllBuffers:win.DWORD,
    dwMaxHw3DStaticBuffers:win.DWORD,
    dwMaxHw3DStreamingBuffers:win.DWORD,
    dwFreeHw3DAllBuffers:win.DWORD,
    dwFreeHw3DStaticBuffers:win.DWORD,
    dwFreeHw3DStreamingBuffers:win.DWORD,
    dwTotalHwMemBytes:win.DWORD,
    dwFreeHwMemBytes:win.DWORD,
    dwMaxContigFreeHwMemBytes:win.DWORD,
    dwUnlockTransferRateHwBuffers:win.DWORD,
    dwPlayCpuOverheadSwBuffers:win.DWORD,
    dwReserved1:win.DWORD,
    dwReserved2:win.DWORD,
}

DSBCAPS :: struct{
    dwSize              : win.DWORD,
    dwFlags             : win.DWORD,
    dwBufferBytes       : win.DWORD,
    dwUnlockTransferRate: win.DWORD,
    dwPlayCpuOverhead   : win.DWORD,
}