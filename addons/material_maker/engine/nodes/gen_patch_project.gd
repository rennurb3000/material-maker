@tool
extends MMGenBase
class_name MMGenPatchProject3D
var _manager : MMMeshManager
var projected_map : MMTexture = null
# idea: similar to bake node, but shoot rays in the direction of the "patch"
# if it hits, the uv of the patch will be written, or mask = 0
const SIZES := [256,512,1024,2048,4096]

const VERTEX_SHADER := "res://addons/material_maker/map_generator/mesh_extraction/meshmap2_vertex.tres"
const FRAGMENT_SHADER := "res://addons/material_maker/map_generator/mesh_extraction/patch_project_fragment.tres"
const BVH_UTILS := "res://addons/material_maker/map_generator/mesh_extraction/bvh_utils.tres"
const BVH_TRAVERSAL := "res://addons/material_maker/map_generator/mesh_extraction/bvh_traversal.tres"
var _updating := false
var _update_pending := false

func _get_patch_position()->Vector3:
	return Vector3(get_parameter("tx"),get_parameter("ty"),get_parameter("tz"))
func _get_patch_rotation()->Vector3:
	return Vector3(deg_to_rad(get_parameter("rx")),deg_to_rad(get_parameter("ry")),deg_to_rad(get_parameter("rz")))
func _calc_patch_matrix()->Transform3D:
	return Transform3D(Basis.from_euler(_get_patch_rotation()),_get_patch_position())
	
	
func _ready() -> void:
	super._ready()
	call_deferred("update_map")

func get_type() -> String:
	return "patch_project_3d"

func get_type_name() -> String:
	return "Patch Project 3D"

func get_input_defs() -> Array:
	return [
		{name="mesh", type="mesh", shortdesc="Mesh"},
	]
func get_output_defs(_show_hidden:bool = false)->Array:
	return [
		{name="output",type="rgb",shortdesc="Projected image or UV"},
		{name="mask",type="f",shortdesc="Projection Mask"}
		]

func get_parameter_defs() -> Array:
	return[
		{name="surface",type="float",label="Surface",default=-1.0,min=-1.0,max=128.0,step=1.0},
		{name="tx",type="float",label="Tx",default=0.0,min=-100.0,max=100.0,step=0.01},
		{name="ty",type="float",label="Ty",default=0.0,min=-100.0,max=100.0,step=0.01},
		{name="tz",type="float",label="Tz",default=2.0,min=-100.0,max=100.0,step=0.01},
		{name="rx",type="float",label="Rx",default=180.0,min=-180.0,max=180.0,step=1.0},
		{name="ry",type="float",label="Ry",default=0.0,min=-180.0,max=180.0,step=1.0},
		{name="rz",type="float",label="Rz",default=0.0,min=-180.0,max=180.0,step=1.0},
		{name="su",type="float",label="Su",default=1.0,min=0.0,max=100.0,step=0.01},
		{name="sv",type="float",label="Sv",default=1.0,min=0.0,max=100.0,step=0.01},
		{name= "map_size",type="enum",label="Resolution",default=3,values=[
			{name="256",value=256},
			{name="512",value=512},
			{name="1024",value=1024},
			{name="2048",value=2048},
			{name="4096",value=4096},
			]}
	]
func set_parameter(n : String, v) -> void:
	super.set_parameter(n,v)
	if n in ["surface","tx","ty","tz","rx","ry","rz","su","sv","map_size"]:
		update_map()

func source_changed(input_index : int) -> void:
	update_map()

func get_mesh_data()->MMBvhData:
	var source = get_source(0)
	if source == null:
		return null
	if not source.generator.has_method("get_mesh_data"):
		return null
	return source.generator.get_mesh_data()
	
func get_texture_parameter_name() ->String:
	return "patch_project_3d_%d"%get_instance_id()
	
func update_map():
	if _updating:
		_update_pending = true
		return
	_updating = true
	while true:
		_update_pending = false
		await _render_projection_map()
		if not _update_pending:
			break
	_updating = false

