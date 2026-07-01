extends Object
class_name MMBvhGeneratorGPU
const KEY_VERTICES := "vertices"
const KEY_INDICES := "indices"
const KEY_SURFACE_IDS := "surface_ids"
const KEY_SCENE_AABB := "scene_aabb"
const KEY_VERTEX_BUFFER := "vertex_buffer"
const KEY_INDEX_BUFFER := "index_buffer"
const KEY_MORTON_BUFFER := "morton_buffer"
const KEY_MORTON_BUFFER_TMP := "morton_buffer"
const KEY_ELEMENT_BUFFER := "element_buffer"
const KEY_LBVH_BUFFER := "lbvh_buffer"
const KEY_LBVH_CONSTRUCTION_INFO_BUFFER = "lbvh_construction_info_buffer"
const KEY_BVH_IMAGE := "bvh_image"
const KEY_BVH_IMAGE_TEXTURE := "bvh_image_texture"


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
	
	for surface_idx in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface_idx)
		var surface_vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var surface_indices : PackedInt32Array = arrays [Mesh.ARRAY_INDEX]
		vertices.append_array(surface_vertices)
		for i in surface_vertices.size(): #TODO compute shader ?
			indices.append(vertex_offset+i)
			surface_ids.append(surface_idx)
		vertex_offset += surface_vertices.size()
	ctx[KEY_VERTICES] = vertices
	ctx[KEY_INDICES] = indices
	ctx[KEY_SURFACE_IDS] = surface_ids
	ctx[KEY_SCENE_AABB] = mesh.get_aabb() # TODO measure performance reduce shader otherwise
	return ctx
	
static func _create_buffers(ctx:Dictionary)-> void:
	var rd:= RenderingServer.get_rendering_device()
	var vertices : PackedVector3Array = ctx[KEY_VERTICES]
	var indices : PackedInt32Array = ctx[KEY_INDICES]
	var vertex_bytes := PackedByteArray()
	vertex_bytes.resize(vertices.size()*3*4)
	for i in vertices.size():
		vertex_bytes.encode_float(i*12+0,vertices[i].x)
		vertex_bytes.encode_float(i*12+4,vertices[i].y)
		vertex_bytes.encode_float(i*12+8,vertices[i].z)
	ctx[KEY_VERTEX_BUFFER] = rd.storage_buffer_create(vertex_bytes.size(),vertex_bytes)
	var index_bytes := PackedByteArray()
	index_bytes.resize(indices.size()*4)
	for i in indices.size():
		index_bytes.encode_u32(i*4,indices[i])
	ctx[KEY_INDEX_BUFFER] = rd.storage_buffer_create(index_bytes.size(),index_bytes)
	var tri_count : int = ctx[KEY_INDICES].size()/3
	ctx[KEY_MORTON_BUFFER] = rd.storage_buffer_create(tri_count*8)
	ctx[KEY_ELEMENT_BUFFER] = rd.storage_buffer_create(tri_count*28) # aabb min + aabb max + id = 12+12+4 
	
static func _generate_element_aabbs(ctx:Dictionary)->void:
	# create aabbs for each element/primtive/triangle
	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/triangle_aabb.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	var shader := rd.shader_create_from_spirv(shader_spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var uniforms : Array[RDUniform] = []
	
	# vertices
	var vertex_uniform = RDUniform.new()
	vertex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertex_uniform.binding = 0
	vertex_uniform.add_id(ctx.vertex_buffer)
	uniforms.push_back(vertex_uniform)
	
	# indices
	var index_uniform := RDUniform.new()
	index_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	index_uniform.binding = 1
	index_uniform.add_id(ctx.index_buffer)
	uniforms.push_back(index_uniform)
	
	# output_elements
	var element_uniform := RDUniform.new()
	element_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	element_uniform.binding = 2
	element_uniform.add_id(ctx.element_buffer)
	uniforms.push_back(element_uniform)
	
	var uniform_set := rd.uniform_set_create(uniforms,shader,0)
	var tri_cout : int = ctx.indices.size()/3
	var push_constants := PackedByteArray()
	push_constants.resize(4)
	push_constants.encode_u32(0,tri_cout)
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list,pipeline)
	rd.compute_list_bind_uniform_set(compute_list,uniform_set,0)
	rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	rd.compute_list_dispatch(compute_list,ceili(float(tri_cout)/64.0),1,1)
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
static func _generate_morton_codes(ctx:Dictionary)->void:
	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/morton.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	var shader := rd.shader_create_from_spirv(shader_spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var uniforms : Array[RDUniform] = []
	
	var primitive_count : int =  ctx.indices.size()/3
	ctx.morton_buffer = rd.storage_buffer_create(primitive_count*8) # uint morton + uint primitive idx
	
	var morton_uniform := RDUniform.new()
	morton_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	morton_uniform.binding = 0
	morton_uniform.add_id(ctx.morton_buffer)
	uniforms.push_back(morton_uniform)
	
	var element_uniform = RDUniform.new()
	element_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	element_uniform.binding = 1
	element_uniform.add_id(ctx.element_buffer)
	uniforms.push_back(element_uniform)
	
	var uniform_set := rd.uniform_set_create(uniforms,shader,0)
	var aabb : AABB = ctx.scene_aabb
	
	var push_constants := PackedByteArray()
	push_constants.resize(32) # 1*4 2*12 = 28+ alignment
	push_constants.encode_u32(0,primitive_count)
	push_constants.encode_float(4,aabb.position.x)
	push_constants.encode_float(8,aabb.position.y)
	push_constants.encode_float(12,aabb.position.z)
	push_constants.encode_float(16,aabb.end.x)
	push_constants.encode_float(20,aabb.end.y)
	push_constants.encode_float(24,aabb.end.z)
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list,pipeline)
	rd.compute_list_bind_uniform_set(compute_list,uniform_set,0)
	rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	rd.compute_list_dispatch(compute_list,ceili(float(primitive_count)/64.0),1,1)
	rd.compute_list_end()
	rd.submit()

