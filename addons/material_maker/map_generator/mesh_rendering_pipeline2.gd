# NOTE this pipeline is used for meshloader2 mesh datatypes!
class_name  MMMeshRenderingPipeline2
extends MMMeshRenderingPipeline

var surface: int = 0
var attributes : Dictionary = {}
func draw_list_extra_setup(rd : RenderingDevice,
							draw_list : int, 
							shader : RID,
							rids : RIDs):
	if attributes == null:
		push_error("no attributes set")
		
	var indices : PackedInt32Array =  attributes["indices"]
	var index_buffer := rd.index_buffer_create(indices.size(),RenderingDevice.INDEX_BUFFER_FORMAT_UINT32,indices.to_byte_array())
	var index_array:= rd.index_array_create(index_buffer,0,indices.size())
	rids.add(index_array,"index_array")
	rids.add(index_buffer,"index_buffer")
	
	rd.draw_list_bind_index_array(draw_list,index_array)
	index_count = 0
	
	
func setup(mesh_data:Mesh,mesh_attributes:Dictionary)->void:
	mesh = mesh_data
	attributes = mesh_attributes
	
	var lut_names := [
		MMMeshExtractor.KEY_POSITION_LUT,
		MMMeshExtractor.KEY_NORMAL_LUT,
		MMMeshExtractor.KEY_TANGENT_LUT,
		MMMeshExtractor.KEY_COLOR_LUT,
		MMMeshExtractor.KEY_UV_LUT,
		MMMeshExtractor.KEY_UV2_LUT,
		MMMeshExtractor.KEY_SURFACE_ID_LUT
	]

	for i in lut_names.size():
		var texture := MMTexture.new()
		texture.set_texture(attributes[lut_names[i]])
		add_parameter_or_texture(
			["position_lut", "normal_lut", "tangent_lut",
			 "color_lut", "uv_lut", "uv2_lut", "surface_id_lut"][i],
			"sampler2D",
			texture
		)
	add_parameter_or_texture("map_mode", "int", 0)
	add_parameter_or_texture("selected_surface", "int", -1)

func _postprocess(source:MMTexture,size:Vector2i,pixels:int,result:Dictionary)->void:
	result["texture"] = dilate_map(source,size,pixels)
	
func _compute_pass(shader_name:String,source:MMTexture,size:Vector2i,pixels:int,seams:MMTexture = null)->MMTexture:
	var output := MMTexture.new()
	var compute := MMComputeShader.new()
	compute.clear()
	compute.add_parameter_or_texture("tex","sampler2D",source)
	compute.add_parameter_or_texture("pixels","int",pixels)
	
	if seams != null:
		compute.add_parameter_or_texture("seams_map","sampler2D",seams)
	var shader_path := "res://addons/material_maker/map_generator/%s_compute.tres"%shader_name
	if not compute.set_shader(load(shader_path).text,3):
		return null
	compute.in_thread_render_ext([output],size)
	return output

func generate_seams(source:MMTexture,size:Vector2i,pixels:int)->MMTexture:
	var horizontal := _compute_pass("seams_1",source,size,pixels)
	if horizontal == null:
		return null
	return _compute_pass("seams_2",horizontal,size,pixels)
	
func dilate_map(source:MMTexture,size:Vector2i,pixels:int)->MMTexture:
	var seams := generate_seams(source,size,pixels)
	if seams == null:
		return source
	var result:= _compute_pass("dilate",source,size,pixels,seams)
	return result if result!=null else source

func render_map(vertex_shader:String,fragment_shader:String,size:Vector2i,map_mode:int,selected_surface:int = -1,postprocess:Array=[])->MMTexture:
	if not await set_shader(vertex_shader,fragment_shader):
		return null
	set_parameter("map_mode",map_mode)
	set_parameter("selected_surface",selected_surface)
	
	var result := MMTexture.new()
	await render(size,TEXTURE_TYPE_RGBA32F,result)
	var pixels := size.x / 4
	# dont dilate uv, uv2, uv mask
	if pixels >0 and "dilate" in postprocess:
		var processed:={}
		await mm_renderer.thread_run(_postprocess,[result,size,pixels,processed])
		result = processed["texture"]
	return result
