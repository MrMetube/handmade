package main

import win "core:sys/windows"

init_xInput :: proc() {
	assert(XInputGetState == XInputGetStateStub, "xInput has already been initialized")

	xInput_lib := win.LoadLibraryW(win.utf8_to_wstring("Xinput1_4.dll"))
	if xInput_lib == nil {
		// TODO Diagnostics
		xInput_lib = win.LoadLibraryW(win.utf8_to_wstring("XInput9_1_0.dll"))
	}
	if xInput_lib == nil {
		// TODO Diagnostics
		xInput_lib = win.LoadLibraryW(win.utf8_to_wstring("xinput1_3.dll"))
	}
	if (xInput_lib != nil) {
		XInputGetState = cast(ProcXInputGetState) win.GetProcAddress(xInput_lib, "XInputGetState")
		XInputSetState = cast(ProcXInputSetState) win.GetProcAddress(xInput_lib, "XInputSetState")
	} else {
		// TODO Diagnostics
	}
}

XInputGetState : ProcXInputGetState = XInputGetStateStub
XInputSetState : ProcXInputSetState = XInputSetStateStub

XINPUT_STATE  :: struct {
  dwPacketNumber : win.DWORD,
  Gamepad : XINPUT_GAMEPAD,
}

XINPUT_GAMEPAD :: struct {
  wButtons: win.WORD,
  bLeftTrigger: win.BYTE,
  bRightTrigger: win.BYTE,
  sThumbLX: win.SHORT,
  sThumbLY: win.SHORT,
  sThumbRX: win.SHORT,
  sThumbRY: win.SHORT,
}

XINPUT_VIBRATION :: struct {
  wLeftMotorSpeed : win.WORD,
  wRightMotorSpeed : win.WORD,
}

@(private="file")
ProcXInputGetState :: #type proc(dwUserIndex: win.DWORD, pState: ^XINPUT_STATE ) -> win.DWORD
@(private="file")
ProcXInputSetState :: #type proc(dwUserIndex: win.DWORD, pVibration: ^XINPUT_VIBRATION) -> win.DWORD

@(private="file")
XInputGetStateStub : ProcXInputGetState = proc(dwUserIndex: win.DWORD, pState: ^XINPUT_STATE ) -> win.DWORD { 
	return ERROR_DEVICE_NOT_CONNECTED
}
@(private="file")
XInputSetStateStub : ProcXInputSetState = proc(dwUserIndex: win.DWORD, pVibration: ^XINPUT_VIBRATION) -> win.DWORD { 
	return ERROR_DEVICE_NOT_CONNECTED
}


// XINPUT_KEYSTROKE :: struct {
//   VirtualKey: win.WORD,
//   Unicode: win.WCHAR,
//   Flags: win.WORD,
//   UserIndex: win.BYTE,
//   HidCode: win.BYTE,
// }

// XINPUT_CAPABILITIES :: struct {
//   Type : win.BYTE,
//   SubType : win.BYTE,
//   Flags : win.WORD,
//   Gamepad : XINPUT_GAMEPAD,
//   Vibration : XINPUT_VIBRATION,
// }

// XINPUT_BATTERY_INFORMATION :: struct {
//   BatteryType: win.BYTE,
//   BatteryLevel: win.BYTE,
// }

ERROR_DEVICE_NOT_CONNECTED :: 0x048F

XUSER_MAX_COUNT :: 4
XUSER_INDEX_ANY :: 0x000000FF

XINPUT_GAMEPAD_DPAD_UP        :: 0x0001
XINPUT_GAMEPAD_DPAD_DOWN      :: 0x0002
XINPUT_GAMEPAD_DPAD_LEFT      :: 0x0004
XINPUT_GAMEPAD_DPAD_RIGHT     :: 0x0008
XINPUT_GAMEPAD_START          :: 0x0010
XINPUT_GAMEPAD_BACK           :: 0x0020
XINPUT_GAMEPAD_LEFT_THUMB     :: 0x0040
XINPUT_GAMEPAD_RIGHT_THUMB    :: 0x0080
XINPUT_GAMEPAD_LEFT_SHOULDER  :: 0x0100
XINPUT_GAMEPAD_RIGHT_SHOULDER :: 0x0200
XINPUT_GAMEPAD_A              :: 0x1000
XINPUT_GAMEPAD_B              :: 0x2000
XINPUT_GAMEPAD_X              :: 0x4000
XINPUT_GAMEPAD_Y              :: 0x8000

XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE  :: 7849
XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE :: 8689
XINPUT_GAMEPAD_TRIGGER_THRESHOLD    :: 30


