package gpu
/*
	Credits go to https://github.com/wrapperup
*/

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"


// Slang bindings
import sl "slang"


when ODIN_OS == .Darwin {
	// NOTE: just a bogus import of the system library,
	// needed so we can add a linker flag to point to /usr/local/lib (where vulkan is installed by default)
	// when trying to load vulkan.
	@(require, extra_linker_flags = "-rpath /usr/local/lib")
	foreign import __ "system:System.framework"
}

/* Ensure that slang compilation succeeded without any errors */
slang_check :: #force_inline proc(#any_int result: int, loc := #caller_location)
{
	result: i32 = sl.Result(result)
	if sl.FAILED(result) {
		code: i32 = sl.GET_RESULT_CODE(result)
		facility: i32 = sl.GET_RESULT_FACILITY(result)
		estr: string
		switch sl.Result(result) {
		case:
			estr = "Unknown error"
		case sl.E_NOT_IMPLEMENTED():
			estr = "E_NOT_IMPLEMENTED"
		case sl.E_NO_INTERFACE():
			estr = "E_NO_INTERFACE"
		case sl.E_ABORT():
			estr = "E_ABORT"
		case sl.E_INVALID_HANDLE():
			estr = "E_INVALID_HANDLE"
		case sl.E_INVALID_ARG():
			estr = "E_INVALID_ARG"
		case sl.E_OUT_OF_MEMORY():
			estr = "E_OUT_OF_MEMORY"
		case sl.E_BUFFER_TOO_SMALL():
			estr = "E_BUFFER_TOO_SMALL"
		case sl.E_UNINITIALIZED():
			estr = "E_UNINITIALIZED"
		case sl.E_PENDING():
			estr = "E_PENDING"
		case sl.E_CANNOT_OPEN():
			estr = "E_CANNOT_OPEN"
		case sl.E_NOT_FOUND():
			estr = "E_NOT_FOUND"
		case sl.E_INTERNAL_FAIL():
			estr = "E_INTERNAL_FAIL"
		case sl.E_NOT_AVAILABLE():
			estr = "E_NOT_AVAILABLE"
		case sl.E_TIME_OUT():
			estr = "E_TIME_OUT"
		}

		fmt.panicf("Failed with error: %v (%v) Facility: %v", estr, code, facility, loc = loc)
	}
}

diagnostics_check :: #force_inline proc(diagnostics: ^sl.IBlob, loc := #caller_location)
{
	if diagnostics != nil {
		buffer := slice.bytes_from_ptr(diagnostics->getBufferPointer(), int(diagnostics->getBufferSize()))
		assert(false, string(buffer), loc)
	}
}

// Compiles the triangle.slang shader and creates the pipeline (or re-creates it if it exists)
compile_shader_module :: proc(path, vertex_main, fragment_main: cstring) -> vk.ShaderModule
{
	// time the compilation
	start_compile_time := time.tick_now()

	code, diagnostics: ^sl.IBlob
	r: sl.Result

	target_desc := sl.TargetDesc {
		structureSize = size_of(sl.TargetDesc),
		format        = .SPIRV,
		flags         = {.GENERATE_SPIRV_DIRECTLY},
		profile       = rs.slang_global_session->findProfile("sm_6_0"),
	}

	compiler_option_entries := [?]sl.CompilerOptionEntry{{name = .VulkanUseEntryPointName, value = {intValue0 = 1}}}

	session_desc := sl.SessionDesc {
		structureSize            = size_of(sl.SessionDesc),
		targets                  = &target_desc,
		targetCount              = 1,
		compilerOptionEntries    = &compiler_option_entries[0],
		compilerOptionEntryCount = 1,
	}

	session: ^sl.ISession
	slang_check(rs.slang_global_session->createSession(session_desc, &session))
	defer session->release()

	blob: ^sl.IBlob

	module: ^sl.IModule = session->loadModule(path, &diagnostics)
	if module == nil {
		fmt.println("Shader compile error!")
		return {}
	}
	defer module->release()
	diagnostics_check(diagnostics)

	vertex_entry: ^sl.IEntryPoint
	r = module->findEntryPointByName(vertex_main, &vertex_entry)
	slang_check(r)

	fragment_entry: ^sl.IEntryPoint
	r = module->findEntryPointByName(fragment_main, &fragment_entry)
	slang_check(r)

	if vertex_entry == nil {
		fmt.println("Expected 'vertexmain' entry point")
		return {}
	}
	if fragment_entry == nil {
		fmt.println("Expected 'fragmentmain' entry point")
		return {}
	}

	components := [3]^sl.IComponentType{module, vertex_entry, fragment_entry}

	linked_program: ^sl.IComponentType
	r = session->createCompositeComponentType(&components[0], len(components), &linked_program, &diagnostics)
	diagnostics_check(diagnostics)
	slang_check(r)

	target_code: ^sl.IBlob
	r = linked_program->getTargetCode(0, &target_code, &diagnostics)
	diagnostics_check(diagnostics)
	slang_check(r)

	code_size := target_code->getBufferSize()
	source_code := slice.bytes_from_ptr(target_code->getBufferPointer(), auto_cast code_size)

	info := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(source_code), // codeSize needs to be in bytes
		pCode    = raw_data(slice.reinterpret([]u32, source_code)), // code needs to be in 32bit words
	}

	vk_module: vk.ShaderModule
	vk_check(vk.CreateShaderModule(rs.device, &info, nil, &vk_module))

	duration_msec := time.tick_since(start_compile_time)
	fmt.println("Loaded shader in", duration_msec)

	return vk_module
}

