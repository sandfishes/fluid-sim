package marching2d
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import "core:math/rand"
import "core:os"
import "core:sort"
import "core:thread"
import "core:time"
import "gpu"
import "vendor:glfw"
import vk "vendor:vulkan"
// Define some useful constants
GRAVITY: f32 : 0
DOWN: [2]f32 : {0, 1}
RIGHT: [2]f32 : {1, 1}
DAMPING_FACTOR: f32 : 0.70
FRICTION_COEFFICIENT: f32 : 0.98
MASS: f32 : 1
TARGET_DENSITY: f32 : 1.0
PRESSURE_MULTIPLER: f32 : 300
INIT_SPEED_SCALE: f32 : 0
FIELD_RADIUS: f32 : 30
DRAW_RADIUS: f32 : 3
NUM_PARTICLES :: 2000

Simulation :: struct {
	width, height:           f32,
	radius:                  f32,
	field_radius:            f32,
	top_speed:               f32,
	vertices:                [dynamic]Vertex, //(change to instances later)
	indices:                 [dynamic]u32,
	gpu_constants:           GPU_Draw_Push_Constants,
	buffers:                 Buffer_Struct,

	// Hot reloading info
	current_last_write_time: time.Time,

	// resources
	thread_pool:             thread.Pool,
	core_count:              int,

	// Fluid particles
	particles:               #soa[dynamic]Point,
	spatial_lookup:          [NUM_PARTICLES]Spatial_Entry,
	start_indices:           [NUM_PARTICLES]int,

	// Input
	cursor_pos:              [2]f32,
	mouse_left:              bool,
	mouse_right:             bool,
}

sim: Simulation

// TODO claydo
update_sim :: proc(dt: f32)
{
	free_all(context.temp_allocator)
	positions, velocity, densities := soa_unzip(sim.particles[:])
	sim.top_speed = 0

	thread_data := Delta_Time{dt}
	// Apply natural forces and predict position
	do_all(apply_natural_forces, thread_data, 0, len(positions), &sim.thread_pool)

	update_spatial_lookup()
	// Calculate densities. Accesses global state (like a lot)
	do_all(calculate_densities, thread_data, 0, len(positions), &sim.thread_pool)
	do_all(apply_pressure_forces, thread_data, 0, len(positions), &sim.thread_pool)

	// update positions
	do_all(update_positions, thread_data, 0, len(positions), &sim.thread_pool)
}

cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64)
{
	// need to convert to vulkan coordinates or things go weird
	sim.cursor_pos = [2]f32{f32(x), f32(y)} - {sim.width, sim.height}
}

mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button: i32, action: i32, mods: i32)
{
	if button == glfw.MOUSE_BUTTON_LEFT {
		if action == glfw.PRESS {
			sim.mouse_left = true
		} else if action == glfw.RELEASE {
			sim.mouse_left = false
		}
	}

	if button == glfw.MOUSE_BUTTON_RIGHT {
		if action == glfw.PRESS {
			sim.mouse_right = true
		} else if action == glfw.RELEASE {
			sim.mouse_right = false
		}
	}

	context = runtime.default_context()
	fmt.println(sim.mouse_left, sim.mouse_right)
}

interaction_force :: proc(
	input_pos: [2]f32,
	radius: f32,
	strength: f32,
	particle_pos: [2]f32,
	particle_vel: [2]f32,
) -> [2]f32
{
	interaction_force := [2]f32{0, 0}
	dist := glsl.distance(input_pos, particle_pos)

	// if particle indside radius calculate force towards input point
	if dist < radius {
		dir_to_input := glsl.normalize(input_pos - particle_pos)
		centre_t := 1 - dist / radius
		// calculate force (velocity subtracted to slow the particle)
		interaction_force += (dir_to_input * strength - particle_vel) * centre_t
	}
	return interaction_force
}

Delta_Time :: struct {
	dt: f32,
}

calculate_densities :: proc(thread_data: thread.Task)
{
	data := get_task_data(Delta_Time, thread_data)
	for &p, i in sim.particles[data.start:data.end] {
		p.density = calculate_density(p.pos, data.start + i)
	}
}

