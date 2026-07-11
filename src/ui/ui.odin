package ui

import clay "clay-odin"

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:strings"
import fs "vendor:fontstash"

FONT_ATLAS_SIZE :: 1024

UI_State :: struct {
	ctx:               runtime.Context,
	width, height:     f32,
	pc:                Platform_Context, // this is the platform context which changes per implementation
	config:            UI_Config, // Defines where the ui is drawn
	font_ctx:          fs.FontContext,
	update_font_atlas: bool,
	free:              bool, // Indicates if this is a freestanding ui or part of another window
	click:             Click_State,
	cursor_callback:   proc(_: rawptr) -> (f32, f32, bool),
	user_ptr:          rawptr,
	initialized:       bool,
	frame:             proc(_: f32),
	active_string:     ^string,
	caret:             struct {
		timeSinceChange: f64,
		visible:         bool,
	},
	setup:             proc(_: rawptr),
	aa_enabled:        bool,
}

Backend_Type :: enum {
	METAL,
	WGPU,
	VULKAN,
}

Click_State :: enum {
	UP,
	DOWN,
	PRESSED,
}

UI_Config :: struct {
	x, y:   f32,
	width:  f32,
	height: f32,
}

Texture :: struct {
	x, y, width, height: u32,
	idx:                 u32, // Integer into the texture array
}
Scissor_Section :: struct {
	type:   enum {
		START,
		END,
	},
	offset: u32,
	bounds: [4]f32,
}

s: UI_State

// The user needs to set up their own render and window, and then pass those in the config
init :: proc(
	platform_config: Platform_Config,
	config: UI_Config, // specify the dimensions and position of the ui
	user_ptr: rawptr = nil,
	frame: proc(_: f32), // procedure to run each frame to draw the UI. Done as a callback to allow wgpu
	setup: proc(_: rawptr) = nil,
)
{
	s.ctx = context
	min_memory_size: c.size_t = c.size_t(clay.MinMemorySize())
	memory := make([^]u8, min_memory_size)
	arena: clay.Arena = clay.CreateArenaWithCapacityAndMemory(min_memory_size, memory)
	clay.Initialize(
		arena = arena,
		layoutDimensions = {config.width, config.height},
		errorHandler = {handler = error_handler, userData = nil},
	)
	fs.Init(&s.font_ctx, FONT_ATLAS_SIZE, FONT_ATLAS_SIZE, .BOTTOMLEFT)
	load_font("fira", #load("FiraCode-SemiBold.ttf"))

	clay.SetMeasureTextFunction(measure_text, nil)
	s.user_ptr = user_ptr
	s.config = config
	s.frame = frame
	s.setup = setup
	s.aa_enabled = true
	platform_init(platform_config)
	backend_init() // initialize whichever backend we are using
	s.font_ctx.callbackUpdate = must_update_font_atlas
}

must_update_font_atlas :: proc(data: rawptr, quad: [4]f32, data2: rawptr)
{
	s.update_font_atlas = true
}

load_font :: proc(name: string, data: []byte) -> int
{
	font: int = fs.AddFontMem(&s.font_ctx, name, data, freeLoadedData = false)
	return font
}

error_handler :: proc "c" (error_data: clay.ErrorData)
{
	context = runtime.default_context()
	errMsg: [^]c.char = error_data.errorText.chars
	errString: string = strings.clone_from_cstring(cstring(errMsg))
	fmt.println(errString)
	panic(errString)
}

begin_layout :: proc()
{
	x, y: f32
	clicked: bool
	x, y, clicked = pointer_callback()
	clay.SetPointerState({x, y}, clicked)
	// only register a PRESSED state on the first frame
	if !clicked {
		s.click = .UP
	} else if s.click == .PRESSED {
		s.click = .DOWN
	} else if s.click == .UP {
		s.click = .PRESSED
	}
	clay.SetLayoutDimensions({s.config.width / 2, s.config.height / 2})
	clay.BeginLayout()
}

end_layout :: proc(dt: f32) -> clay.ClayArray(clay.RenderCommand)
{
	return clay.EndLayout(c.float(dt))
}

set_debug_mode_enabled :: proc(value: bool)
{
	clay.SetDebugModeEnabled(value)
}

// FIXME This is probably faster, but line height is wrong
measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	userData: rawptr,
) -> clay.Dimensions
{

	context = runtime.default_context()
	font := fs.__getFont(&s.font_ctx, int(config.fontId))

	max_text_width: f32 = 0.0
	line_text_width: f32 = 0.0

	lh: f32 = config.lineHeight != 0 ? f32(config.lineHeight) : f32(config.fontSize) * 0.8
	height: f32 = lh

	prev_glyph_idx: fs.Glyph_Index = -1
	text_str: string = string(text.chars[:text.length])
	for ru in text_str {
		if ru == '\n' {
			max_text_width = max(max_text_width, line_text_width)
			line_text_width = 0
			height += lh
			continue
		}
		if glyph, glyph_ok := fs.__getGlyph(&s.font_ctx, font, ru, i16(config.fontSize), 0);
		   glyph_ok {
			if prev_glyph_idx != -1 {
				adv := f32(fs.__getGlyphKernAdvance(font, prev_glyph_idx, glyph.index))
				line_text_width += f32(int(adv + f32(config.letterSpacing) + 0.5))
			}
			line_text_width += f32(glyph.xadvance)
			prev_glyph_idx = glyph.index
		}

	}
	// 1 letter spacing is subtracted off the width to account for the extra space from the last character
	max_text_width = max(max_text_width, line_text_width)
	return clay.Dimensions{max_text_width, height}
}


