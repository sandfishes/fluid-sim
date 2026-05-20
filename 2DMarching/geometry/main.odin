package geometry
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

EPSILON: f32 = 0.0001
/* generates the geometry.odin config file */
main :: proc()
{
	bldr: strings.Builder
	strings.builder_init(&bldr)
	// defer strings.builder_destroy(&bldr)

	strings.write_string(&bldr, "package geometry\n\n")
	strings.write_string(&bldr, circle_code(8))
	strings.write_string(&bldr, circle_code(16))

	err := os.write_entire_file_from_string("geometry.odin", data = strings.to_string(bldr))
	if err != nil {
		fmt.eprintf("Failed to generate geometry file", err)
	}
}

circle_code :: proc(segments: u32) -> string
{
	positions := make([dynamic][2]f32)
	indices := make([dynamic]u32)
	segment_width: f32 = (math.PI * 2.0) / f32(segments)
	angle: f32 = 0

	append(&positions, [2]f32{0, 0})
	for i in 0 ..< segments {
		append(&positions, [2]f32{math.cos(angle), math.sin(angle)})
		angle += segment_width
	}

	bldr: strings.Builder
	strings.builder_init(&bldr)

	fmt.sbprintf(&bldr, "CIRCLE_%d_POS :: [?][2]f32{{", segments)
	for pos in positions {
		fmt.sbprintf(&bldr, "{{%.3f, %.3f}},", pos[0], pos[1])
	}
	strings.write_string(&bldr, "}\n")
	fmt.sbprintf(&bldr, "CIRCLE_%d_INDICES :: [?]u32{{", segments)
	i: int = 1
	for i < len(positions) - 1 {
		fmt.sbprintf(&bldr, "%d, %d, %d, ", 0, i, i + 1)
		i += 1
	}
	fmt.sbprintf(&bldr, "%d, %d, %d, ", 0, i, 1)
	strings.write_string(&bldr, "}\n")
	out := strings.to_string(bldr)
	fmt.println(out)
	return out
}
