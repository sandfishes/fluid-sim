package marching2d

import "core:math/rand"
import geom "geometry"

import "../gpu"

import "core:fmt"
import "core:math"
import glsl "core:math/linalg/glsl"
import "core:os"
import "core:thread"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"

Buffer_Struct :: struct {
	index_buffer:          gpu.GPUBuffer,
	vertex_buffer:         gpu.GPUBuffer,
	vertex_buffer_address: vk.DeviceAddress, // Pointer to the buffer on the GPU side.
}

GPU_Draw_Push_Constants :: struct {
	world_matrix:  matrix[4, 4]f32,
	vertex_buffer: vk.DeviceAddress,
}

Vertex :: struct {
	pos: [2]f32,
	col: [3]f32,
}

Point :: struct {
	pos:     [2]f32,
	vel:     [2]f32,
	density: f32,
}

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

	// Fluid particles
	particles:               #soa[dynamic]Point,
}

sim: Simulation

main :: proc()
{
	rs: ^gpu.Renderer_State = &gpu.rs
	// set up the window and Vulkan
	vk_setup()

	// Create index buffer

	init_sim()
	last_frame_time := glfw.GetTime()
	for !glfw.WindowShouldClose(rs.window) {
		current_frame_time := glfw.GetTime()
		dt: f32 = f32(current_frame_time - last_frame_time)
		last_frame_time = current_frame_time
		glfw.PollEvents()
		cmd: vk.CommandBuffer = vk_frame_setup()

		update_sim(dt)
		draw_sim()

		vk.CmdPushConstants(
			cmd,
			rs.pipeline_layout,
			{.VERTEX},
			0,
			size_of(GPU_Draw_Push_Constants),
			&sim.gpu_constants,
		)

		buffers := [?]vk.Buffer{sim.buffers.vertex_buffer.buffer}
		offsets := [?]vk.DeviceSize{0}
		vk.CmdBindVertexBuffers(cmd, 0, 1, &buffers[0], &offsets[0])
		vk.CmdBindIndexBuffer(cmd, sim.buffers.index_buffer.buffer, 0, .UINT32)

		// Draw triangle
		vk.CmdDrawIndexed(cmd, u32(len(sim.indices)), 1, 0, 0, 0)

		vk_frame_end(cmd)

		rs.frame_number += 1
		free_all(context.temp_allocator)
	}
	cleanup()
}


// Define some useful constants
GRAVITY: f32 : 50
DOWN: [2]f32 : {0, 1}
RIGHT: [2]f32 : {1, 1}
DAMPING_FACTOR: f32 : 0.8
MASS: f32 : 1

