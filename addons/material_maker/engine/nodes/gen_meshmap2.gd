@tool
extends MMGenBase
class_name MMGenMeshMap2

const MESH_MAPS : Array[Dictionary] = [
	{name="Position",output_type="rgb", attribute =MMMeshExtractor.KEY_POSITION_LUT,postprocess=["dilate"]},
	{name="Normal",output_type="rgb",attribute =MMMeshExtractor.KEY_NORMAL_LUT,postprocess=["dilate"]},
	{name="Tangent",output_type="rgb",attribute = MMMeshExtractor.KEY_TANGENT_LUT,postprocess=["dilate"]},
	{name="Color",output_type="rgb",attribute = MMMeshExtractor.KEY_COLOR_LUT,postprocess=["dilate"]},
	{name="UV",output_type="rgb",attribute = MMMeshExtractor.KEY_UV_LUT},
	{name="UV2",output_type="rgb",attribute = MMMeshExtractor.KEY_UV2_LUT},
	{name="Surface ID",output_type="f",attribute = MMMeshExtractor.KEY_SURFACE_ID_LUT},
	{name="UV Mask",output_type="f",attribute="uv_mask"},
]
var current_map : MMTexture = null
var _pipeline : MMMeshRenderingPipeline2 = null

func _ready() -> void:
	super._ready()

func get_type() -> String:
	return "meshmap2"

func get_type_name() -> String:
	return "Mesh Map 2"

func get_input_defs() -> Array:
	return [
		{name="mesh", type="mesh", shortdesc="Mesh"}
	]
func get_output_defs(_show_hidden:bool = false)->Array:
	return [{type=MESH_MAPS[int(get_parameter("map"))].output_type}]

func get_parameter_defs() -> Array:
	return[
		{name="map",type="enum",label="Map",values=MESH_MAPS,default=0},
		{name="surface",type="float",label="Surface",default=-1.0,min=-1.0,max=128.0,step=1.0},
		{name= "map_size",type="enum",label="Resolution",default=2048,values=[
			{name="256",value=256},
			{name="512",value=512},
			{name="1024",value=1024},
			{name="2048",value=2048},
			{name="4096",value=4096},
			
			]}
	]
func set_parameter(n : String, v) -> void:
	super.set_parameter(n,v)
	if n in ["map","surface","map_size"]:
		update_map()
		notify_output_change(0)

func source_changed(input_index : int) -> void:
	update_map()
func get_current_mesh()->Mesh:
	var source = get_source(0)
	if source == null:
		return null
	if not source.generator.has_method("get_mesh_data"):
		return null
	var data: MMBvhData = source.generator.get_mesh_data()
	if data == null:
		return null
	return MMMeshManager.get_instance().get_mesh(data.mesh_path)

func update_map()->void:
	var mesh := get_current_mesh()
	if mesh == null:
		return
	var source = get_source(0)
	if source == null:
		return
	var data:MMBvhData = source.generator.get_mesh_data()
	if data == null:
		return
	var attributes := MMMeshManager.get_instance().get_attributes(data.mesh_path)
	if attributes.is_empty():
		return
	_pipeline = MMMeshRenderingPipeline2.new()
	_pipeline.setup(mesh,attributes)
	
	var vertex_shader = load("res://addons/material_maker/map_generator/mesh_extraction/meshmap2_vertex.tres").text
	var fragment_shader = load("res://addons/material_maker/map_generator/mesh_extraction/meshmap2_fragment.tres").text
	
	var mode := int(get_parameter("map"))
	var definition := MESH_MAPS[mode]
	var postprocess := definition.get("postprocess",[])
	var size := int(get_parameter("map_size"))
	current_map = await  _pipeline.render_map(vertex_shader,fragment_shader,Vector2i(size,size),mode,int(get_parameter("surface")),postprocess)
	notify_output_change(0)
	mm_deps.dependency_update(get_texture_parameter_name(),current_map,true)

func get_texture_parameter_name() ->String:
		return "meshmap2_%d"%get_instance_id()
		
func _get_shader_code(uv, _output_index, context) -> ShaderCode:
	var rv := ShaderCode.new()
	var output_type :String = MESH_MAPS[int(get_parameter("map"))].output_type
	var variant = context.get_variant(self,uv)
	var variable := "meshmap2_%d_%d" %[get_instance_id(),variant]
	rv.output_type = output_type
	if variant == -1:
		variant = context.get_variant(self,uv)
		variable = "meshmap2_%d_%d"%[get_instance_id(),variant]
		var texture_name := get_texture_parameter_name()
		rv.add_uniform(texture_name,"sampler2D",current_map)
		var value := "texture(%s,%s).rgb"%[texture_name,uv]
		if output_type == "f":
			value = "texture(%s,%s).r"%[texture_name,uv]
		rv.code = "%s %s = %s;\n"%[mm_io_types.types[output_type].type,variable,value]
	rv.output_values[output_type]=variable
	return rv
	