measure_text_fs :: proc(text: string, config: clay.TextElementConfig, userData: rawptr) -> [2]f32
{
	state := fs.__getState(&s.font_ctx)
	state^ = {
		size    = f32(config.fontSize), // What does this do exactly?
		blur    = 0,
		spacing = f32(config.letterSpacing),
		font    = int(config.fontId),
		ah      = fs.AlignHorizontal(.LEFT),
		av      = fs.AlignVertical(.BOTTOM),
	}
	bounds: [4]f32
	fs.TextBounds(&s.font_ctx, text = text, bounds = &bounds) // I think this is quite slow
	return [2]f32{bounds[2] - bounds[0], bounds[3] - bounds[1]}
}

clicked :: #force_inline proc() -> bool
{
	if s.click == .PRESSED {
		s.active_string = nil
	}
	return clay.Hovered() && s.click == .PRESSED
}

// NOTE GENERAL RENDERING SECTION
push_rectangle :: #force_inline proc(
	pos: ^[dynamic][2]f32,
	col: ^[dynamic][4]f32,
	uv: ^[dynamic][2]f32,
	ids: ^[dynamic]i32,
	box: clay.BoundingBox,
	color: clay.Color,
)
{
	color := color / 255
	// TODO indices would be nice I guess
	append_elems(
		pos,
		[2]f32{box.x, box.y}, // bottom left
		[2]f32{box.x + box.width, box.y}, // bottom right
		[2]f32{box.x, box.y + box.height}, // top left
		[2]f32{box.x + box.width, box.y + box.height}, // top right
		[2]f32{box.x, box.y + box.height}, // top left
		[2]f32{box.x + box.width, box.y}, // bottom right
	)
	append_elems(col, color, color, color, color, color, color)
	white_area := [2]f32{0.5 / s.config.width, 0.5 / s.config.height}

	append_elems(uv, white_area, white_area, white_area, white_area, white_area, white_area)
	// append_elems(
	// 	uv,
	// 	[2]f32{0, 0},
	// 	[2]f32{1, 0},
	// 	[2]f32{0, 1},
	// 	[2]f32{1, 1},
	// 	[2]f32{0, 1},
	// 	[2]f32{1, 0},
	// )
	append_elems(ids, 0, 0, 0, 0, 0, 0)
}

