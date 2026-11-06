extends Object
class_name MMBvhGeneratorGPU
# LBVH Overview
# This is a GPU BVH builder (LBVH),an integration of 
# https://github.com/MircoWerner/VkLBVH 
# also a good read : https://research.nvidia.com/sites/default/files/pubs/2010-06_HLBVH-Hierarchical-LBVH/HLBVH-final.pdf
# Architecture wise the bvh building is called via the static generate function
# which internally creates a singleton instance of the builder 
# Each stage is done within a compute shader pipeline
# For each BVH, a context dictionary is handed over each stage
# 
# - mesh extraction and buffer creation
# - 1: 	element wise aabb
#		creates an aabb for each triangle
#		it is stored in the elementwise buffers
# -2 :	for each element a morton code is generated
#		this is a spatial hash encoding x,y,z of the aabb center 
#		in an alternating form
# -3 :	the elements are sorted regarding their morton codes 
#		where spatial near elements are nearby
# -4 : 	To get leaf nodes with 6 children like in the original bvh code
#		clusters of max 6 elements are created and written in a buffer 
#		as is the morton code of the aabb center
# -5 :	Same as earlier, the clusters are sorted according the morton codes
# -6 : 	Now that the clusters are arranged in a spatial ordering,
#		A hierarchy is built, but this time bottom up and in parallel
# -7 :	The compound AABBs are built 
#
#	At this point we have built the complete bvh .
#	Within the following stages, the format is adjusted to a mm bvh compatible form!
#	(_generate_mm_bvh)
# -8 :	for each node, the level is computed (by going pack the parent nodes and count)
# -9 :	the size of each node is calculated, depending on the number of children (leaf node) or inbetween nodes
# -10 :	the storage position of each node is calculated using a prefix scan (blelloch scan)
#		example (1,2,1,1,3,..) -> (0,1,3,4,5,8)....
# -11 : the writeout shader, which encodes everything into a texture
# Finally the generated bvh texture is read back to the cpu
# and the resources from the context dictionary are cleaned up
# which leaves you with the regular old BVH

const KEY_VERTICES : String = "vertices"
const KEY_INDICES : String = "indices"
const KEY_SURFACE_IDS : String = "surface_ids"
const KEY_SCENE_AABB : String = "scene_aabb"
const KEY_VERTEX_BUFFER : String = "vertex_buffer"
const KEY_INDEX_BUFFER : String = "index_buffer"
const KEY_MORTON_BUFFER : String = "morton_buffer"
const KEY_MORTON_BUFFER_TMP : String = "morton_buffer_tmp"
const KEY_ELEMENT_BUFFER : String = "element_buffer"
const KEY_LBVH_BUFFER : String = "lbvh_buffer"
const KEY_LBVH_CONSTRUCTION_INFO_BUFFER : String = "lbvh_construction_info_buffer"
const KEY_BVH_IMAGE : String = "bvh_image"
const KEY_BVH_IMAGE_TEXTURE : String = "bvh_image_texture"
const KEY_NODE_SIZE_BUFFER : String = "node_size_buffer"
const KEY_NODE_OFFSET_BUFFER : String = "node_offset_buffer"
const KEY_NODE_LEVEL_BUFFER : String = "node_level_buffer"
const KEY_PACKED_BVH_BUFFER: String = "packed_bvh_buffer"
const KEY_NODE_WRITEOUT_BUFFER: String = "node_writeout_buffer"
const KEY_NODE_DATA_START : String = "node_data_start"
#const KEY_SIDE := "side" non square texture, matching cpu mm
const KEY_WIDTH : String = "width"
const KEY_HEIGHT : String = "height"
const MAX_TEXTURE_WIDTH : int = 16384
const LBVH_NODE_SIZE : int = 36
const ELEMENT_SIZE : int = 28
const LBVH_CONSTRUCTION_INFO_SIZE : int = 8 # uint +int
const INVALID_POINTER : int = 0
const KEY_BVH_IMAGE_RID : String =  "bvh_image_rid"
const MM_HEADER_TEXELS : int = 1
const MM_NODE_TEXELS : int = 3 #TODO replace in shader
const MM_LEAF_TEXELS : int = 5 #TODO selectable , for normal mode, or bake mode

