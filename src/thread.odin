package marching2d

import "base:runtime"
import "core:thread"

Task_Data :: struct($T: typeid) {
	start, end: int, // The indices provided to the user
	using data: T,
}

do_all :: proc(do_proc: proc(_: thread.Task), data: $T, start, end: int, pool: ^thread.Pool = nil)
{
	thread_count := len(pool.threads)
	chunk_size := (end - start) / thread_count
	task_datas: [25]Task_Data(T)
	i: int = 0
	for i < thread_count - 1 {
		task_datas[i] = Task_Data(T) {
			data  = data,
			start = start + i * chunk_size,
			end   = start + i * chunk_size + chunk_size,
		}
		thread.pool_add_task(pool, runtime.nil_allocator(), do_proc, &task_datas[i], i)
		i += 1
	}
	// Last chunk
	task_datas[i] = Task_Data(T) {
		data  = data,
		start = start + i * chunk_size,
		end   = end,
	}
	thread.pool_add_task(pool, runtime.nil_allocator(), do_proc, &task_datas[i], i)
	thread.pool_finish(pool)
}

get_task_data :: proc($T: typeid, task: thread.Task) -> ^Task_Data(T)
{
	return cast(^Task_Data(T))task.data
}


Map_Task_Data :: struct($T: typeid, $O: typeid) {
	inputs:  []T,
	outputs: []O,
	func:    proc(_: T) -> O,
}

mut_map :: proc {
	mut_map_slice,
}
/* Parallel processing of the elements "in" into "out". If in in == out it */
mut_map_slice :: proc(
	inputs: []$T,
	outputs: []$O,
	func: proc(_: T) -> O,
	pool: ^thread.Pool = nil,
	core_count: int = 4,
)
{
	if pool == nil {
		for elem, i in inputs {
			outputs[i] = func(elem)
		}
		return
	}

	task_processor :: proc(task: thread.Task)
	{
		data := cast(^Map_Task_Data(T, O))task.data
		for input, i in data.inputs {
			data.outputs[i] = data.func(input)
		}
	}

	chunk_size := len(inputs) / core_count
	task_datas: [20]Map_Task_Data(T, O) // if you have more than 20 cores... rip
	for i in 0 ..< core_count {
		section := min(chunk_size, len(inputs) - chunk_size * i)
		task_datas[i] = Map_Task_Data(T, O) {
			inputs  = inputs[i * chunk_size:][:section],
			outputs = outputs[i * chunk_size:][:section],
			func    = func,
		}
		thread.pool_add_task(pool, runtime.nil_allocator(), task_processor, &task_datas[i], i)
	}

	thread.pool_finish(pool)
}