///////////////////////////////////////////////////////////////////////////////////////////////////
// Vulkan impl

import "base:runtime"
import "core:c"
import "core:math/linalg"
import "core:math/linalg/hlsl"
import "core:mem"
import "core:reflect"

// Set required features to enable here. These are used to pick the physical device as well.
REQUIRED_FEATURES := vk.PhysicalDeviceFeatures2 {
	sType    = .PHYSICAL_DEVICE_FEATURES_2,
	pNext    = &REQUIRED_VK_11_FEATURES,
	features = {},
}

REQUIRED_VK_11_FEATURES := vk.PhysicalDeviceVulkan11Features {
	sType                         = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
	pNext                         = &REQUIRED_VK_12_FEATURES,
	variablePointers              = true,
	variablePointersStorageBuffer = true,
}

REQUIRED_VK_12_FEATURES := vk.PhysicalDeviceVulkan12Features {
	sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
	pNext = &REQUIRED_VK_13_FEATURES,
}

REQUIRED_VK_13_FEATURES := vk.PhysicalDeviceVulkan13Features {
	sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
	dynamicRendering = true,
	synchronization2 = true,
}

// Set required extensions to support.
DEVICE_EXTENSIONS := []cstring {
	vk.KHR_SWAPCHAIN_EXTENSION_NAME,
	vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME, // Enabled by default in 1.3
	vk.KHR_COPY_COMMANDS_2_EXTENSION_NAME, // Enabled by default in 1.3
	vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME, // Enabled by default in 1.3
	vk.KHR_SHADER_NON_SEMANTIC_INFO_EXTENSION_NAME, // Enabled by default in 1.3
}
// Set validation layers to enable.
VALIDATION_LAYERS := []cstring{"VK_LAYER_KHRONOS_validation"}

// Set validation features to enable.
VALIDATION_FEATURES := []vk.ValidationFeatureEnableEXT{.DEBUG_PRINTF}

// Number of frames to provide in flight.
FRAME_OVERLAP :: 2

/* Check the result of a Vulkan function call and provide diagnostics on failure (when in debug mode) */
vk_check :: proc(result: vk.Result, loc := #caller_location)
{
	p := context.assertion_failure_proc
	if result != .SUCCESS {
		when ODIN_DEBUG {
			p("vk_check failed", reflect.enum_string(result), loc)
		} else {
			p("vk_check failed", "NOT SUCCESS", loc)
		}
	}
}

/* callback that will be triggered when specific Vulkan functions fail. */
debug_callback :: proc "system" (
	message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user_data: rawptr,
) -> b32
{
	context = runtime.default_context()
	fmt.println(callback_data.pMessage)
	// print out which objects failed and triggered the callback
	for i in 0 ..< callback_data.objectCount {
		name := callback_data.pObjects[i].pObjectName

		if len(name) > 0 {
			fmt.println(" -", callback_data.pObjects[i].pObjectName)
		}
	}

	return false
}

/* Context for the Vulkan rs*/
Renderer_State :: struct {
	window:                 glfw.WindowHandle,
	debug_messenger:        vk.DebugUtilsMessengerEXT,
	enable_logs:            bool,
	instance:               vk.Instance,
	physical_device:        vk.PhysicalDevice,
	device:                 vk.Device,

	// Queues
	graphics_queue:         vk.Queue,
	graphics_queue_family:  u32,
	surface:                vk.SurfaceKHR,

	// Swapchain
	swapchain:              vk.SwapchainKHR,
	swapchain_images:       []vk.Image,
	swapchain_image_index:  u32,
	swapchain_image_views:  []vk.ImageView,
	swapchain_image_format: vk.Format,
	swapchain_extent:       vk.Extent2D,

	// Command Pool/Buffer
	frames:                 [FRAME_OVERLAP]FrameData,
	frame_number:           int,

	// Immediate submit
	imm_fence:              vk.Fence,
	imm_command_buffer:     vk.CommandBuffer,
	imm_command_pool:       vk.CommandPool,

	// Draw resources
	draw_image:             GPUImage,
	depth_image:            GPUImage,
	draw_extent:            vk.Extent2D,
	msaa_samples:           vk.SampleCountFlag,

	// Application resources
	pipeline_layout:        vk.PipelineLayout,
	pipeline:               vk.Pipeline,

	// Slang
	slang_global_session:   ^sl.IGlobalSession,
}

/* Global state for the rs. Used instead of passing it around to functions */
rs: Renderer_State

FrameData :: struct {
	swapchain_semaphore, render_semaphore: vk.Semaphore,
	render_fence:                          vk.Fence,
	command_pool:                          vk.CommandPool,
	main_command_buffer:                   vk.CommandBuffer,
}

GPUImage :: struct {
	image:      vk.Image,
	image_view: vk.ImageView,
	memory:     vk.DeviceMemory,
	extent:     vk.Extent3D,
	format:     vk.Format,
}

GPUBuffer :: struct {
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	size:   vk.DeviceSize,
}

/* Returns the framedata for the current frame. */
current_frame :: proc() -> ^FrameData
{
	return &rs.frames[rs.frame_number % FRAME_OVERLAP]
}

/* Create a command buffer for one time submit */
begin_immediate_submit :: proc() -> vk.CommandBuffer
{
	vk_check(vk.ResetFences(rs.device, 1, &rs.imm_fence))
	vk_check(vk.ResetCommandBuffer(rs.imm_command_buffer, {}))

	// Create the command buffer
	cmd := rs.imm_command_buffer
	cmd_begin_info := vk.CommandBufferBeginInfo {
		sType            = .COMMAND_BUFFER_BEGIN_INFO,
		pNext            = nil,
		pInheritanceInfo = nil,
		flags            = {.ONE_TIME_SUBMIT},
	}
	vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info))

	return cmd
}

