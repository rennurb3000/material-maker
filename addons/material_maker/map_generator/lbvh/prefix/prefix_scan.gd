class_name PrefixScan
# prefix sum constants
const SCAN_WORKGROUP_SIZE := 256
const ELEMENTS_PER_GROUP := SCAN_WORKGROUP_SIZE *2

var _scan_pipeline : RID
var _scan_shader :RID
var _add_block_offset_pipeline : RID
var _add_block_offset_shader :RID
var _rd : RenderingDevice

func _init(rd : RenderingDevice) -> void:
	_rd =rd
	_init_shaders()
	
func _init_shaders()->void:
	_init_scan_shader()
	_init_add_block_offset_shader()

func exclusive_scan_u32(input_buffer:RID, element_count:int)->RID:
	var output_buffer := _rd.storage_buffer_create(element_count*4)
	var block_count := ceili(float(element_count)/float(ELEMENTS_PER_GROUP))
	var block_sum_buffer := _rd.storage_buffer_create(max(block_count,1)*4)
	
	_dispatch_scan_blocks(input_buffer,output_buffer,block_sum_buffer,element_count)
	if block_count > 1:
		var scanned_block_sums := exclusive_scan_u32(block_sum_buffer,block_count)
		_dispatch_add_block_offsets(output_buffer,scanned_block_sums,element_count)
	return output_buffer
	
# note we need the pipeline recursively!
func _init_scan_shader()->void:
	if _scan_pipeline.is_valid():
		return
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/prefix/scan_blocks.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	_scan_shader = _rd.shader_create_from_spirv(shader_spirv)
	_scan_pipeline = _rd.compute_pipeline_create(_scan_shader)
	
func _init_add_block_offset_shader()->void:
	if _add_block_offset_pipeline.is_valid():
		return
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/prefix/add_block_offsets.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	_add_block_offset_shader = _rd.shader_create_from_spirv(shader_spirv)
	_add_block_offset_pipeline = _rd.compute_pipeline_create(_add_block_offset_shader)
	
func _dispatch_scan_blocks(input_buffer:RID,
								output_buffer:RID,
								block_sum_buffer:RID, element_count :int)-> void:
	var uniforms : Array[RDUniform] = []
	var input_uniform := RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_uniform.binding = 0
	input_uniform.add_id(input_buffer)
	uniforms.push_back(input_uniform)
	
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output_uniform.binding = 1
	output_uniform.add_id(output_buffer)
	uniforms.push_back(output_uniform)
	
	# block sums
	var block_uniform := RDUniform.new()
	block_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	block_uniform.binding = 2
	block_uniform.add_id(block_sum_buffer)
	uniforms.push_back(block_uniform)
	
	var uniform_set := _rd.uniform_set_create(uniforms,_scan_shader,0)
	var push_constants := PackedByteArray()
	push_constants.resize(4)
	push_constants.encode_u32(0,element_count)
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_scan_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list,uniform_set,0)
	_rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	var num_groups := ceili(float(element_count)/ float(ELEMENTS_PER_GROUP))
	_rd.compute_list_dispatch(compute_list,num_groups,1,1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	
func _dispatch_add_block_offsets(output_buffer:RID,
								block_offset_buffer:RID, 
								element_count :int)-> void:
	var uniforms : Array[RDUniform] = []
	
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output_uniform.binding = 0
	output_uniform.add_id(output_buffer)
	uniforms.push_back(output_uniform)
	
	# block sums
	var block_offset_uniform := RDUniform.new()
	block_offset_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	block_offset_uniform.binding = 1
	block_offset_uniform.add_id(block_offset_buffer)
	uniforms.push_back(block_offset_uniform)
	
	var uniform_set := _rd.uniform_set_create(uniforms,_add_block_offset_shader,0)
	var push_constants := PackedByteArray()
	push_constants.resize(4)
	push_constants.encode_u32(0,element_count)
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_add_block_offset_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list,uniform_set,0)
	_rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	var num_groups := ceili(float(element_count)/ float(ELEMENTS_PER_GROUP))
	_rd.compute_list_dispatch(compute_list,num_groups,1,1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