/*
This function draws rounded boxes. I think this is a design mistake, and eventually the design should shift so that
we have the id pipeline specify the corner radius. -2 = text. -1 = image. 0 = regular rectangle. > 0 = corner radius.
However, this approach is a bit problematic because it doesn't allow uneven corner radiuses. This is probably a decent tradeoff,
and I can abstract that functionality of clay away to enable it.
*/
// TODO Is this actually possible with an SDF
push_rectangle_rounded :: proc(
	pos: ^[dynamic][2]f32,
	col: ^[dynamic][4]f32,
	uv: ^[dynamic][2]f32,
	ids: ^[dynamic]i32,
	box: clay.BoundingBox,
	color: clay.Color,
	corners: clay.CornerRadius,
)
{
	color := color / 255
	// bottom middle
	append_elems(
		pos,
		[2]f32{box.x + corners.bottomLeft, box.y}, // bottom left
		[2]f32{box.x + box.width - corners.bottomRight, box.y}, // bottom right
		[2]f32{box.x + corners.bottomLeft, box.y + corners.bottomLeft}, // top left
		[2]f32{box.x + box.width - corners.bottomRight, box.y + corners.bottomRight}, // top right
		[2]f32{box.x + corners.bottomLeft, box.y + corners.bottomLeft}, // top left
		[2]f32{box.x + box.width - corners.bottomRight, box.y}, // bottom right
	)
	// top middle
	append_elems(
		pos,
		[2]f32{box.x + corners.topLeft, box.y + box.height - corners.topLeft}, // bottom left
		[2]f32{box.x + box.width - corners.topRight, box.y + box.height - corners.topRight}, // bottom right
		[2]f32{box.x + corners.topLeft, box.y + box.height}, // top left
		[2]f32{box.x + box.width - corners.topRight, box.y + box.height}, // top right
		[2]f32{box.x + corners.topLeft, box.y + box.height}, // top left
		[2]f32{box.x + box.width - corners.topRight, box.y + box.height - corners.topRight}, // bottom right
	)

	// left middle
	append_elems(
		pos,
		[2]f32{box.x, box.y + corners.bottomLeft}, // bottom left
		[2]f32{box.x + corners.bottomLeft, box.y + corners.bottomLeft}, // bottom right
		[2]f32{box.x, box.y + box.height - corners.topLeft}, // top left
		[2]f32{box.x + corners.topLeft, box.y + box.height - corners.topLeft}, // top right
		[2]f32{box.x, box.y + box.height - corners.topLeft}, // top left
		[2]f32{box.x + corners.bottomLeft, box.y + corners.bottomLeft}, // bottom right
	)

	// right middle
	append_elems(
		pos,
		[2]f32{box.x + box.width - corners.bottomRight, box.y + corners.bottomRight}, // bottom left
		[2]f32{box.x + box.width, box.y + corners.bottomRight}, // bottom right
		[2]f32{box.x + box.width - corners.topRight, box.y + box.height - corners.topRight}, // top left
		[2]f32{box.x + box.width, box.y + box.height - corners.topRight}, // top right
		[2]f32{box.x + box.width - corners.topRight, box.y + box.height - corners.topRight}, // top left
		[2]f32{box.x + box.width, box.y + corners.bottomRight}, // bottom right
	)

	// center
	append_elems(
		pos,
		[2]f32{box.x + corners.bottomLeft, box.y + corners.bottomLeft}, // bottom left
		[2]f32{box.x + box.width - corners.bottomRight, box.y + corners.bottomRight}, // bottom right
		[2]f32{box.x + corners.topLeft, box.y + box.height - corners.topLeft}, // top left
		[2]f32{box.x + box.width - corners.topRight, box.y + box.height - corners.topRight}, // top right
		[2]f32{box.x + corners.topLeft, box.y + box.height - corners.topLeft}, // top left
		[2]f32{box.x + box.width - corners.bottomRight, box.y + corners.bottomRight}, // bottom right
	)

	// bottom-left
	fan: [15][2]f32 = FAN_BOTTOM_LEFT * corners.bottomLeft
	for i in 0 ..< 15 {
		fan[i] += [2]f32{box.x + corners.bottomLeft, box.y + corners.bottomLeft}
	}
	append(pos, ..fan[:])
	// bottom-right
	fan = FAN_BOTTOM_RIGHT * corners.bottomRight
	for i in 0 ..< 15 {
		fan[i] += [2]f32{box.x + box.width - corners.bottomRight, box.y + corners.bottomRight}
	}
	append(pos, ..fan[:])
	// top-left
	fan = FAN_TOP_LEFT * corners.topLeft
	for i in 0 ..< 15 {
		fan[i] += [2]f32{box.x + corners.topLeft, box.y + box.height - corners.topLeft}
	}
	append(pos, ..fan[:])
	// top-right
	fan = FAN_TOP_RIGHT * corners.topRight
	for i in 0 ..< 15 {
		fan[i] += [2]f32 {
			box.x + box.width - corners.topRight,
			box.y + box.height - corners.topRight,
		}
	}
	append(pos, ..fan[:])
	white_area := [2]f32{0.5 / s.config.width, 0.5 / s.config.height}
	for i in 0 ..< (6 * 5 + 4 * 15) {
		append(col, color)
		append(ids, 0)
		append(uv, white_area)
	}
}