/* Submit the one time command buffer. */
end_immediate_submit :: proc()
{
	cmd := rs.imm_command_buffer

	vk_check(vk.EndCommandBuffer(cmd))

	cmd_info := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		pNext         = nil,
		commandBuffer = cmd,
		deviceMask    = 0,
	}

	submit := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		pNext                    = nil,
		waitSemaphoreInfoCount   = 0,
		pWaitSemaphoreInfos      = nil,
		signalSemaphoreInfoCount = 0,
		pSignalSemaphoreInfos    = nil,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmd_info,
	}


	// submit command buffer to the queue and execute it.
	//  _renderFence will now block until the graphic commands finish execution
	vk_check(vk.QueueSubmit2KHR(rs.graphics_queue, 1, &submit, rs.imm_fence))

	vk_check(vk.WaitForFences(rs.device, 1, &rs.imm_fence, true, 9_999_999_999))
}

/* The memory type of the physical device. Integrated GPUs don't have dedicated VRAM and share with the CPU */
find_memory_type :: proc(
	physical_device: vk.PhysicalDevice,
	type_filter: u32,
	properties: vk.MemoryPropertyFlags,
) -> u32
{
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_properties)

	// Loop through all the available memory types, and check against the requested properties until we get one that
	// is a superset of the request properties.
	i: u32
	for i in 0 ..< mem_properties.memoryTypeCount {
		if (type_filter & (1 << i)) != 0 && (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {
			return i
		}
	}

	assert(false, "Couldn't find memory type.")
	return 0
}

/* Create a gpu side image that we can write to */
create_image :: proc(
	format: vk.Format,
	extent: vk.Extent3D,
	image_usage_flags: vk.ImageUsageFlags,
	properties: vk.MemoryPropertyFlags = {.DEVICE_LOCAL},
	tiling: vk.ImageTiling = .OPTIMAL,
	flags: vk.ImageCreateFlags = {},
) -> GPUImage
{
	gpu_image := GPUImage {
		format = format,
		extent = extent,
	}
	// Create the actual VkImage
	{
		img_info := vk.ImageCreateInfo {
			sType       = .IMAGE_CREATE_INFO,
			imageType   = .D2,
			format      = format,
			extent      = extent,
			mipLevels   = 1,
			arrayLayers = 1,
			tiling      = tiling,
			usage       = image_usage_flags,
			flags       = flags,
			samples     = {._1},
		}
		vk_check(vk.CreateImage(rs.device, &img_info, nil, &gpu_image.image))
	}

	// Allocate the memory for the image
	{
		mem_requirements: vk.MemoryRequirements
		vk.GetImageMemoryRequirements(rs.device, gpu_image.image, &mem_requirements)
		alloc_info := vk.MemoryAllocateInfo {
			sType           = .MEMORY_ALLOCATE_INFO,
			allocationSize  = mem_requirements.size,
			memoryTypeIndex = find_memory_type(rs.physical_device, mem_requirements.memoryTypeBits, properties),
		}
		vk_check(vk.AllocateMemory(rs.device, &alloc_info, nil, &gpu_image.memory))
		vk.BindImageMemory(rs.device, gpu_image.image, gpu_image.memory, 0)
	}

	return gpu_image
}

/* Create a view for the image which we can write to */
create_image_view :: proc(device: vk.Device, image: ^GPUImage, aspect_flags: vk.ImageAspectFlags)
{
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		viewType = .D2,
		image = image.image,
		format = image.format,
		subresourceRange = {
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
			aspectMask = aspect_flags,
		},
	}

	vk_check(vk.CreateImageView(device, &info, nil, &image.image_view))
}

/* Create a GPU side buffer to write data into */
create_buffer :: proc(
	alloc_size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags = {.DEVICE_LOCAL},
	loc := #caller_location,
) -> GPUBuffer
{
	buffer_info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = alloc_size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}

	gpu_buffer := GPUBuffer {
		size = alloc_size,
	}
	vk_check(vk.CreateBuffer(rs.device, &buffer_info, nil, &gpu_buffer.buffer))

	mem_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(rs.device, gpu_buffer.buffer, &mem_requirements)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_requirements.size,
		memoryTypeIndex = find_memory_type(rs.physical_device, mem_requirements.memoryTypeBits, properties),
	}

	vk_check(vk.AllocateMemory(rs.device, &alloc_info, nil, &gpu_buffer.memory))

	vk.BindBufferMemory(rs.device, gpu_buffer.buffer, gpu_buffer.memory, 0)

	return gpu_buffer
}