func _render_projection_map()->void:
	var data := get_mesh_data()
	if data == null or data.mesh_path.is_empty():
		return
	var manager := MMMeshManager.get_instance()
	var mesh := manager.get_mesh(data.mesh_path)
	if mesh == null:
		return
	var attributes := manager.get_attributes(data.mesh_path)
	if not attributes.has("indices"):
		return
	var bvh_texture  = manager.get_bvh(data.mesh_path)
	if bvh_texture==null:
		return
	var pipeline := MMMeshRenderingPipeline2.new()
	pipeline.setup(mesh,attributes)
	var bvh := MMTexture.new()
	bvh.set_texture(bvh_texture)
	pipeline.add_parameter_or_texture("bvh_data", "sampler2D",bvh)
	var patch_transform := _calc_patch_matrix()
	var patch_inverse := patch_transform.affine_inverse()
	pipeline.add_parameter_or_texture("patch_inverse","mat4x4",Projection(patch_inverse))
	# Orthographic direction from global origin towards patch origin
	# as object is at  ZERO
	var direction := _get_patch_position().normalized()
	if direction.is_zero_approx():
		direction = patch_transform.basis.z.normalized()
		
	pipeline.add_parameter_or_texture(
		"patch_direction",
		"vec4",
		Color(direction.x, direction.y, direction.z, 0.0)
	)
	pipeline.add_parameter_or_texture(
		"su",
		"float",
		maxf(float(get_parameter("su")), 0.00001)
	)
		
	pipeline.add_parameter_or_texture(
		"sv",
		"float",
		maxf(float(get_parameter("sv")), 0.00001)
	)
	var selected_surface := int(get_parameter("surface"))
	var replaces := {
		"@SURFACE_FILTER": (
			"" if selected_surface < 0
			else "if (int(round(v_surface_id)) != %d) discard;" % selected_surface
		),
		"@BVH_UTILS": load(BVH_UTILS).text,
		"@BVH_TRAVERSAL": load(BVH_TRAVERSAL).text
	}
	print("Patch inverse: ", patch_inverse)
	print("Direction: ", direction)
	print("Expected local direction: ", patch_inverse.basis * direction)
	print("Mesh AABB: ", mesh.get_aabb())
	var local_origin := patch_inverse * Vector3.ZERO
	var local_direction := patch_inverse.basis * direction
	var t := -local_origin.z / local_direction.z
	var hit := local_origin + local_direction * t

	print("Projected mesh origin: ", hit)
	print("Expected patch UV: ", Vector2(hit.x / 2.5 + 0.5, hit.y / 2.5 + 0.5))
	var vertex_shader: String = load(VERTEX_SHADER).text
	var fragment_shader: String = load(FRAGMENT_SHADER).text
	var resolution: int = SIZES[int(get_parameter("map_size"))]
	var size := Vector2i(resolution, resolution)
	var result := await pipeline.render_map(
		vertex_shader,
		fragment_shader,
		size,
		0,
		selected_surface,
		[],
		replaces
	)
	if result == null:
		return
	projected_map = result
	var tex =  await projected_map.get_texture()
	var image: Image = tex.get_image()
	var center := Vector2i(image.get_width() / 2, image.get_height() / 2)

	print("Patch pixel center: ", image.get_pixelv(center))
	print("Patch pixel range: ", image.get_format(), " ", image.get_size())
	mm_deps.dependency_update(
		get_texture_parameter_name(),
		projected_map,
		true
	)
	notify_output_change(0)
	notify_output_change(1)
	
func _get_shader_code(uv, output_index, context) -> ShaderCode:
	var rv := ShaderCode.new()
	var output_type := "rgb" if output_index == 0 else "f"
	rv.output_type = output_type
	
	var variant = context.get_variant(self, uv)
	var variable := "patch_%d_%d_%d" % [
		get_instance_id(), output_index, variant
	]
	
	if variant == -1:
		variant = context.get_variant(self, uv)
		variable = "patch_%d_%d_%d" % [
			get_instance_id(), output_index, variant
		]
		
		if projected_map != null:
			var texture_name := get_texture_parameter_name()
			rv.add_uniform(texture_name, "sampler2D", projected_map)
			
			var expression := (
				"texture(%s, %s).rgb" % [texture_name, uv]
				if output_index == 0
				else "texture(%s, %s).a" % [texture_name, uv]
			)
			
			if output_index == 0:
				rv.code = "vec3 %s = %s;\n" % [
				variable, expression
				]
			else:
				rv.code = "float %s = %s;\n" % [
					variable, expression
				]
		else:
			if output_index == 0:
				rv.code = "vec3 %s = vec3(0.0);\n" % variable
			else:
				rv.code = "float %s = 0.0;\n" % variable
				
	rv.output_values[output_type] = variable
	return rv
