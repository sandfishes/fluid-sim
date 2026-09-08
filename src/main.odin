package marching2d

import "core:math"
import "core:math/rand"
import "core:mem"
// NOTE
// On linux you MUST add the src/gpu/slang/lib folder to LD_LIBRARY_PATH or else
// slang will not be able to compile the shaders.
import geom "geometry"

import "base:runtime"
import "core:os"
import "core:time"
import "gpu"
import "ui"
import "vendor:glfw"
import vk "vendor:vulkan"

Buffer_Struct :: struct {
	index_buffer:          gpu.GPU_Buffer,
	vertex_buffer:         gpu.GPU_Buffer,
	vertex_buffer_address: vk.DeviceAddress, // Pointer to the buffer on the GPU side.
	storage_buffers:       [gpu.FRAMES_IN_FLIGHT]gpu.GPU_Buffer,
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
	pos:           [2]f32,
	predicted_pos: [2]f32,
	vel:           [2]f32,
	density:       f32,
	near_density:  f32,
}

Particle :: struct {
	position: [2]f32,
	velocity: [2]f32,
	color:    [4]f32,
}


main :: proc()
{
	rs: ^gpu.Renderer_State = &gpu.rs
	// set up the window and Vulkan
	vk_setup()

	// Create index buffer
	init_sim()
	last_frame_time := glfw.GetTime()
	platform_config: ui.Platform_Config = {
		window = rs.window,
	}
	ui_config: ui.UI_Config = {
		x      = 0,
		y      = 0,
		width  = 600,
		height = 400,
	}
	// TODO remove frame stuff
	ui.init(platform_config, ui_config, nil, nil)
	prepare_compute()
	for !glfw.WindowShouldClose(rs.window) {
		current_frame_time := glfw.GetTime()
		dt: f32 = min(0.167, f32(current_frame_time - last_frame_time))
		// dt: f32 = f32(current_frame_time - last_frame_time)
		last_frame_time = current_frame_time

		if sim.mouse_left == .CLICK {
			sim.mouse_left = .DOWN
		}
		if sim.mouse_right == .CLICK {
			sim.mouse_right = .DOWN
		}

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

		draw_controls(dt, cmd)

		vk_frame_end(cmd)

		rs.frame_number += 1
		free_all(context.temp_allocator)
	}
	cleanup()
}

