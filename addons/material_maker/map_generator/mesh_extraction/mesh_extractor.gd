extends Object
class_name  MMMeshExtractor

const KEY_VERTICES : String = "vertices"
const KEY_INDICES : String = "indices"
const KEY_SURFACE_IDS : String = "surface_ids"
const KEY_SCENE_AABB :String = "scene_aabb"

const KEY_VERTEX_COUNT : String = "vertex_count"
const KEY_INDEX_COUNT : String = "index_count"

const KEY_SURFACE_ID_LUT : String = "surface_id_lut"
const KEY_POSITION_LUT : String = "position_lut"
const KEY_NORMAL_LUT : String = "normal_lut"
const KEY_TANGENT_LUT : String = "tangent_lut"
const KEY_COLOR_LUT : String = "vertex_color_lut"
const KEY_UV_LUT : String = "uv_lut"
const KEY_UV2_LUT : String = "uv2_lut"

const LUT_KEYS: Array[String] = [
	KEY_SURFACE_ID_LUT,
	KEY_POSITION_LUT,
	KEY_NORMAL_LUT,
	KEY_TANGENT_LUT,
	KEY_COLOR_LUT,
	KEY_UV_LUT,
	KEY_UV2_LUT
]

const HAS_NORMAL : int = 1 << 0
const HAS_TANGENT: int = 1 << 1
const HAS_COLOR  : int = 1 << 2
const HAS_UV     : int = 1 << 3
const HAS_UV2    : int = 1 << 4

var _rd : RenderingDevice

