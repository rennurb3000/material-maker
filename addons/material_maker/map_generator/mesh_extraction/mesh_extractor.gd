extends Object
class_name  MMMeshExtractor

const KEY_VERTICES := "vertices"
const KEY_INDICES := "indices"
const KEY_SURFACE_IDS := "surface_ids"
const KEY_SCENE_AABB := "scene_aabb"

const KEY_VERTEX_COUNT := "vertex_count"
const KEY_INDEX_COUNT := "index_count"

const KEY_SURFACE_ID_LUT := "surface_id_lut"
const KEY_POSITION_LUT := "position_lut"
const KEY_NORMAL_LUT := "normal_lut"
const KEY_TANGENT_LUT := "tangent_lut"
const KEY_COLOR_LUT := "vertex_color_lut"
const KEY_UV_LUT := "uv_lut"
const KEY_UV2_LUT := "uv2_lut"

const HAS_NORMAL := 1 << 0;
const HAS_TANGENT:= 1 << 1;
const HAS_COLOR  := 1 << 2;
const HAS_UV     := 1 << 3;
const HAS_UV2    := 1 << 4;

var _rd : RenderingDevice
var _shader : RID
var _pipeline : RID
func _storage_uniform(binding:int,buffer:RID)->RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform
	
func _image_uniform(binding:int,texture: RID )->RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform
	
func _create_lut(width : int, height: int, format: RenderingDevice.DataFormat)->RID:
		var texture_format := RDTextureFormat.new()
		texture_format.width = width
		texture_format.height = height
		texture_format.format = format
		texture_format.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		 | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT 
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
		return _rd.texture_create(texture_format,RDTextureView.new())
func _init(rd:RenderingDevice)->void:
	_rd = rd
	var shader_file : RDShaderFile = load("res://addons/material_maker/map_generator/mesh_extraction/vertex_concat.glsl")
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv())
	_pipeline = _rd.compute_pipeline_create(_shader) 
#func extract_cpu(mesh:Mesh) ->Dictionary:
#	pass
	
