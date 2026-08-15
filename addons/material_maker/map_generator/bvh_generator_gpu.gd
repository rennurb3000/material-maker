# TODO : check subgroup size for nvidia(32) or amd(64) and replace 
# TODO : replace LBVH_COMMON
extends Object
class_name MMBvhGeneratorGPU
const KEY_VERTICES := "vertices"
const KEY_INDICES := "indices"
const KEY_SURFACE_IDS := "surface_ids"
const KEY_SCENE_AABB := "scene_aabb"
const KEY_VERTEX_BUFFER := "vertex_buffer"
const KEY_INDEX_BUFFER := "index_buffer"
const KEY_MORTON_BUFFER := "morton_buffer"
const KEY_MORTON_BUFFER_TMP := "morton_buffer_tmp"
const KEY_ELEMENT_BUFFER := "element_buffer"
const KEY_LBVH_BUFFER := "lbvh_buffer"
const KEY_LBVH_CONSTRUCTION_INFO_BUFFER = "lbvh_construction_info_buffer"
const KEY_BVH_IMAGE := "bvh_image"
const KEY_BVH_IMAGE_TEXTURE := "bvh_image_texture"
const KEY_NODE_SIZE_BUFFER := "node_size_buffer"
const KEY_NODE_OFFSET_BUFFER := "node_offset_buffer"
const KEY_NODE_LEVEL_BUFFER := "node_level_buffer"
const KEY_PACKED_BVH_BUFFER:= "packed_bvh_buffer"
const KEY_NODE_WRITEOUT_BUFFER:= "node_writeout_buffer"
const KEY_NODE_DATA_START := "node_data_start"
const KEY_SIDE := "side"
const LBVH_NODE_SIZE := 36
const ELEMENT_SIZE := 28
const LBVH_CONSTRUCTION_INFO_SIZE := 8 # uint +int
const INVALID_POINTER :=0
const KEY_BVH_IMAGE_RID := "bvh_image_rid"
const MM_HEADER_TEXELS := 1
const MM_NODE_TEXELS := 3 #TODO replace in shader
const MM_LEAF_TEXELS := 5 #TODO selectable , for normal mode, or bake mode
#TODO extend for better debugability
enum BVHStatus{
	OK,
	INVALID_MESH,
	PIPELINE_CREATE_FAILED
}
# helper node class for testing the lbvh result
class LBVHNode:
	var left : int
	var right :int
	var primitive :int
	var aabb: AABB
# cpu helper node for testing only
class LBVHConstructionInfo:
	var parent: int
	var visitationCount;

# Using the "lazy" singleton pattern for a static interface
static var _instance : MMBvhGeneratorGPU

var _rd: RenderingDevice

# required pipelines are kept as members
var _triangle_aabb_shader:RID
var _triangle_aabb_pipeline:RID 

var _morton_shader :RID
var _morton_pipeline :RID

var _radix_shader :RID
var _radix_pipeline : RID

var _hierarchy_shader : RID
var _hierarchy_pipeline :RID

var _bb_node_shader :RID
var _bb_node_pipeline :RID 

var _node_sizes_shader :RID
var _node_sizes_pipeline :RID

var _writeout_shader : RID
var _writeout_pipeline :RID

var _node_levels_shader : RID
var _node_levels_pipeline :RID

# used to calculate storage positions 
var _prefix_scan : PrefixScan
# simple singleton pattern, so we can easily provide a static bvh interface like before
static func get_instance(rendering_device : RenderingDevice=null)->MMBvhGeneratorGPU:
	if _instance == null:
		if rendering_device == null:
			rendering_device = RenderingServer.create_local_rendering_device()
		_instance = MMBvhGeneratorGPU.new(rendering_device)
		return _instance
	if rendering_device != null and rendering_device != _instance._rd:
		_instance = MMBvhGeneratorGPU.new(rendering_device)
	return _instance
	
func _init(rendering_device:RenderingDevice) -> void:
	assert(rendering_device!= null)
	_rd = rendering_device
	_prefix_scan = PrefixScan.new(_rd)
	_init_triangle_aabb_pipeline()
	_init_morton_pipeline()
	_init_radix_pipeline()
	_init_hierarchy_pipeline()
	_init_bb_pipeline()
	_init_node_size_pipeline()
	_init_node_levels_pipeline()
	_init_writeout_pipeline()

# TODO refactor init functions
# NOTE i am not using a MM Pipeline, since i want to use that in my own game -.-
func _init_triangle_aabb_pipeline() -> void:
	if _triangle_aabb_pipeline.is_valid():
		return
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/triangle_aabb.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	_triangle_aabb_shader = _rd.shader_create_from_spirv(shader_spirv)
	_triangle_aabb_pipeline = _rd.compute_pipeline_create(_triangle_aabb_shader)

