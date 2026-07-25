@tool
extends MMGenBase
class_name MMGenCustomBake

var timer : Timer
var filetime : int = 0

var current_mesh : ArrayMesh = null
var current_bvh = null
var current_vertex_pos_lut :MMTexture = null
var world_pos_texture : MMTexture

var baked_maps := {
	"world_position":null,
	"world_normal": null,
	"hit_normal":null,
	"ao":null,
	"thickness":null,
	"uv":null,
	"vertex_color":null,
	"curvature_color":null,
}

# copied from image
func get_filetime(file_path : String) -> int:
	if FileAccess.file_exists(file_path):
		return FileAccess.get_modified_time(file_path)
	return 0

func _on_timeout() -> void:
	var path : String = get_parameter("mesh")
	if path.is_empty():
		return
	var new_time = get_filetime(path)
	if new_time != filetime:
		filetime = new_time
		print("mesh changed:  %s"%[path])
		reload_mesh()
		
func _ready() -> void:
	super._ready()
	timer = Timer.new()
	add_child(timer)
	timer.wait_time = 2.0
	timer.start()
	timer.timeout.connect(_on_timeout)

func reload_mesh():
	var load_start = Time.get_ticks_msec()
	current_mesh = MMMeshLoader.load_mesh(get_parameter("mesh"))
	var load_time = Time.get_ticks_msec() - load_start
	if current_mesh:
		print("loaded mesh with ",current_mesh.get_surface_count()," surfaces")
		print("mesh load took %.3f s"% (load_time/1000.0))
		var bvh_start = Time.get_ticks_msec()
		current_bvh = MMBvhGeneratorGPU.generate(current_mesh,true,mm_renderer.rendering_device)
		assert(current_bvh!=null)
		print(current_bvh)
		var bvh_time = Time.get_ticks_msec() -bvh_start
		print("BVH generation took %.3f s"%(bvh_time/1000.0))
		print("generate lut textures")
		var vertex_count := get_vertex_count(current_mesh)
		var lut_width := int (ceil(sqrt(vertex_count)))
		current_vertex_pos_lut= MMTexture.new()
		await render_vertex_lut(current_mesh,Vector2i(lut_width,lut_width),current_vertex_pos_lut,vertex_count)
		#baked_maps["world_position"] = current_vertex_pos_lut
		print("lut_textures created")
		print("vertex count: ", vertex_count)
		print("lut size: ", lut_width)
	bake_maps()
