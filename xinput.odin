package main

import win "core:sys/windows"

XInputGetState : ProcXInputGetState = XInputGetStateStub
XInputSetState : ProcXInputSetState = XInputSetStateStub

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



// ---------------------- Internal stuff



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