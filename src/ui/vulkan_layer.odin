package ui
// TODO should all vulkan access be wrapped by this?
import gpu "../gpu"
import "core:fmt"
import "core:math/linalg/glsl"
import "core:slice"
import "core:time"
import fs "vendor:fontstash"
import Vk "vendor:vulkan"

// config used to initialize the render context.
UI_Context :: struct {
	pipeline_layout:   Vk.PipelineLayout,
	pipeline:          Vk.Pipeline,
	gpu_constants:     Buffer_Descriptor,
	pos_buffer:        gpu.GPU_Buffer,
	col_buffer:        gpu.GPU_Buffer,
	uvs_buffer:        gpu.GPU_Buffer,
	ids_buffer:        gpu.GPU_Buffer,
	font_atlas:        gpu.GPU_Texture,
	descriptor_layout: Vk.DescriptorSetLayout,
	descriptor_set:    Vk.DescriptorSet,
	descriptor_pool:   Vk.DescriptorPool,
}

// TODO interleave?
Buffer_Descriptor :: struct {
	world_matrix: matrix[4, 4]f32,
	pos_buffer:   Vk.DeviceAddress,
	col_buffer:   Vk.DeviceAddress,
	uvs_buffer:   Vk.DeviceAddress,
	ids_buffer:   Vk.DeviceAddress,
}

Submit_Args :: struct {
	cmd:       Vk.CommandBuffer,
	imm_cmd:   Vk.CommandBuffer,
	imm_fence: ^Vk.Fence,
}

uc: UI_Context

// All GPU operations rely entirely on the GPU abstraction layer
// If we every need a separate vulkan instance (no idea why we would) then this must be passed as an argument to the init and stored in the UI context.
backend_init :: proc()
{
	uc.gpu_constants = Buffer_Descriptor {
		world_matrix = glsl.mat4Ortho3d(
			0, //f32(s.config.width) / 2,
			2 * f32(s.config.width) / 2,
			0,
			// f32(s.config.height) / 2,
			2 * f32(s.config.height) / 2,
			-100,
			100,
		),
		pos_buffer   = 0,
		col_buffer   = 0,
		uvs_buffer   = 0,
	}
	// Create the descriptor pool
	{
		pool_size: Vk.DescriptorPoolSize = {
			descriptorCount = 1000,
			type            = .COMBINED_IMAGE_SAMPLER,
		}

		pool_create_info: Vk.DescriptorPoolCreateInfo = {
			sType         = .DESCRIPTOR_POOL_CREATE_INFO,
			flags         = {.UPDATE_AFTER_BIND_EXT},
			maxSets       = 1000,
			poolSizeCount = 1,
			pPoolSizes    = &pool_size,
		}
		gpu.vk_check(
			Vk.CreateDescriptorPool(gpu.rs.device, &pool_create_info, nil, &uc.descriptor_pool),
		)
	}


	// Create the texture binding (descriptor layout + set)
	{

		descriptor_set_layout_binding: Vk.DescriptorSetLayoutBinding = {
			binding            = 0,
			descriptorType     = .COMBINED_IMAGE_SAMPLER,
			descriptorCount    = 1000, // max number textures
			stageFlags         = {.FRAGMENT, .VERTEX},
			pImmutableSamplers = nil,
		}
		binding_flags: Vk.DescriptorBindingFlags = {
			.PARTIALLY_BOUND,
			.VARIABLE_DESCRIPTOR_COUNT_EXT,
			.UPDATE_AFTER_BIND,
		}
		extra_create_info: Vk.DescriptorSetLayoutBindingFlagsCreateInfoEXT = {
			sType         = .DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO_EXT,
			bindingCount  = 1,
			pBindingFlags = &binding_flags,
		}
		descriptor_set_layout_create_info: Vk.DescriptorSetLayoutCreateInfo = {
			sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = 1,
			pBindings    = &descriptor_set_layout_binding,
			flags        = {.UPDATE_AFTER_BIND_POOL_EXT},
			pNext        = &extra_create_info,
		}

		Vk.CreateDescriptorSetLayout(
			gpu.rs.device,
			&descriptor_set_layout_create_info,
			nil,
			&uc.descriptor_layout,
		)

		max_binding: u32 = 1000
		count_info: Vk.DescriptorSetVariableDescriptorCountAllocateInfoEXT = {
			sType              = .DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO_EXT,
			descriptorSetCount = 1,
			pDescriptorCounts  = &max_binding,
		}
		alloc_info: Vk.DescriptorSetAllocateInfo = {
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool     = uc.descriptor_pool,
			descriptorSetCount = 1,
			pSetLayouts        = &uc.descriptor_layout,
			pNext              = &count_info,
		}
		gpu.vk_check(Vk.AllocateDescriptorSets(gpu.rs.device, &alloc_info, &uc.descriptor_set))
	}
	// Create the font atlas
	{
		image_size := Vk.DeviceSize(s.font_ctx.width * s.font_ctx.height * 1)
		image_format: Vk.Format = .R8_UNORM

		uc.font_atlas = gpu.create_image(
			u32(s.font_ctx.width),
			u32(s.font_ctx.height),
			.R8_UNORM,
			{.TRANSFER_DST, .SAMPLED},
			{.COLOR},
			{.DEVICE_LOCAL},
		)
		sampler_create_info: Vk.SamplerCreateInfo = {
			sType                   = .SAMPLER_CREATE_INFO,
			addressModeU            = .REPEAT,
			addressModeV            = .REPEAT,
			addressModeW            = .REPEAT,
			unnormalizedCoordinates = false,
		}
		gpu.vk_check(
			Vk.CreateSampler(gpu.rs.device, &sampler_create_info, nil, &uc.font_atlas.sampler),
		)
		// Bind the font atlas into descriptor set position 0
		image_info: Vk.DescriptorImageInfo = {
			imageLayout = .SHADER_READ_ONLY_OPTIMAL,
			imageView   = uc.font_atlas.view,
			sampler     = uc.font_atlas.sampler,
		}
		write_set: Vk.WriteDescriptorSet = {
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = uc.descriptor_set,
			dstBinding      = 0,
			dstArrayElement = 0,
			descriptorCount = 1,
			descriptorType  = .COMBINED_IMAGE_SAMPLER,
			pImageInfo      = &image_info,
		}
		Vk.UpdateDescriptorSets(gpu.rs.device, 1, &write_set, 0, nil)
		s.update_font_atlas = true
	}
	module: Vk.ShaderModule = gpu.compile_shader_module(
		"src/ui/ui_shader.slang",
		"vertexmain",
		"fragmentmain",
	)

	uc.pipeline_layout, uc.pipeline = create_ui_pipeline(module)
}