/* Writes to the buffer with the input slice at offset. */
write_buffer_slice :: proc(buffer: ^GPUBuffer, in_data: []$T, offset: vk.DeviceSize = 0, loc := #caller_location)
{
	size := size_of(T) * len(in_data)
	assert(
		buffer.size >= vk.DeviceSize(u64(size) + u64(offset)),
		"The size of the slice and offset is larger than the buffer",
		loc,
	)

	data: [^]u8
	vk.MapMemory(rs.device, buffer.memory, 0, buffer.size, {}, cast(^rawptr)&data)
	mem.copy(data[offset:], raw_data(in_data), size)
	vk.UnmapMemory(rs.device, buffer.memory)
}

/* Write to a buffer. Uploads the data via a staging buffer. This is useful if your buffer is GPU only. */
staging_write_buffer_slice :: proc(
	buffer: ^GPUBuffer,
	in_data: []$T,
	offset: vk.DeviceSize = 0,
	loc := #caller_location,
)
{
	size := size_of(T) * len(in_data)
	assert(
		buffer.size >= vk.DeviceSize(u64(size) + u64(offset)),
		"The size of the slice and offset is larger than the buffer",
		loc,
	)

	staging: GPUBuffer = create_buffer(vk.DeviceSize(size), {.TRANSFER_SRC}, {.HOST_VISIBLE, .HOST_COHERENT})
	defer
	{
		vk.DestroyBuffer(rs.device, staging.buffer, nil)
		vk.FreeMemory(rs.device, staging.memory, nil)
	}

	write_buffer_slice(&staging, in_data, loc = loc)

	{
		cmd := begin_immediate_submit()
		region := vk.BufferCopy {
			dstOffset = offset,
			srcOffset = 0,
			size      = vk.DeviceSize(size),
		}

		vk.CmdCopyBuffer(cmd, staging.buffer, buffer.buffer, 1, &region)
		end_immediate_submit()
	}
}

/* Populate VkImageView in image */
init_image_view :: proc(device: vk.Device, image: ^GPUImage, aspect_flags: vk.ImageAspectFlags)
{
	info := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		viewType = .D2,
		image = image.image,
		format = image.format,
		subresourceRange = {
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
			aspectMask = aspect_flags,
		},
	}

	vk_check(vk.CreateImageView(device, &info, nil, &image.image_view))
}

/* Helper function for adding image barriers, otherwise it becomes very verbose. */
transition_image :: proc(
	cmd: vk.CommandBuffer,
	image: vk.Image,
	current_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
)
{
	dep_info := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		pNext                   = nil,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &vk.ImageMemoryBarrier2 {
			sType = .IMAGE_MEMORY_BARRIER_2,
			pNext = nil,
			srcStageMask = {.ALL_COMMANDS},
			srcAccessMask = {.MEMORY_WRITE},
			dstStageMask = {.ALL_COMMANDS},
			dstAccessMask = {.MEMORY_WRITE, .MEMORY_READ},
			oldLayout = current_layout,
			newLayout = new_layout,
			image = image,
			subresourceRange = {
				aspectMask = (new_layout == .DEPTH_ATTACHMENT_OPTIMAL || new_layout == .DEPTH_READ_ONLY_OPTIMAL) ? {.DEPTH} : {.COLOR},
				baseMipLevel = 0,
				levelCount = vk.REMAINING_MIP_LEVELS,
				baseArrayLayer = 0,
				layerCount = vk.REMAINING_ARRAY_LAYERS,
			},
		},
	}

	vk.CmdPipelineBarrier2KHR(cmd, &dep_info)
}

