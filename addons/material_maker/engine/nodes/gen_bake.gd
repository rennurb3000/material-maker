@tool
extends MMGenBase
class_name MMGenCustomBake


var current_vertex_pos_lut :MMTexture = null
var world_pos_texture : MMTexture

var baked_map : MMTexture
		
func _ready() -> void:
	super._ready()

func get_type() -> String:
	return "bake"

func get_type_name() -> String:
	return "Bake Map"
func get_description() -> String:
	var desc_list : PackedStringArray = PackedStringArray()
	desc_list.push_back(TranslationServer.translate("Bake Map"))
	var longdesc = "Will generate baked maps from any mesh"
	desc_list.push_back(TranslationServer.translate(longdesc))
	return "\n".join(desc_list)

func get_parameter_defs() -> Array:
	return [
		{
			name = "map_mode",
			type = "enum",
			default =0,
			values = [
				{name="World Position",value=0},
				{name="World Normal",value =1}, 
				{name="UV",value=2},
				{name="UV2",value=3},
				{name="Vertex Color",value=4},
				{name="Surface ID",value=5}]
		},
		{
			name = "bake_size",
			type = "enum",
			default = 2048,
			values =[
				{name="256",value=256},
				{name="512",value=512},
				{name="1024",value=1024},
				{name="2048",value=2048},
				{name="4096",value=4096}]
		},
		{
			name="color",
			type= "color",
			default = Color(1.0,0.0,0.0,1.0)
		},
		{
			name="offset_scale",
			type= "float",
			default = 1.0,
			min = -10.0,
			max = 10.0,
		},
		{
			name= "max_raylength",
			type = "float",
			default = 10.0,
			min = 0.0,
			max = 100.0,
		}
	]
func set_parameter(n : String, v) -> void:
	super.set_parameter(n,v)
	notify_output_change(0)
	call_deferred("_request_rebake")
	
	
func get_output_defs(_show_hidden : bool = false) -> Array:
	return [
		{name ="output",type ="rgb", shortdesc = "baked map"}
	]
func get_input_defs() -> Array:
	return [
		{name = "mesh",type = "mesh",shortdesc= "mesh"},
		{name = "ray_origin",type = "rgb",shortdesc = "ray origin"},
		{name = "ray_dir",type = "rgb",shortdesc = "ray dir"},
		{name = "offset_map",type = "f",shortdesc = "offset"},
		{name = "mask",type = "f",shortdesc = "mask"},
	]
func get_texture_parameter_name(output_name : String) ->String:
	return "bake_%d_%s"%[get_instance_id(),output_name]


func get_mesh_data() ->MMBvhData:
	var source = get_source(0)
	if source == null:
		return null
	if not source.generator.has_method("get_mesh_data"):
		return null
	return source.generator.get_mesh_data()

func _wrap_texture(texture) ->MMTexture:
	if texture == null:
		return null
	if texture is MMTexture:
		return texture
	var mm_tex := MMTexture.new()
	mm_tex.set_texture(texture)
	return mm_tex
	
func _get_bake_context()->Dictionary:
	var data := get_mesh_data()
	if data == null or data.mesh_path.is_empty():
		return {}
	var manager := MMMeshManager.get_instance()
	var mesh := manager.get_mesh(data.mesh_path)
	if mesh == null:
		return {}
	var bvh = manager.get_bvh(data.mesh_path)
	var attributes := manager.get_attributes(data.mesh_path)
	
	return {
		"mesh":mesh,
		"bvh":bvh,
		"attributes":attributes
	}

func _get_shader_code(uv, _output_index, context) -> ShaderCode:
	var rv := ShaderCode.new()
	rv.output_type = get_output_defs()[_output_index].type
	var color : Color = get_parameter("color")
	
	var genname = "o%d" % get_instance_id()
	var variant = context.get_variant(self,uv)
	
	
	if variant == -1:
		variant = context.get_variant(self, uv)

		if baked_map != null:
			var texture_name = get_texture_parameter_name("output")
			rv.add_uniform(texture_name,"sampler2D",baked_map)

	
			if rv.output_type == "f":
				rv.code = "float %s_%d = texture(%s, %s).r;\n" % [genname, variant, texture_name, uv]
				rv.output_values.f = "%s_%d" % [genname, variant]
			else:
				rv.code = "vec3 %s_%d = texture(%s, %s).rgb;\n" % [genname, variant, texture_name, uv]
				rv.output_values.rgb = "%s_%d" % [genname, variant]
		else:
			if rv.output_type == "f":
				rv.code = "float %s_%d = %f;\n" % [genname, variant, color.r]
				rv.output_values.f = "%s_%d" % [genname, variant]
			else:
				rv.code = "vec3 %s_%d = vec3(%f, %f, %f);\n" % [genname, variant, color.r, color.g, color.b]
				rv.output_values.rgb = "%s_%d" % [genname, variant]

	return rv
	