backend_resize :: proc()
{unimplemented()}


// TODO grab the active buffer from the gpu render context, and swap it back when done

// the user MUST rebind their pipeline buffer after this, or else everything breaks.
// There should be a way to handle that better but I don't know what it is
backend_render :: proc(
	pos: [dynamic][2]f32,
	col: [dynamic][4]f32,
	uvs: [dynamic][2]f32,
	ids: [dynamic]i32,
	scissors: [dynamic]Scissor_Section,
	args: Submit_Args,
)
{
	// switch to the ui pipeline
	Vk.CmdBindPipeline(args.cmd, .GRAPHICS, uc.pipeline)

	// Check if the buffers are big enough, if not replace them
	if len(pos) > int(uc.pos_buffer.size) {
		Vk.WaitForFences(gpu.rs.device, 1, args.imm_fence, true, 1000_000_000)
		Vk.DestroyBuffer(gpu.rs.device, uc.pos_buffer.buffer, nil)
		Vk.FreeMemory(gpu.rs.device, uc.pos_buffer.memory, nil)
		Vk.DestroyBuffer(gpu.rs.device, uc.col_buffer.buffer, nil)
		Vk.FreeMemory(gpu.rs.device, uc.col_buffer.memory, nil)
		Vk.DestroyBuffer(gpu.rs.device, uc.uvs_buffer.buffer, nil)
		Vk.FreeMemory(gpu.rs.device, uc.uvs_buffer.memory, nil)
		Vk.DestroyBuffer(gpu.rs.device, uc.ids_buffer.buffer, nil)
		Vk.FreeMemory(gpu.rs.device, uc.ids_buffer.memory, nil)
		uc.pos_buffer = gpu.create_buffer(
			Vk.DeviceSize(size_of(pos[0]) * len(pos) * 2),
			{.TRANSFER_DST, .VERTEX_BUFFER},
			{.DEVICE_LOCAL},
		)
		uc.col_buffer = gpu.create_buffer(
			Vk.DeviceSize(size_of(col[0]) * len(col) * 2),
			{.TRANSFER_DST, .VERTEX_BUFFER},
			{.DEVICE_LOCAL},
		)
		uc.uvs_buffer = gpu.create_buffer(
			Vk.DeviceSize(size_of(uvs[0]) * len(uvs) * 2),
			{.TRANSFER_DST, .VERTEX_BUFFER},
			{.DEVICE_LOCAL},
		)
		uc.ids_buffer = gpu.create_buffer(
			Vk.DeviceSize(size_of(ids[0]) * len(ids) * 2),
			{.TRANSFER_DST, .VERTEX_BUFFER},
			{.DEVICE_LOCAL},
		)
		// TODO need different architecture to get around this.
		pos_buffer_address_info := Vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = uc.pos_buffer.buffer,
		}

		col_buffer_address_info := Vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = uc.col_buffer.buffer,
		}

		uvs_buffer_address_info := Vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = uc.uvs_buffer.buffer,
		}

		ids_buffer_address_info := Vk.BufferDeviceAddressInfo {
			sType  = .BUFFER_DEVICE_ADDRESS_INFO,
			buffer = uc.ids_buffer.buffer,
		}
		uc.gpu_constants.pos_buffer = Vk.GetBufferDeviceAddress(
			gpu.rs.device,
			&pos_buffer_address_info,
		)
		uc.gpu_constants.col_buffer = Vk.GetBufferDeviceAddress(
			gpu.rs.device,
			&col_buffer_address_info,
		)
		uc.gpu_constants.uvs_buffer = Vk.GetBufferDeviceAddress(
			gpu.rs.device,
			&uvs_buffer_address_info,
		)
		uc.gpu_constants.ids_buffer = Vk.GetBufferDeviceAddress(
			gpu.rs.device,
			&ids_buffer_address_info,
		)
	}

	// Writes all of the data do the buffer. This needs to be done every frame (why?)
	gpu.staging_write_buffer_slice(&uc.pos_buffer, pos[:], 0)
	gpu.staging_write_buffer_slice(&uc.col_buffer, col[:], 0)
	gpu.staging_write_buffer_slice(&uc.uvs_buffer, uvs[:], 0)
	gpu.staging_write_buffer_slice(&uc.ids_buffer, ids[:], 0)
	offsets: [4]Vk.DeviceSize = {0, 0, 0, 0}
	buffers: [4]Vk.Buffer = {
		uc.pos_buffer.buffer,
		uc.col_buffer.buffer,
		uc.uvs_buffer.buffer,
		uc.ids_buffer.buffer,
	}

	update_atlas(args.imm_cmd, args.imm_fence)

	Vk.CmdPushConstants(
		args.cmd,
		uc.pipeline_layout,
		{.VERTEX},
		0,
		size_of(Buffer_Descriptor),
		&uc.gpu_constants,
	)

	Vk.CmdBindVertexBuffers(args.cmd, 0, 4, &buffers[0], &offsets[0])

	Vk.CmdBindDescriptorSets(
		args.cmd,
		.GRAPHICS,
		uc.pipeline_layout,
		0,
		1,
		&uc.descriptor_set,
		0,
		nil,
	)

	offset: u32 = 0
	default_bounds: Vk.Rect2D = {
		offset = {x = i32(s.config.x), y = i32(s.config.y)},
		extent = {u32(s.config.width), u32(s.config.height)},
	}
	// Scisccor rectangle occur in screen space in pixel coordinates
	Vk.CmdSetScissor(args.cmd, 0, 1, &default_bounds)
	for &section in scissors {
		if section.offset == offset {continue}
		// draw up to the next scissor boundary
		Vk.CmdDraw(args.cmd, section.offset - offset, 1, offset, 0)
		// scissor on start, and clear on end, or if width <= 0
		if section.type == .START && section.bounds[2] > 0 {
			scissor_width: u32 = min(u32(s.config.width), u32(section.bounds[2]))
			scissor_height: u32 = min(u32(s.config.height), u32(section.bounds[3]))
			bounds: Vk.Rect2D = {
				offset = {i32(section.bounds.x), i32(section.bounds.y)},
				extent = {scissor_width, scissor_height},
			}
			Vk.CmdSetScissor(args.cmd, 0, 1, &bounds)
		} else {
			Vk.CmdSetScissor(args.cmd, 0, 1, &default_bounds)
		}
		offset = section.offset
	}
	Vk.CmdSetScissor(args.cmd, 0, 1, &default_bounds)
	Vk.CmdDraw(args.cmd, u32(len(pos)) - offset, 1, offset, 0)
}