/* Initialize the global renderer state for Vulkan. */
init_vulkan :: proc()
{
	// set up slang global session
	assert(sl.createGlobalSession(sl.API_VERSION, &rs.slang_global_session) == sl.OK)

	// Create instance and load required procedures
	{
		// Loads vulkan api functions needed to create an instance
		vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))
		assert(vk.GetInstanceProcAddr != nil, "Vulkan function pointers not loaded")
		glfw_extensions := glfw.GetRequiredInstanceExtensions()
		extension_count := len(glfw_extensions)

		extensions: [dynamic]cstring
		defer delete(extensions)

		resize(&extensions, extension_count)

		for ext, i in glfw_extensions {
			extensions[i] = ext
		}

		when ODIN_OS == .Darwin {
			append(&extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
		}
		append(&extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

		create_info := vk.InstanceCreateInfo {
			sType                   = .INSTANCE_CREATE_INFO,
			pNext                   = &vk.DebugUtilsMessengerCreateInfoEXT {
				sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
				messageSeverity = {.WARNING, .ERROR, .INFO},
				messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
				pfnUserCallback = debug_callback,
				pNext = &vk.ValidationFeaturesEXT {
					sType = .VALIDATION_FEATURES_EXT,
					pEnabledValidationFeatures = raw_data(VALIDATION_FEATURES),
					enabledValidationFeatureCount = u32(len(VALIDATION_LAYERS)),
				},
			},
			pApplicationInfo        = &{
				sType = .APPLICATION_INFO,
				pApplicationName = "Hello Triangle",
				applicationVersion = vk.MAKE_VERSION(0, 0, 1),
				pEngineName = "No Engine",
				engineVersion = vk.MAKE_VERSION(1, 0, 0),
				apiVersion = vk.API_VERSION_1_3,
			},
			ppEnabledExtensionNames = raw_data(extensions),
			enabledExtensionCount   = cast(u32)len(extensions),
			enabledLayerCount       = u32(len(VALIDATION_LAYERS)),
			ppEnabledLayerNames     = raw_data(VALIDATION_LAYERS),
		}

		when ODIN_OS == .Darwin {
			create_info.flags |= {.ENUMERATE_PORTABILITY_KHR}
		}

		vk_check(vk.CreateInstance(&create_info, nil, &rs.instance))

		// Load instance-specific procedures
		vk.load_proc_addresses_instance(rs.instance)

		n_ext: u32
		vk.EnumerateInstanceExtensionProperties(nil, &n_ext, nil)

		extension_props := make([]vk.ExtensionProperties, n_ext)
		defer delete(extension_props)

		vk.EnumerateInstanceExtensionProperties(nil, &n_ext, raw_data(extension_props))

		for &ext in &extension_props {
			fmt.println(" -", cstring(&ext.extensionName[0]))
		}
	}


	// Create debug messenger
	{
		debug_utils_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
			sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
			messageSeverity = {.VERBOSE, .WARNING, .INFO, .ERROR},
			messageType     = {.GENERAL, .VALIDATION},
			pfnUserCallback = debug_callback,
			pUserData       = nil,
		}

		vk_check(vk.CreateDebugUtilsMessengerEXT(rs.instance, &debug_utils_create_info, nil, &rs.debug_messenger))
	}


	vk_check(glfw.CreateWindowSurface(rs.instance, rs.window, nil, &rs.surface))


	device_extensions: [dynamic]cstring
	resize(&device_extensions, len(DEVICE_EXTENSIONS))
	for ext, i in DEVICE_EXTENSIONS {
		device_extensions[i] = ext
	}

	// Get physical device
	{
		device_count: u32 = 0
		vk.EnumeratePhysicalDevices(rs.instance, &device_count, nil)

		devices := make([]vk.PhysicalDevice, device_count)
		defer delete(devices)
		vk.EnumeratePhysicalDevices(rs.instance, &device_count, raw_data(devices))

		// Pick a fallback GPU, if you don't have a discrete GPU.
		if len(devices) > 0 {
			rs.physical_device = devices[0]
		}

		// TODO clean up later
		for device in devices {
			// This is a really crude check, this does NOT check for features. Don't do this in real programs.
			// We're just going to assume your discrete GPU supports the ones we use for this example.
			properties: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(device, &properties)
			if properties.deviceType == .DISCRETE_GPU {
				rs.physical_device = device
				break
			}
		}

		if rs.physical_device == nil {
			panic("No GPU found that supports all required features.")
		}

		// In accordance with the Vulkan specification, if VK_KHR_portability_subset
		// is in the device extensions, then it must be part of the enabled extensions
		// when creating the device.
		//
		// We check here to see if that extension is present, and then add it to our
		// list of enabled device extensions if it is.
		//
		// This is required for Vulkan support on macOS via MoltenVK.

		n_dev_ext: u32
		vk.EnumerateDeviceExtensionProperties(rs.physical_device, nil, &n_dev_ext, nil)

		dev_extension_props := make([]vk.ExtensionProperties, n_dev_ext)
		defer delete(dev_extension_props)

		vk.EnumerateDeviceExtensionProperties(rs.physical_device, nil, &n_dev_ext, raw_data(dev_extension_props))

		for &ext in &dev_extension_props {
			// NOTE: `KHR_PORTABILITY_SUBSET_EXTENSION_NAME` is not defined by
			//       vendor:vulkan because vulkan_beta.h is not used by the wrapper
			//       generator at this time, so we use the raw name string instead.
			if cstring(&ext.extensionName[0]) == "VK_KHR_portability_subset" {
				append(&device_extensions, "VK_KHR_portability_subset")
				break
			}
		}
	}

	// Get the correct queue family
	{
		queue_family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(rs.physical_device, &queue_family_count, nil)

		queue_families := make([]vk.QueueFamilyProperties, queue_family_count)
		defer delete(queue_families)
		vk.GetPhysicalDeviceQueueFamilyProperties(rs.physical_device, &queue_family_count, raw_data(queue_families))

		has_graphics := false

		for queue_family, i in &queue_families {
			if .GRAPHICS in queue_family.queueFlags {
				rs.graphics_queue_family = u32(i)
				has_graphics = true
			}
		}

		assert(has_graphics)
	}


	// Create graphics queue.
	{
		queue_priority: f32 = 1.0

		queue_create_info: vk.DeviceQueueCreateInfo
		queue_create_info.sType = .DEVICE_QUEUE_CREATE_INFO
		queue_create_info.queueFamilyIndex = rs.graphics_queue_family
		queue_create_info.queueCount = 1
		queue_create_info.pQueuePriorities = &queue_priority

		device_create_info := vk.DeviceCreateInfo {
			sType                   = .DEVICE_CREATE_INFO,
			pNext                   = &REQUIRED_FEATURES,
			pQueueCreateInfos       = &queue_create_info,
			queueCreateInfoCount    = 1,
			ppEnabledExtensionNames = raw_data(device_extensions),
			enabledExtensionCount   = u32(len(device_extensions)),
		}

		vk_check(vk.CreateDevice(rs.physical_device, &device_create_info, nil, &rs.device))

		assert(rs.device != nil)

		vk.GetDeviceQueue(rs.device, rs.graphics_queue_family, 0, &rs.graphics_queue)
	}


	// Create swapchain
	{
		SwapChainSupportDetails :: struct {
			capabilities:  vk.SurfaceCapabilitiesKHR,
			formats:       []vk.SurfaceFormatKHR,
			present_modes: []vk.PresentModeKHR,
		}

		// Helper procedures
		/* This allocates format and present_mode slices.*/
		query_swapchain_support :: proc() -> SwapChainSupportDetails
		{
			details: SwapChainSupportDetails

			vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(rs.physical_device, rs.surface, &details.capabilities)
			// Formats
			{
				format_count: u32
				vk.GetPhysicalDeviceSurfaceFormatsKHR(rs.physical_device, rs.surface, &format_count, nil)

				formats := make([]vk.SurfaceFormatKHR, format_count)
				vk.GetPhysicalDeviceSurfaceFormatsKHR(rs.physical_device, rs.surface, &format_count, raw_data(formats))

				details.formats = formats
			}
			// Present modes
			{
				present_mode_count: u32
				vk.GetPhysicalDeviceSurfacePresentModesKHR(rs.physical_device, rs.surface, &present_mode_count, nil)

				present_modes := make([]vk.PresentModeKHR, present_mode_count)
				vk.GetPhysicalDeviceSurfacePresentModesKHR(
					rs.physical_device,
					rs.surface,
					&present_mode_count,
					raw_data(present_modes),
				)

				details.present_modes = present_modes
			}

			return details
		}

		/* This returns true if a surface format was found that matches the requirements.
		 Otherwise, this returns the first surface format and false. */
		choose_swap_surface_format :: proc(available_formats: []vk.SurfaceFormatKHR) -> (vk.SurfaceFormatKHR, bool)
		{
			for surface_format in available_formats {
				if surface_format.format == .B8G8R8A8_UNORM && surface_format.colorSpace == .SRGB_NONLINEAR {
					return surface_format, true
				}
			}

			return available_formats[0], false
		}

		choose_swap_present_mode :: proc(available_present_modes: []vk.PresentModeKHR) -> vk.PresentModeKHR
		{
			return .FIFO
		}

		/* If there is no current extent, then get extent form the gfw framebuffer size */
		choose_swap_extent :: proc(window: glfw.WindowHandle, capabilities: ^vk.SurfaceCapabilitiesKHR) -> vk.Extent2D
		{
			if (capabilities.currentExtent.width != max(u32)) {
				return capabilities.currentExtent
			} else {
				width, height := glfw.GetFramebufferSize(window)

				actual_extent := vk.Extent2D{u32(width), u32(height)}

				actual_extent.width = clamp(
					actual_extent.width,
					capabilities.minImageExtent.width,
					capabilities.maxImageExtent.width,
				)
				actual_extent.height = clamp(
					actual_extent.height,
					capabilities.minImageExtent.height,
					capabilities.maxImageExtent.height,
				)

				return actual_extent
			}
		}

		// Get actual swapchain
		swapchain_support: SwapChainSupportDetails = query_swapchain_support()
		defer
		{
			delete(swapchain_support.formats)
			delete(swapchain_support.present_modes)
		}

		surface_format: vk.SurfaceFormatKHR
		surface_format, _ = choose_swap_surface_format(swapchain_support.formats)
		present_mode: vk.PresentModeKHR = choose_swap_present_mode(swapchain_support.present_modes)
		extent: vk.Extent2D = choose_swap_extent(rs.window, &swapchain_support.capabilities)

		image_count := swapchain_support.capabilities.minImageCount + 1

		if swapchain_support.capabilities.maxImageCount > 0 &&
		   image_count > swapchain_support.capabilities.maxImageCount {
			image_count = swapchain_support.capabilities.maxImageCount
		}

		create_info := vk.SwapchainCreateInfoKHR {
			sType                 = .SWAPCHAIN_CREATE_INFO_KHR,
			surface               = rs.surface,
			minImageCount         = image_count,
			imageFormat           = surface_format.format,
			imageColorSpace       = surface_format.colorSpace,
			imageExtent           = extent,
			imageArrayLayers      = 1,
			imageUsage            = {.COLOR_ATTACHMENT, .TRANSFER_DST},

			// TODO: Support multiple queues?
			imageSharingMode      = .EXCLUSIVE,
			queueFamilyIndexCount = 0, // Optional
			pQueueFamilyIndices   = nil, // Optional
			preTransform          = swapchain_support.capabilities.currentTransform,
			compositeAlpha        = {.OPAQUE},
			presentMode           = present_mode,
			clipped               = true,
			oldSwapchain          = {},
		}

		vk_check(vk.CreateSwapchainKHR(rs.device, &create_info, nil, &rs.swapchain))

		vk.GetSwapchainImagesKHR(rs.device, rs.swapchain, &image_count, nil)
		rs.swapchain_images = make([]vk.Image, image_count)
		vk.GetSwapchainImagesKHR(rs.device, rs.swapchain, &image_count, raw_data(rs.swapchain_images))

		rs.swapchain_image_format = surface_format.format
		rs.swapchain_extent = extent

		rs.swapchain_image_views = make([]vk.ImageView, len(rs.swapchain_images))
		// Create the swapchain image views
		for i in 0 ..< len(rs.swapchain_images) {
			create_info := vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = rs.swapchain_images[i],
				viewType = .D2,
				format = rs.swapchain_image_format,
				components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
				subresourceRange = {
					aspectMask = {.COLOR},
					baseMipLevel = 0,
					levelCount = 1,
					baseArrayLayer = 0,
					layerCount = 1,
				},
			}

			vk_check(vk.CreateImageView(rs.device, &create_info, nil, &rs.swapchain_image_views[i]))
		}
	}

	// Create the draw image
	{
		x, y := glfw.GetWindowSize(rs.window)

		draw_image_format: vk.Format = .R32G32B32A32_SFLOAT
		draw_image_extent := vk.Extent3D{u32(x), u32(y), 1}
		draw_image_usages := vk.ImageUsageFlags{.TRANSFER_SRC, .TRANSFER_DST, .STORAGE, .COLOR_ATTACHMENT}

		rs.draw_image = create_image(draw_image_format, draw_image_extent, draw_image_usages)
		create_image_view(rs.device, &rs.draw_image, {.COLOR})

		rs.depth_image = create_image(.D32_SFLOAT, draw_image_extent, {.DEPTH_STENCIL_ATTACHMENT})
		create_image_view(rs.device, &rs.depth_image, {.DEPTH})
	}

	// Create command pool
	{
		command_pool_info := vk.CommandPoolCreateInfo {
			sType            = .COMMAND_POOL_CREATE_INFO,
			pNext            = nil,
			flags            = {.RESET_COMMAND_BUFFER},
			queueFamilyIndex = rs.graphics_queue_family,
		}

		for i in 0 ..< FRAME_OVERLAP {
			vk_check(vk.CreateCommandPool(rs.device, &command_pool_info, nil, &rs.frames[i].command_pool))

			cmd_alloc_info := vk.CommandBufferAllocateInfo {
				sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
				pNext              = nil,
				commandPool        = rs.frames[i].command_pool,
				commandBufferCount = 1,
				level              = .PRIMARY,
			}

			vk_check(vk.AllocateCommandBuffers(rs.device, &cmd_alloc_info, &rs.frames[i].main_command_buffer))
		}

		vk_check(vk.CreateCommandPool(rs.device, &command_pool_info, nil, &rs.imm_command_pool))

		cmd_alloc_info := vk.CommandBufferAllocateInfo {
			sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
			pNext              = nil,
			commandPool        = rs.imm_command_pool,
			commandBufferCount = 1,
			level              = .PRIMARY,
		}

		vk_check(vk.AllocateCommandBuffers(rs.device, &cmd_alloc_info, &rs.imm_command_buffer))
	}

	// Create frame fences
	{
		fence_create_info := vk.FenceCreateInfo {
			sType = .FENCE_CREATE_INFO,
			flags = {.SIGNALED},
		}
		semaphore_create_info := vk.SemaphoreCreateInfo {
			sType = .SEMAPHORE_CREATE_INFO,
			flags = {},
		}

		for &frame in rs.frames {
			vk_check(vk.CreateFence(rs.device, &fence_create_info, nil, &frame.render_fence))

			vk_check(vk.CreateSemaphore(rs.device, &semaphore_create_info, nil, &frame.swapchain_semaphore))
			vk_check(vk.CreateSemaphore(rs.device, &semaphore_create_info, nil, &frame.render_semaphore))
		}

		vk.CreateFence(rs.device, &fence_create_info, nil, &rs.imm_fence)

	}
	// End bootstrapping
}