apply_pressure_forces :: proc(thread_data: thread.Task)
{
	data := get_task_data(Delta_Time, thread_data)
	for &p, i in sim.particles[data.start:data.end] {
		pressure_force: [2]f32 = calculate_pressure_force(data.start + i)
		pressure_acceleration: [2]f32 = pressure_force / p.density
		p.vel += pressure_acceleration * data.dt
		p.vel *= FRICTION_COEFFICIENT
	}
}

apply_natural_forces :: proc(thread_data: thread.Task)
{
	data := get_task_data(Delta_Time, thread_data)
	for &p in sim.particles[data.start:data.end] {
		p.vel += DOWN * GRAVITY * data.dt
		p.pos += p.vel * data.dt
	}
}

update_positions :: proc(thread_data: thread.Task)
{
	data := get_task_data(Delta_Time, thread_data)
	for &p in sim.particles[data.start:data.end] {
		if sim.mouse_left {
			p.vel -= interaction_force(sim.cursor_pos, 200, 3000, p.pos, p.vel) * data.dt
		}
		if sim.mouse_right {
			p.vel += interaction_force(sim.cursor_pos, 200, 2000, p.pos, p.vel) * data.dt
		}
		p.pos += p.vel * data.dt
		if abs(p.pos.x) > sim.width - 10 {
			p.pos.x = math.sign(p.pos.x) * (sim.width - 10)
			p.vel.x *= -DAMPING_FACTOR
		}

		if abs(p.pos.y) > sim.height - 10 {
			p.pos.y = math.sign(p.pos.y) * (sim.height - 10)
			p.vel.y *= -DAMPING_FACTOR
		}
		sim.top_speed = max(sim.top_speed, glsl.length(p.vel))
	}
}

Spatial_Entry :: struct {
	idx:      int,
	cell_key: int,
}

Spatial_Lookup_Data :: struct {
	radius: f32,
}

Update_Start_Key_Data :: struct {}

update_spatial_lookup :: proc()
{

	do_all(
		update_spatial_point,
		Spatial_Lookup_Data{sim.field_radius},
		0,
		len(sim.particles),
		&sim.thread_pool,
	)

	sort.quick_sort_proc(sim.spatial_lookup[:], key_predicate)

	// calculate start key of each unique cell
	do_all(update_start_key, Update_Start_Key_Data{}, 0, len(sim.particles), &sim.thread_pool)
}

key_predicate :: proc(entry_1: Spatial_Entry, entry_2: Spatial_Entry) -> int
{
	return entry_1.cell_key - entry_2.cell_key
}

update_spatial_point :: proc(thread_data: thread.Task)
{
	data := get_task_data(Spatial_Lookup_Data, thread_data)
	radius := data.data.radius
	points, _, _ := soa_unzip(sim.particles[:])
	for &point, i in points[data.start:data.end] {
		idx := i + data.start
		cell_x, cell_y := position_to_cell_coord(point, radius)
		cell_key := key_from_hash(hash_cell(cell_x, cell_y))
		sim.spatial_lookup[idx] = Spatial_Entry{idx, cell_key}
		sim.start_indices[idx] = -1
	}
}

position_to_cell_coord :: #force_inline proc(point: [2]f32, radius: f32) -> (int, int)
{
	cell_x: int = int(point.x / radius)
	cell_y: int = int(point.y / radius)
	return cell_x, cell_y
}

hash_cell :: #force_inline proc(cell_x, cell_y: int) -> u32
{
	a := u32(cell_x) * 15823
	b := u32(cell_y) * 9737333
	return a + b
}

key_from_hash :: proc(hash: u32) -> int
{
	return cast(int)hash % len(sim.spatial_lookup)
}