vk_setup :: proc()
{
	rs := &gpu.rs
	glfw.Init()
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)

	rs.window = glfw.CreateWindow(1200, 700, "2D Simulation", nil, nil)
	gpu.init_vulkan()

	// Load shaders
	module: vk.ShaderModule = gpu.compile_shader_module(
		"src/shaders/triangle.slang",
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
		for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
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

Compute_Uniform_Data :: struct {
	delta_t: f32,
	// dest_x:         f32,
	// dest_y:         f32,
	// particle_count: i32,
}

Compute :: struct {
	fences:                [gpu.FRAMES_IN_FLIGHT]vk.Fence,
	descriptor_pool:       vk.DescriptorPool,
	descriptor_set_layout: vk.DescriptorSetLayout,
	descriptor_sets:       [gpu.FRAMES_IN_FLIGHT]vk.DescriptorSet,
	pipeline_layout:       vk.PipelineLayout,
	pipeline:              vk.Pipeline,
	pipeline_cache:        vk.PipelineCache,
	uniform_buffers:       [gpu.FRAMES_IN_FLIGHT]gpu.GPU_Buffer,
	storage_buffers:       [gpu.FRAMES_IN_FLIGHT]gpu.GPU_Buffer,
	uniform_data:          Compute_Uniform_Data,
}
compute: Compute

Compute_Particle :: struct {
	pos: [2]f32,
	vel: [2]f32,
	col: [3]f32,
}

prepare_compute :: proc()
{
	rs := &gpu.rs

	module: vk.ShaderModule = gpu.compile_compute_shader_module(
		"src/shaders/compute.slang",
		"main",
	)
	compute_shader_stage_info_CI: vk.PipelineShaderStageCreateInfo = {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = module,
		pName  = "main",
	}
	// initialize particles
	particles := new([NUM_PARTICLES]Compute_Particle)
	for &particle in particles {
		r: f32 = 0.25 * math.sqrt(rand.float32())
		theta := rand.float32() * 2 * 3.14159265358979323846
		x := r * math.cos(theta) * 600 / 800
		y := r * math.sin(theta)
		particle.pos = {x, y}
		particle.vel = {x, y} * 0.00025
		particle.col = {rand.float32(), rand.float32(), rand.float32()}
	}

	// Create the storage buffers
	for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
		compute.storage_buffers[i] = gpu.create_buffer(
			size_of(Compute_Particle) * NUM_PARTICLES,
			{.STORAGE_BUFFER, .VERTEX_BUFFER, .TRANSFER_DST},
			{.DEVICE_LOCAL},
		)
		// bit inefficient to create multiple staging buffers for this, but it's fine.
		gpu.staging_write_buffer_slice(&compute.storage_buffers[i], particles[:], 0)
	}

	// create the uniform buffers
	for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
		compute.uniform_buffers[i] = gpu.create_buffer(
			size_of(Compute_Uniform_Data),
			{.UNIFORM_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
	}

	// Set up the descriptors
	layout_bindings: [3]vk.DescriptorSetLayoutBinding = {}

	layout_bindings[0].binding = 0
	layout_bindings[0].descriptorCount = 1
	layout_bindings[0].descriptorType = .UNIFORM_BUFFER
	layout_bindings[0].pImmutableSamplers = nil
	layout_bindings[0].stageFlags = {.COMPUTE}

	layout_bindings[1].binding = 1
	layout_bindings[1].descriptorCount = 1
	layout_bindings[1].descriptorType = .STORAGE_BUFFER
	layout_bindings[1].pImmutableSamplers = nil
	layout_bindings[1].stageFlags = {.COMPUTE}

	layout_bindings[2].binding = 2
	layout_bindings[2].descriptorCount = 1
	layout_bindings[2].descriptorType = .STORAGE_BUFFER
	layout_bindings[2].pImmutableSamplers = nil
	layout_bindings[2].stageFlags = {.COMPUTE}

	layout_CI: vk.DescriptorSetLayoutCreateInfo = {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 3,
		pBindings    = raw_data(layout_bindings[:]),
	}

	gpu.vk_check(
		vk.CreateDescriptorSetLayout(rs.device, &layout_CI, nil, &compute.descriptor_set_layout),
	)

	for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
		uniform_buffer_info: vk.DescriptorBufferInfo = {
			buffer = compute.uniform_buffers[i].buffer,
			offset = 0,
			range  = size_of(Compute_Uniform_Data),
		}
		storage_buffer_info_last_frame := vk.DescriptorBufferInfo {
			buffer = compute.storage_buffers[(i - 1) % gpu.FRAMES_IN_FLIGHT].buffer,
			offset = 0,
			range  = size_of(Compute_Particle) * NUM_PARTICLES,
		}
		storage_buffer_info_current_frame := vk.DescriptorBufferInfo {
			buffer = compute.storage_buffers[i].buffer,
			offset = 0,
			range  = size_of(Compute_Particle) * NUM_PARTICLES,
		}
		descriptor_writes: [3]vk.WriteDescriptorSet = {
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = compute.descriptor_sets[i],
				dstBinding = 0,
				dstArrayElement = 0,
				descriptorType = .UNIFORM_BUFFER,
				descriptorCount = 1,
				pBufferInfo = &uniform_buffer_info,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = compute.descriptor_sets[i],
				dstBinding = 0,
				dstArrayElement = 0,
				descriptorType = .STORAGE_BUFFER,
				descriptorCount = 1,
				pBufferInfo = &storage_buffer_info_last_frame,
			},
			{
				sType = .WRITE_DESCRIPTOR_SET,
				dstSet = compute.descriptor_sets[i],
				dstBinding = 2,
				dstArrayElement = 0,
				descriptorType = .STORAGE_BUFFER,
				descriptorCount = 1,
				pBufferInfo = &storage_buffer_info_current_frame,
			},
		}
		vk.UpdateDescriptorSets(rs.device, 3, raw_data(descriptor_writes[:]), 0, nil)
	}

	// Create descriptor pool
	pool_sizes: [2]vk.DescriptorPoolSize
	pool_sizes[0] = {
		type            = .UNIFORM_BUFFER,
		descriptorCount = gpu.FRAMES_IN_FLIGHT,
	}
	pool_sizes[1] = {
		type            = .STORAGE_BUFFER,
		descriptorCount = gpu.FRAMES_IN_FLIGHT * 2,
	}
	pool_CI: vk.DescriptorPoolCreateInfo = {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = 2,
		pPoolSizes    = raw_data(pool_sizes[:]),
		maxSets       = gpu.FRAMES_IN_FLIGHT,
	}
	gpu.vk_check(vk.CreateDescriptorPool(rs.device, &pool_CI, nil, &compute.descriptor_pool))

	// Create compute pipeline
	pipeline_layout_CI: vk.PipelineLayoutCreateInfo = {
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts    = &compute.descriptor_set_layout,
	}
	gpu.vk_check(
		vk.CreatePipelineLayout(rs.device, &pipeline_layout_CI, nil, &compute.pipeline_layout),
	)
	pipeline_CI: vk.ComputePipelineCreateInfo = {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		layout = compute.pipeline_layout,
		stage  = compute_shader_stage_info_CI,
	}

	gpu.vk_check(vk.CreateComputePipelines(rs.device, 0, 1, &pipeline_CI, nil, &compute.pipeline))

}