push_border :: #force_inline proc(
	pos: ^[dynamic][2]f32,
	col: ^[dynamic][4]f32,
	uv: ^[dynamic][2]f32,
	ids: ^[dynamic]i32,
	box: clay.BoundingBox,
	color: clay.Color,
	width: clay.BorderWidth,
)
{
	color := color / 255
	bounds := clay.BoundingBox {
		x      = box.x,
		y      = box.y,
		width  = box.width,
		height = f32(width.top),
	}
	push_rectangle(pos, col, uv, ids, bounds, color)
	bounds = clay.BoundingBox {
		x      = box.x,
		y      = box.y + box.height - f32(width.bottom),
		width  = box.width,
		height = f32(width.bottom),
	}
	push_rectangle(pos, col, uv, ids, bounds, color)
	bounds = clay.BoundingBox {
		x      = box.x,
		y      = box.y,
		width  = f32(width.left),
		height = box.height,
	}
	push_rectangle(pos, col, uv, ids, bounds, color)
	bounds = clay.BoundingBox {
		x      = box.x + box.width - f32(width.right),
		y      = box.y,
		width  = f32(width.right),
		height = box.height,
	}
	push_rectangle(pos, col, uv, ids, bounds, color)
}

push_border_rounded :: proc(
	pos: ^[dynamic][2]f32,
	col: ^[dynamic][4]f32,
	uv: ^[dynamic][2]f32,
	ids: ^[dynamic]i32,
	box: clay.BoundingBox,
	color: clay.Color,
	corners: clay.CornerRadius,
	width: clay.BorderWidth,
)
{
	//sides
	bounds := clay.BoundingBox {
		x      = box.x + corners.topLeft,
		y      = box.y,
		width  = box.width - corners.topLeft - corners.topRight,
		height = f32(width.top),
	}
	push_rectangle(pos, col, uv, ids, bounds, color)
	bounds = clay.BoundingBox {
		x      = box.x + corners.bottomLeft,
		y      = box.y + box.height - f32(width.bottom),
		width  = box.width - corners.bottomLeft - corners.bottomRight,
		height = f32(width.bottom),
	}
	push_rectangle(pos, col, uv, ids, bounds, color)
	bounds = clay.BoundingBox {
		x      = box.x,
		y      = box.y + corners.bottomLeft,
		width  = f32(width.left),
		height = box.height - corners.bottomLeft - corners.topLeft,
	}
	push_rectangle(pos, col, uv, ids, bounds, color)
	bounds = clay.BoundingBox {
		x      = box.x + box.width - f32(f32(width.right)),
		y      = box.y + corners.topRight,
		width  = f32(f32(width.right)),
		height = box.height - corners.topRight - corners.bottomRight,
	}
	push_rectangle(pos, col, uv, ids, bounds, color)

	// corners
	push_corner_arc(
		pos,
		f32(f32(width.right)),
		f32(width.top),
		corners.topRight,
		[2]f32{box.x + box.width - corners.topRight, box.y + corners.topRight},
		{1, -1},
	)
	push_corner_arc(
		pos,
		f32(width.left),
		f32(width.top),
		corners.topLeft,
		[2]f32{box.x + corners.topLeft, box.y + corners.topLeft},
		{-1, -1},
	)
	push_corner_arc(
		pos,
		f32(f32(width.right)),
		f32(width.bottom),
		corners.bottomRight,
		[2]f32{box.x + box.width - corners.bottomRight, box.y + box.height - corners.bottomRight},
		{1, 1},
	)
	push_corner_arc(
		pos,
		f32(width.left),
		f32(width.bottom),
		corners.bottomLeft,
		[2]f32{box.x + corners.bottomLeft, box.y + box.height - corners.bottomLeft},
		{-1, 1},
	)
	// TODO better way to do this?
	white_area := [2]f32{0.5 / s.config.width, 0.5 / s.config.height}
	for i in 0 ..< (4 * 5 * 6) {
		append(col, color / 255)
		append(ids, 0)
		append(uv, white_area)
	}


}
// Hard coded corner segment
cos := [6]f32{1, 0.951, 0.809, 0.588, 0.309, 0} // 18 degree jumps
sin := [6]f32{0, 0.309, 0.588, 0.809, 0.951, 1} // 18 degree jumps