// XINPUT_KEYSTROKE_KEYDOWN :: 0x001 // The key was pressed.
// XINPUT_KEYSTROKE_KEYUP   :: 0x002 // The key was pressed.
// XINPUT_KEYSTROKE_REPEAT  :: 0x004 // The key was pressed.

// XINPUT_DEVSUBTYPE_UNKNOWN          :: 0x00  // 	Unknown. The controller type is unknown.
// XINPUT_DEVSUBTYPE_GAMEPAD          :: 0x01  // 	Gamepad controller. Includes Left and Right Sticks, Left and Right Triggers, Directional Pad, and all standard buttons (A, B, X, Y, START, BACK, LB, RB, LSB, RSB).
// XINPUT_DEVSUBTYPE_WHEEL            :: 0x02  // 	Racing wheel controller. Left Stick X reports the wheel rotation, Right Trigger is the acceleration pedal, and Left Trigger is the brake pedal. Includes Directional Pad and most standard buttons (A, B, X, Y, START, BACK, LB, RB). LSB and RSB are optional.
// XINPUT_DEVSUBTYPE_ARCADE_STICK     :: 0x03  // 	Arcade stick controller. Includes a Digital Stick that reports as a DPAD (up, down, left, right), and most standard buttons (A, B, X, Y, START, BACK). The Left and Right Triggers are implemented as digital buttons and report either 0 or 0xFF. LB, LSB, RB, and RSB are optional.
// XINPUT_DEVSUBTYPE_FLIGHT_STICK     :: 0x04  // 	Flight stick controller. Includes a pitch and roll stick that reports as the Left Stick, a POV Hat which reports as the Right Stick, a rudder (handle twist or rocker) that reports as Left Trigger, and a throttle control as the Right Trigger. Includes support for a primary weapon (A), secondary weapon (B), and other standard buttons (X, Y, START, BACK). LB, LSB, RB, and RSB are optional.
// XINPUT_DEVSUBTYPE_DANCE_PAD        :: 0x05  // 	Dance pad controller. Includes the Directional Pad and standard buttons (A, B, X, Y) on the pad, plus BACK and START.
// XINPUT_DEVSUBTYPE_GUITAR           :: 0x06  // 	Guitar controller. The strum bar maps to DPAD (up and down), and the frets are assigned to A (green), B (red), Y (yellow), X (blue), and LB (orange). Right Stick Y is associated with a vertical orientation sensor; Right Stick X is the whammy bar. Includes support for BACK, START, DPAD (left, right). Left Trigger (pickup selector), Right Trigger, RB, LSB (fret modifier), RSB are optional.
// XINPUT_DEVSUBTYPE_GUITAR_ALTERNATE :: 0x07  // 	Alternate guitar controller. Supports a larger range of movement for the vertical orientation sensor.
// XINPUT_DEVSUBTYPE_DRUM_KIT         :: 0x08  // 	Drum controller. The drum pads are assigned to buttons: A for green (Floor Tom), B for red (Snare Drum), X for blue (Low Tom), Y for yellow (High Tom), and LB for the pedal (Bass Drum). Includes Directional-Pad, BACK, and START. RB, LSB, and RSB are optional.
// XINPUT_DEVSUBTYPE_GUITAR_BASS      :: 0x0B  // 	Bass guitar controller. Identical to Guitar, with the distinct subtype to simplify setup.
// XINPUT_DEVSUBTYPE_ARCADE_PAD       :: 0x13  // 	Arcade pad controller. Includes Directional Pad and most standard buttons (A, B, X, Y, START, BACK, LB, RB). The Left and Right Triggers are implemented as digital buttons and report either 0 or 0xFF. Left Stick, Right Stick, LSB, and RSB are optional.

// XINPUT_FLAG_GAMEPAD :: 0x00000001 //	Limit query to devices of controller type.

// XINPUT_CAPS_VOICE_SUPPORTED :: 0x0004

// BATTERY_DEVTYPE_GAMEPAD   :: 0x00
// BATTERY_DEVTYPE_HEADSET   :: 0x01
// BATTERY_TYPE_DISCONNECTED :: 0x00
// BATTERY_TYPE_WIRED        :: 0x01
// BATTERY_TYPE_ALKALINE     :: 0x02
// BATTERY_TYPE_NIMH         :: 0x03
// BATTERY_TYPE_UNKNOWN      :: 0xFF

// BATTERY_LEVEL_EMPTY       :: 0x00
// BATTERY_LEVEL_LOW         :: 0x01
// BATTERY_LEVEL_MEDIUM      :: 0x02
// BATTERY_LEVEL_FULL        :: 0x03
