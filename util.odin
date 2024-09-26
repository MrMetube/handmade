package main

swap :: proc(a, b: ^$T) {
	b^, a^ = a^, b^
}