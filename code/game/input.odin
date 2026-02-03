package game

@(common) 
Input :: struct {
    delta_time:     f32,
    quit_requested: bool,
    
    controllers: [5] InputController,
        
    // @note(viktor): this is for debugging only
    mouse: struct {
        buttons: [Mouse_Button] InputButton,
        p:     v2,
        wheel: f32, // @todo(viktor): this seems to always be 0
    },
    
    shift_down, 
    alt_down, 
    control_down: b32,
}

@(common) 
InputButton :: struct {
    half_transition_count: u32,
    ended_down:            b32,
}

@(common) 
InputController :: struct {
    // @todo(viktor): allow outputing vibration
    is_connected: b32,
    is_analog:    b32,
    
    stick_average: v2,
    
    buttons: [Controller_Button] InputButton,
}

@(common) 
Controller_Button :: enum {
    stick_up,  stick_down,  stick_left,  stick_right, 
    button_up, button_down, button_left, button_right,
    dpad_up,   dpad_down,   dpad_left,   dpad_right,  
    
    start, back,
    shoulder_left, shoulder_right,
    thumb_left,    thumb_right,
}

Mouse_Button :: enum {
    left,
    right,
    middle,
    extra1,
    extra2,
}

was_pressed :: proc (button: InputButton) -> b32 {
    return button.half_transition_count > 1 || button.half_transition_count == 1 && button.ended_down
}

is_down :: proc (button: InputButton) -> b32 {
    return button.ended_down
}