func _serialize(data: Dictionary) -> Dictionary:
	# TODO see gen_image for file metadata
	return data

func _serialize_data(data: Dictionary) -> Dictionary:
	return data

func _deserialize(data : Dictionary) -> void:
	pass

func bake_maps():
	var size = int(get_parameter("bake_size"))
	var sizes := [256, 512, 1024, 2048, 4096]
	print("bake size is %d"%size)
	var bake_size = Vector2i(size,size)
	match int(get_parameter("map_mode")):
		0: await bake_world_position(bake_size)
		1: await bake_world_normal(bake_size)
		2: await bake_uv(bake_size)
		3: await bake_uv2(bake_size)
		4: await bake_vertex_color(bake_size)
		5: await bake_surface_id(bake_size)

func render_input_texture(input_index : int,size:Vector2i)->MMTexture:
	var source = get_source(input_index)
	if source == null:
		print("woot2")
		return null
	return await source.generator.render_output_to_texture(
		source.output_index,
		size
	)

func get_output_index(output_name:String)->int:
	var outputs := get_output_defs()
	for i in outputs.size():
		if outputs[i].name == output_name:
			return i
	return -1

func add_input_texture(pipeline:MMBakePipeline,uniform_name:String,input_index:int,size:Vector2i)->bool:
	var tex = await render_input_texture(input_index,size)
	print(uniform_name, tex)
	if tex:
		pipeline.add_parameter_or_texture(uniform_name,"sampler2D",tex)
		return true
	else:
		print("woot")
		return false

func bake_attribute(attribute_key:String,output_name:String,bake_size:Vector2i)->void:
	var ctx:= _get_bake_context()
	if ctx.is_empty():
		return
	var current_mesh :Mesh = ctx["mesh"]
	var current_bvh = ctx["bvh"]
	var attributes:Dictionary = ctx["attributes"]
	if current_bvh == null or current_mesh == null:
		return
	if not attributes.has(attribute_key):
		return
	
	var attribute_lut := _wrap_texture(attributes[attribute_key])
	var bvh := _wrap_texture(current_bvh)
	
	if attribute_lut == null or bvh == null:
		return
	var pipeline := MMBakePipeline.new()
	var vertex_shader = load("res://addons/material_maker/map_generator/fullscreen_vertex.tres").text
	var fragment_shader = load("res://addons/material_maker/map_generator/bake_fragment.tres").text
	
	pipeline.add_parameter_or_texture("bvh_data","sampler2D",bvh)
	pipeline.add_parameter_or_texture("vertex_attribute_lut","sampler2D",attribute_lut)
	
	await add_input_texture(pipeline,"ray_origin",1,bake_size)
	await add_input_texture(pipeline,"ray_dir",2,bake_size)
	
	var replaces :Dictionary ={}
	if await add_input_texture(pipeline,"offset_map",3,bake_size):
		replaces["@OFFSET_EXPR"]= "texture(offset_map,uv).r"
	else:
		replaces["@OFFSET_EXPR"]= "1.0"

	if await add_input_texture(pipeline,"mask",4,bake_size):
		replaces["@MASK_EXPR"]= "texture(mask,uv).r"
	else:
		replaces["@MASK_EXPR"]= "1.0"

		
	pipeline.add_parameter_or_texture("offset_scale","float",get_parameter("offset_scale"))
	pipeline.add_parameter_or_texture("max_raylength","float",get_parameter("max_raylength"))
	
	match output_name:
		"world_normal":
			replaces["@BAKE_RESULT"] = """
				outColor = vec4(normalize(interpolated.xyz),1.0);
			"""
		"surface_id":
			replaces["@BAKE_RESULT"] = """
				outColor = vec4(a0.rrr,1.0);
			"""
		_:
			replaces["@BAKE_RESULT"] = """
				outColor = vec4(interpolated,1.0);
			"""
	
	
	if !await pipeline.set_shader(vertex_shader,fragment_shader,replaces):
		push_error("Shader compilation failed")
		return
	baked_map = MMTexture.new()
	await pipeline.render(bake_size,MMRenderingPipeline.TEXTURE_TYPE_RGBA32F,baked_map)
	
	mm_deps.dependency_update(get_texture_parameter_name("output"),baked_map,true)
	notify_output_change(0)
		
	print("%s complete",output_name)
	
func bake_world_position(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_POSITION_LUT,"world_position",bake_size)
	
func _request_rebake()->void:
	await bake_maps()

func bake_world_normal(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_NORMAL_LUT,"world_normal",bake_size)

func bake_uv(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_UV_LUT,"uv",bake_size)
func bake_uv2(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_UV2_LUT,"uv2",bake_size)
func bake_vertex_color(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_COLOR_LUT,"vertex_color",bake_size)
func bake_surface_id(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_SURFACE_ID_LUT,"surface_id",bake_size)
func bake_hit_normal():
	pass
func bake_thickness():
	pass
func bake_ao():
	pass
