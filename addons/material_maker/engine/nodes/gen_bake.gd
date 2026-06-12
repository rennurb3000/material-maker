@tool
extends MMGenBase
class_name MMGenCustomBake

var timer : Timer
var filetime : int = 0

var current_mesh : ArrayMesh = null
var current_bvh = null

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
		current_bvh = MMBvhGenerator.generate(current_mesh)
		var bvh_time = Time.get_ticks_msec() -bvh_start
		print("BVH generation took %.3f s"%(bvh_time/1000.0))

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
		{type ="rgb"}
	]
	
func _get_shader_code(uv, _output_index, context) -> ShaderCode:
	var rv := ShaderCode.new()
	rv.output_type = "rgb"
	var color : Color = get_parameter("color")
	
	var genname = "o%d" % get_instance_id()
	var variant = context.get_variant(self,uv)
	
	if variant == -1:
		variant = context.get_variant(self,uv)
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