func get_vertex_count(mesh:ArrayMesh)->int:
	var count := 0
	for surface_idx in mesh.get_surface_count():
		var arrays = mesh.surface_get_arrays(surface_idx)
		var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		count+= vertices.size()
	return count 
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
			name="color",
			type= "color",
			default = Color(1.0,0.0,0.0,1.0)
		},
		{
			name="mesh",
			type = "file",
			label="Mesh",
			default="",
			filters=MMMeshLoader.get_file_dialog_filters(),
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
	if n == "mesh":
		filetime = get_filetime(v)
		reload_mesh()
	notify_output_change(0)
	
func get_output_defs(_show_hidden : bool = false) -> Array:
	return [
		{name ="world_position",type ="rgb", shortdesc = "world"},
		{name ="world_normal",type ="rgb", shortdesc = "world normal"},
		{name ="hit_normal",type ="rgb", shortdesc = "normal"},
		{name ="ao",type ="f", shortdesc = "ao"},
		{name ="thickness",type ="f", shortdesc = "thickness"},
		{name ="uv",type ="rgb", shortdesc = "uv"},
		{name ="vertex_color",type ="rgb", shortdesc = "vertex color"},
		{name ="curvature",type ="f", shortdesc = "curvature"},
	]
func get_input_defs() -> Array:
	return [
		{name = "ray_origin",type = "rgb",shortdesc = "ray origin"},
		{name = "ray_dir",type = "rgb",shortdesc = "ray dir"},
		{name = "offset_map",type = "f",shortdesc = "offset"},
		{name = "mask",type = "f",shortdesc = "mask"},
	]
func get_texture_parameter_name(output_name : String) ->String:
	return "bake_%d_%s"%[get_instance_id(),output_name]

func _get_shader_code(uv, _output_index, context) -> ShaderCode:
	var rv := ShaderCode.new()
	rv.output_type = "rgb"
	var color : Color = get_parameter("color")
	
	var genname = "o%d" % get_instance_id()
	var variant = context.get_variant(self,uv)
	var map_name = baked_maps.keys()[_output_index]

	if variant == -1:
		variant = context.get_variant(self,uv)
		if (map_name in baked_maps) and baked_maps[map_name] != null:
			var texture_name = get_texture_parameter_name(map_name)
			rv.add_uniform(
				texture_name,
				"sampler2D",
				baked_maps[map_name]
			)
			rv.code = "vec3 %s_%d = texture(%s,%s).rgb; \n"% [genname,variant,texture_name,uv]
			rv.output_values.rgb = "%s_%d" % [genname,variant]
		
		else:
			rv.code = "vec3 %s_%d = vec3(%f,%f,%f); \n"% [genname,variant,color.r,color.g,color.b]
			rv.output_values.rgb = "%s_%d" % [genname,variant]
			
	
	return rv
	
func _serialize(data: Dictionary) -> Dictionary:
	# TODO see gen_image for file metadata
	return data

func _serialize_data(data: Dictionary) -> Dictionary:
	return data

func _deserialize(data : Dictionary) -> void:
	pass

func bake_maps():
	bake_world_position(Vector2i(2048,2048))

func render_input_texture(input_index : int,size:Vector2i)->MMTexture:
	var source = get_source(input_index)
	if source == null:
		print("woot2")
		return null
	return await source.generator.render_output_to_texture(
		source.output_index,
		size
	)
func add_input_texture(pipeline:MMBakePipeline,uniform_name:String,input_index:int,size:Vector2i)->bool:
	var tex = await render_input_texture(input_index,size)
	print(uniform_name, tex)
	if tex:
		pipeline.add_parameter_or_texture(uniform_name,"sampler2D",tex)
		return true
	else:
		print("woot")
		return false

func bake_world_position(bake_size:Vector2i):
	if current_mesh == null:
		return
	var pipeline = MMBakePipeline.new()
	var vertex_shader = load("res://addons/material_maker/map_generator/fullscreen_vertex.tres").text
	var fragment_shader = load("res://addons/material_maker/map_generator/bake_fragment.tres").text
	var bvh : MMTexture = MMTexture.new()
	bvh.set_texture(current_bvh)
	
	pipeline.add_parameter_or_texture(
		"bvh_data",
		"sampler2D",
		bvh
	)
	pipeline.add_parameter_or_texture("vertex_position_lut","sampler2D",current_vertex_pos_lut)
	await add_input_texture(pipeline,"ray_origin",0,bake_size)
	await add_input_texture(pipeline,"ray_dir",1,bake_size)
	await add_input_texture(pipeline,"offset_map",2,bake_size)
	await add_input_texture(pipeline,"mask",3,bake_size)
	pipeline.add_parameter_or_texture(
		"offset_scale",
		"float",
		get_parameter("offset_scale")
	)
	pipeline.add_parameter_or_texture(
		"max_raylength",
		"float",
		get_parameter("max_raylength")
	)
	print("textures:")
	for t in pipeline.input_textures:
		print("  ", t.name)
	if !await pipeline.set_shader(vertex_shader,fragment_shader):
		push_error("Shader compilation failed")
		return
	baked_maps["world_position"] = MMTexture.new()
	#pipeline.in_thread_render(Vector2i(2048,2048),3,world_pos_texture)
	await pipeline.render(Vector2i(2048,2048),3,baked_maps["world_position"])
	print("bake complete")
	mm_deps.dependency_update(get_texture_parameter_name("world_position"),baked_maps["world_position"],true)
	pass
	
func render_vertex_lut(mesh:Mesh,lut_size:Vector2i,target:MMTexture,vertex_count:int):
	var pipeline = MMVertexLutPipeline.new()
	pipeline.vertex_count = vertex_count
	pipeline.add_parameter_or_texture("lut_width","float",float(lut_size.x))
	pipeline.add_parameter_or_texture("lut_height","float",float(lut_size.y))
	await pipeline.set_shader(
		load("res://addons/material_maker/map_generator/bake_LUT_vertex.tres").text,
		load("res://addons/material_maker/map_generator/bake_LUT_position_fragment.tres").text,
	)
	pipeline.mesh = mesh
	return await pipeline.render(lut_size,MMRenderingPipeline.TEXTURE_TYPE_RGBA32F,target)
	
	
func bake_world_position_test():
	if current_mesh == null:
		return
	var pipeline = MMMeshRenderingPipeline.new()
	pipeline.mesh = current_mesh
	
	var vertex_shader = load("res://addons/material_maker/map_generator/ao_vertex.tres").text
	var fragment_shader = load("res://addons/material_maker/map_generator/bake_fragment.tres").text
	var bvh : MMTexture = MMTexture.new()
	bvh.set_texture(current_bvh)
	

	pipeline.add_parameter_or_texture(
		"bvh_data",
		"sampler2D",
		bvh
	)
	
	if !await pipeline.set_shader(vertex_shader,fragment_shader):
		push_error("Shader compilation failed")
		return
	baked_maps["world_position"] = MMTexture.new()
	#pipeline.in_thread_render(Vector2i(2048,2048),3,world_pos_texture)
	await pipeline.render(Vector2i(2048,2048),3,baked_maps["world_position"])
	print("bake complete")
	mm_deps.dependency_update(get_texture_parameter_name("world_position"),baked_maps["world_position"],true)
	pass
func bake_world_normal():
	pass
func bake_uv():
	pass
func bake_vertex_color():
	pass
func bake_hit_normal():
	pass
func bake_thickness():
	pass
func bake_ao():
	pass
