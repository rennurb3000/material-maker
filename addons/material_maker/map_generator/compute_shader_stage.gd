# Note : this class does not depend on compute_shader.gd
# we need a separate pipeline, since we need to keep those lbvh shaders chilling around
# and we need to work with storage buffers, not textures 
# and a replaceable rendering device (for testing)
extends  MMPipeline
class_name MMComputeShaderStage

var _rd : RenderingDevice
var _shader : RID
var _pipeline : RID
var _push_constants : PackedByteArray = PackedByteArray()
var _uniforms: Dictionary[int,Dictionary] = {}
var _stage_name : String
var _logging : bool
var _last_dispatch_usec : int = 0

func _init(rd:RenderingDevice,stage_name:String,logging:bool) -> void:
	_rd = rd if rd!=null else mm_renderer.rendering_device
	assert(_rd!=null)
	_stage_name = stage_name
	_logging = logging
	
func clear():
	_free_pipeline()
	_push_constants = PackedByteArray()
	_uniforms.clear()
	super.clear()
	
func set_shader(string:String,replaces:Dictionary={})->bool:
	_free_pipeline()
	_shader = do_compile_shader(_rd,{"compute":string},replaces.duplicate())
	if not _shader.is_valid():
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("failed to create stage pipeline")
		_free_pipeline()
		return false
	return true

func set_uniform(set_index:int,binding:int,uniform_type:RenderingDevice.UniformType,buffer:RID)->void:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = uniform_type
	uniform.binding = binding
	uniform.add_id(buffer)
	if not _uniforms.has(set_index):
		_uniforms[set_index] = {}
	_uniforms[set_index][binding] = uniform

# Sets push constants in a compute shader 
func set_push_constants(data : PackedByteArray)->void:
	_push_constants = data
	
func dispatch(x:int,y:int,z:int)->bool:
	if not _pipeline.is_valid():
		push_error("invalid compute shader")
		return false
	var start_time : int = Time.get_ticks_usec()
	var uniform_sets:Array[RID] = []
	var set_indices :Array[int]= _uniforms.keys()
	set_indices.sort()
	
	for set_index in set_indices:
		var uniforms : Array[RDUniform] = []
		var bindings : Dictionary = _uniforms[set_index]
		for binding : int in bindings:
			uniforms.append(bindings[binding])
		var uniform_set := _rd.uniform_set_create(uniforms,_shader,set_index)
		if not uniform_set.is_valid():
			_free_uniform_sets(uniform_sets)
			return false
		uniform_sets.append(uniform_set)
	
	var compute_list : int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_pipeline)
	
	for i in set_indices.size():
		_rd.compute_list_bind_uniform_set(compute_list,uniform_sets[i],set_indices[i])
	
	if not _push_constants.is_empty():
		_rd.compute_list_set_push_constant(compute_list,_push_constants,_push_constants.size())
	
	_rd.compute_list_dispatch(compute_list,x,y,z)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	_free_uniform_sets(uniform_sets)
	_last_dispatch_usec = Time.get_ticks_usec() - start_time
	if _logging:
		print("Stage %s : %d us"%[_stage_name,_last_dispatch_usec])
	return true
		
func _free_uniform_sets(sets:Array[RID])->void:
	for uniform_set in sets:
		if uniform_set.is_valid():
			_rd.free_rid(uniform_set)
			
#Dispatch Note: we do not do textures here, so i called it dispatch
func _free_pipeline() ->void:
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
		_pipeline = RID()
	
	if _shader.is_valid():
		_rd.free_rid(_shader)
		_shader = RID()