func _init_morton_pipeline():
	if _morton_pipeline.is_valid():
		return
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/morton.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	_morton_shader = _rd.shader_create_from_spirv(shader_spirv)
	_morton_pipeline = _rd.compute_pipeline_create(_morton_shader)
	
func _init_radix_pipeline():
	if _radix_pipeline.is_valid():
		return
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/sort_morton_codes.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	_radix_shader = _rd.shader_create_from_spirv(shader_spirv)
	_radix_pipeline = _rd.compute_pipeline_create(_radix_shader)
	
func _init_hierarchy_pipeline():
	if _hierarchy_pipeline.is_valid():
		return
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/build_hierarchy.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	_hierarchy_shader = _rd.shader_create_from_spirv(shader_spirv)
	_hierarchy_pipeline = _rd.compute_pipeline_create(_hierarchy_shader)
	
func _init_bb_pipeline():
	if _bb_node_pipeline.is_valid():
		return
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/build_bounding_boxes.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	_bb_node_shader = _rd.shader_create_from_spirv(shader_spirv)
	_bb_node_pipeline = _rd.compute_pipeline_create(_bb_node_shader)

func _init_node_size_pipeline():
	if _node_sizes_pipeline.is_valid():
		return
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/node_size_prefix.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	_node_sizes_shader = _rd.shader_create_from_spirv(shader_spirv)
	_node_sizes_pipeline = _rd.compute_pipeline_create(_node_sizes_shader)
	
func _init_writeout_pipeline():
	if _writeout_pipeline.is_valid():
		return
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/writeout_mm_bvh.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	_writeout_shader = _rd.shader_create_from_spirv(shader_spirv)
	_writeout_pipeline = _rd.compute_pipeline_create(_writeout_shader)

func _init_node_levels_pipeline():
	if _node_levels_pipeline.is_valid():
		return
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/generate_node_levels.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	_node_levels_shader = _rd.shader_create_from_spirv(shader_spirv)
	_node_levels_pipeline = _rd.compute_pipeline_create(_node_levels_shader)
# idea: lbvh based on https://github.com/MircoWerner/VkLBVH
# https://research.nvidia.com/sites/default/files/pubs/2010-06_HLBVH-Hierarchical-LBVH/HLBVH-final.pdf
# as far as i understand it: 
# 1) morton : each "potent" has a digit from the next coordinate slice x0,y0,z0,x1,y1,z1,...
# 2) therfore, all morton codes can be radix sorted and can easily create the splits 
# 3) build the hierachy -> find out how to write to the Image
# - rework the vertex generatioon
# TODO shader replacement + refactor 
# (reuse material-maker/addons/material_maker/engine/pipeline/compute_shader.gd if possible)
# Prepare buffers from mesh for lbvh 
# TODO material idx -> prefix sum
# https://github.com/linebender/vello/blob/custom-hal-archive-with-shaders/tests/shader/prefix.comp
static func _extract_mesh(mesh:Mesh)-> Dictionary:
	# TODO extend for all surfaces! and create LUT with that
	var ctx := {}
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	# NOTE we will write that later in a LUT to enable material id textures/masks
	var surface_ids := PackedInt32Array()
	
	var vertex_offset := 0
	
	for surface_idx in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_idx)
		print("surface %d , size: "% surface_idx,arrays.size())
		for j in arrays.size():
			print(j,": ",type_string(typeof(arrays[j])))
		if arrays.is_empty():
			continue
		var surface_vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		vertices.append_array(surface_vertices)
		surface_ids.append(surface_idx)
		if arrays[Mesh.ARRAY_INDEX] == null:
			for i in surface_vertices.size():
				indices.append(vertex_offset+i)
		else:
			var surface_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]			#TODO compute shader ? maybe prefix sum or custom
			for i in surface_indices: 
				indices.append(vertex_offset+i)
		vertex_offset += surface_vertices.size()
		
	ctx[KEY_VERTICES] = vertices
	ctx[KEY_INDICES] = indices
	ctx[KEY_SURFACE_IDS] = surface_ids
	ctx[KEY_SCENE_AABB] = mesh.get_aabb() # TODO measure performance reduce shader otherwise
	return ctx
	
func _create_buffers(ctx:Dictionary)-> BVHStatus:
	var vertices : PackedVector3Array = ctx[KEY_VERTICES]
	var indices : PackedInt32Array = ctx[KEY_INDICES]
	if vertices.is_empty() or indices.is_empty() or indices.size()%3!=0:
		return BVHStatus.INVALID_MESH
		
	var vertex_bytes := PackedByteArray()
	#TODO -> GPU 
	vertex_bytes.resize(vertices.size()*16) # 16 bc alignment?
	for i in vertices.size():
		var offset = i*16
		vertex_bytes.encode_float(i*16+0,vertices[i].x)
		vertex_bytes.encode_float(i*16+4,vertices[i].y)
		vertex_bytes.encode_float(i*16+8,vertices[i].z)
		vertex_bytes.encode_float(i*16+12,0.0)
	ctx[KEY_VERTEX_BUFFER] = _rd.storage_buffer_create(vertex_bytes.size(),vertex_bytes)
	var index_bytes := PackedByteArray()
	index_bytes.resize(indices.size()*4)
	for i in indices.size():
		index_bytes.encode_u32(i*4,indices[i])
	ctx[KEY_INDEX_BUFFER] = _rd.storage_buffer_create(index_bytes.size(),index_bytes)
	var tri_count : int = ctx[KEY_INDICES].size()/3
	ctx[KEY_ELEMENT_BUFFER] = _rd.storage_buffer_create(tri_count*ELEMENT_SIZE) # aabb min + aabb max + id = 12+12+4 
	return BVHStatus.OK
	