update_start_key :: proc(thread_data: thread.Task)
{
	data := get_task_data(Update_Start_Key_Data, thread_data)
	points, _, _ := soa_unzip(sim.particles[:])
	for point, i in points[data.start:data.end] {
		idx := i + data.start
		key := sim.spatial_lookup[idx].cell_key
		key_prev := idx == 0 ? -1 : sim.spatial_lookup[idx - 1].cell_key
		if (key != key_prev) {
			sim.start_indices[key] = idx
		}
	}
}

IDX_BUFFER_SIZE :: 500
@(thread_local)
thread_idx_buffer: [IDX_BUFFER_SIZE]int
get_points_within_radius :: proc(sample_point: [2]f32, buffer: ^[IDX_BUFFER_SIZE]int) -> int
{
	n := 0
	spatial_lookup := sim.spatial_lookup
	start_indices := sim.start_indices
	points, _, _ := soa_unzip(sim.particles[:])
	centre_x, centre_y := position_to_cell_coord(sample_point, sim.field_radius)
	cell_offsets: [9][2]int = get_cell_offsets(centre_x, centre_y)
	for pair in cell_offsets {
		key := key_from_hash(hash_cell(pair.x, pair.y))
		cell_start_idx := sim.start_indices[key]
		if cell_start_idx == -1 {continue} 	// no points in the square
		for i := cell_start_idx; i < len(sim.spatial_lookup); i += 1 {
			if sim.spatial_lookup[i].cell_key != key {break}
			particle_index := sim.spatial_lookup[i].idx
			buffer[n] = particle_index
			n += 1
			if n >= IDX_BUFFER_SIZE { 	// safety
				return n
			}
		}
	}
	return n
}

get_cell_offsets :: proc(x, y: int) -> [9][2]int
{
	return [9][2]int {
		{x, y},
		{x + 1, y},
		{x - 1, y},
		{x, y - 1},
		{x + 1, y - 1},
		{x - 1, y - 1},
		{x, y + 1},
		{x + 1, y + 1},
		{x - 1, y + 1},
	}
}

convert_density_to_pressure :: proc(density: f32) -> f32
{
	density_error := density - TARGET_DENSITY
	return density_error * PRESSURE_MULTIPLER
}

smooth_kern :: #force_inline proc(rad, dst: f32) -> f32
{
	if dst >= rad {return 0}
	volume := math.PI * math.pow(rad, 4) / 6 // Can make precalculate if needed
	return (rad - dst) * (rad - dst) / volume
}

smooth_kern_deriv :: #force_inline proc(rad, dst: f32) -> f32
{
	if dst >= rad {return 0}

	scale := 12 / (math.pow(rad, 4) * math.PI)
	return (dst - rad) * scale
}

calculate_density :: proc(sample_point: [2]f32, idx: int) -> f32
{
	density: f32 = 0
	points, _, _ := soa_unzip(sim.particles[:])
	n := get_points_within_radius(sample_point, &thread_idx_buffer)
	for i in 0 ..< n {
		point := points[thread_idx_buffer[i]]
		dst := glsl.distance(point, sample_point)
		influence := smooth_kern(sim.field_radius, dst)
		density += MASS * influence
	}
	return density
}

calculate_pressure_force :: proc(sample_idx: int) -> [2]f32
{
	pressure_force: [2]f32 = {0, 0}
	points, _, densities := soa_unzip(sim.particles[:])
	sample_point := points[sample_idx]
	n := get_points_within_radius(sample_point, &thread_idx_buffer)
	for i in 0 ..< n {
		idx := thread_idx_buffer[i]
		point := points[idx]
		dst: f32 = glsl.distance(point, sample_point)
		if dst < 0.0001 {continue}
		dir: [2]f32 = (point - sample_point) / dst
		slope: f32 = smooth_kern_deriv(sim.field_radius, dst)
		density := densities[idx]
		shared_pressure := calculate_shared_pressure(densities[sample_idx], density)
		pressure_force -= shared_pressure * dir * slope * MASS / density
	}
	return pressure_force
}

calculate_shared_pressure :: proc(density_1: f32, density_2: f32) -> f32
{
	pressure_1 := convert_density_to_pressure(density_1)
	pressure_2 := convert_density_to_pressure(density_2)
	return (pressure_1 + pressure_2) / 2
}

