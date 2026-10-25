@tool
extends MMGenBase
class_name MMGenMesh2Sdf3d
# Realtime Collision detection Christer Ericson  chapter 5.1 and  6 
var _manager : MMMeshManager

func _ready() ->void:
	super._ready()
	_manager = MMMeshManager.get_instance()

func get_type() -> String:
	return "mesh2sdf3d"

func get_type_name() ->String:
	return "Mesh to SDF3D"
	
func get_description() -> String:
	return "samples the bvh of a 3d for sdf3d"

func get_input_defs() -> Array:
	return[
		{name = "mesh",type="mesh",shortdesc="Mesh"}
	]

func get_output_defs(_show_hidden:bool = false)->Array:
	return[{
		name = "sdf3d",type="sdf3d",shortdesc="SDF3D"
	}]
func get_mesh_data()->MMBvhData:
	var source = get_source(0)
	if source == null:
		return null
	if not source.generator.has_method("get_mesh_data"):
		return null
	return source.generator.get_mesh_data()
	
func get_bvh() ->MMTexture:
	var data := get_mesh_data()
	if data == null:
		return null
	var bvh = MMMeshManager.get_instance().get_bvh(data.mesh_path)
	if bvh == null:
		return null
	var texture := MMTexture.new()
	texture.set_texture(bvh)
	return texture
	
func _get_shader_code(uv, output_index, context) -> ShaderCode:
	var rv := ShaderCode.new()
	rv.output_type = "sdf3d"

	var genname := "o%d" % get_instance_id()
	var variant = context.get_variant(self, uv)

	if variant == -1:
		variant = context.get_variant(self, uv)

		var bvh := get_bvh()
		if bvh == null:
			rv.code = "float %s_%d = 1e6;\n" % [genname, variant]
		else:
			var uniform_name := "%s_bvh_data" % genname
			rv.add_uniform(uniform_name, "sampler2D", bvh)

			var shader_code: String = load(
				"res://addons/material_maker/map_generator/mesh_extraction/mesh_2_sdf3d.tres"
			).text

			# Unique function name and sampler for this node
			shader_code = shader_code.replace("bvh_data", uniform_name)
			shader_code = shader_code.replace("mm_mesh_sdf", "%s_mesh_sdf" % genname)

			rv.add_global(shader_code, "%s_mesh_sdf" % genname)

			rv.code = "float %s_%d = %s_mesh_sdf(%s);\n" % [
				genname, variant, genname, uv
			]

	rv.output_values.sdf3d = "%s_%d" % [genname, variant]
	return rv