func _generate_element_aabbs(ctx:Dictionary)->BVHStatus:
	# create aabbs for each element/primtive/triangle
	var uniforms : Array[RDUniform] = []
	
	# vertices
	var vertex_uniform = RDUniform.new()
	vertex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertex_uniform.binding = 0
	vertex_uniform.add_id(ctx[KEY_VERTEX_BUFFER])
	uniforms.push_back(vertex_uniform)
	
	# indices
	var index_uniform := RDUniform.new()
	index_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	index_uniform.binding = 1
	index_uniform.add_id(ctx[KEY_INDEX_BUFFER])
	uniforms.push_back(index_uniform)
	
	# output_elements
	var element_uniform := RDUniform.new()
	element_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	element_uniform.binding = 2
	element_uniform.add_id(ctx[KEY_ELEMENT_BUFFER])
	uniforms.push_back(element_uniform)
	
	var uniform_set := _rd.uniform_set_create(uniforms,_triangle_aabb_shader,0)
	var tri_count : int = ctx[KEY_INDICES].size()/3
	var push_constants := PackedByteArray()
	push_constants.resize(4)
	push_constants.encode_u32(0,tri_count)
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_triangle_aabb_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list,uniform_set,0)
	_rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	_rd.compute_list_dispatch(compute_list,ceili(float(tri_count)/64.0),1,1)
	
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return BVHStatus.OK
	
