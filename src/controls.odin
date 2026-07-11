package marching2d

import "core:fmt"
import "core:strconv"
import "core:strings"
import "gpu"
import "ui"
import clay "ui/clay-odin"
import vk "vendor:vulkan"

COLOR_LIGHT :: clay.Color{244, 235, 230, 255}
COLOR_LIGHT_HOVER :: clay.Color{224, 215, 210, 255}
COLOR_DARK_HOVER :: clay.Color{124, 115, 110, 100}
BACKGROUND_CLEAR :: clay.Color{0, 0, 0, 0}
draw_controls :: proc(dt: f32, cmd: vk.CommandBuffer)
{
	ui.begin_layout()
	// Start

	if clay.UI(clay.ID("OuterContainer"))(
	{
		layout = {
			childGap = 0,
			layoutDirection = .TopToBottom,
			sizing = {clay.SizingGrow(), clay.SizingGrow()},
		},
		backgroundColor = BACKGROUND_CLEAR,
	},
	) {

		radius()
		gravity()
		pressure()
		near_pressure()
		viscoscity()

	}


	// End
	commands := ui.end_layout(dt) // memory for this is owned by clay
	ui.render_ui(&commands, ui.Submit_Args{cmd, gpu.rs.imm_command_buffer, &gpu.rs.imm_fence})
}

radius :: proc()
{

	if clay.UI(clay.ID("Radius"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingFit(), clay.SizingFit()}},
		backgroundColor = BACKGROUND_CLEAR,
	},
	) {
		if clay.UI(clay.ID("RadiusControl"))(
		{
			layout = {layoutDirection = .LeftToRight, padding = {3, 3, 3, 3}},
			backgroundColor = BACKGROUND_CLEAR,
			cornerRadius = clay.CornerRadiusAll(5),
		},
		) {
			text_box("Radius")
			if button("+") {
				sim.field_radius += 10
			}
			if button("-") {
				sim.field_radius -= 10
			}
			@(static) buf: [16]u8
			str: string = strconv.write_float(buf[:], f64(sim.field_radius), 'f', 1, 32)
			text_box(str)
		}
	}
}
gravity :: proc()
{

	if clay.UI(clay.ID("Gravity"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingFit(), clay.SizingFit()}},
		backgroundColor = BACKGROUND_CLEAR,
	},
	) {
		if clay.UI(clay.ID("GravityControl"))(
		{
			layout = {layoutDirection = .LeftToRight, padding = {3, 3, 3, 3}},
			backgroundColor = BACKGROUND_CLEAR,
			cornerRadius = clay.CornerRadiusAll(5),
		},
		) {
			text_box("Gravity")
			if button("+") {
				GRAVITY += 50
			}
			if button("-") {
				GRAVITY -= 50
			}
			@(static) gravity_buf: [16]u8
			gravity_str: string = strconv.write_float(gravity_buf[:], f64(GRAVITY), 'f', 0, 32)
			text_box(gravity_str)
		}
	}
}

pressure :: proc()
{

	if clay.UI(clay.ID("Pressure"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingFit(), clay.SizingFit()}},
		backgroundColor = BACKGROUND_CLEAR,
	},
	) {
		if clay.UI(clay.ID("PressureControl"))(
		{
			layout = {layoutDirection = .LeftToRight, padding = {3, 3, 3, 3}},
			backgroundColor = BACKGROUND_CLEAR,
			cornerRadius = clay.CornerRadiusAll(5),
		},
		) {
			text_box("Pressure Mult")
			if button("+") {
				PRESSURE_MULTIPLER += 100
			}
			if button("-") {
				PRESSURE_MULTIPLER -= 100
			}
			@(static) buf: [16]u8
			str: string = strconv.write_float(buf[:], f64(PRESSURE_MULTIPLER), 'f', 0, 32)
			text_box(str)
		}
	}
}
near_pressure :: proc()
{

	if clay.UI(clay.ID("NearPressure"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingFit(), clay.SizingFit()}},
		backgroundColor = BACKGROUND_CLEAR,
	},
	) {
		if clay.UI(clay.ID("NearPressureControl"))(
		{
			layout = {layoutDirection = .LeftToRight, padding = {3, 3, 3, 3}},
			backgroundColor = BACKGROUND_CLEAR,
			cornerRadius = clay.CornerRadiusAll(5),
		},
		) {
			text_box("Near Pressure Mult")
			if button("+") {
				NEAR_PRESSURE_MULTIPLIER += 100
			}
			if button("-") {
				NEAR_PRESSURE_MULTIPLIER -= 100
			}
			@(static) buf: [16]u8
			str: string = strconv.write_float(buf[:], f64(NEAR_PRESSURE_MULTIPLIER), 'f', 0, 64)
			text_box(str)
		}
	}
}
viscoscity :: proc()
{

	if clay.UI(clay.ID("Viscoscity"))(
	{
		layout = {layoutDirection = .TopToBottom, sizing = {clay.SizingFit(), clay.SizingFit()}},
		backgroundColor = BACKGROUND_CLEAR,
	},
	) {
		if clay.UI(clay.ID("ViscoscityControl"))(
		{
			layout = {layoutDirection = .LeftToRight, padding = {3, 3, 3, 3}},
			backgroundColor = BACKGROUND_CLEAR,
			cornerRadius = clay.CornerRadiusAll(5),
		},
		) {
			text_box("Viscoscity")
			if button("+") {
				VISCOSCITY_STRENGTH += 10
			}
			if button("-") {
				VISCOSCITY_STRENGTH -= 10
			}
			@(static) buf: [16]u8
			str: string = strconv.write_float(buf[:], f64(VISCOSCITY_STRENGTH), 'f', 1, 32)
			text_box(str)
		}
	}
}
COLOR_WHITE: clay.Color = {231, 226, 205, 255}

text_box :: proc(text: string, width: f32 = 0, height: f32 = 0)
{

	if clay.UI()(
	{
		layout = {padding = {5, 5, 5, 5}},
		backgroundColor = BACKGROUND_CLEAR,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {width = clay.BorderAll(1), color = COLOR_WHITE},
	},
	) {
		clay.TextDynamic(text, {fontId = 0, fontSize = 12, textColor = COLOR_WHITE})
	}
}

button :: proc(text: string, width: f32 = 0, height: f32 = 0) -> bool
{
	clicked: bool = false
	if clay.UI()(
	{
		layout = {padding = {5, 5, 5, 5}},
		backgroundColor = BACKGROUND_CLEAR,
		cornerRadius = clay.CornerRadiusAll(5),
		border = {width = clay.BorderAll(1), color = COLOR_WHITE},
	},
	) {
		if clay.Hovered() && sim.mouse_left == .CLICK {
			clicked = true
		}
		if text != "" {
			clay.Text(text, {fontId = 0, fontSize = 12, textColor = COLOR_WHITE})
		}
	}
	return clicked
}

