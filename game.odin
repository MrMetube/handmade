package main

// timing, controller/keyboard input, bitmap buffer to use, sound buffer to use
game_update_and_render :: proc(buffer: GameOffscreenBuffer, xOffset, yOffset: i32) {
	render_weird_gradient(buffer, xOffset, yOffset)
}


GameOffscreenBuffer :: struct {
	memory : rawptr, // TODO should this just be [^]struct{bb, gg, rr, xx} ?
	width  : i32,
	height : i32,
}

render_weird_gradient :: proc(buffer: GameOffscreenBuffer , xOffset, yOffset: i32) {
	Color :: struct {
		b, g, r, pad: u8
	}

	bytes := cast([^]u8) buffer.memory
	row_index: i32 = 0

	for y in 0..<buffer.height {
		for x in 0..<buffer.width {
			pixel := cast(^Color) &bytes[row_index]
			pixel.b = u8(x + xOffset)
			pixel.g = u8(y + yOffset)
			row_index += size_of(Color)
		}
	}
}