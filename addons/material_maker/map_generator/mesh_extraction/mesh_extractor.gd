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
var _rd : RenderingDevice

func _init(rd:RenderingDevice)->void:
	_rd = rd
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
		total_vertex_count +=vertices.size()
		total_index_count += indices.size() if indices != null else vertices.size()
	
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
	
	var vertex_output_uniform := RDUniform.new()
	vertex_output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertex_output_uniform.binding = 2
	vertex_output_uniform.add_id(vertex_buffer)
	
	var index_output_uniform := RDUniform.new()
	index_output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	index_output_uniform.binding = 3
	index_output_uniform.add_id(index_buffer)
	
	var surface_id_output_uniform := RDUniform.new()
	surface_id_output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	surface_id_output_uniform.binding = 4
	surface_id_output_uniform.add_id(surface_id_buffer)
	
	for surface_idx  in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices = arrays[Mesh.ARRAY_INDEX]
		var indexed = indices!=null
		var vertex_count := vertices.size()
		var index_count = indices.size() if indices != null else vertex_count
		
		var vertex_input_buffer := _rd.storage_buffer_create(vertices.size()*16,vertices.to_byte_array())
		var vertex_input_uniform := RDUniform.new()
		vertex_input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		vertex_input_uniform.binding = 0
		vertex_input_uniform.add_id(vertex_input_buffer)
		
		var input_index_buffer := RID()
		var index_input_uniform := RDUniform.new()
		index_input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		index_input_uniform.binding = 1
		if indexed: 
			var index_data:PackedByteArray = indices.to_byte_array()
			input_index_buffer = _rd.storage_buffer_create(index_data.size(),index_data)
			index_input_uniform.add_id(input_index_buffer)
		
		vertex_offset += vertex_count
		index_offset += index_count
	
	return ctx