create_ui_pipeline :: proc(module: Vk.ShaderModule) -> (Vk.PipelineLayout, Vk.Pipeline)
{
	buffer_range := Vk.PushConstantRange {
		offset     = 0,
		size       = size_of(Buffer_Descriptor),
		stageFlags = {.VERTEX},
	}

	pipeline_layout_info := Vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pNext                  = nil,
		flags                  = {},
		setLayoutCount         = 1,
		pSetLayouts            = &uc.descriptor_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &buffer_range,
	}
	// Create pipelines and pipeline layouts
	pipeline_layout: Vk.PipelineLayout
	gpu.vk_check(
		Vk.CreatePipelineLayout(gpu.rs.device, &pipeline_layout_info, nil, &pipeline_layout),
	)

	pipelineInfo := Vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &Vk.PipelineRenderingCreateInfo {
			sType = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount = 1,
			pColorAttachmentFormats = &gpu.rs.draw_image.format,
			depthAttachmentFormat = gpu.rs.depth_image.format,
		},
		pStages             = raw_data(
			[]Vk.PipelineShaderStageCreateInfo {
				{
					sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
					stage = {.VERTEX},
					module = module,
					pName = "vertexmain",
				},
				{
					sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
					stage = {.FRAGMENT},
					module = module,
					pName = "fragmentmain",
				},
			},
		),
		stageCount          = 2,
		pVertexInputState   = &{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO},
		pInputAssemblyState = &{
			sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
			topology = .TRIANGLE_LIST,
			primitiveRestartEnable = false,
		},
		pViewportState      = &{
			sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
			viewportCount = 1,
			scissorCount = 1,
		},
		pRasterizationState = &{
			sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
			polygonMode = .FILL,
			lineWidth = 1,
			frontFace = .COUNTER_CLOCKWISE,
		},
		pMultisampleState   = &{
			sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
			sampleShadingEnable = false,
			rasterizationSamples = {._1},
			minSampleShading = 1.0,
			pSampleMask = nil,
			alphaToCoverageEnable = false,
			alphaToOneEnable = false,
		},
		pColorBlendState    = &{
			sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
			logicOpEnable = false,
			logicOp = .COPY,
			attachmentCount = 1,
			pAttachments = &Vk.PipelineColorBlendAttachmentState {
				colorWriteMask = {.R, .G, .B, .A},
				blendEnable = true,
				srcColorBlendFactor = .SRC_ALPHA,
				dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
				colorBlendOp = .ADD,
				srcAlphaBlendFactor = .ONE,
				dstAlphaBlendFactor = .ZERO,
				alphaBlendOp = .ADD,
			},
		},
		pDepthStencilState  = &{
			sType = .PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
			depthTestEnable = true,
			depthWriteEnable = true,
			depthCompareOp = .LESS_OR_EQUAL,
			depthBoundsTestEnable = false,
			stencilTestEnable = false,
			front = {},
			back = {},
			minDepthBounds = 0.0,
			maxDepthBounds = 1.0,
		},
		layout              = pipeline_layout,
		pDynamicState       = &{
			sType = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
			pDynamicStates = raw_data([]Vk.DynamicState{.VIEWPORT, .SCISSOR}),
			dynamicStateCount = 2,
		},
	}

	pipeline: Vk.Pipeline

	if Vk.CreateGraphicsPipelines(gpu.rs.device, 0, 1, &pipelineInfo, nil, &pipeline) != .SUCCESS {
		fmt.println("Couldn't create graphics pipeline!")
		return {}, {}
	}

	// We don't need to keep the shader modules around
	Vk.DestroyShaderModule(gpu.rs.device, module, nil)

	return pipeline_layout, pipeline
}

update_atlas :: proc(cmd: Vk.CommandBuffer, fence: ^Vk.Fence)
{
	dirty_texture :=
		s.font_ctx.dirtyRect[0] < s.font_ctx.dirtyRect[2] &&
		s.font_ctx.dirtyRect[1] < s.font_ctx.dirtyRect[3]
	if dirty_texture {
		fs.__dirtyRectReset(&s.font_ctx)
		s.update_font_atlas = true
	}
	if s.update_font_atlas {
		fs.__AtlasAddWhiteRect(&s.font_ctx, 1, 1) // Required for loading shapes
		pixels: []byte = s.font_ctx.textureData
		if len(pixels) > 0 {
			// TODO if the font atlas grows, we need to adjust the size of the image accordingly
			// Right now the atlas keeps filling up with junk until it fills the entire image,
			// then it tries to grow (which is can't) and crashes. Need to allow resizing, and stop
			// it growing with garbage.
			gpu.staging_write_image(
				uc.font_atlas.image,
				pixels,
				u32(s.font_ctx.width),
				u32(s.font_ctx.height),
				.R8_UNORM,
				u32(s.font_ctx.width),
			)
		}
		s.update_font_atlas = false
	}
}