// TODO claydo
update_sim :: proc(dt: f32)
{
	free_all(context.temp_allocator)
	// Natural forces!
	for &particle in sim.particles {
		particle.vel += DOWN * GRAVITY * dt
		particle.pos += particle.vel * dt
	}

	// Resolve collisions
	for &p in sim.particles {
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

	update_densities()
}

smooth_kern :: #force_inline proc(rad, dst: f32) -> f32
{
	volume := math.PI * math.pow(rad, 8) / 4 // Can make precalculate if needed
	value := max(0, rad * rad - dst * dst)
	return value * value * value / volume
}

smooth_kern_deriv :: #force_inline proc(rad, dst: f32) -> f32
{
	if (dst > rad) {return 0}
	f: f32 = rad * rad - dst * dst
	scale: f32 = -24 / (math.PI * math.pow(rad, 8))
	return scale * dst * f * f
}

calculate_density :: proc(sample_point: [2]f32) -> f32
{
	density: f32 = 0
	positions, _ := soa_unzip(sim.particles[:])
	for p in positions {
		dst := glsl.distance(p, sample_point)
		influence := smooth_kern(sim.field_radius, dst)
		density := MASS * influence
	}
	return density
}

// multithreading
update_densities :: proc()
{
	positions, _, densities := soa_unzip(sim.particles[:])
	for p, i in positions {
		densities[i] = calculate_density(p)
	}
}

/* To calculate some property at position x, we loop through every particle, and sum the property for that particle,
multipled by mass, divided by density, multiplied by the smoothing function. */
calculate_property :: proc(sample_point: [2]f32, properties: []f32) -> f32
{
	property: f32 = 0
	positions: [][2]f32
	positions, _, _ = soa_unzip(sim.particles[:])
	for p, i in positions {
		dst := glsl.distance(p, sample_point)
		influence := smooth_kern(sim.field_radius, dst)
		density: f32 = calculate_density(p)
		property += properties[i] * influence * MASS / density
	}
	return property
}

calculate_property_gradient :: proc(sample_point: [2]f32, properties: []f32) -> [2]f32
{
	property_gradient: [2]f32 = {0, 0}
	positions: [][2]f32
	positions, _ = soa_unzip(sim.particles[:])
	for p, i in positions {
		dst: f32 = glsl.distance(p, sample_point)
		dir: [2]f32 = (p - sample_point) / dst // WARNING dst is 0 if sampling itself?
		slope: f32 = smooth_kern_deriv(sim.field_radius, dst)
		density: f32 = calculate_density(p) // WARNING obviously should be pre-calculated
		property_gradient -= properties[i] * dir * slope * MASS / density
	}
	return property_gradient
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

NUM_PARTICLES :: 1500
init_sim :: proc()
{
	rs := &gpu.rs
	width, height := glfw.GetFramebufferSize(rs.window)
	sim.width, sim.height = 0.5 * f32(width), 0.5 * f32(height)
	sim.radius = 10
	sim.field_radius = 50
	sim.top_speed = 0.1
	core_count := os.get_processor_core_count()
	thread.pool_init(&sim.thread_pool, context.allocator, core_count - 1) // Not allocating so default is fine
	thread.pool_start(&pool)
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
				{(2 * rand.float32() - 1) * 100, (2 * rand.float32() - 1) * 100},
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

vk_setup :: proc()
{
	rs := &gpu.rs
	glfw.Init()
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)

	rs.window = glfw.CreateWindow(800, 600, "2D Simulation", nil, nil)
	gpu.init_vulkan()

	// Load shaders
	module: vk.ShaderModule = gpu.compile_shader_module(
		"triangle.slang",
		"vertexmain",
		"fragmentmain",
	)
	create_pipeline(module)
	assert(rs.pipeline != 0, "Couldn't load shaders!")
	sim.current_last_write_time, _ = os.last_write_time_by_name("triangle.slang")
}

vk_frame_setup :: proc() -> vk.CommandBuffer
{

	rs := &gpu.rs
	last_write_time, err := os.last_write_time_by_name("triangle.slang")

	// Hot reload shader

	if err == nil && sim.current_last_write_time != last_write_time {
		vk.DestroyPipelineLayout(rs.device, rs.pipeline_layout, nil)
		vk.DestroyPipeline(rs.device, rs.pipeline, nil)
		for i in 0 ..< gpu.FRAME_OVERLAP {
			gpu.vk_check(
				vk.WaitForFences(rs.device, 1, &rs.frames[i].render_fence, true, 1_000_000_000),
			)
		}

		module: vk.ShaderModule = gpu.compile_shader_module(
			"triangle.slang",
			"vertexmain",
			"fragmentmain",
		)
		create_pipeline(module)
		assert(rs.pipeline != 0, "Couldn't load shaders!")
		sim.current_last_write_time = last_write_time
	}


	// Wait until we can access the current frame

	gpu.vk_check(
		vk.WaitForFences(rs.device, 1, &gpu.current_frame().render_fence, true, 1_000_000_000),
	)
	gpu.vk_check(
		vk.AcquireNextImageKHR(
			rs.device,
			rs.swapchain,
			1_000_000_000,
			gpu.current_frame().swapchain_semaphore,
			0,
			&rs.swapchain_image_index,
		),
	)
	rs.draw_extent.width = rs.draw_image.extent.width
	rs.draw_extent.height = rs.draw_image.extent.height
	gpu.vk_check(vk.ResetFences(rs.device, 1, &gpu.current_frame().render_fence))


	cmd := gpu.current_frame().main_command_buffer
	// reset and init the command buffer

	gpu.vk_check(
		vk.ResetCommandBuffer(gpu.current_frame().main_command_buffer, {.RELEASE_RESOURCES}),
	)
	cmd_begin_info := vk.CommandBufferBeginInfo {
		sType            = .COMMAND_BUFFER_BEGIN_INFO,
		pNext            = nil,
		pInheritanceInfo = nil,
		flags            = {.ONE_TIME_SUBMIT},
	}
	gpu.vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info))


	// Start drawing
	gpu.begin_render_pass()

	vk.CmdBindPipeline(cmd, .GRAPHICS, rs.pipeline)

	return cmd
}