static func generate_triangle_aabbs_test(mesh:Mesh,rendering_device:RenderingDevice,ctx :Dictionary)->BVHStatus:
	# context needs to be {} at this stage
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	var _ctx = generator._extract_mesh(mesh)
	ctx.merge(_ctx,true)
	var status = generator._create_buffers(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs(ctx)
	if status != BVHStatus.OK:
		return status
	return BVHStatus.OK

static func calculate_triangle_aabb_cpu(vertices:PackedVector3Array,indices:PackedInt32Array,tri:int)->AABB:
	var index_offset = tri*3
	var v0 := vertices[indices[index_offset+0]]
	var v1 := vertices[indices[index_offset+1]]
	var v2 := vertices[indices[index_offset+2]]
	
	var min_v := Vector3(min(v0.x,min(v1.x,v2.x)),min(v0.y,min(v1.y,v2.y)),min(v0.z,min(v1.z,v2.z)))
	var max_v := Vector3(max(v0.x,max(v1.x,v2.x)),max(v0.y,max(v1.y,v2.y)),max(v0.z,max(v1.z,v2.z)))
	return AABB(min_v,max_v-min_v)
	


func _generate_morton_codes(ctx:Dictionary)->BVHStatus:
	var uniforms : Array[RDUniform] = []
	if not _morton_pipeline.is_valid():
		return BVHStatus.PIPELINE_CREATE_FAILED
	var primitive_count : int =  ctx[KEY_INDICES].size()/3
	ctx[KEY_MORTON_BUFFER] = _rd.storage_buffer_create(primitive_count*8) # uint morton + uint primitive idx
	
	var morton_uniform := RDUniform.new()
	morton_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	morton_uniform.binding = 0
	morton_uniform.add_id(ctx[KEY_MORTON_BUFFER])
	uniforms.push_back(morton_uniform)
	
	var element_uniform = RDUniform.new()
	element_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	element_uniform.binding = 1
	element_uniform.add_id(ctx[KEY_ELEMENT_BUFFER])
	uniforms.push_back(element_uniform)
	
	var uniform_set := _rd.uniform_set_create(uniforms,_morton_shader,0)
	var aabb : AABB = ctx[KEY_SCENE_AABB]
	
	var push_constants := PackedByteArray()
	push_constants.resize(28) # 1*4 2*12 = 28+ alignment
	push_constants.encode_u32(0,primitive_count)
	push_constants.encode_float(4,aabb.position.x)
	push_constants.encode_float(8,aabb.position.y)
	push_constants.encode_float(12,aabb.position.z)
	push_constants.encode_float(16,aabb.end.x)
	push_constants.encode_float(20,aabb.end.y)
	push_constants.encode_float(24,aabb.end.z)
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_morton_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list,uniform_set,0)
	_rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	_rd.compute_list_dispatch(compute_list,ceili(float(primitive_count)/64.0),1,1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return BVHStatus.OK

static func generate_morton_codes_test(mesh:Mesh,
										rendering_device : RenderingDevice,
										ctx:Dictionary)->BVHStatus:
	assert(ctx.is_empty())
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	ctx.merge(generator._extract_mesh(mesh),true)
	var status := generator._create_buffers(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_morton_codes(ctx)
	if status != BVHStatus.OK:
		return status
	return BVHStatus.OK

# cpu version of the morton code, for testing
static func _expandBits(v:int)->int:
	v = (v * 0x00010001) & 0xFF0000FF
	v = (v * 0x00000101) & 0x0F00F00F
	v = (v * 0x00000011) & 0xC30C30C3
	v = (v * 0x00000005) & 0x49249249
	return v
static func _morton3d(x:float,y:float,z:float)->int:
	x = min(max(x * 1024.0, 0.0), 1023.0)
	y = min(max(y * 1024.0, 0.0), 1023.0)
	z = min(max(z * 1024.0, 0.0), 1023.0)
	var xx = _expandBits(int(x))
	var yy = _expandBits(int(y))
	var zz = _expandBits(int(z))
	return xx * 4 + yy * 2 + zz
	
static func calculate_morton_code_cpu(aabb:AABB,scene_aabb:AABB)->int:
	var center := aabb.get_center()
	var mapped := (center-scene_aabb.position)/scene_aabb.size
	return _morton3d(mapped.x,mapped.y,mapped.z)

func _sort_morton_codes(ctx:Dictionary) -> BVHStatus:
	if not _radix_pipeline.is_valid():
		return BVHStatus.PIPELINE_CREATE_FAILED
	var uniforms : Array[RDUniform] = []
	var num_elements :int =  ctx[KEY_INDICES].size() / 3
	
	ctx[KEY_MORTON_BUFFER_TMP] = _rd.storage_buffer_create(num_elements*8)
	var morton_in_uniform := RDUniform.new()
	morton_in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	morton_in_uniform.binding = 0
	morton_in_uniform.add_id(ctx[KEY_MORTON_BUFFER])
	uniforms.push_back(morton_in_uniform)
	
	var morton_out_uniform := RDUniform.new()
	morton_out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	morton_out_uniform.binding = 1
	morton_out_uniform.add_id(ctx[KEY_MORTON_BUFFER_TMP])
	uniforms.push_back(morton_out_uniform)
	
	var uniform_set := _rd.uniform_set_create(uniforms,_radix_shader,1)
	var push_constants := PackedByteArray()
	push_constants.resize(4)
	push_constants.encode_u32(0,num_elements)
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_radix_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list,uniform_set,1)
	_rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	_rd.compute_list_dispatch(compute_list,1,1,1)
	_rd.compute_list_end()
	
	_rd.submit()
	_rd.sync()
	
	return BVHStatus.OK

static func generate_sort_morton_test(mesh:Mesh,
										rendering_device : RenderingDevice,
										ctx:Dictionary)->BVHStatus:
	assert(ctx.is_empty())
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	ctx.merge(generator._extract_mesh(mesh),true)
	var status := generator._create_buffers(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_morton_codes(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._sort_morton_codes(ctx)
	#TEST
	var data := rendering_device.buffer_get_data(ctx[KEY_MORTON_BUFFER])
	for i in range(min(20, data.size() / 8)):
		print(
		i,
		" morton=",
		data.decode_u32(i * 8),
		" element=",
		data.decode_u32(i * 8 + 4)
		)
	if status != BVHStatus.OK:
		return status
	return BVHStatus.OK

func _build_hierarchy(ctx:Dictionary)->BVHStatus:
	if not _hierarchy_pipeline.is_valid():
		return BVHStatus.PIPELINE_CREATE_FAILED
	var uniforms : Array[RDUniform] = []
	
	var num_elements : int = ctx[KEY_INDICES].size()/3
	var total_nodes := num_elements * 2-1
	
	ctx[KEY_LBVH_BUFFER] = _rd.storage_buffer_create(
		total_nodes*LBVH_NODE_SIZE # node size
	)
	ctx[KEY_LBVH_CONSTRUCTION_INFO_BUFFER] = _rd.storage_buffer_create(
		total_nodes*8 # parent + visited count
	)
	
	var morton_uniform := RDUniform.new()
	morton_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	morton_uniform.binding = 0
	morton_uniform.add_id(ctx[KEY_MORTON_BUFFER])
	uniforms.push_back(morton_uniform)
	
	var elements_uniform := RDUniform.new()
	elements_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	elements_uniform.binding = 1
	elements_uniform.add_id(ctx[KEY_ELEMENT_BUFFER])
	uniforms.push_back(elements_uniform)
	
	# output bvh!
	var lbvh_uniform := RDUniform.new()
	lbvh_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	lbvh_uniform.binding = 2
	lbvh_uniform.add_id(ctx[KEY_LBVH_BUFFER])
	uniforms.push_back(lbvh_uniform)
	
	var construction_uniform := RDUniform.new()
	construction_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	construction_uniform.binding = 3
	construction_uniform.add_id(ctx[KEY_LBVH_CONSTRUCTION_INFO_BUFFER])
	uniforms.push_back(construction_uniform)
	
	var uniform_set := _rd.uniform_set_create(uniforms,_hierarchy_shader,2) #the original shader uses set 2, why not
	
	var push_constants = PackedByteArray()
	push_constants.resize(8)# NOTE was 8, seems i need multiple of 16
	push_constants.encode_u32(0,num_elements)
	push_constants.encode_u32(4,1) # absolute pointers
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_hierarchy_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list,uniform_set,2)
	_rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	_rd.compute_list_dispatch(compute_list,ceili(float(num_elements) / 256.0),1,1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return BVHStatus.OK

	
func _build_bounding_boxes(ctx:Dictionary)->BVHStatus:

	var uniforms : Array[RDUniform] = []
	var num_elements : int = ctx[KEY_INDICES].size()/3
	
	var lbvh_uniform := RDUniform.new()
	lbvh_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	lbvh_uniform.binding = 0
	lbvh_uniform.add_id(ctx[KEY_LBVH_BUFFER])
	uniforms.push_back(lbvh_uniform)
	
	var construction_uniform := RDUniform.new()
	construction_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	construction_uniform.binding = 1
	construction_uniform.add_id(ctx[KEY_LBVH_CONSTRUCTION_INFO_BUFFER])
	uniforms.push_back(construction_uniform)
	
	var uniform_set := _rd.uniform_set_create(uniforms,_bb_node_shader,3)
	var push_constants := PackedByteArray()
	push_constants.resize(8)
	push_constants.encode_u32(0,num_elements)
	push_constants.encode_u32(4,1)# absolute pointers
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_bb_node_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list,uniform_set,3)
	_rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	
	_rd.compute_list_dispatch(compute_list,ceili(float(num_elements)/256.0),1,1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return BVHStatus.OK
	
# TODO actually make pipeline steps XD
static func generate_hierarchy_test(mesh:Mesh,
										rendering_device : RenderingDevice,
										ctx:Dictionary)->BVHStatus:
	assert(ctx.is_empty())
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	ctx.merge(generator._extract_mesh(mesh),true)
	var status := generator._create_buffers(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_morton_codes(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._sort_morton_codes(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._build_hierarchy(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._build_bounding_boxes(ctx)
	if status != BVHStatus.OK:
		return status
	
	var num_elements : int = ctx[KEY_INDICES].size() / 3
	var leaf_offset := num_elements - 1
	var lbvh_bytes : PackedByteArray = rendering_device.buffer_get_data(ctx[KEY_LBVH_BUFFER])
	print("==============Leaf check ==========")
	
	for i in range(min(20, num_elements)):
		var node := MMBvhGeneratorGPU.read_lbvh_node(lbvh_bytes, leaf_offset + i)
		print(
		"leaf ", i,
		" node=", leaf_offset + i,
		" left=", node.left,
		" right=", node.right,
		" primitive=", node.primitive,
		" min=", node.aabb.position,
		" max=", node.aabb.end
		)
	print("============= Internal Nodes =============")

	for i in range(min(20, num_elements - 1)):
		var node := MMBvhGeneratorGPU.read_lbvh_node(lbvh_bytes, i)

		print(
			"node=", i,
			" left=", node.left,
			" right=", node.right,
			" primitive=", node.primitive
		)
	return BVHStatus.OK

func _calculate_node_sizes(ctx)->BVHStatus:
	if not _node_sizes_pipeline.is_valid():
		return BVHStatus.PIPELINE_CREATE_FAILED
	var uniforms : Array[RDUniform] = []
	var num_elements : int = ctx[KEY_INDICES].size()/3
	var node_count := num_elements*2-1
	ctx[KEY_NODE_SIZE_BUFFER] = _rd.storage_buffer_create(node_count*4)
	
	var lbvh_uniform := RDUniform.new()
	lbvh_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	lbvh_uniform.binding = 0
	lbvh_uniform.add_id(ctx[KEY_LBVH_BUFFER])
	uniforms.push_back(lbvh_uniform)
	
	var node_size_uniform := RDUniform.new()
	node_size_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	node_size_uniform.binding = 1
	node_size_uniform.add_id(ctx[KEY_NODE_SIZE_BUFFER])
	uniforms.push_back(node_size_uniform)
	
	var uniform_set := _rd.uniform_set_create(
		uniforms,
		_node_sizes_shader,
		0
	)
	var push_constants := PackedByteArray()
	push_constants.resize(4)
	push_constants.encode_u32(0,node_count)
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_node_sizes_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list,uniform_set,0)
	_rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	_rd.compute_list_dispatch(compute_list,ceili(float(node_count)/256),1,1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return BVHStatus.OK

func _calculate_node_levels(ctx:Dictionary)->BVHStatus:
	if not _node_levels_pipeline.is_valid():
		return BVHStatus.PIPELINE_CREATE_FAILED
	var num_elements : int = ctx[KEY_INDICES].size()/3
	var total_nodes := num_elements * 2-1
	ctx[KEY_NODE_LEVEL_BUFFER] = _rd.storage_buffer_create(total_nodes*4)
	var uniforms : Array[RDUniform] = []
	
	var construction_uniform := RDUniform.new()
	construction_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	construction_uniform.binding = 0
	construction_uniform.add_id(ctx[KEY_LBVH_CONSTRUCTION_INFO_BUFFER])
	uniforms.push_back(construction_uniform)
	
	var levels_uniform := RDUniform.new()
	levels_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	levels_uniform.binding = 1
	levels_uniform.add_id(ctx[KEY_NODE_LEVEL_BUFFER])
	uniforms.push_back(levels_uniform)
	
	var uniform_set := _rd.uniform_set_create(
		uniforms,
		_node_levels_shader,
		0
	)
	var push_constants := PackedByteArray()
	push_constants.resize(8)
	push_constants.encode_u32(0,total_nodes)
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_node_levels_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list,uniform_set,0)
	_rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	_rd.compute_list_dispatch(compute_list,ceili(float(total_nodes)/256),1,1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return BVHStatus.OK
	
	
func _scan_node_sizes(ctx:Dictionary)->BVHStatus:
	var tri_count : int = ctx[KEY_INDICES].size()/3
	var node_count := tri_count*2-1
	ctx[KEY_NODE_OFFSET_BUFFER] = _prefix_scan.exclusive_scan_u32(ctx[KEY_NODE_SIZE_BUFFER],node_count)
	if not ctx[KEY_NODE_OFFSET_BUFFER].is_valid():
		return BVHStatus.PIPELINE_CREATE_FAILED
	return BVHStatus.OK

func _writeout_mm_bvh(ctx:Dictionary)->BVHStatus:
	if not _writeout_pipeline.is_valid():
		return BVHStatus.PIPELINE_CREATE_FAILED
	var num_elements : int = ctx[KEY_INDICES].size()/3
	var total_nodes := num_elements * 2-1
	var node_data_start : int = ctx[KEY_NODE_DATA_START]
	var uniforms : Array[RDUniform] = []
	
	var lbvh_uniform := RDUniform.new()
	lbvh_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	lbvh_uniform.binding = 0
	lbvh_uniform.add_id(ctx[KEY_LBVH_BUFFER])
	uniforms.push_back(lbvh_uniform)
	
	var offsets_uniform := RDUniform.new()
	offsets_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	offsets_uniform.binding = 1
	offsets_uniform.add_id(ctx[KEY_NODE_OFFSET_BUFFER])
	uniforms.push_back(offsets_uniform)
	
	var levels_uniform := RDUniform.new()
	levels_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	levels_uniform.binding =2
	levels_uniform.add_id(ctx[KEY_NODE_LEVEL_BUFFER])
	uniforms.push_back(levels_uniform)
	
	var verices_uniform := RDUniform.new()
	verices_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	verices_uniform.binding =3
	verices_uniform.add_id(ctx[KEY_VERTEX_BUFFER])
	uniforms.push_back(verices_uniform)
	
	var indices_uniform := RDUniform.new()
	indices_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	indices_uniform.binding =4
	indices_uniform.add_id(ctx[KEY_INDEX_BUFFER])
	uniforms.push_back(indices_uniform)
	

	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	output_uniform.binding = 5
	output_uniform.add_id(ctx[KEY_BVH_IMAGE])
	uniforms.push_back(output_uniform)

	var uniform_set := _rd.uniform_set_create(
		uniforms,
		_writeout_shader,
		0
	)
	var push_constants := PackedByteArray()
	push_constants.resize(12)
	push_constants.encode_u32(0,total_nodes)
	push_constants.encode_u32(4, node_data_start)
	push_constants.encode_u32(8, ctx[KEY_SIDE])
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_writeout_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list,uniform_set,0)
	_rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	_rd.compute_list_dispatch(compute_list,ceili(float(total_nodes)/256),1,1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()
	return BVHStatus.OK

func _allocate_mm_output(ctx:Dictionary)->BVHStatus:
	var size_data : PackedByteArray = _rd.buffer_get_data(ctx[KEY_NODE_SIZE_BUFFER])
	var offset_data : PackedByteArray = _rd.buffer_get_data(ctx[KEY_NODE_OFFSET_BUFFER])
	var node_data_texels := get_total_node_texels(size_data,offset_data)
	var primitive_count: int = ctx[KEY_INDICES].size() / 3
	var node_count := primitive_count * 2 - 1
	ctx[KEY_NODE_DATA_START] = MM_HEADER_TEXELS+  node_count
	var total_texels = ctx[KEY_NODE_DATA_START] + node_data_texels
	var side := ceili(sqrt(float(total_texels)))
	ctx[KEY_SIDE] = side
	var image := Image.create(side,side,false,Image.FORMAT_RGBAF)
	print(
	"node_count=", node_count,
	" node_data_start=", ctx[KEY_NODE_DATA_START],
	" node_data_texels=", node_data_texels,
	" total_texels=", total_texels,
	" side=", side,
	" capacity=", side * side,
	" spare=", side * side - total_texels
)
	ctx[KEY_BVH_IMAGE] = image
	ctx[KEY_BVH_IMAGE_TEXTURE] = ImageTexture.create_from_image(image)

	# R,G,B,A * 4Byte = 16
	var format := RDTextureFormat.new()
	format.width = ctx[KEY_SIDE]
	format.height = ctx[KEY_SIDE] 
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = (RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
						RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
						RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT)
	
	ctx[KEY_BVH_IMAGE] = _rd.texture_create(format,RDTextureView.new())
	return BVHStatus.OK
	
# all lbvh steps
func _generate_lbvh(ctx:Dictionary)-> BVHStatus:
	var start_time : int = Time.get_ticks_usec()
	var status := _generate_element_aabbs(ctx)
	print("stage 1: elementwise aabb : %d usec" % (Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _generate_morton_codes(ctx)
	print("stage 2: mortoncodes : %d usec" % (Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _sort_morton_codes(ctx)
	print("stage 3: sort mortoncodes : %d usec" % (Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _build_hierarchy(ctx)
	print("stage 4: build hierarchy: %d usec" %(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _build_bounding_boxes(ctx)
	print("stage 5: build bounding boxes: %d usec"%(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	return BVHStatus.OK

# conversion to mm compatible format
func _generate_mm_bvh(ctx:Dictionary)->BVHStatus:
	var start_time : int = Time.get_ticks_usec()
	var status := _calculate_node_levels(ctx)
	print("stage 6: node_level_calculation : %d usec"%(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _calculate_node_sizes(ctx)
	print("stage 7: node_level_calculation : %d usec"%(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _scan_node_sizes(ctx)
	print("stage 8: storage offset_generation : %d usec"%(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	status = _allocate_mm_output(ctx)
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _writeout_mm_bvh(ctx)
	print("stage 9: writeout : %d usec"%(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	return BVHStatus.OK
	
func _cleanup(ctx:Dictionary)-> void:
	# free all temp buffers at once
	const to_free := [
		KEY_VERTEX_BUFFER,
		KEY_INDEX_BUFFER,
		KEY_ELEMENT_BUFFER,
		KEY_MORTON_BUFFER,
		KEY_MORTON_BUFFER_TMP,
		KEY_LBVH_BUFFER,
		KEY_LBVH_CONSTRUCTION_INFO_BUFFER,
		KEY_NODE_SIZE_BUFFER,
		KEY_NODE_OFFSET_BUFFER,
		KEY_NODE_LEVEL_BUFFER,
		KEY_PACKED_BVH_BUFFER, 
		KEY_NODE_WRITEOUT_BUFFER,
		KEY_BVH_IMAGE
	]
	for key in to_free:
		if ctx.has(key):
			var rid : RID = ctx[key]
			if rid.is_valid():
				_rd.free_rid(rid)

func _generate(mesh:Mesh)->ImageTexture:
	var total_start_time : int= Time.get_ticks_usec()
	var ctx := _extract_mesh(mesh)
	var status := _create_buffers(ctx)
	print("extract mesh: %d usec",Time.get_ticks_usec()-total_start_time)
	var start_time : int= Time.get_ticks_usec()
	if status != BVHStatus.OK:
		print("oh noes")
		return null
	status = _generate_lbvh(ctx)
	print("lbvh : %d usec",Time.get_ticks_usec()-start_time)

	if status != BVHStatus.OK:
		_cleanup(ctx)
		return null
	start_time = Time.get_ticks_usec()
	status = _generate_mm_bvh(ctx)
	print("mm conversion : %d usec",Time.get_ticks_usec()-start_time)

	if status != BVHStatus.OK:
		_cleanup(ctx)
		return null
	var texture : ImageTexture = ctx[KEY_BVH_IMAGE_TEXTURE]
	#_cleanup(ctx)
	print("total : %d usec",Time.get_ticks_usec()-total_start_time)
	
	print("textures..")
	print(ctx[KEY_BVH_IMAGE])
	print(ctx[KEY_BVH_IMAGE_TEXTURE])
	print(texture)
	var bytes: PackedByteArray = _rd.texture_get_data(ctx[KEY_BVH_IMAGE], 0)
	var image := Image.create_from_data(
		ctx[KEY_SIDE],
		ctx[KEY_SIDE],
		false,
		Image.FORMAT_RGBAF,
		bytes
	)


	print(image.get_pixel(0,0))
	print(image.get_pixel(1,0))
	print(image.get_pixel(2,0))

	#image.save_png("user://gpu_debug.png")

	return ImageTexture.create_from_image(image)
	return texture
	
static func generate(mesh: Mesh,add_vertex_info : bool = false,rendering_device:RenderingDevice=null) -> ImageTexture:
	var generator := get_instance(rendering_device)
	return generator._generate(mesh)

static func read_lbvh_node(data:PackedByteArray,node_idx:int)->LBVHNode:
	var offset := node_idx * LBVH_NODE_SIZE
	var node := LBVHNode.new()
	node.left = data.decode_s32(offset+0)
	node.right = data.decode_s32(offset+4)
	node.primitive = data.decode_u32(offset+8)
	var min := Vector3(
		data.decode_float(offset+12),
		data.decode_float(offset+16),
		data.decode_float(offset+20))
	var max := Vector3(
		data.decode_float(offset+24),
		data.decode_float(offset+28),
		data.decode_float(offset+32))
	node.aabb = AABB(min,max-min)
	return node
	
static func read_lbvh_nodes(data:PackedByteArray)->Array[LBVHNode]:
	var num_nodes = data.size()/LBVH_NODE_SIZE
	var retvar : Array[LBVHNode] = []
	retvar.resize(num_nodes)
	for idx in range(num_nodes):
		retvar[idx] = read_lbvh_node(data,idx)
	return retvar

static func traverse_lbvh_cpu(nodes:Array[LBVHNode],node_idx:int,visitor:Callable)->void:
	var node := nodes[node_idx]
	visitor.call(node_idx,node)
	if node.left !=INVALID_POINTER:
		traverse_lbvh_cpu(nodes,node.left,visitor)
	if node.right !=INVALID_POINTER:
		traverse_lbvh_cpu(nodes,node.right,visitor)
		
static func read_lbvh_construction_infos(data:PackedByteArray)->Array[LBVHConstructionInfo]:
	var count := data.size() /LBVH_CONSTRUCTION_INFO_SIZE
	var result : Array[LBVHConstructionInfo] = []
	result.resize(count)
	for idx in count:
		var offset := idx * LBVH_CONSTRUCTION_INFO_SIZE
		var info := LBVHConstructionInfo.new()
		info.parent = data.decode_u32(offset)
		info.visitationCount = data.decode_u32(offset+4)
		result[idx] = info
	return result

static func get_total_node_texels(size_data:PackedByteArray,offset_data:PackedByteArray)->int:
	var last := size_data.size() /4 -1
	return offset_data.decode_u32(last*4)+size_data.decode_u32(last*4)
#static func generate(mesh: Mesh,add_vertex_info : bool = false) -> ImageTexture:
#	pass
static func validate_hierarchy(nodes:Array[LBVHNode],construction:Array,primitive_count:int)->bool:
	var node_count := primitive_count *2-1
	var leaf_offset := primitive_count -1
	var incoming := PackedInt32Array()
	incoming.resize(node_count)
	
	for idx in range(leaf_offset):
		var node:=nodes[idx]
		for child in [node.left,node.right]:
			#valid children
			if(child<0 or child>=node_count):
				print("node %d has invalid child %d"%[idx,child])
				return false
			#children parent loop
			if (child==idx):
				print("node %d references itself"%idx)
				return false
			incoming[child]+=1
			#construction info mismatch regarding parent children relationship
			if(construction[child].parent!=idx):
				print("node %d -> child %d , but child parent is %d"%[idx,child,construction[child].parent])
				return false
		# root should not have parents
	if(incoming[0]!=0):
		print("root has %d parents!"%incoming[0])
		return false
	for idx in range(1, node_count):
		if (incoming[idx]!=1):
			print("node %d has %d parents"%[idx,incoming[idx]])
			return false
	#verify tree by dfs
	var state:= PackedByteArray()
	state.resize(node_count)
	var stack: Array[Array] = [[0,false]]
	while not stack.is_empty():
		var entry := stack.pop_back()
		var idx :int = entry[0]
		var exiting: bool = entry[1]
		if exiting:
			state[idx] = 2
			continue
		if (state[idx] ==1):
			print("cycle detected at node %d"%idx)
			return false
		if state[idx] == 2:
			continue
		state[idx] = 1
		stack.append([idx,true])
		if idx<leaf_offset:
			stack.append([nodes[idx].right,false])
			stack.append([nodes[idx].left,false])
	for idx in range(node_count):
		if state[idx] != 2:
			print("node %d is unreachable from root"%idx)
			return false
	return true
func _get_mesh(mesh:ArrayMesh)->void:
	pass
