package ui

import "base:runtime"
import "core:fmt"
import "core:strings"
import "vendor:glfw"

Platform_Config :: struct {
	window: glfw.WindowHandle,
}

Platform_Context :: struct {
	window: glfw.WindowHandle,
}

platform_init :: proc(config: Platform_Config)
{
	s.pc.window = config.window
}

get_framebuffer_size :: proc() -> (width, height: u32)
{
	window := cast(glfw.WindowHandle)s.pc.window
	iw, ih := glfw.GetFramebufferSize(window)
	return u32(iw), u32(ih)
}

framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32)
{
	context = s.ctx
	backend_resize()
}

get_dpi :: proc() -> f32
{
	window := cast(glfw.WindowHandle)s.pc.window
	x, y := glfw.GetWindowContentScale(window)
	return x
}

update_caret :: proc(dt: f64)
{
	BLINK_TIME :: 500
	s.caret.timeSinceChange += dt
	if s.caret.timeSinceChange > BLINK_TIME {
		s.caret.visible = !s.caret.visible
		s.caret.timeSinceChange = 0
	}
}

char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune)
{
	context = runtime.default_context()
	if s.active_string == nil {
		return
	}
	bldr := strings.Builder{}
	strings.write_string(&bldr, s.active_string^)
	strings.write_rune(&bldr, codepoint)
	new_active_string := strings.to_string(bldr)
	delete(s.active_string^)
	s.active_string^ = new_active_string
}

get_window_size :: proc() -> (i32, i32)
{
	window := cast(glfw.WindowHandle)s.pc.window
	return glfw.GetWindowSize(window)
}


pointer_callback :: proc() -> (f32, f32, bool)
{
	window := cast(glfw.WindowHandle)s.pc.window
	width, height := glfw.GetWindowSize(window)
	scaling_x, scaling_y := s.config.width / f32(width), s.config.height / f32(height)
	x, y := glfw.GetCursorPos(window)
	cursor_pos := [2]f32{f32(x), f32(y)} * [2]f32{scaling_x, scaling_y} //- {f32(width), f32(height)}
	down := glfw.GetMouseButton(window, glfw.MOUSE_BUTTON_1) == glfw.PRESS
	return f32(cursor_pos.x), f32(cursor_pos.y), down
}