draw_sim :: proc()
{
	clear(&sim.vertices)
	clear(&sim.indices)
	in_range_points := make(map[int]bool)
	defer delete(in_range_points)
	n := get_points_within_radius(sim.cursor_pos, &thread_idx_buffer)
	for i in 0 ..< n {
		in_range_points[thread_idx_buffer[i]] = true
	}
	for particle, i in sim.particles {
		// scale_vel := clamp(glsl.length(particle.vel) / sim.top_speed, 0, 1)
		scale_vel := clamp(glsl.length(particle.vel) / 200, 0, 1)
		color: [3]f32
		if in_range_points[i] != false {
			color = {1, 1, 1}
		} else {
			color = {scale_vel, 0.7, 1 - scale_vel}
		}
		draw_circle(&sim.vertices, &sim.indices, particle.pos, sim.radius, color)
	}
	gpu.staging_write_buffer_slice(&sim.buffers.index_buffer, sim.indices[:])
	gpu.staging_write_buffer_slice(&sim.buffers.vertex_buffer, sim.vertices[:]) // Why every frame?
}

init_sim :: proc()
{
	rs := &gpu.rs
	glfw.SetCursorPosCallback(rs.window, cursor_pos_callback)
	glfw.SetMouseButtonCallback(rs.window, mouse_button_callback)
	width, height := glfw.GetFramebufferSize(rs.window)
	sim.width, sim.height = 0.5 * f32(width), 0.5 * f32(height)
	sim.radius = DRAW_RADIUS
	sim.field_radius = FIELD_RADIUS
	sim.top_speed = 0.1
	sim.core_count = os.get_processor_core_count()
	thread.pool_init(&sim.thread_pool, context.allocator, sim.core_count - 1) // Not allocating so default is fine
	thread.pool_start(&sim.thread_pool)
	sim.particles = make(#soa[dynamic]Point)
	sim.vertices = make([dynamic]Vertex, context.temp_allocator)
	sim.indices = make([dynamic]u32, context.temp_allocator)
	for i in 0 ..< NUM_PARTICLES {
		append(
			&sim.particles,
			Point {
				{
					// -sim.width + 2 * rand.float32() * sim.width,
					// -sim.height + 2 * rand.float32() * sim.height,
					f32(i) * math.sin(f32(i) / 10) / 5,
					f32(i) * math.cos(f32(i) / 10) / 5,
					// -sim.width / 6 + f32(i % 25) * sim.width / (50),
					// -sim.height / 6 + f32(i / 25) * sim.height / (50),
				},
				{
					(2 * rand.float32() - 1) * INIT_SPEED_SCALE,
					(2 * rand.float32() - 1) * INIT_SPEED_SCALE,
				},
				0,
			},
		)
		// Preload the data so buffers are the correct size.
		draw_circle(&sim.vertices, &sim.indices, {0, 0}, 0.025, {1, 1, 1})
	}
	sim.buffers.index_buffer = gpu.create_buffer(
		auto_cast (size_of(u32) * len(sim.indices)),
		{.INDEX_BUFFER, .TRANSFER_DST},
	)

	sim.buffers.vertex_buffer = gpu.create_buffer(
		auto_cast (size_of(Vertex) * len(sim.vertices)),
		{.VERTEX_BUFFER, .TRANSFER_DST},
	)

	mesh := Buffer_Struct{sim.buffers.index_buffer, sim.buffers.vertex_buffer, 0}
	vertex_buffer_address_info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = mesh.vertex_buffer.buffer,
	}
	mesh.vertex_buffer_address = vk.GetBufferDeviceAddress(rs.device, &vertex_buffer_address_info)

	sim.gpu_constants = GPU_Draw_Push_Constants {
		world_matrix  = glsl.mat4Ortho3d(
			-f32(width) / 2,
			f32(width) / 2,
			-f32(height) / 2,
			f32(height) / 2,
			-100,
			100,
		),
		vertex_buffer = mesh.vertex_buffer_address,
	}
}

