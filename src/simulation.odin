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
GRAVITY: f32 = 0
DOWN: [2]f32 = {0, 1}
RIGHT: [2]f32 = {1, 1}
DAMPING_FACTOR: f32 = 0.8
MASS: f32 = 1
TARGET_DENSITY: f32 = 1.0
PRESSURE_MULTIPLER: f32 = 0
NEAR_PRESSURE_MULTIPLIER: f32 = 0
INIT_SPEED_SCALE: f32 = 0
FIELD_RADIUS: f32 = 20
DRAW_RADIUS: f32 = 8
NUM_PARTICLES :: 2000
INTERACTION_FORCE: f32 = 5000
SMOOTHING_RADIUS: f32 = 100
VISCOSCITY_STRENGTH: f32 = 0

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
	mouse_left:              Mouse_State,
	mouse_right:             Mouse_State,
}

Mouse_State :: enum {
	CLICK,
	DOWN,
	UP,
}

sim: Simulation

// TODO claydo
update_sim :: proc(dt: f32)
{
	free_all(context.temp_allocator)
	sim.top_speed = 0

	thread_data := Delta_Time{dt / 2}
	// Apply natural forces and predict position
	do_all(apply_natural_forces, thread_data, 0, len(sim.particles), &sim.thread_pool)
	update_spatial_lookup()
	do_all(calculate_densities, thread_data, 0, len(sim.particles), &sim.thread_pool)
	do_all(apply_pressure_forces, thread_data, 0, len(sim.particles), &sim.thread_pool)
	do_all(apply_viscoscity_forces, thread_data, 0, len(sim.particles), &sim.thread_pool)
	do_all(update_positions, thread_data, 0, len(sim.particles), &sim.thread_pool)

	do_all(apply_natural_forces, thread_data, 0, len(sim.particles), &sim.thread_pool)
	update_spatial_lookup()
	do_all(calculate_densities, thread_data, 0, len(sim.particles), &sim.thread_pool)
	do_all(apply_pressure_forces, thread_data, 0, len(sim.particles), &sim.thread_pool)
	do_all(apply_viscoscity_forces, thread_data, 0, len(sim.particles), &sim.thread_pool)
	do_all(update_positions, thread_data, 0, len(sim.particles), &sim.thread_pool)

}

apply_viscoscity_forces :: proc(thread_data: thread.Task)
{
	data := get_task_data(Delta_Time, thread_data)
	for &p, i in sim.particles[data.start:data.end] {
		p.vel += calculate_viscoscity_force(data.start + i)
	}
}

calculate_viscoscity_force :: proc(idx: int) -> [2]f32
{
	viscoscity_force: [2]f32 = {0, 0}
	pos := sim.particles.predicted_pos[idx]
	n := get_points_within_radius(pos, &thread_idx_buffer)
	for i in 0 ..< n {
		other_idx := thread_idx_buffer[i]
		dst := glsl.distance(pos, sim.particles.predicted_pos[other_idx])
		if dst < 0.0001 {continue}
		influence := smooth_kern(SMOOTHING_RADIUS, dst)
		viscoscity_force += (sim.particles.vel[other_idx] - sim.particles.vel[idx]) * influence
	}
	return viscoscity_force * VISCOSCITY_STRENGTH
}

viscoscity_kernel :: proc(radius, dst: f32) -> f32
{
	if dst >= radius {return 0}
	volume := math.PI * math.pow(radius, 8) / 4
	value := radius * radius - dst * dst
	return value * value * value / volume

}

cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, x, y: f64)
{
	// need to convert to vulkan coordinates or things go weird
	sim.cursor_pos = [2]f32{f32(x), f32(y)} * 2 - {sim.width, sim.height}
}

mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button: i32, action: i32, mods: i32)
{
	if button == glfw.MOUSE_BUTTON_LEFT {
		if action == glfw.PRESS {
			sim.mouse_left = .CLICK
		} else if action == glfw.RELEASE {
			sim.mouse_left = .UP
		}
	}

	if button == glfw.MOUSE_BUTTON_RIGHT {
		if action == glfw.PRESS {
			sim.mouse_right = .CLICK
		} else if action == glfw.RELEASE {
			sim.mouse_right = .UP
		}
	}

	context = runtime.default_context()
}

interaction_force :: proc(
	input_pos: [2]f32,
	radius: f32,
	particle_pos: [2]f32,
	particle_vel: [2]f32,
) -> [2]f32
{
	interaction_force := [2]f32{0, 0}
	dist := glsl.distance(input_pos, particle_pos)

	// if particle indside radius calculate force towards input point
	if dist < radius && dist > radius * 0.4 {
		dir_to_input := glsl.normalize(input_pos - particle_pos)
		centre_t := 1 - dist / radius
		// calculate force (velocity subtracted to slow the particle)
		interaction_force += (dir_to_input * INTERACTION_FORCE - particle_vel) * centre_t
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
		p.density, p.near_density = calculate_density(p.predicted_pos, data.start + i)
	}
}

apply_pressure_forces :: proc(thread_data: thread.Task)
{
	data := get_task_data(Delta_Time, thread_data)
	for &p, i in sim.particles[data.start:data.end] {
		pressure_force := calculate_pressure_force(data.start + i)
		pressure_acceleration: [2]f32 = pressure_force / p.density
		p.vel += pressure_acceleration * data.dt
	}
}