push_corner_arc :: proc(
	pos: ^[dynamic][2]f32,
	width_h, width_v, radius: f32,
	xy: [2]f32,
	sign: [2]f32,
)
{
	for i in 0 ..< (len(cos) - 1) {
		// outer_radius - weighted average width
		inner_radius1 :=
			radius - ((f32(len(cos) - i) * width_h + f32(i) * width_v) / f32(len(cos)))
		inner_radius2 :=
			radius - ((f32(len(cos) - i - 1) * width_h + f32(i + 1) * width_v) / f32(len(cos)))

		one := [2]f32{radius * cos[i], radius * sin[i]} * sign + xy
		two := [2]f32{radius * cos[i + 1], radius * sin[i + 1]} * sign + xy
		three := [2]f32{inner_radius2 * cos[i + 1], inner_radius2 * sin[i + 1]} * sign + xy
		four := [2]f32{inner_radius1 * cos[i], inner_radius1 * sin[i]} * sign + xy
		append_elems(pos, one, two, three, three, four, one)
	}
}

@(private = "package")
FAN_TOP_LEFT :: [?][2]f32 {
	{0, 0},
	{0, 1},
	{-0.309, 0.951},
	{0, 0},
	{-0.309, 0.951},
	{-0.588, 0.809},
	{0, 0},
	{-0.588, 0.809},
	{-0.809, 0.588},
	{0, 0},
	{-0.809, 0.588},
	{-0.951, 0.309},
	{0, 0},
	{-0.951, 0.309},
	{-1, 0},
}
@(private = "package")
FAN_TOP_RIGHT :: [?][2]f32 {
	{0, 0},
	{0, 1},
	{0.309, 0.951},
	{0, 0},
	{0.309, 0.951},
	{0.588, 0.809},
	{0, 0},
	{0.588, 0.809},
	{0.809, 0.588},
	{0, 0},
	{0.809, 0.588},
	{0.951, 0.309},
	{0, 0},
	{0.951, 0.309},
	{1, 0},
}
@(private = "package")
FAN_BOTTOM_LEFT :: [?][2]f32 {
	{0, 0},
	{0, -1},
	{-0.309, -0.951},
	{0, 0},
	{-0.309, -0.951},
	{-0.588, -0.809},
	{0, 0},
	{-0.588, -0.809},
	{-0.809, -0.588},
	{0, 0},
	{-0.809, -0.588},
	{-0.951, -0.309},
	{0, 0},
	{-0.951, -0.309},
	{-1, 0},
}

