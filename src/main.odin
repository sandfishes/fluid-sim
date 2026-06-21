package marching2d

// NOTE
// On linux you MUST add the src/gpu/slang/lib folder to LD_LIBRARY_PATH or else
// slang will not be able to compile the shaders.
import "core:math/rand"
import geom "geometry"

import "gpu"

import "base:runtime"
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