vulkan_shutdown :: proc()
{
	vk.DeviceWaitIdle(rs.device)

	vk.DestroyImage(rs.device, rs.draw_image.image, nil)
	vk.DestroyImageView(rs.device, rs.draw_image.image_view, nil)
	vk.FreeMemory(rs.device, rs.draw_image.memory, nil)

	vk.DestroyImage(rs.device, rs.depth_image.image, nil)
	vk.DestroyImageView(rs.device, rs.depth_image.image_view, nil)
	vk.FreeMemory(rs.device, rs.depth_image.memory, nil)

	for &frame in rs.frames {
		vk.DestroyCommandPool(rs.device, frame.command_pool, nil)

		vk.DestroyFence(rs.device, frame.render_fence, nil)
		vk.DestroySemaphore(rs.device, frame.render_semaphore, nil)
		vk.DestroySemaphore(rs.device, frame.swapchain_semaphore, nil)
	}

	vk.DestroyCommandPool(rs.device, rs.imm_command_pool, nil)
	vk.DestroyFence(rs.device, rs.imm_fence, nil)

	vk.DestroySwapchainKHR(rs.device, rs.swapchain, nil)

	// We don't need to delete the swapchain images, it was created by the driver
	// However, we did create the views, so we will destroy those now.
	for &image_view in rs.swapchain_image_views {
		vk.DestroyImageView(rs.device, image_view, nil)
	}

	delete(rs.swapchain_image_views)
	delete(rs.swapchain_images)

	vk.DestroySurfaceKHR(rs.instance, rs.surface, nil)
	vk.DestroyDevice(rs.device, nil)

	vk.DestroyDebugUtilsMessengerEXT(rs.instance, rs.debug_messenger, nil)

	vk.DestroyInstance(rs.instance, nil)
}