var _stage : MMComputeShaderStage

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
		var texture_format : RDTextureFormat = RDTextureFormat.new()
		texture_format.width = width
		texture_format.height = height
		texture_format.format = format
		texture_format.usage_bits = (
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		 | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT 
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
		return _rd.texture_create(texture_format,RDTextureView.new())

func _get_total_counts(mesh:Mesh)->Dictionary:
	var total_vertex_count : int = 0
	var total_index_count : int = 0
	for surface_idx  in range(mesh.get_surface_count()):
		var arrays : Array = mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			continue
		var indices : PackedInt32Array = (arrays[Mesh.ARRAY_INDEX]if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array())
		var indexed : bool = not indices.is_empty()
		total_vertex_count += vertices.size()
		total_index_count += indices.size() if indexed else vertices.size()
	return {"vertex_count":total_vertex_count,"index_count":total_index_count}
	
func _create_cpu_lut(width:int,height:int)->Image:
	var image : Image = Image.create(width,height,false,Image.FORMAT_RGBAF)
	image.fill(Color(0.0,0.0,0.0,0.0))
	return image

func _lut_coord(index:int,width:int)->Vector2i:
	return Vector2i(index%width,index/width)

func _set_lut_pixel(image:Image,index: int,width:int,value:Color)->void:
	var coord : Vector2i = _lut_coord(index,width)
	image.set_pixel(coord.x,coord.y,value)
	


func _init(rd:RenderingDevice)->void:
	_rd = rd
	if _rd == null:
		return
	_stage = MMComputeShaderStage.new(_rd,"Mesh Extraction",true)
	var shader_source : String = load("res://addons/material_maker/map_generator/mesh_extraction/vertex_concat.tres").text
	assert(_stage.set_shader(shader_source))

func extract_cpu(mesh:Mesh)->Dictionary:
	var ctx : Dictionary = {}
	if mesh == null:
		return ctx
	var counts : Dictionary = _get_total_counts(mesh)
	var total_vertex_count : int = counts["vertex_count"]
	var total_index_count : int = counts["index_count"]
	if total_vertex_count == 0:
		return ctx
	
	var lut_width : int = maxi(1,ceili(sqrt(float(total_vertex_count))))
	var lut_height : int = maxi(1,ceili(float(total_vertex_count)/float(lut_width)))
	
	var out_vertices : PackedVector3Array = PackedVector3Array()
	out_vertices.resize(total_vertex_count)
	var out_indices : PackedInt32Array = PackedInt32Array()
	out_indices.resize(total_index_count)
	var out_surface_ids : PackedInt32Array = PackedInt32Array()
	out_surface_ids.resize(total_vertex_count)
	
	# LUTS
	var position_lut : Image = _create_cpu_lut(lut_width,lut_height)
	var normal_lut : Image = _create_cpu_lut(lut_width,lut_height)
	var tangent_lut : Image = _create_cpu_lut(lut_width,lut_height)
	var color_lut : Image = _create_cpu_lut(lut_width,lut_height)
	var uv_lut : Image = _create_cpu_lut(lut_width,lut_height)
	var uv2_lut : Image = _create_cpu_lut(lut_width,lut_height)
	var surface_id_lut : Image = _create_cpu_lut(lut_width,lut_height)
	
	var vertex_offset : int = 0
	var index_offset:int = 0
	for surface_idx in range(mesh.get_surface_count()):
		var arrays : Array = mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			continue
		var indices : PackedInt32Array= PackedInt32Array(arrays[Mesh.ARRAY_INDEX]
										if arrays[Mesh.ARRAY_INDEX]!= null 
										else PackedInt32Array())
		var indexed : bool = not indices.is_empty()
		
		var normals : PackedVector3Array = PackedVector3Array(arrays[Mesh.ARRAY_NORMAL]
										if arrays[Mesh.ARRAY_NORMAL]!= null 
										else PackedVector3Array())
										
		var tangents : PackedFloat32Array = PackedFloat32Array(arrays[Mesh.ARRAY_TANGENT]
										if arrays[Mesh.ARRAY_TANGENT]!= null 
										else PackedFloat32Array())
										
		var colors : PackedColorArray= PackedColorArray(arrays[Mesh.ARRAY_COLOR]
										if arrays[Mesh.ARRAY_COLOR]!= null 
										else PackedColorArray())
										
		var uvs : PackedVector2Array= PackedVector2Array(arrays[Mesh.ARRAY_TEX_UV]
										if arrays[Mesh.ARRAY_TEX_UV]!= null 
										else PackedVector2Array())
										
		var uv2s : PackedVector2Array= PackedVector2Array(arrays[Mesh.ARRAY_TEX_UV2]
									if arrays[Mesh.ARRAY_TEX_UV2]!= null 
									else PackedVector2Array())
		
		var vertex_count : int = vertices.size()
		var index_count : int = indices.size() if indexed else vertex_count
		
		# Vertex data + Luts!
		for i in range(vertex_count):
			var dst : int = vertex_offset + i
			var position : Vector3 = vertices[i]
			out_vertices[dst] = position
			out_surface_ids[dst] = surface_idx
			
			var normal : Vector3 = Vector3(0.0,0.0,1.0) if i>=normals.size() else normals[i]
			var tangent_src : int = i*4
			var tangent : Vector4 = Vector4(1.0,0.0,0.0,1.0)
			if tangent_src+3 <tangents.size():
				tangent.x = tangents[tangent_src+0]
				tangent.y = tangents[tangent_src+1]
				tangent.z = tangents[tangent_src+2]
				tangent.w = tangents[tangent_src+3]
			var color: Color = Color.WHITE if i >= colors.size() else colors[i]
			var uv : Vector2 = Vector2.ZERO if i >= uvs.size() else uvs[i]
			var uv2 : Vector2 = Vector2.ZERO if i >= uv2s.size() else uv2s[i]
			
			_set_lut_pixel(position_lut,dst,lut_width,Color(position.x,position.y,position.z,1.0))
			_set_lut_pixel(normal_lut,dst,lut_width,Color(normal.x,normal.y,normal.z,0.0))
			_set_lut_pixel(tangent_lut,dst,lut_width,Color(tangent.x,tangent.y,tangent.z,tangent.w))
			_set_lut_pixel(color_lut,dst,lut_width,color)
			_set_lut_pixel(uv_lut,dst,lut_width,Color(uv.x,uv.y,0.0,0.0))
			_set_lut_pixel(uv2_lut,dst,lut_width,Color(uv2.x,uv2.y,0.0,0.0))
			_set_lut_pixel(surface_id_lut,dst,lut_width,Color(float(surface_idx),0.0,0.0,0.0))
			
		if indexed:
			for i in range(index_count):
				out_indices[index_offset+i]=vertex_offset+indices[i]
		else:
			for i in range(vertex_count):
				out_indices[index_offset+i] = vertex_offset + i
		vertex_offset += vertex_count
		index_offset += index_count
	
	ctx["lut_width"] = lut_width
	ctx["lut_height"] = lut_height
	
	ctx[KEY_VERTICES] = out_vertices
	ctx[KEY_INDICES]= out_indices
	ctx[KEY_SURFACE_IDS] = out_surface_ids
	
	ctx[KEY_POSITION_LUT] = position_lut
	ctx[KEY_NORMAL_LUT] = normal_lut
	ctx[KEY_TANGENT_LUT] = tangent_lut
	ctx[KEY_COLOR_LUT] = color_lut
	ctx[KEY_UV_LUT]= uv_lut
	ctx[KEY_UV2_LUT] = uv2_lut
	ctx[KEY_SURFACE_ID_LUT] = surface_id_lut
	
	ctx[KEY_SCENE_AABB] = mesh.get_aabb()
	ctx[KEY_VERTEX_COUNT] = total_vertex_count
	ctx[KEY_INDEX_COUNT] = total_index_count
	return ctx
	
static func get_lut_texture(extracted:Dictionary,lut_name:String,rd :RenderingDevice = null)->ImageTexture:
	var value : Variant = extracted.get(lut_name)
	if value is Image:
		return ImageTexture.create_from_image(value)
	if value is RID and rd!=null:
		var width : int = extracted["lut_width"]
		var height : int = extracted["lut_height"]
		var bytes : PackedByteArray = rd.texture_get_data(value,0)
		var image : Image = Image.create_from_data(width,height,false,Image.FORMAT_RGBAF,bytes)
		return ImageTexture.create_from_image(image)
	return null
	
func extract_gpu(mesh:Mesh)->Dictionary:
	var ctx :Dictionary = {}
	var total_vertex_count :int = 0
	var total_index_count :int = 0
	var success : bool = false
	for surface_idx in range(mesh.get_surface_count()):
		var arrays :Array = mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices = arrays[Mesh.ARRAY_INDEX]
		var indexed = indices != null and not indices.is_empty()
		total_index_count += indices.size() if indexed else vertices.size()
		total_vertex_count +=vertices.size()
	
	if total_vertex_count == 0:
		return {}
	var lut_width :int = maxi(1, ceili(sqrt(float(total_vertex_count))))
	var lut_height :int = maxi(1,ceili(float(total_vertex_count)/lut_width))
	ctx["lut_width"] = lut_width
	ctx["lut_height"] = lut_height
	ctx[KEY_POSITION_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_NORMAL_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_TANGENT_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_COLOR_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_UV_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_UV2_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	ctx[KEY_SURFACE_ID_LUT] = _create_lut(lut_width,lut_height,RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	
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
	
	_stage.set_uniform(0, 7, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,vertex_buffer)
	_stage.set_uniform(0, 8, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,index_buffer)
	
	_stage.set_uniform(0,9,RenderingDevice.UNIFORM_TYPE_IMAGE,ctx[KEY_POSITION_LUT])
	_stage.set_uniform(0,10,RenderingDevice.UNIFORM_TYPE_IMAGE,ctx[KEY_NORMAL_LUT])
	_stage.set_uniform(0,11,RenderingDevice.UNIFORM_TYPE_IMAGE,ctx[KEY_TANGENT_LUT])
	_stage.set_uniform(0,12,RenderingDevice.UNIFORM_TYPE_IMAGE,ctx[KEY_COLOR_LUT])
	_stage.set_uniform(0,13,RenderingDevice.UNIFORM_TYPE_IMAGE,ctx[KEY_UV_LUT])
	_stage.set_uniform(0,14,RenderingDevice.UNIFORM_TYPE_IMAGE,ctx[KEY_UV2_LUT])
	_stage.set_uniform(0,15,RenderingDevice.UNIFORM_TYPE_IMAGE,ctx[KEY_SURFACE_ID_LUT])
	
	_stage.set_uniform(0,16,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,surface_id_buffer)
	success = _stage.begin()
	if not success:
		for value: Variant in ctx.values():
			if value is RID and value.is_valid():
				_rd.free_rid(value)
		return {}
	
	
	var temp_buffers :Array[RID] = []
	var uniform_sets : Array[RID] = []
	for surface_idx :int  in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty():
			continue
		var indices : PackedInt32Array= PackedInt32Array(arrays[Mesh.ARRAY_INDEX]
										if arrays[Mesh.ARRAY_INDEX]!= null 
										else PackedInt32Array())
		var indexed : bool = not indices.is_empty()
		
		var normals : PackedVector3Array = PackedVector3Array(arrays[Mesh.ARRAY_NORMAL]
										if arrays[Mesh.ARRAY_NORMAL]!= null 
										else PackedVector3Array())
										
		var tangents : PackedFloat32Array = PackedFloat32Array(arrays[Mesh.ARRAY_TANGENT]
										if arrays[Mesh.ARRAY_TANGENT]!= null 
										else PackedFloat32Array())
										
		var colors : PackedColorArray= PackedColorArray(arrays[Mesh.ARRAY_COLOR]
										if arrays[Mesh.ARRAY_COLOR]!= null 
										else PackedColorArray())
										
		var uvs : PackedVector2Array= PackedVector2Array(arrays[Mesh.ARRAY_TEX_UV]
										if arrays[Mesh.ARRAY_TEX_UV]!= null 
										else PackedVector2Array())
										
		var uv2s : PackedVector2Array= PackedVector2Array(arrays[Mesh.ARRAY_TEX_UV2]
									if arrays[Mesh.ARRAY_TEX_UV2]!= null 
									else PackedVector2Array())
		var vertex_count : int = vertices.size()
		var index_count : int = indices.size() if indexed else vertex_count
		var attribute_flags: int = 0
		if not normals.is_empty():
			attribute_flags |= HAS_NORMAL
		if not tangents.is_empty():
			attribute_flags |= HAS_TANGENT
		if not colors.is_empty():
			attribute_flags |= HAS_COLOR
		if not uvs.is_empty():
			attribute_flags |= HAS_UV
		if not uv2s.is_empty():
			attribute_flags |= HAS_UV2
		var input_data: Array[PackedByteArray] = [
			vertices.to_byte_array(),
			indices.to_byte_array() if indexed else PackedInt32Array([0]).to_byte_array(),
			normals.to_byte_array() if not normals.is_empty() else PackedFloat32Array([0.0]).to_byte_array(),
			tangents.to_byte_array() if not tangents.is_empty() else PackedFloat32Array([0.0, 0.0, 0.0, 1.0]).to_byte_array(),
			colors.to_byte_array() if not colors.is_empty() else PackedColorArray([Color.WHITE]).to_byte_array(),
			uvs.to_byte_array() if not uvs.is_empty() else PackedVector2Array([Vector2.ZERO]).to_byte_array(),
			uv2s.to_byte_array() if not uv2s.is_empty() else PackedVector2Array([Vector2.ZERO]).to_byte_array()
			]
			
		for binding: int in range(input_data.size()):
			var data: PackedByteArray = input_data[binding]
			var buffer: RID = _rd.storage_buffer_create(data.size(), data)
			temp_buffers.append(buffer)
			
			_stage.set_uniform(0,binding,RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,buffer)
		var push_constants: PackedByteArray = PackedInt32Array([
				vertex_count,
				index_count,
				vertex_offset,
				index_offset,
				surface_idx,
				int(indexed),
				attribute_flags,
				lut_width
			]).to_byte_array()
		_stage.set_push_constants(push_constants)
		var workgroups: int = ceili(float(maxi(vertex_count, index_count)) / 256.0)
		if not _stage.dispatch_batch(workgroups, 1, 1):
			success = false
			break

		vertex_offset += vertex_count
		index_offset += index_count
	var finished : bool = _stage.end()
	success = success and finished
	for buffer : RID in temp_buffers:
		if buffer.is_valid():
			_rd.free_rid(buffer)
	if not success :
		for value: Variant in ctx.values():
			if value  is RID and value.is_valid():
				_rd.free_rid(value)
		return {}
	return ctx

func cleanup()->void:
	if _rd == null:
		return 
	_stage.clear()