const LEAF_SIZE : int = 6 
const MORTON_ELEMENT_SIZE : int = 8

const KEY_CLUSTER_COUNT : String = "cluster_count"
const KEY_CLUSTER_ELEMENT_BUFFER : String = "cluster_element_buffer"
const KEY_CLUSTER_MORTON_BUFFER : String = "cluster_morton_buffer"
const KEY_CLUSTER_MORTON_BUFFER_TMP : String = "cluster_morton_buffer_tmp"
const KEY_ADD_VERTEX_INFO : String = "add_vertex_info"
# TODO refactor constants to common constants! (for mesh extractor)
const KEY_VERTEX_COUNT : String = "vertex_count"
const KEY_INDEX_COUNT : String = "index_count"

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

# stages:

var _triangle_aabb_stage : MMComputeShaderStage
var _morton_stage : MMComputeShaderStage
var _radix_stage : MMComputeShaderStage
var _leaf_cluster_stage : MMComputeShaderStage
var _hierarchy_stage : MMComputeShaderStage
var _bb_node_stage : MMComputeShaderStage
var _node_sizes_stage : MMComputeShaderStage
var _writeout_stage : MMComputeShaderStage
var _node_levels_stage : MMComputeShaderStage
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
	_init_stages()
	
func _init_stages():
	const BASE_PATH := "res://addons/material_maker/map_generator/lbvh/"
	var common: String = load(BASE_PATH + "LBVH_common.tres").text
	var stages :Array[Dictionary]= [
			{"name":"Triangle AABB","res":"triangle_aabb.tres","stage":"_triangle_aabb_stage"},
			{"name":"Morton","res":"morton.tres","stage":"_morton_stage"},
			{"name":"Radix","res":"sort_morton_codes.tres","stage":"_radix_stage"},
			{"name":"Leaf Cluster","res":"leaf_cluster.tres","stage":"_leaf_cluster_stage"},
			{"name":"Hierarchy","res":"build_hierarchy.tres","stage":"_hierarchy_stage"},
			{"name":"Bounding Boxes","res":"build_bounding_boxes.tres","stage":"_bb_node_stage"},
			{"name": "Node Sizes", "res": "node_size_prefix.tres", "stage": "_node_sizes_stage"},
			{"name":"Node Levels","res":"generate_node_levels.tres","stage":"_node_levels_stage"},
			{"name":"MM Writeout","res":"writeout_mm_bvh.tres","stage":"_writeout_stage"},
		]
	for config : Dictionary in stages:
		var stage : MMComputeShaderStage = MMComputeShaderStage.new(_rd,config["name"],true)
		var source : String = load(BASE_PATH+config["res"]).text
		var success: bool = stage.set_shader(source,{"@LBVH_COMMON":common})
		assert(success,"Failed to compile %s"%[config["res"]])
		set(config["stage"],stage)

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
	ctx[KEY_VERTEX_COUNT] = vertices.size()
	ctx[KEY_INDEX_COUNT] = indices.size()
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
	var tri_count : int = ctx[KEY_INDEX_COUNT]/3
	ctx[KEY_ELEMENT_BUFFER] = _rd.storage_buffer_create(tri_count*ELEMENT_SIZE) # aabb min + aabb max + id = 12+12+4 
	return BVHStatus.OK
	