@(private = "package")
FAN_BOTTOM_RIGHT :: [?][2]f32 {
	{0, 0},
	{0, -1},
	{0.309, -0.951},
	{0, 0},
	{0.309, -0.951},
	{0.588, -0.809},
	{0, 0},
	{0.588, -0.809},
	{0.809, -0.588},
	{0, 0},
	{0.809, -0.588},
	{0.951, -0.309},
	{0, 0},
	{0.951, -0.309},
	{1, 0},
}


push_text :: proc(
	text: string,
	x, y: f32,
	color: clay.Color,
	font_id: u16,
	font_size: f32,
	line_height: f32,
	spacing: f32,
	pos: ^[dynamic][2]f32,
	col: ^[dynamic][4]f32,
	uv: ^[dynamic][2]f32,
	ids: ^[dynamic]i32,
)
{
	color := color / 255
	state := fs.__getState(&s.font_ctx)
	spacing := math.floor(spacing + 0.5)
	state^ = {
		size    = font_size, // What does this do exactly?
		blur    = 0,
		spacing = spacing,
		font    = 0, //int(font_id),
		ah      = fs.AlignHorizontal(.LEFT),
		av      = fs.AlignVertical(.BASELINE),
	}
	i := 0
	for iter := fs.TextIterInit(&s.font_ctx, x, y, text); true; {
		quad: fs.Quad
		sz := iter.isize

		x := math.floor(x + 0.5)
		y := math.floor(y + 0.5)
		fs.TextIterNext(&s.font_ctx, &iter, &quad) or_break

		y0 := 2 * y - quad.y0 + f32(sz) / 20
		y1 := 2 * y - quad.y1 + f32(sz) / 20
		x0 := quad.x0 //2 * x - quad.x0 + 400
		x1 := quad.x1 //2 * x - quad.x1 + 400

		i += 1
		append_elems(
			pos,
			[2]f32{x0, y0}, // bottom left
			[2]f32{x1, y0}, // bottom right
			[2]f32{x0, y1}, // top left
			[2]f32{x1, y1}, // top right
			[2]f32{x0, y1}, // top left
			[2]f32{x1, y0}, // bottom right
		)
		append_elems(
			uv,
			[2]f32{quad.s0, quad.t0}, // bottom left
			[2]f32{quad.s1, quad.t0}, // bottom right
			[2]f32{quad.s0, quad.t1}, // top left
			[2]f32{quad.s1, quad.t1}, // top right
			[2]f32{quad.s0, quad.t1}, // top left
			[2]f32{quad.s1, quad.t0}, // bottom right
		)
		append_elems(col, color, color, color, color, color, color)
		append_elems(ids, 0, 0, 0, 0, 0, 0)
	}
}

// TODO rounded images
push_image :: proc(
	box: clay.BoundingBox,
	texture: Texture,
	pos: ^[dynamic][2]f32,
	uv: ^[dynamic][2]f32,
	col: ^[dynamic][4]f32,
	ids: ^[dynamic]i32,
)
{
	// TODO indices would be nice I guess
	append_elems(
		pos,
		[2]f32{box.x, box.y}, // bottom left
		[2]f32{box.x + box.width, box.y}, // bottom right
		[2]f32{box.x, box.y + box.height}, // top left
		[2]f32{box.x + box.width, box.y + box.height}, // top right
		[2]f32{box.x, box.y + box.height}, // top left
		[2]f32{box.x + box.width, box.y}, // bottom right
	)
	color := [4]f32{0, 0, 0, 1}
	append_elems(col, color, color, color, color, color, color)
	x1, x2, y1, y2 :=
		f32(texture.x),
		f32(texture.x + texture.width),
		f32(texture.y),
		f32(texture.y + texture.height)
	append_elems(
		uv,
		[2]f32{x1, y1}, // bottom left
		[2]f32{x2, y1}, // bottom right
		[2]f32{x1, y2}, // top left
		[2]f32{x2, y2}, // top right
		[2]f32{x1, y2}, // top left
		[2]f32{x2, y1}, // bottom right)
	)
	append_elems(
		ids,
		i32(texture.idx + 1),
		i32(texture.idx + 1),
		i32(texture.idx + 1),
		i32(texture.idx + 1),
		i32(texture.idx + 1),
		i32(texture.idx + 1),
	)
}

