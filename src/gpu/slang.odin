package gpu
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"
// Slang bindings
import sl "slang"


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
		buffer := slice.bytes_from_ptr(
			diagnostics->getBufferPointer(),
			int(diagnostics->getBufferSize()),
		)
		assert(false, string(buffer), loc)
	}
}

// Compiles the triangle.slang shader and creates the pipeline (or re-creates it if it exists)
compile_shader_module :: proc(path, vertex_main, fragment_main: cstring) -> vk.ShaderModule
{
	// time the compilation
	start_compile_time: time.Tick = time.tick_now()

	code, diagnostics: ^sl.IBlob
	r: sl.Result

	target_desc: sl.TargetDesc = {
		structureSize = size_of(sl.TargetDesc),
		format        = .SPIRV,
		flags         = {.GENERATE_SPIRV_DIRECTLY},
		profile       = rs.slang_global_session->findProfile("sm_6_0"),
	}

	compiler_option_entries: []sl.CompilerOptionEntry = {
		{name = .VulkanUseEntryPointName, value = {intValue0 = 1}},
	}

	contents, err := os.read_entire_file_from_path(
		strings.clone_from_cstring(path),
		context.allocator,
	)
	delete(contents)
	if err != nil {
		fmt.println("shader path does not exist! | ", err)
	}
	session_desc: sl.SessionDesc = {
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
		fmt.println("Shader compile error! GPU module")
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

	components: [3]^sl.IComponentType = {module, vertex_entry, fragment_entry}

	linked_program: ^sl.IComponentType
	r = session->createCompositeComponentType(
		&components[0],
		len(components),
		&linked_program,
		&diagnostics,
	)
	diagnostics_check(diagnostics)
	slang_check(r)

	target_code: ^sl.IBlob
	r = linked_program->getTargetCode(0, &target_code, &diagnostics)
	diagnostics_check(diagnostics)
	slang_check(r)

	code_size := target_code->getBufferSize()
	source_code := slice.bytes_from_ptr(target_code->getBufferPointer(), auto_cast code_size)

	info: vk.ShaderModuleCreateInfo = {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(source_code), // codeSize needs to be in bytes
		pCode    = raw_data(slice.reinterpret([]u32, source_code)), // code needs to be in 32bit words
	}

	vk_module: vk.ShaderModule
	vk_check(vk.CreateShaderModule(rs.device, &info, nil, &vk_module))

	duration_msec: time.Duration = time.tick_since(start_compile_time)
	fmt.println("Loaded shader in", duration_msec)

	return vk_module
}