vk_frame_end :: proc(cmd: vk.CommandBuffer)
{
	rs := &gpu.rs
	vk.CmdEndRenderingKHR(cmd)

	// End drawing
	gpu.end_render_pass()

	// present the swapchain to the screen
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		pSwapchains        = &rs.swapchain,
		swapchainCount     = 1,
		pWaitSemaphores    = &gpu.current_frame().render_semaphore,
		waitSemaphoreCount = 1,
		pImageIndices      = &rs.swapchain_image_index,
	}
	gpu.vk_check(vk.QueuePresentKHR(rs.graphics_queue, &present_info))
}

draw_circle :: proc(
	vertex_buffer: ^[dynamic]Vertex,
	index_buffer: ^[dynamic]u32,
	pos: [2]f32,
	radius: f32,
	col: [3]f32,
)
{
	for circle_pos in geom.CIRCLE_16_POS { 	// I think this can be done with zipping
		append(vertex_buffer, Vertex{pos + circle_pos * radius, col})

	}
	indices := geom.CIRCLE_16_INDICES
	start := u32(len(vertex_buffer))
	for idx in geom.CIRCLE_16_INDICES {
		append(index_buffer, start + idx)
	}
}

draw_square :: proc(
	vertex_buffer: ^[dynamic]Vertex,
	index_buffer: ^[dynamic]u32,
	pos: [2]f32,
	length: f32,
	col: [3]f32,
)
{
	append_elems(
		vertex_buffer,
		Vertex{pos + {0, 0}, COLOR_BLUE},
		Vertex{pos + {length, 0}, COLOR_BLUE},
		Vertex{pos + {0, length}, COLOR_BLUE},
		Vertex{pos + {length, length}, COLOR_BLUE},
	)
	start := u32(len(vertex_buffer))
	append_elems(index_buffer, start, start + 2, start + 1, start + 3, start + 1, start + 2)
}

COLOR_BLUE :: [3]f32{0.2, 0.2, 0.8}

create_pipeline :: proc(module: vk.ShaderModule)
{
	rs := &gpu.rs

	buffer_range := vk.PushConstantRange {
		offset     = 0,
		size       = size_of(GPU_Draw_Push_Constants),
		stageFlags = {.VERTEX},
	}

	pipeline_layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pNext                  = nil,
		flags                  = {},
		setLayoutCount         = 0,
		pSetLayouts            = nil,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &buffer_range,
	}

	rs.pipeline_layout, rs.pipeline = gpu.create_pipeline(module, pipeline_layout_info)
}

cleanup :: proc()
{
	rs := &gpu.rs
	// Cleanup our stuff
	vk.DeviceWaitIdle(rs.device)

	vk.DestroyBuffer(rs.device, sim.buffers.index_buffer.buffer, nil)
	vk.FreeMemory(rs.device, sim.buffers.index_buffer.memory, nil)

	vk.DestroyBuffer(rs.device, sim.buffers.vertex_buffer.buffer, nil)
	vk.FreeMemory(rs.device, sim.buffers.vertex_buffer.memory, nil)

	vk.DestroyPipeline(rs.device, rs.pipeline, nil)
	vk.DestroyPipelineLayout(rs.device, rs.pipeline_layout, nil)

	// Cleanup rest of vulkan
	gpu.vulkan_shutdown()

}