apply_natural_forces :: proc(thread_data: thread.Task)
{
	data := get_task_data(Delta_Time, thread_data)
	for &p in sim.particles[data.start:data.end] {
		p.vel += DOWN * GRAVITY * data.dt
		p.predicted_pos = p.pos + p.vel * data.dt
	}
}

update_positions :: proc(thread_data: thread.Task)
{
	data := get_task_data(Delta_Time, thread_data)
	for &p in sim.particles[data.start:data.end] {
		if sim.mouse_left == .DOWN {
			p.vel -= interaction_force(sim.cursor_pos, 400, p.pos, p.vel) * data.dt
		}
		if sim.mouse_right == .DOWN {
			p.vel += interaction_force(sim.cursor_pos, 400, p.pos, p.vel) * data.dt
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
	_, predicted_points, _, _, _ := soa_unzip(sim.particles[:])
	for &point, i in predicted_points[data.start:data.end] {
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
	_, predicted_points, _, _, _ := soa_unzip(sim.particles[:])
	for point, i in predicted_points[data.start:data.end] {
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

convert_density_to_pressure :: proc(density, near_density: f32) -> (f32, f32)
{
	pressure := (density - TARGET_DENSITY) * PRESSURE_MULTIPLER
	near_pressure := near_density * NEAR_PRESSURE_MULTIPLIER
	return pressure, near_pressure
}

// Quadratic spike
smooth_kern :: #force_inline proc(rad, dst: f32) -> f32
{
	if dst >= rad {return 0}
	scale := 6 / (math.PI * math.pow(rad, 4)) // inverse volume
	return (rad - dst) * (rad - dst) * scale
}


smooth_kern_deriv :: #force_inline proc(rad, dst: f32) -> f32
{
	if dst >= rad {return 0}
	scale := 12 / (math.pow(rad, 4) * math.PI)
	return (dst - rad) * scale
}

// cubic spike
near_smooth_kern :: #force_inline proc(rad, dst: f32) -> f32
{
	if dst >= rad {return 0}
	scale := 10 / (math.PI * math.pow(rad, 5)) // inverse volume
	return math.pow(rad - dst, 3) * scale
}

near_smooth_kern_deriv :: #force_inline proc(rad, dst: f32) -> f32
{
	if dst >= rad {return 0}
	scale := 10 / (math.PI * math.pow(rad, 5)) // inverse volume
	return 3 * (dst - rad) * (rad - dst) * scale
}

calculate_density :: proc(sample_point: [2]f32, idx: int) -> (f32, f32)
{
	density: f32 = 0
	near_density: f32 = 0
	_, predicted_points, _, _, _ := soa_unzip(sim.particles[:])
	n := get_points_within_radius(sample_point, &thread_idx_buffer)
	for i in 0 ..< n {
		point := predicted_points[thread_idx_buffer[i]]
		dst := glsl.distance(point, sample_point)
		density += MASS * smooth_kern(sim.field_radius, dst)
		near_density += MASS * near_smooth_kern(sim.field_radius, dst)
	}
	return density, near_density
}

calculate_pressure_force :: proc(sample_idx: int) -> [2]f32
{
	pressure_force: [2]f32 = {0, 0}
	_, predicted_points, _, densities, near_densities := soa_unzip(sim.particles[:])
	sample_point := predicted_points[sample_idx]
	n := get_points_within_radius(sample_point, &thread_idx_buffer)
	for i in 0 ..< n {
		idx := thread_idx_buffer[i]
		point := predicted_points[idx]
		dst: f32 = glsl.distance(point, sample_point)
		if dst < 0.0001 {continue}
		dir: [2]f32 = (point - sample_point) / dst
		slope: f32 = smooth_kern_deriv(sim.field_radius, dst)
		near_slope: f32 = near_smooth_kern_deriv(sim.field_radius, dst)
		density := densities[idx]
		near_density := near_densities[idx]
		shared_pressure, near_shared_pressure := calculate_shared_pressure(
			densities[sample_idx],
			density,
			near_densities[sample_idx],
			near_density,
		)
		pressure_force -=
			(shared_pressure * slope / density +
				near_slope * near_shared_pressure / near_density) *
			dir *
			MASS
	}
	return pressure_force
}

calculate_shared_pressure :: proc(
	density_1, density_2, near_density_1, near_density_2: f32,
) -> (
	f32,
	f32,
)
{
	pressure_1, near_pressure_1 := convert_density_to_pressure(density_1, near_density_1)
	pressure_2, near_pressure_2 := convert_density_to_pressure(density_2, near_density_2)
	return (pressure_1 + pressure_2) / 2, (near_pressure_1 + near_pressure_2) / 2
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
		// scale_vel := clamp(2 * glsl.length(particle.vel) / sim.top_speed, 0, 1)
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
		x := f32(i) * math.sin(f32(i) / 10) / 5
		y := f32(i) * math.cos(f32(i) / 10) / 5
		append(
			&sim.particles,
			Point {
				{x, y},
				{x, y},
				{
					(2 * rand.float32() - 1) * INIT_SPEED_SCALE,
					(2 * rand.float32() - 1) * INIT_SPEED_SCALE,
				},
				0,
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