func _generate_element_aabbs_stage(ctx:Dictionary)->BVHStatus:
	var stage : MMComputeShaderStage= _triangle_aabb_stage
	stage.set_uniform(0,0,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_VERTEX_BUFFER])
	stage.set_uniform(0,1,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_INDEX_BUFFER])
	stage.set_uniform(0,2,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_ELEMENT_BUFFER])
	
	var tri_count : int = ctx[KEY_INDEX_COUNT]/3
	var pc := PackedByteArray()
	pc.resize(4)
	pc.encode_u32(0,tri_count)
	stage.set_push_constants(pc)
	var groups = ceili(float(tri_count)/64.0)
	if not stage.dispatch(groups,1,1):
		return BVHStatus.PIPELINE_CREATE_FAILED
	return BVHStatus.OK
	
static func generate_triangle_aabbs_test(mesh:Mesh,rendering_device:RenderingDevice,ctx :Dictionary)->BVHStatus:
	# context needs to be {} at this stage
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	var _ctx = generator._extract_mesh(mesh)
	ctx.merge(_ctx,true)
	var status = generator._create_buffers(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs_stage(ctx)
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
	var primitive_count : int = ctx[KEY_INDEX_COUNT]/3
	ctx[KEY_MORTON_BUFFER] = _rd.storage_buffer_create(primitive_count*MORTON_ELEMENT_SIZE)
	_morton_stage.set_uniform(0,0,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_MORTON_BUFFER])
	_morton_stage.set_uniform(0,1,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_ELEMENT_BUFFER])
	var aabb : AABB = ctx[KEY_SCENE_AABB]
	var pc : PackedByteArray = PackedByteArray()
	pc.resize(28)
	pc.encode_u32(0, primitive_count)
	pc.encode_float(4, aabb.position.x)
	pc.encode_float(8, aabb.position.y)
	pc.encode_float(12, aabb.position.z)
	pc.encode_float(16, aabb.end.x)
	pc.encode_float(20, aabb.end.y)
	pc.encode_float(24, aabb.end.z)
	_morton_stage.set_push_constants(pc)
	
	var groups := ceili(float(primitive_count) / 64.0)
	if not _morton_stage.dispatch(groups,1,1):
		return BVHStatus.PIPELINE_CREATE_FAILED
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
	status = generator._generate_element_aabbs_stage(ctx)
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

func _generate_leaf_clusters(ctx:Dictionary)->BVHStatus:
	var triangle_count: int = ctx[KEY_INDEX_COUNT] / 3
	var cluster_count: int = ceili(float(triangle_count) / float(LEAF_SIZE))
	ctx[KEY_CLUSTER_COUNT] = cluster_count
	ctx[KEY_CLUSTER_ELEMENT_BUFFER] = _rd.storage_buffer_create(cluster_count * ELEMENT_SIZE)
	ctx[KEY_CLUSTER_MORTON_BUFFER] = _rd.storage_buffer_create(cluster_count * MORTON_ELEMENT_SIZE)
	_leaf_cluster_stage.set_uniform(0, 0, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, ctx[KEY_ELEMENT_BUFFER])
	_leaf_cluster_stage.set_uniform(0, 1, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, ctx[KEY_MORTON_BUFFER])
	_leaf_cluster_stage.set_uniform(0, 2, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, ctx[KEY_CLUSTER_ELEMENT_BUFFER])
	_leaf_cluster_stage.set_uniform(0, 3, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, ctx[KEY_CLUSTER_MORTON_BUFFER])
	
	var aabb: AABB = ctx[KEY_SCENE_AABB]
	var pc : PackedByteArray = PackedByteArray()
	pc.resize(32)
	pc.encode_u32(0, triangle_count)
	pc.encode_u32(4, LEAF_SIZE)
	pc.encode_float(8, aabb.position.x)
	pc.encode_float(12, aabb.position.y)
	pc.encode_float(16, aabb.position.z)
	pc.encode_float(20, aabb.end.x)
	pc.encode_float(24, aabb.end.y)
	pc.encode_float(28, aabb.end.z)
	
	_leaf_cluster_stage.set_push_constants(pc)
	
	if not _leaf_cluster_stage.dispatch(ceili(float(cluster_count) / 256.0), 1, 1):
		return BVHStatus.PIPELINE_CREATE_FAILED
		
	return BVHStatus.OK
	