func extract_gpu(mesh:Mesh)->Dictionary:
	var ctx := {}
	var total_vertex_count := 0
	var total_index_count := 0
	for surface_idx in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices = arrays[Mesh.ARRAY_INDEX]
		var indexed = indices != null and not indices.is_empty()
		total_index_count += indices.size() if indexed else vertices.size()
		total_vertex_count +=vertices.size()
	
	if total_vertex_count == 0:
		return {}
	var lut_width := maxi(1, ceili(sqrt(float(total_vertex_count))))
	var lut_height := maxi(1,ceili(float(total_vertex_count)/lut_width))
	ctx["lut_width"] = lut_width
	ctx["lut_height"] = lut_height
	ctx[KEY_POSITION_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_NORMAL_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_TANGENT_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_COLOR_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_UV_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_UV2_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_SURFACE_ID_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32_UINT)
	
	
	
	var vertex_offset := 0
	var index_offset := 0
	
	var vertex_buffer := _rd.storage_buffer_create(total_vertex_count*16)
	var index_buffer := _rd.storage_buffer_create(total_index_count*4)
	var surface_id_buffer := _rd.storage_buffer_create(total_vertex_count*4)
	ctx[KEY_VERTICES] = vertex_buffer
	ctx[KEY_INDICES] = index_buffer
	ctx[KEY_SURFACE_IDS] = surface_id_buffer
	ctx[KEY_SCENE_AABB]= mesh.get_aabb()
	ctx[KEY_VERTEX_COUNT] = total_vertex_count
	ctx[KEY_INDEX_COUNT] = total_index_count
	
	var output_uniforms:Array[RDUniform]= [
		_storage_uniform(7,vertex_buffer),
		_storage_uniform(8,index_buffer),
		_image_uniform(9,ctx[KEY_POSITION_LUT]),
		_image_uniform(10,ctx[KEY_NORMAL_LUT]),
		_image_uniform(11,ctx[KEY_TANGENT_LUT]),
		_image_uniform(12,ctx[KEY_COLOR_LUT]),
		_image_uniform(13,ctx[KEY_UV_LUT]),
		_image_uniform(14,ctx[KEY_UV2_LUT]),
		_image_uniform(15,ctx[KEY_SURFACE_ID_LUT]),
		_storage_uniform(16, surface_id_buffer),
	]
	
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list,_pipeline)
	
	var temp_buffers :Array[RID] = []
	var uniform_sets : Array[RID] = []
	
	for surface_idx  in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			continue
		var indices = arrays[Mesh.ARRAY_INDEX]
		var vertex_count := vertices.size()
		var indexed = not indices.is_empty()
		var index_count = indices.size() if indexed else vertex_count
		
		if vertex_count == 0:
			continue 
		var attribute_flags := 0;
		var input_uniforms : Array[RDUniform] = []
		
		# pos
		var position_data := vertices.to_byte_array()
		var position_buffer := _rd.storage_buffer_create(position_data.size(),position_data)
		temp_buffers.append(position_buffer)
		input_uniforms.append(_storage_uniform(0,position_buffer))
		
		#indices (or dummy for non indexed surface)
		var index_data = indices.to_byte_array() if indexed else PackedInt32Array([0]).to_byte_array()
		var input_index_buffer := _rd.storage_buffer_create(index_data.size(),index_data)
		temp_buffers.append(input_index_buffer)
		input_uniforms.append(_storage_uniform(1,input_index_buffer))
		
		# Normals
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		if not normals.is_empty():
			attribute_flags |= HAS_NORMAL

		var normal_data := normals.to_byte_array() if not normals.is_empty() \
			else PackedFloat32Array([0.0]).to_byte_array()

		var normal_buffer := _rd.storage_buffer_create(
			normal_data.size(), normal_data
		)
		temp_buffers.append(normal_buffer)
		input_uniforms.append(_storage_uniform(2, normal_buffer))

		# Tangents
		var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		if not tangents.is_empty():
			attribute_flags |= HAS_TANGENT

		var tangent_data := tangents.to_byte_array() if not tangents.is_empty() \
		else PackedFloat32Array([0.0, 0.0, 0.0, 1.0]).to_byte_array()

		var tangent_buffer := _rd.storage_buffer_create(
			tangent_data.size(), tangent_data
			)
		temp_buffers.append(tangent_buffer)
		input_uniforms.append(_storage_uniform(3, tangent_buffer))

		# Colors
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
		if not colors.is_empty():
			attribute_flags |= HAS_COLOR

		var color_data := colors.to_byte_array() if not colors.is_empty() \
		else PackedColorArray([Color.WHITE]).to_byte_array()

		var color_buffer := _rd.storage_buffer_create(
		color_data.size(), color_data
		)
		temp_buffers.append(color_buffer)
		input_uniforms.append(_storage_uniform(4, color_buffer))

		# UV
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		if not uvs.is_empty():
			attribute_flags |= HAS_UV

		var uv_data := uvs.to_byte_array() if not uvs.is_empty() \
		else PackedVector2Array([Vector2.ZERO]).to_byte_array()

		var uv_buffer := _rd.storage_buffer_create(
		uv_data.size(), uv_data
		)
		temp_buffers.append(uv_buffer)
		input_uniforms.append(_storage_uniform(5, uv_buffer))

		# UV2
		var uv2s: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array() 
		if not uv2s.is_empty():
			attribute_flags |= HAS_UV2

		var uv2_data := uv2s.to_byte_array() if not uv2s.is_empty() \
		else PackedVector2Array([Vector2.ZERO]).to_byte_array()

		var uv2_buffer := _rd.storage_buffer_create(
		uv2_data.size(), uv2_data
		)
		temp_buffers.append(uv2_buffer)
		input_uniforms.append(_storage_uniform(6, uv2_buffer))

		# Bind all inputs and shared outputs
		var uniforms: Array[RDUniform] = []
		uniforms.append_array(input_uniforms)
		uniforms.append_array(output_uniforms)

		var uniform_set := _rd.uniform_set_create(uniforms, _shader, 0)
		uniform_sets.append(uniform_set)

		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)

		var push_constants := PackedInt32Array([
			vertex_count,
			index_count,
			vertex_offset,
			index_offset,
			surface_idx,
			int(indexed),
			attribute_flags,
			lut_width
			]).to_byte_array()

		_rd.compute_list_set_push_constant(
		compute_list,
		push_constants,
		push_constants.size()
		)
		
		var workgroups := ceili(
		float(maxi(vertex_count, index_count)) / 256.0
		)
		_rd.compute_list_dispatch(compute_list, workgroups, 1, 1)
		_rd.compute_list_add_barrier(compute_list)
		vertex_offset += vertex_count
		index_offset += index_count
	_rd.compute_list_end()
	
	_rd.submit()
	_rd.sync()

	for uniform_set in uniform_sets:
		_rd.free_rid(uniform_set)
	for buffer in temp_buffers:
		_rd.free_rid(buffer)
	return ctx

func cleanup()->void:
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