DEFAULT_PIPELINE_LAYOUT_INFO :: vk.PipelineLayoutCreateInfo {
	sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
	pNext                  = nil,
	flags                  = {},
	setLayoutCount         = 0,
	pSetLayouts            = nil,
	pushConstantRangeCount = 0,
	pPushConstantRanges    = nil,
}

create_pipeline :: proc(
	module: vk.ShaderModule,
	layout_info: vk.PipelineLayoutCreateInfo = DEFAULT_PIPELINE_LAYOUT_INFO,
) -> (
	vk.PipelineLayout,
	vk.Pipeline,
)
{
	layout_info := layout_info
	// Create pipelines and pipeline layouts
	pipeline_layout: vk.PipelineLayout
	vk_check(vk.CreatePipelineLayout(rs.device, &layout_info, nil, &pipeline_layout))

	pipelineInfo := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		pNext               = &vk.PipelineRenderingCreateInfo {
			sType = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount = 1,
			pColorAttachmentFormats = &rs.draw_image.format,
			depthAttachmentFormat = rs.depth_image.format,
		},
		pStages             = raw_data(
			[]vk.PipelineShaderStageCreateInfo {
				{sType = .PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = module, pName = "vertexmain"},
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
		pViewportState      = &{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, scissorCount = 1},
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
			pAttachments = &vk.PipelineColorBlendAttachmentState {
				colorWriteMask = {.R, .G, .B, .A},
				blendEnable = false,
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
			pDynamicStates = raw_data([]vk.DynamicState{.VIEWPORT, .SCISSOR}),
			dynamicStateCount = 2,
		},
	}

	pipeline: vk.Pipeline

	if vk.CreateGraphicsPipelines(rs.device, 0, 1, &pipelineInfo, nil, &pipeline) != .SUCCESS {
		fmt.println("Couldn't create graphics pipeline!")
		return {}, {}
	}

	// We don't need to keep the shader modules around
	vk.DestroyShaderModule(rs.device, module, nil)

	return pipeline_layout, pipeline
}

begin_render_pass :: proc()
{
	cmd := current_frame().main_command_buffer
	// Geometry pass
	transition_image(cmd, rs.draw_image.image, .UNDEFINED, .COLOR_ATTACHMENT_OPTIMAL)
	transition_image(cmd, rs.depth_image.image, .UNDEFINED, .DEPTH_ATTACHMENT_OPTIMAL)

	// This also clears both the color and depth images.
	render_info := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		layerCount = 1,
		renderArea = {extent = rs.draw_extent},
		pDepthAttachment = &{
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = rs.depth_image.image_view,
			imageLayout = .DEPTH_ATTACHMENT_OPTIMAL,
			loadOp = .CLEAR,
			storeOp = .STORE,
			clearValue = {depthStencil = {depth = 1.0}},
		},
		pColorAttachments = &vk.RenderingAttachmentInfo {
			sType = .RENDERING_ATTACHMENT_INFO,
			imageView = rs.draw_image.image_view,
			imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
			loadOp = .CLEAR,
			storeOp = .STORE,
			clearValue = {color = {float32 = {0, 0, 0, 1}}},
		},
		colorAttachmentCount = 1,
	}
	vk.CmdBeginRenderingKHR(cmd, &render_info)

	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(rs.draw_extent.width),
		height   = f32(rs.draw_extent.height),
		minDepth = 0.0,
		maxDepth = 1.0,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	scissor := vk.Rect2D {
		offset = {x = 0, y = 0},
		extent = {rs.draw_extent.width, rs.draw_extent.height},
	}
	vk.CmdSetScissor(cmd, 0, 1, &scissor)
}

