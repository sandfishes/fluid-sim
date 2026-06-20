package marching2d
import "../gpu"
import "base:runtime"
import "core:compress"
import "core:fmt"
import "core:math"
import "core:math/linalg/glsl"
import "core:math/rand"
import "core:os"
import "core:thread"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"
// Define some useful constants
GRAVITY: f32 : 0
DOWN: [2]f32 : {0, 1}
RIGHT: [2]f32 : {1, 1}
DAMPING_FACTOR: f32 : 0.9
MASS: f32 : 1
TARGET_DENSITY: f32 : 1
PRESSURE_MULTIPLER: f32 : 100
INIT_SPEED_SCALE: f32 : 0
FIELD_RADIUS: f32 : 50

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
}

sim: Simulation

// TODO claydo
update_sim :: proc(dt: f32)
{
	free_all(context.temp_allocator)


	positions, velocity, densities := soa_unzip(sim.particles[:])

	// Calculate densities. Accesses global state (like a lot)
	thread_data := Delta_Time{dt}
	do_all(calculate_densities, thread_data, 0, len(positions), &sim.thread_pool)
	do_all(apply_pressure_forces, thread_data, 0, len(positions), &sim.thread_pool)
	// for &p, i in sim.particles {
	// 	pressure_force: [2]f32 = calculate_pressure_force(i)
	// 	pressure_acceleration: [2]f32 = pressure_force / p.density
	// 	p.vel = pressure_acceleration * dt
	// }
	// Apply natural forces
	do_all(apply_natural_forces, thread_data, 0, len(positions), &sim.thread_pool)
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
		p.vel = pressure_acceleration * data.dt
		// TODO should be p.vel -=
	}
}

Natural_Force_Data :: struct {
	dt: f32,
}
apply_natural_forces :: proc(thread_data: thread.Task)
{
	data := get_task_data(Delta_Time, thread_data)
	for &p in sim.particles[data.start:data.end] {
		p.vel += DOWN * GRAVITY * data.dt
		p.pos += p.vel * data.dt
		if abs(p.pos.x) > sim.width - sim.field_radius {
			p.pos.x = math.sign(p.pos.x) * (sim.width - sim.field_radius)
			p.vel.x *= -DAMPING_FACTOR
		}

		if abs(p.pos.y) > sim.height - sim.field_radius {
			p.pos.y = math.sign(p.pos.y) * (sim.height - sim.field_radius)
			p.vel.y *= -DAMPING_FACTOR
		}
		sim.top_speed = max(sim.top_speed, glsl.length(p.vel))
	}
}

convert_density_to_pressure :: proc(density: f32) -> f32
{
	density_error := density - TARGET_DENSITY
	return density_error * PRESSURE_MULTIPLER
}

smooth_kern :: #force_inline proc(rad, dst: f32) -> f32
{
	if dst >= sim.field_radius {return 0}
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
	positions, _, _ := soa_unzip(sim.particles[:])
	for p, i in positions {
		// if i == idx {continue}
		dst := glsl.distance(p, sample_point)
		influence := smooth_kern(sim.field_radius, dst)
		density += MASS * influence
	}
	return density
}

calculate_pressure_force :: proc(idx: int) -> [2]f32
{
	pressure_force: [2]f32 = {0, 0}
	positions: [][2]f32
	densities: []f32
	positions, _, densities = soa_unzip(sim.particles[:])
	sample_point := positions[idx]
	for p, i in positions {
		if i == idx {continue}
		dst: f32 = glsl.distance(p, sample_point)
		dst = max(0.0001, dst)
		dir: [2]f32 = (p - sample_point) / dst
		slope: f32 = smooth_kern_deriv(sim.field_radius, dst)
		density: f32 = densities[i]
		pressure_force -= convert_density_to_pressure(density) * dir * slope * MASS / density
	}
	return pressure_force
}


draw_sim :: proc()
{
	clear(&sim.vertices)
	clear(&sim.indices)
	for particle in sim.particles {
		scale_vel := clamp(glsl.length(particle.vel) / sim.top_speed, 0, 1)
		draw_circle(
			&sim.vertices,
			&sim.indices,
			particle.pos,
			sim.radius,
			{scale_vel, 1 - scale_vel, 0.3},
		)
	}
	gpu.staging_write_buffer_slice(&sim.buffers.index_buffer, sim.indices[:])
	gpu.staging_write_buffer_slice(&sim.buffers.vertex_buffer, sim.vertices[:]) // Why every frame?
}

NUM_PARTICLES :: 500
init_sim :: proc()
{
	rs := &gpu.rs
	width, height := glfw.GetFramebufferSize(rs.window)
	sim.width, sim.height = 0.5 * f32(width), 0.5 * f32(height)
	sim.radius = 10
	sim.field_radius = FIELD_RADIUS
	sim.top_speed = 0.1
	sim.core_count = os.get_processor_core_count()
	thread.pool_init(&sim.thread_pool, context.allocator, sim.core_count - 1) // Not allocating so default is fine
	thread.pool_start(&sim.thread_pool)
	sim.particles = make(#soa[dynamic]Point)
	sim.vertices = make([dynamic]Vertex, context.temp_allocator)
	sim.indices = make([dynamic]u32, context.temp_allocator)
	for particle in 0 ..< NUM_PARTICLES {
		append(
			&sim.particles,
			Point {
				{
					-sim.width + 2 * rand.float32() * sim.width,
					-sim.height + 2 * rand.float32() * sim.height,
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

