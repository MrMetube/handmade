//+private file
// TODO study how they made the dsound odin wrapper and apply it here
package main

import "core:fmt"
import win "core:sys/windows"

load_xAudio2 :: proc() {
	xAudio2_lib := win.LoadLibraryW(win.utf8_to_wstring("xaudio2_9.dll"))
	if (xAudio2_lib != nil) {
		fmt.println("Loaded")
		XAudio2Create = cast(ProcXAudio2Create) win.GetProcAddress(xAudio2_lib, "XAudio2Create")
	}
}

XAudio2Create : proc(ppXAudio2 : ^^IXAudio2, Flags : win.UINT32, XAudio2Processor : XAUDIO2_PROCESSOR) -> win.HRESULT

@(private="file")
ProcXAudio2Create :: #type proc(ppXAudio2 : ^^IXAudio2, Flags : win.UINT32, XAudio2Processor : XAUDIO2_PROCESSOR) -> win.HRESULT
@(private="file")
XAudio2CreateStub :: proc(ppXAudio2 : ^^IXAudio2, Flags : win.UINT32, XAudio2Processor : XAUDIO2_PROCESSOR) -> win.HRESULT {
	// XAUDIO2_E_INVALID_CALL :: 0x88960001
	return -1
}

IXAudio2 :: struct {
	AddRef                 : ^proc(), // 	Adds a reference to the XAudio2 object.
	CommitChanges          : ^proc(), // 	Atomically applies a set of operations that are tagged with a given identifier.

	CreateMasteringVoice   : ^proc(
		self: ^IXAudio2,
		ppMasteringVoice : ^^IXAudio2MasteringVoice,
		InputChannels : win.UINT32,
		InputSampleRate : win.UINT32,
		Flags : win.UINT32,
		szDeviceId : win.LPCWSTR,
		pEffectChain : ^XAUDIO2_EFFECT_CHAIN,
		StreamCategory : AUDIO_STREAM_CATEGORY
	) -> win.HRESULT, // 	Creates and configures a mastering voice.


	CreateSourceVoice      : ^proc(), // 	Creates and configures a source voice.
	CreateSubmixVoice      : ^proc(), // 	Creates and configures a submix voice.
	GetPerformanceData     : ^proc(), // 	Returns current resource usage details, such as available memory or CPU usage.
	QueryInterface         : ^proc(), // 	Queries for a given COM interface on the XAudio2 object.
	RegisterForCallbacks   : ^proc(), // 	Adds an IXAudio2EngineCallback pointer to the XAudio2 engine callback list.
	Release                : ^proc(), // 	Releases a reference to the XAudio2 object.
	SetDebugConfiguration  : ^proc(), // 	Changes global debug logging options for XAudio2.
	StartEngine            : ^proc(), // 	Starts the audio processing thread.
	StopEngine             : ^proc(), // 	Stops the audio processing thread.
	UnregisterForCallbacks : ^proc(), // 	Removes an IXAudio2EngineCallback pointer from the XAudio2 engine callback list.
}

IXAudio2MasteringVoice :: struct{
	GetChannelMask : ^proc(),
}

XAUDIO2_EFFECT_CHAIN :: struct {
	// EffectCount : win.UINT32,
  	// pEffectDescriptors : [^]XAUDIO2_EFFECT_DESCRIPTOR,
}
// XAUDIO2_EFFECT_DESCRIPTOR : struct {
//   	pEffect : ^IUnknown,
// 	InitialState : win.BOOL,
//     OutputChannels : win.UINT32,
// }

AUDIO_STREAM_CATEGORY :: enum i32 {
  AudioCategory_Other = 0,
  AudioCategory_ForegroundOnlyMedia,
  AudioCategory_BackgroundCapableMedia,
  AudioCategory_Communications,
  AudioCategory_Alerts,
  AudioCategory_SoundEffects,
  AudioCategory_GameEffects,
  AudioCategory_GameMedia,
  AudioCategory_GameChat,
  AudioCategory_Speech,
  AudioCategory_Movie,
  AudioCategory_Media,
  AudioCategory_FarFieldSpeech,
  AudioCategory_UniformSpeech,
  AudioCategory_VoiceTyping
}

XAUDIO2_FILTER_TYPE :: enum i32 {
  LowPassFilter = 0,
  BandPassFilter,
  HighPassFilter,
  NotchFilter,
  LowPassOnePoleFilter,
  HighPassOnePoleFilter,
}

XAUDIO2_PROCESSOR :: i32

Processor1 :: 0x00000001
Processor2 :: 0x00000002
Processor3 :: 0x00000004
Processor4 :: 0x00000008
Processor5 :: 0x00000010
Processor6 :: 0x00000020
Processor7 :: 0x00000040
Processor8 :: 0x00000080
Processor9 :: 0x00000100
Processor10 :: 0x00000200
Processor11 :: 0x00000400
Processor12 :: 0x00000800
Processor13 :: 0x00001000
Processor14 :: 0x00002000
Processor15 :: 0x00004000
Processor16 :: 0x00008000
Processor17 :: 0x00010000
Processor18 :: 0x00020000
Processor19 :: 0x00040000
Processor20 :: 0x00080000
Processor21 :: 0x00100000
Processor22 :: 0x00200000
Processor23 :: 0x00400000
Processor24 :: 0x00800000
Processor25 :: 0x01000000
Processor26 :: 0x02000000
Processor27 :: 0x04000000
Processor28 :: 0x08000000
Processor29 :: 0x10000000
Processor30 :: 0x20000000
Processor31 :: 0x40000000
Processor32 :: 0x80000000

XAUDIO2_ANY_PROCESSOR :: 0xffffffff
XAUDIO2_DEFAULT_PROCESSOR :: Processor1
