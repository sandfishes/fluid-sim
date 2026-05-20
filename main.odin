package main

import "gpu"

import la "core:math/linalg"
import "core:os"
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

main :: proc()
{
	rs: ^gpu.Renderer_State = &gpu.rs
	// set up the window and Vulkan

	// TODO move this layout info somewhere
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

	{
		glfw.Init()
		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)

		rs.window = glfw.CreateWindow(800, 600, "Hello Triangle", nil, nil)
		gpu.init_vulkan()

		// Load shaders
		module: vk.ShaderModule = gpu.compile_shader_module("triangle.slang", "vertexmain", "fragmentmain")
		rs.pipeline_layout, rs.pipeline = gpu.create_pipeline(module, pipeline_layout_info)
		assert(rs.pipeline != 0, "Couldn't load shaders!")
	}

	current_last_write_time, ok := os.last_write_time_by_name("triangle.slang")
	assert(ok == nil)

	// Create index buffer
	indices := [?]u32{0, 1, 2, 2, 3, 0}
	indices_buffer := gpu.create_buffer(auto_cast size_of(indices), {.INDEX_BUFFER, .TRANSFER_DST})
	gpu.staging_write_buffer_slice(&indices_buffer, indices[:])

	Vertex :: struct {
		position: [3]f32,
		color:    [4]f32,
	}

	vertices := [?]Vertex {
		{{-0.5, -0.5, 0.0}, {1.0, 0.0, 0.0, 1.0}},
		{{-0.5, 0.5, 0.0}, {0.0, 1.0, 0.0, 1.0}},
		{{0.5, 0.5, 0.0}, {0.0, 0.0, 1.0, 1.0}},
	}

	vertex_buffer := gpu.create_buffer(auto_cast size_of(vertices), {.VERTEX_BUFFER, .TRANSFER_DST})
	mesh := Buffer_Struct{indices_buffer, vertex_buffer, 0}
	vertex_buffer_address_info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = mesh.vertex_buffer.buffer,
	}
	mesh.vertex_buffer_address = vk.GetBufferDeviceAddress(rs.device, &vertex_buffer_address_info)

	for !glfw.WindowShouldClose(rs.window) {
		glfw.PollEvents()

		last_write_time, err := os.last_write_time_by_name("triangle.slang")

		// Hot reload shader
		{
			if err == nil && current_last_write_time != last_write_time {
				vk.DestroyPipelineLayout(rs.device, rs.pipeline_layout, nil)
				vk.DestroyPipeline(rs.device, rs.pipeline, nil)
				for i in 0 ..< gpu.FRAME_OVERLAP {
					gpu.vk_check(vk.WaitForFences(rs.device, 1, &rs.frames[i].render_fence, true, 1_000_000_000))
				}

				module: vk.ShaderModule = gpu.compile_shader_module("triangle.slang", "vertexmain", "fragmentmain")
				rs.pipeline_layout, rs.pipeline = gpu.create_pipeline(module, pipeline_layout_info)
				assert(rs.pipeline != 0, "Couldn't load shaders!")
				current_last_write_time = last_write_time
			}
		}

		// Wait until we can access the current frame
		{
			gpu.vk_check(vk.WaitForFences(rs.device, 1, &gpu.current_frame().render_fence, true, 1_000_000_000))
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
		}

		cmd := gpu.current_frame().main_command_buffer
		// reset and init the command buffer
		{
			gpu.vk_check(vk.ResetCommandBuffer(gpu.current_frame().main_command_buffer, {.RELEASE_RESOURCES}))
			cmd_begin_info := vk.CommandBufferBeginInfo {
				sType            = .COMMAND_BUFFER_BEGIN_INFO,
				pNext            = nil,
				pInheritanceInfo = nil,
				flags            = {.ONE_TIME_SUBMIT},
			}
			gpu.vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info))
		}

		// Start drawing
		gpu.begin_render_pass()

		vk.CmdBindPipeline(cmd, .GRAPHICS, rs.pipeline)

		push_constants := GPU_Draw_Push_Constants {
			world_matrix  = la.MATRIX4F32_IDENTITY,
			vertex_buffer = mesh.vertex_buffer_address,
		}

		vk.CmdPushConstants(cmd, rs.pipeline_layout, {.VERTEX}, 0, size_of(GPU_Draw_Push_Constants), &push_constants)
		gpu.staging_write_buffer_slice(&vertex_buffer, vertices[:]) // Why every frame?

		vk.CmdBindIndexBuffer(cmd, mesh.index_buffer.buffer, 0, .UINT32)
		// Draw triangle
		vk.CmdDrawIndexed(cmd, 3, 1, 0, 0, 0)

		vk.CmdEndRenderingKHR(cmd)

		// End drawing
		gpu.end_render_pass()

		// present the swapchain to the screen
		{
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

		rs.frame_number += 1
	}

	// Cleanup our stuff
	vk.DeviceWaitIdle(rs.device)

	vk.DestroyBuffer(rs.device, indices_buffer.buffer, nil)
	vk.FreeMemory(rs.device, indices_buffer.memory, nil)

	vk.DestroyPipeline(rs.device, rs.pipeline, nil)
	vk.DestroyPipelineLayout(rs.device, rs.pipeline_layout, nil)

	// Cleanup rest of vulkan
	gpu.vulkan_shutdown()

}