static func generate_leaf_clusters_test(
	mesh:Mesh,
	rendering_device: RenderingDevice,
	ctx:Dictionary
)-> BVHStatus:
	assert(ctx.is_empty())
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	ctx.merge(generator._extract_mesh(mesh),true)
	var status := generator._create_buffers(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs_stage(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_morton_codes(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._sort_morton_codes(ctx)
	return generator._generate_leaf_clusters(ctx)

func _sort_morton_codes(
	ctx:Dictionary,
	morton_key: String = KEY_MORTON_BUFFER,
	temp_key: String = KEY_MORTON_BUFFER_TMP,
	num_elements: int = -1
	) -> BVHStatus:
	if num_elements < 0:
		num_elements = ctx[KEY_INDEX_COUNT] / 3
	ctx[temp_key] = _rd.storage_buffer_create(num_elements*MORTON_ELEMENT_SIZE)
	_radix_stage.set_uniform(1,0,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[morton_key])
	_radix_stage.set_uniform(1,1,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[temp_key])
	var pc : PackedByteArray = PackedByteArray()
	pc.resize(4)
	pc.encode_u32(0, num_elements)

	_radix_stage.set_push_constants(pc)
	
	if not _radix_stage.dispatch(1,1,1):
		return BVHStatus.PIPELINE_CREATE_FAILED
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
	status = generator._generate_element_aabbs_stage(ctx)
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
	var num_elements: int = ctx[KEY_CLUSTER_COUNT]
	var total_nodes: int = num_elements * 2 - 1
	ctx[KEY_LBVH_BUFFER] = _rd.storage_buffer_create(total_nodes * LBVH_NODE_SIZE)
	ctx[KEY_LBVH_CONSTRUCTION_INFO_BUFFER] = _rd.storage_buffer_create(total_nodes * LBVH_CONSTRUCTION_INFO_SIZE)
	_hierarchy_stage.set_uniform(2, 0, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_CLUSTER_MORTON_BUFFER])
	_hierarchy_stage.set_uniform(2, 1, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_CLUSTER_ELEMENT_BUFFER])
	_hierarchy_stage.set_uniform(2, 2, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_LBVH_BUFFER])
	_hierarchy_stage.set_uniform(2, 3, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_LBVH_CONSTRUCTION_INFO_BUFFER])
	var pc : PackedByteArray = PackedByteArray()
	pc.resize(8)
	pc.encode_u32(0, num_elements)
	pc.encode_u32(4, 1) # Absolute pointers
	_hierarchy_stage.set_push_constants(pc)
	if not _hierarchy_stage.dispatch(ceili(float(num_elements) / 256.0), 1, 1):
			return BVHStatus.PIPELINE_CREATE_FAILED
			
	return BVHStatus.OK
	