render_ui :: proc(commands: ^clay.ClayArray(clay.RenderCommand), args: Submit_Args)
{
	if commands.length == 0 {return}

	context.allocator = context.temp_allocator
	pos := make([dynamic][2]f32)
	col := make([dynamic][4]f32)
	uv := make([dynamic][2]f32)
	ids := make([dynamic]i32)
	defer {delete(pos); delete(col); delete(uv); delete(ids)}

	offset: u32 = 0
	scissors := make([dynamic]Scissor_Section, 5)
	for i in 0 ..< commands.length {
		command: ^clay.RenderCommand = clay.RenderCommandArray_Get(commands, i)
		bounding_box: clay.BoundingBox = shift_bounding_box(
			command.boundingBox,
			s.config.x,
			s.config.y,
		)
		#partial switch command.commandType {
		case .Rectangle:
			{
				render_data: clay.RectangleRenderData = command.renderData.rectangle
				if render_data.cornerRadius.topLeft > 0 ||
				   render_data.cornerRadius.topRight > 0 ||
				   render_data.cornerRadius.bottomLeft > 0 ||
				   render_data.cornerRadius.bottomRight > 0 {
					push_rectangle_rounded(
						&pos,
						&col,
						&uv,
						&ids,
						bounding_box,
						render_data.backgroundColor,
						render_data.cornerRadius,
					)
				} else {
					push_rectangle(
						&pos,
						&col,
						&uv,
						&ids,
						bounding_box,
						render_data.backgroundColor,
					)
				}

			}
		case .Border:
			{
				render_data := command.renderData.border
				if render_data.cornerRadius.topLeft > 0 ||
				   render_data.cornerRadius.topRight > 0 ||
				   render_data.cornerRadius.bottomLeft > 0 ||
				   render_data.cornerRadius.bottomRight > 0 {
					push_border_rounded(
						&pos,
						&col,
						&uv,
						&ids,
						bounding_box,
						render_data.color,
						render_data.cornerRadius,
						render_data.width,
					)
				} else {
					push_border(
						&pos,
						&col,
						&uv,
						&ids,
						bounding_box,
						render_data.color,
						render_data.width,
					)
				}
			}
		case .Text:
			{
				render_data: clay.TextRenderData = command.renderData.text
				stringContents: clay.StringSlice = render_data.stringContents
				text: string = string(stringContents.chars[:stringContents.length])
				push_text(
					text = text,
					x = bounding_box.x,
					y = bounding_box.y,
					color = render_data.textColor,
					font_id = render_data.fontId,
					font_size = f32(render_data.fontSize),
					line_height = f32(render_data.lineHeight),
					spacing = f32(render_data.letterSpacing),
					pos = &pos,
					col = &col,
					uv = &uv,
					ids = &ids,
				)
			}
		case .ScissorStart:
			{
				offset = u32(len(pos))
				bounds := [4]f32 {
					bounding_box.x,
					bounding_box.y,
					bounding_box.width,
					bounding_box.height,
				}
				append(&scissors, Scissor_Section{type = .START, bounds = bounds, offset = offset})
			}
		case .ScissorEnd:
			{
				offset = u32(len(pos))
				append(&scissors, Scissor_Section{type = .END, offset = offset})
			}
		case .Image:
			{
				push_image(
					bounding_box,
					((^Texture)(command.renderData.image.imageData))^,
					pos = &pos,
					col = &col,
					uv = &uv,
					ids = &ids,
				)
			}
		}
	}
	backend_render(pos, col, uv, ids, scissors, args)
}

shift_bounding_box :: proc(bounding_box: clay.BoundingBox, x, y: f32) -> clay.BoundingBox
{
	return clay.BoundingBox {
		x = bounding_box.x,
		y = bounding_box.y,
		width = bounding_box.width,
		height = bounding_box.height,
	}
}

get_scroll_offset :: proc() -> [2]f32
{
	return clay.GetScrollOffset()
}