static func _sort_morton_codes(ctx:Dictionary) -> void:
	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/sort_morton_codes.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	var shader := rd.shader_create_from_spirv(shader_spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var uniforms : Array[RDUniform] = []
	var num_elements :int =  ctx.indices.size() / 3
	
	ctx[KEY_MORTON_BUFFER_TMP] = rd.storage_buffer_create(num_elements*8)
	var morton_in_uniform := RDUniform.new()
	morton_in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	morton_in_uniform.binding = 0
	morton_in_uniform.add_id(ctx.morton_buffer_tmp)
	uniforms.push_back(morton_in_uniform)
	
	var morton_out_uniform := RDUniform.new()
	morton_out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	morton_in_uniform.binding = 1
	morton_in_uniform.add_id(ctx.morton_buffer_tmp)
	uniforms.push_back(morton_out_uniform)
	
	var uniform_set := rd.uniform_set_create(uniforms,shader,1)
	var push_constants := PackedByteArray()
	push_constants.resize(4)
	push_constants.encode_u32(0,num_elements)
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list,pipeline)
	rd.compute_list_bind_uniform_set(compute_list,uniform_set,1)
	rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	rd.compute_list_dispatch(compute_list,1,1,1)
	rd.compute_list_end()
	
	rd.submit()
	rd.sync()

static func _build_hierarchy(ctx:Dictionary)->void:
	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/build_hierarchy.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	var shader := rd.shader_create_from_spirv(shader_spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var uniforms : Array[RDUniform] = []
	
	var num_elements : int = ctx[KEY_INDICES].size()/3
	var total_nodes := num_elements * 2-1
	
	ctx[KEY_LBVH_BUFFER] = rd.storage_buffer_create(
		total_nodes*36 # node size
	)
	ctx[KEY_LBVH_CONSTRUCTION_INFO_BUFFER] = rd.storage_buffer_create(
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
	
	var uniform_set := rd.uniform_set_create(uniforms,shader,2) #the original shader uses set 2, why not
	
	var push_constants = PackedByteArray()
	push_constants.resize(8)
	push_constants.encode_u32(0,num_elements)
	push_constants.encode_u32(4,1) # absolute pointers
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list,pipeline)
	rd.compute_list_bind_uniform_set(compute_list,uniform_set,2)
	rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	rd.compute_list_dispatch(compute_list,ceili(float(num_elements) / 256.0),1,1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()

static func _build_bounding_boxes(ctx:Dictionary)->void:
	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	var shader_file := load("res://addons/material_maker/map_generator/lbvh/build_bounding_boxes.glsl")
	var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
	var shader := rd.shader_create_from_spirv(shader_spirv)
	var pipeline := rd.compute_pipeline_create(shader)
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
	
	var uniform_set := rd.uniform_set_create(uniforms,shader,3)
	var push_constants := PackedByteArray()
	push_constants.resize(8)
	push_constants.encode_u32(0,num_elements)
	push_constants.encode_u32(4,1)# absolute pointers
	
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list,pipeline)
	rd.compute_list_bind_uniform_set(compute_list,uniform_set,3)
	rd.compute_list_set_push_constant(compute_list,push_constants,push_constants.size())
	
	rd.compute_list_dispatch(compute_list,ceili(float(num_elements)/256.0),1,1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	
# TODO this is ancually quite nice to have around
# so id refactor it in a new class later, like parallel primitives
# and generate shader code?
# see prefix sum : intro into parallel computing



#static func generate(mesh: Mesh,add_vertex_info : bool = false) -> ImageTexture:
#	pass
	
func _get_mesh(mesh:ArrayMesh)->void:
	pass