end_render_pass :: proc()
{
	cmd := current_frame().main_command_buffer
	transition_image(cmd, rs.draw_image.image, .COLOR_ATTACHMENT_OPTIMAL, .TRANSFER_SRC_OPTIMAL)
	transition_image(cmd, rs.swapchain_images[rs.swapchain_image_index], .UNDEFINED, .TRANSFER_DST_OPTIMAL)

	// Copy the data from the draw image into the current swapchain image
	{
		blit_region := vk.ImageBlit2 {
			sType = .IMAGE_BLIT_2,
			pNext = nil,
			srcSubresource = {aspectMask = {.COLOR}, baseArrayLayer = 0, layerCount = 1, mipLevel = 0},
			srcOffsets = {1 = {x = i32(rs.draw_extent.width), y = i32(rs.draw_extent.height), z = 1}},
			dstSubresource = {aspectMask = {.COLOR}, baseArrayLayer = 0, layerCount = 1, mipLevel = 0},
			dstOffsets = {1 = {x = i32(rs.swapchain_extent.width), y = i32(rs.swapchain_extent.height), z = 1}},
		}
		blit_info := vk.BlitImageInfo2 {
			sType          = .BLIT_IMAGE_INFO_2,
			pNext          = nil,
			dstImage       = rs.swapchain_images[rs.swapchain_image_index],
			dstImageLayout = .TRANSFER_DST_OPTIMAL,
			srcImage       = rs.draw_image.image,
			srcImageLayout = .TRANSFER_SRC_OPTIMAL,
			filter         = .LINEAR,
			regionCount    = 1,
			pRegions       = &blit_region,
		}
		vk.CmdBlitImage2KHR(cmd, &blit_info)
	}

	// transition the swapchain image into present mode
	transition_image(cmd, rs.swapchain_images[rs.swapchain_image_index], .TRANSFER_DST_OPTIMAL, .PRESENT_SRC_KHR)

	// submit the command buffer
	{
		vk_check(vk.EndCommandBuffer(cmd))
		cmd_info := vk.CommandBufferSubmitInfo {
			sType         = .COMMAND_BUFFER_SUBMIT_INFO,
			pNext         = nil,
			commandBuffer = cmd,
			deviceMask    = 0,
		}
		wait_info := vk.SemaphoreSubmitInfo {
			sType       = .SEMAPHORE_SUBMIT_INFO,
			pNext       = nil,
			semaphore   = current_frame().swapchain_semaphore,
			stageMask   = {.COLOR_ATTACHMENT_OUTPUT},
			deviceIndex = 0,
			value       = 1,
		}
		signal_info := vk.SemaphoreSubmitInfo {
			sType       = .SEMAPHORE_SUBMIT_INFO,
			pNext       = nil,
			semaphore   = current_frame().render_semaphore,
			stageMask   = {.ALL_GRAPHICS},
			deviceIndex = 0,
			value       = 1,
		}
		submit := vk.SubmitInfo2 {
			sType                    = .SUBMIT_INFO_2,
			pNext                    = nil,
			waitSemaphoreInfoCount   = 1,
			pWaitSemaphoreInfos      = &wait_info,
			signalSemaphoreInfoCount = 1,
			pSignalSemaphoreInfos    = &signal_info,
			commandBufferInfoCount   = 1,
			pCommandBufferInfos      = &cmd_info,
		}

		vk_check(vk.QueueSubmit2KHR(rs.graphics_queue, 1, &submit, current_frame().render_fence))
	}
}