prepare_compute_old :: proc()
{
	// TODO when allow a separate queue for compute, must also create a separate cmd pool

	// Create fences
	for &fence in compute.fences {
		fence_create_info: vk.FenceCreateInfo = {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		gpu.vk_check(vk.CreateFence(gpu.rs.device, &fence_create_info, nil, &fence))
	}

	// Populate the uniform buffers
	for i in 0 ..< len(compute.uniform_buffers) {
		compute.uniform_buffers[i] = gpu.create_buffer(
			vk.DeviceSize(size_of(Compute_Uniform_Data)),
			{.UNIFORM_BUFFER},
			{.HOST_COHERENT, .HOST_VISIBLE},
		)
		// Create the buffers to actually store the particles
		// TODO write the data into the buffer when intializing the simulation
		compute.storage_buffers[i] = gpu.create_buffer(
			NUM_PARTICLES * size_of(Particle),
			{.STORAGE_BUFFER, .TRANSFER_DST},
			{.DEVICE_LOCAL},
		)
	}

	init_descriptor_sets_old()

	module: vk.ShaderModule = gpu.compile_shader_module(
		"src/shaders/compute.slang",
		"vertexmain",
		"fragmentmain",
	)
	init_compute_pipeline_old(module)
}

init_compute_pipeline_old :: proc(module: vk.ShaderModule)
{
	// Create the pipeline cache
	pipeline_cache_CI: vk.PipelineCacheCreateInfo = {
		sType = .PIPELINE_CACHE_CREATE_INFO,
	}
	gpu.vk_check(
		vk.CreatePipelineCache(gpu.rs.device, &pipeline_cache_CI, nil, &compute.pipeline_cache),
	)

	pipeline_layout_CI: vk.PipelineLayoutCreateInfo = {
		sType          = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts    = &compute.descriptor_set_layout,
	}

	gpu.vk_check(
		vk.CreatePipelineLayout(gpu.rs.device, &pipeline_layout_CI, nil, &compute.pipeline_layout),
	)

	shader_stage_CI: vk.PipelineShaderStageCreateInfo = {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		pName  = "main",
		module = module,
	}
	compute_pipeline_CI: vk.ComputePipelineCreateInfo = {
		sType             = .COMPUTE_PIPELINE_CREATE_INFO,
		layout            = compute.pipeline_layout,
		basePipelineIndex = 0, // TODO is this correct?
		stage             = compute_shader_stage_info_CI,
	}
	// TODO does this require a pipeline cache??
	gpu.vk_check(
		vk.CreateComputePipelines(
			gpu.rs.device,
			compute.pipeline_cache,
			1,
			&compute_pipeline_CI,
			nil,
			&compute.pipeline,
		),
	)
}

init_descriptor_sets_old :: proc()
{
	layoutBindings: []vk.DescriptorSetLayoutBinding = {
		{
			binding            = 0,
			descriptorType     = .STORAGE_BUFFER,
			descriptorCount    = 1, // max number textures
			stageFlags         = {.COMPUTE, .VERTEX, .FRAGMENT},
			pImmutableSamplers = nil,
		},
		{
			binding            = 1,
			descriptorType     = .STORAGE_BUFFER,
			descriptorCount    = 1, // max number textures
			stageFlags         = {.COMPUTE, .VERTEX, .FRAGMENT},
			pImmutableSamplers = nil,
		},
		{
			binding            = 2,
			descriptorType     = .UNIFORM_BUFFER,
			descriptorCount    = 1, // max number textures
			stageFlags         = {.COMPUTE, .VERTEX, .FRAGMENT},
			pImmutableSamplers = nil,
		},
	}
	layout_info: vk.DescriptorSetLayoutCreateInfo = {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 3,
		pBindings    = &layoutBindings[0],
	}
	gpu.vk_check(
		vk.CreateDescriptorSetLayout(
			gpu.rs.device,
			&layout_info,
			nil,
			&compute.descriptor_set_layout,
		),
	)

	// allocate the descriptor sets
	pool_sizes: []vk.DescriptorPoolSize = {
		{.UNIFORM_BUFFER, gpu.FRAMES_IN_FLIGHT * 2},
		{.STORAGE_BUFFER, gpu.FRAMES_IN_FLIGHT * 4},
		{.COMBINED_IMAGE_SAMPLER, gpu.FRAMES_IN_FLIGHT * 2},
	}
	descriptor_pool_CI: vk.DescriptorPoolCreateInfo = {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		pPoolSizes    = &pool_sizes[0],
		poolSizeCount = u32(len(pool_sizes)),
		maxSets       = gpu.FRAMES_IN_FLIGHT,
	}
	gpu.vk_check(
		vk.CreateDescriptorPool(gpu.rs.device, &descriptor_pool_CI, nil, &compute.descriptor_pool),
	)

	for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
		alloc_info: vk.DescriptorSetAllocateInfo = {
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			pNext              = nil,
			descriptorPool     = compute.descriptor_pool,
			pSetLayouts        = &compute.descriptor_set_layout,
			descriptorSetCount = 1,
		}
		gpu.vk_check(
			vk.AllocateDescriptorSets(gpu.rs.device, &alloc_info, &compute.descriptor_sets[i]),
		)
	}

	for i in 0 ..< gpu.FRAMES_IN_FLIGHT {
		// Create the buffer info
		compute_write_descriptor_sets: []vk.WriteDescriptorSet = {
			// We bind the descriptor set of the previous storage buffer because this is the "input" to the system.
			{
				sType = .WRITE_DESCRIPTOR_SET,
				descriptorType = .STORAGE_BUFFER,
				descriptorCount = 1,
				dstBinding = 0,
				dstSet = compute.descriptor_sets[i],
				pBufferInfo = &compute.storage_buffers[(gpu.FRAMES_IN_FLIGHT - 2 + i) % gpu.FRAMES_IN_FLIGHT].descriptor_info,
			},
			// This is the "output" of this frame
			{
				sType = .WRITE_DESCRIPTOR_SET,
				descriptorType = .STORAGE_BUFFER,
				descriptorCount = 1,
				dstBinding = 1,
				dstSet = compute.descriptor_sets[i],
				pBufferInfo = &compute.storage_buffers[i].descriptor_info,
			},
			// This holds the data we need for this frame's calculations
			{
				sType = .WRITE_DESCRIPTOR_SET,
				descriptorType = .UNIFORM_BUFFER,
				descriptorCount = 1,
				dstBinding = 2,
				dstSet = compute.descriptor_sets[i],
				pBufferInfo = &compute.uniform_buffers[i].descriptor_info,
			},
		}
		vk.UpdateDescriptorSets(
			gpu.rs.device,
			u32(len(compute_write_descriptor_sets)),
			&compute_write_descriptor_sets[0],
			0,
			nil,
		)
	}
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
