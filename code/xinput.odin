package main

import win "core:sys/windows"

// @todo(viktor): This whole process of making stubs and then trying to load a library and switching out the stubs with loaded function pointers is always the same. Can we use reflection or the metaprogram to generate this based on an API-struct?
xinput : XInputApi = xinput_stub

XInputApi :: struct {
    GetState: proc (dwUserIndex: win.DWORD, pState:     ^XINPUT_STATE)     -> win.DWORD,
    SetState: proc (dwUserIndex: win.DWORD, pVibration: ^XINPUT_VIBRATION) -> win.DWORD,
}

init_xInput :: proc () {
    assert(xinput.GetState == xinput_stub.GetState, "xInput has already been initialized")
    
    xinput14: cstring16 = "Xinput1_4.dll"
    xinput91: cstring16 = "XInput9_1_0.dll"
    xinput13: cstring16 = "xinput1_3.dll"
    
    xInput_lib := win.LoadLibraryW(xinput14)
    if xInput_lib == nil {
        print("Failed to load %, falling back to %\n", xinput14, xinput91)
        xInput_lib = win.LoadLibraryW(xinput91)
    }
    if xInput_lib == nil {
        print("Failed to load %, falling back to %\n", xinput91, xinput13)
        xInput_lib = win.LoadLibraryW(xinput13)
    }
    
    if xInput_lib != nil {
        xinput.GetState = auto_cast win.GetProcAddress(xInput_lib, "XInputGetState")
        xinput.SetState = auto_cast win.GetProcAddress(xInput_lib, "XInputSetState")
    } else {
        print("Failed to load %\n", xinput13)
        print("Failed to initialize XInput\n")
    }
}

////////////////////////////////////////////////

@(private="file") 
xinput_stub :: XInputApi {
    GetState = proc (dwUserIndex: win.DWORD, pState:     ^XINPUT_STATE)     -> win.DWORD { return ERROR_DEVICE_NOT_CONNECTED },
    SetState = proc (dwUserIndex: win.DWORD, pVibration: ^XINPUT_VIBRATION) -> win.DWORD { return ERROR_DEVICE_NOT_CONNECTED },
}

XINPUT_STATE  :: struct {
    dwPacketNumber: win.DWORD,
    Gamepad:        XINPUT_GAMEPAD,
}

XINPUT_GAMEPAD :: struct {
    wButtons:      win.WORD,
    bLeftTrigger:  win.BYTE,
    bRightTrigger: win.BYTE,
    sThumbLX:      win.SHORT,
    sThumbLY:      win.SHORT,
    sThumbRX:      win.SHORT,
    sThumbRY:      win.SHORT,
}

XINPUT_VIBRATION :: struct {
    wLeftMotorSpeed:  win.WORD,
    wRightMotorSpeed: win.WORD,
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