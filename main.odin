package main

import "gpu"

import "core:os"
import "vendor:glfw"
import vk "vendor:vulkan"

main :: proc()
{
	rs: ^gpu.Renderer_State = &gpu.rs
	// set up the window and Vulkan
	{
		glfw.Init()
		glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
		glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
		rs.window = glfw.CreateWindow(800, 600, "Hello Triangle", nil, nil)
		gpu.init_vulkan()

		// Load shaders
		module: vk.ShaderModule = gpu.compile_shader_module("triangle.slang", "vertexmain", "fragmentmain")
		rs.pipeline_layout, rs.pipeline = gpu.create_pipeline(module)
		assert(rs.pipeline != 0, "Couldn't load shaders!")
	}

	current_last_write_time, ok := os.last_write_time_by_name("triangle.slang")
	assert(ok == nil)

	// Create index buffer
	indices := [?]u32{0, 1, 2, 2, 3, 0}

	indices_buffer := gpu.create_buffer(auto_cast size_of(indices), {.INDEX_BUFFER, .TRANSFER_DST})
	gpu.staging_write_buffer_slice(&indices_buffer, indices[:])

	for !glfw.WindowShouldClose(rs.window) {
		glfw.PollEvents()

		last_write_time, err := os.last_write_time_by_name("example/triangle.slang")

		// Hot reload shader
		{
			if err == nil && current_last_write_time != last_write_time {
				vk.DestroyPipelineLayout(rs.device, rs.pipeline_layout, nil)
				vk.DestroyPipeline(rs.device, rs.pipeline, nil)
				for i in 0 ..< gpu.FRAME_OVERLAP {
					gpu.vk_check(vk.WaitForFences(rs.device, 1, &rs.frames[i].render_fence, true, 1_000_000_000))
				}

				module: vk.ShaderModule = gpu.compile_shader_module("triangle.slang", "vertexmain", "fragmentmain")
				rs.pipeline_layout, rs.pipeline = gpu.create_pipeline(module)
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
		vk.CmdBindIndexBuffer(cmd, indices_buffer.buffer, 0, .UINT32)

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