func _build_bounding_boxes(ctx:Dictionary)->BVHStatus:
	var num_elements: int = ctx[KEY_CLUSTER_COUNT]
	_bb_node_stage.set_uniform(3, 0, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_LBVH_BUFFER])
	_bb_node_stage.set_uniform(3, 1, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_LBVH_CONSTRUCTION_INFO_BUFFER])
	var pc : PackedByteArray = PackedByteArray()
	pc.resize(8)
	pc.encode_u32(0, num_elements)
	pc.encode_u32(4, 1)
	
	_bb_node_stage.set_push_constants(pc)
	if not _bb_node_stage.dispatch(ceili(float(num_elements) / 256.0), 1, 1):
		return BVHStatus.PIPELINE_CREATE_FAILED
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
	status = generator._generate_element_aabbs_stage(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_morton_codes(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._sort_morton_codes(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._generate_leaf_clusters(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._sort_morton_codes(
		ctx,
		KEY_CLUSTER_MORTON_BUFFER,
		KEY_CLUSTER_MORTON_BUFFER_TMP,
		ctx[KEY_CLUSTER_COUNT]
	)
	if status != BVHStatus.OK:
		return status
	status = generator._build_hierarchy(ctx)
	if status != BVHStatus.OK:
		return status
	status = generator._build_bounding_boxes(ctx)
	if status != BVHStatus.OK:
		return status
		
	var num_elements : int = ctx[KEY_CLUSTER_COUNT]
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
	var num_elements: int = ctx[KEY_CLUSTER_COUNT]
	var node_count: int = num_elements * 2 - 1
	ctx[KEY_NODE_SIZE_BUFFER] = _rd.storage_buffer_create(node_count * 4)
	_node_sizes_stage.set_uniform(0, 0, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_LBVH_BUFFER])
	_node_sizes_stage.set_uniform(0, 1, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_NODE_SIZE_BUFFER])
	var pc : PackedByteArray = PackedByteArray()
	pc.resize(16)
	pc.encode_u32(0, node_count)
	pc.encode_u32(4, ctx[KEY_INDEX_COUNT] / 3)
	pc.encode_u32(8, LEAF_SIZE)
	pc.encode_u32(12, int(ctx[KEY_ADD_VERTEX_INFO]))
	_node_sizes_stage.set_push_constants(pc)
	
	if not _node_sizes_stage.dispatch(ceili(float(node_count) / 256.0), 1, 1):
		return BVHStatus.PIPELINE_CREATE_FAILED
	return BVHStatus.OK
	
func _calculate_node_levels(ctx:Dictionary)->BVHStatus:
	var num_elements: int = ctx[KEY_CLUSTER_COUNT]
	var total_nodes: int = num_elements * 2 - 1
	ctx[KEY_NODE_LEVEL_BUFFER] = _rd.storage_buffer_create(total_nodes * 4)
	_node_levels_stage.set_uniform(0, 0, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_LBVH_CONSTRUCTION_INFO_BUFFER])
	_node_levels_stage.set_uniform(0, 1, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,ctx[KEY_NODE_LEVEL_BUFFER])
	var pc := PackedByteArray()
	pc.resize(8)
	pc.encode_u32(0, total_nodes)
	pc.encode_u32(4, 0)
	_node_levels_stage.set_push_constants(pc)
	
	if not _node_levels_stage.dispatch(ceili(float(total_nodes) / 256.0), 1, 1):
		return BVHStatus.PIPELINE_CREATE_FAILED
	return BVHStatus.OK
	
func _scan_node_sizes(ctx:Dictionary)->BVHStatus:
	var tri_count : int = ctx[KEY_CLUSTER_COUNT]
	var node_count := tri_count*2-1
	ctx[KEY_NODE_OFFSET_BUFFER] = _prefix_scan.exclusive_scan_u32(ctx[KEY_NODE_SIZE_BUFFER],node_count)
	if not ctx[KEY_NODE_OFFSET_BUFFER].is_valid():
		return BVHStatus.PIPELINE_CREATE_FAILED
	return BVHStatus.OK

func _writeout_mm_bvh(ctx:Dictionary)->BVHStatus:
	var num_elements: int = ctx[KEY_CLUSTER_COUNT]
	var total_nodes: int = num_elements * 2 - 1
	var node_data_start: int = ctx[KEY_NODE_DATA_START]
	_writeout_stage.set_uniform(0, 0, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, ctx[KEY_LBVH_BUFFER])
	_writeout_stage.set_uniform(0, 1, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, ctx[KEY_NODE_OFFSET_BUFFER])
	_writeout_stage.set_uniform(0, 2, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, ctx[KEY_NODE_LEVEL_BUFFER])
	_writeout_stage.set_uniform(0, 3, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, ctx[KEY_VERTEX_BUFFER])
	_writeout_stage.set_uniform(0, 4, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, ctx[KEY_INDEX_BUFFER])
	_writeout_stage.set_uniform(0, 5, RenderingDevice.UNIFORM_TYPE_IMAGE, ctx[KEY_BVH_IMAGE])
	_writeout_stage.set_uniform(0, 6, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, ctx[KEY_MORTON_BUFFER])
	var pc : PackedByteArray = PackedByteArray()
	pc.resize(24)
	pc.encode_u32(0, total_nodes)
	pc.encode_u32(4, node_data_start)
	pc.encode_u32(8, ctx[KEY_WIDTH])
	pc.encode_u32(12, ctx[KEY_INDEX_COUNT] / 3)
	pc.encode_u32(16, LEAF_SIZE)
	pc.encode_u32(20, int(ctx[KEY_ADD_VERTEX_INFO]))
	
	_writeout_stage.set_push_constants(pc)
	
	if not _writeout_stage.dispatch(ceili(float(total_nodes) / 256.0), 1, 1):
		return BVHStatus.PIPELINE_CREATE_FAILED
		
	return BVHStatus.OK

func _allocate_mm_output(ctx:Dictionary)->BVHStatus:
	var size_data : PackedByteArray = _rd.buffer_get_data(ctx[KEY_NODE_SIZE_BUFFER])
	var offset_data : PackedByteArray = _rd.buffer_get_data(ctx[KEY_NODE_OFFSET_BUFFER])
	var node_data_texels := get_total_node_texels(size_data,offset_data)
	var primitive_count: int = ctx[KEY_CLUSTER_COUNT]
	var node_count := primitive_count * 2 - 1
	ctx[KEY_NODE_DATA_START] = MM_HEADER_TEXELS+  node_count
	var total_texels = ctx[KEY_NODE_DATA_START] + node_data_texels

	var width := mini(total_texels, MAX_TEXTURE_WIDTH)
	var height := ceili(float(total_texels) / float(width))

	ctx[KEY_WIDTH] = width
	ctx[KEY_HEIGHT] = height

	print(
		"node_count=", node_count,
		" node_data_start=", ctx[KEY_NODE_DATA_START],
		" node_data_texels=", node_data_texels,
		" total_texels=", total_texels,
		" width=", width,
		" height=", height,
		" capacity=", width * height,
		" spare=", width * height - total_texels
	)
	
	#ctx[KEY_BVH_IMAGE] = image
	#ctx[KEY_BVH_IMAGE_TEXTURE] = ImageTexture.create_from_image(image)

	# R,G,B,A * 4Byte = 16
	var format := RDTextureFormat.new()
	format.width = width
	format.height = height 
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
	#var status := _generate_element_aabbs(ctx)
	var status : BVHStatus = _generate_element_aabbs_stage(ctx)
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
	status = _generate_leaf_clusters(ctx)
	print("cluster leaves: %d usec" % (Time.get_ticks_usec() - start_time))
	if status != BVHStatus.OK:
		return status

	start_time = Time.get_ticks_usec()
	status = _sort_morton_codes(
		ctx,
	KEY_CLUSTER_MORTON_BUFFER,
	KEY_CLUSTER_MORTON_BUFFER_TMP,
	ctx[KEY_CLUSTER_COUNT]
	)
	print("stage 4: sort clusters: %d usec" % (Time.get_ticks_usec() - start_time))
	if status != BVHStatus.OK:
		return status
		
	start_time = Time.get_ticks_usec()
	status = _build_hierarchy(ctx)
	print("stage 5: build hierarchy: %d usec" %(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _build_bounding_boxes(ctx)
	print("stage 6: build bounding boxes: %d usec"%(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	return BVHStatus.OK

# conversion to mm compatible format
func _generate_mm_bvh(ctx:Dictionary)->BVHStatus:
	var start_time : int = Time.get_ticks_usec()
	var status := _calculate_node_levels(ctx)
	print("stage 7: node_level_calculation : %d usec"%(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _calculate_node_sizes(ctx)
	print("stage 8: node_level_calculation : %d usec"%(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _scan_node_sizes(ctx)
	print("stage 9: storage offset_generation : %d usec"%(Time.get_ticks_usec()-start_time))
	if status != BVHStatus.OK:
		return status
	status = _allocate_mm_output(ctx)
	if status != BVHStatus.OK:
		return status
	start_time = Time.get_ticks_usec()
	status = _writeout_mm_bvh(ctx)
	print("stage 10: writeout : %d usec"%(Time.get_ticks_usec()-start_time))
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
		KEY_CLUSTER_ELEMENT_BUFFER,
		KEY_CLUSTER_MORTON_BUFFER,
		KEY_CLUSTER_MORTON_BUFFER_TMP,
		KEY_BVH_IMAGE
	]
	for key in to_free:
		if ctx.has(key):
			var rid : RID = ctx[key]
			if rid.is_valid():
				_rd.free_rid(rid)
func cleanup()->void:
	_triangle_aabb_stage.clear()
	_morton_stage.clear()
	_radix_stage.clear()
	_leaf_cluster_stage.clear()
	_hierarchy_stage.clear()
	_bb_node_stage.clear()
	_node_sizes_stage.clear()
	_writeout_stage.clear()
	_node_levels_stage.clear()
	_prefix_scan.cleanup()
			
func _generate(mesh:Mesh,add_vertex_info:bool=true)->ImageTexture:
	var total_start_time : int= Time.get_ticks_usec()
	var ctx := _extract_mesh(mesh)
	var status := _create_buffers(ctx)
	print("extract mesh: %d usec",Time.get_ticks_usec()-total_start_time)
	var start_time : int= Time.get_ticks_usec()
	if status != BVHStatus.OK:
		print("oh noes")
		return null
	ctx[KEY_ADD_VERTEX_INFO] = add_vertex_info
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
	#var texture : ImageTexture = ctx[KEY_BVH_IMAGE_TEXTURE]
	#_cleanup(ctx)
	print("total : %d usec",Time.get_ticks_usec()-total_start_time)
	
	#print("textures..")
	#print(ctx[KEY_BVH_IMAGE])
	#print(ctx[KEY_BVH_IMAGE_TEXTURE])
	#print(texture)
	var bytes: PackedByteArray = _rd.texture_get_data(ctx[KEY_BVH_IMAGE], 0)
	var image := Image.create_from_data(
		ctx[KEY_WIDTH],
		ctx[KEY_HEIGHT],
		false,
		Image.FORMAT_RGBAF,
		bytes
	)


	print(image.get_pixel(0,0))
	print(image.get_pixel(1,0))
	print(image.get_pixel(2,0))

	#image.save_png("user://gpu_debug.png")

	return ImageTexture.create_from_image(image)
	
static func generate(mesh: Mesh,add_vertex_info : bool = false,rendering_device:RenderingDevice=null) -> ImageTexture:
	var generator := get_instance(rendering_device)
	return generator._generate(mesh,add_vertex_info)

func _create_buffers_from_extraction(ctx:Dictionary,extracted:Dictionary)->BVHStatus:
		var vertex_count : int = extracted[KEY_VERTEX_COUNT]
		var index_count : int = extracted[KEY_INDEX_COUNT]
		
		if vertex_count == 0 or index_count == 0 or index_count %3!=0:
			return BVHStatus.INVALID_MESH
		ctx[KEY_VERTEX_BUFFER] = extracted[KEY_VERTICES]
		ctx[KEY_INDEX_BUFFER] = extracted[KEY_INDICES]
		ctx[KEY_SCENE_AABB] = extracted[KEY_SCENE_AABB]
		ctx[KEY_VERTEX_COUNT] = vertex_count
		ctx[KEY_INDEX_COUNT] = index_count
		ctx[KEY_ELEMENT_BUFFER] = _rd.storage_buffer_create((index_count/3)*ELEMENT_SIZE)
		return BVHStatus.OK

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
