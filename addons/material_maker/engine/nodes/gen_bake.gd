@tool
extends MMGenBase
class_name MMGenCustomBake

# Bake node:
# Takes ray defining maps (position and normal)  offset, and a mask
# for each texel where the mask is >0.5,a ray is generated
# ray origin = ( pos - dir*offset*offset_scale)
# where dir = - low poly normal 
# if the ray hits a triangle from the bvh and the @SURFACE_FILTER stops it,
# the hitposition and triangle vertices are used to calculate the barycentric coordinates
# the input LUT is interpolated according to the barycentric coordinates
# scale aabb: for maps bound to the range 0.0 .. 1.0 , 
# the position is transformed
# 
# NOTE
# i got problems with an attached buffer between the input maps and the
# bake node on startup 
# recursively searching for the mesh loader node (is output ready) helped a bit
# to check if the texture is actually ready 
# curvature or later cavity is not optimal, as it is not filtered

var current_vertex_pos_lut :MMTexture = null
var world_pos_texture : MMTexture

var baked_map : MMTexture
var _baking : bool = false
var _rebake_pending : bool = false

func _ready() -> void:
	super._ready()

func source_changed(input_index : int) -> void:
	print("BAKE SOURCE CHANGED: ", get_instance_id(), " input=", input_index)
	call_deferred("_request_rebake")

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
				{name="Surface ID",value=5},
				{name="Hit Normal",value=6},
				{name="Ambient Occlusion",value=7},
				{name="Tangent Normal",value=8},
				{name="Thickness",value=9},
				{name="Distance",value=10},
				{name="Curvature",value=11}
				]
		},
		{
			name = "bake_size",
			type = "enum",
			default = 3,
			values =[
				{name="256",value=256},
				{name="512",value=512},
				{name="1024",value=1024},
				{name="2048",value=2048},
				{name="4096",value=4096}]
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
		},
		{
			name = "scale_aabb",
			type = "boolean",
			default = false,
		},
		{
			name = "surface_filter",
			type = "float",
			default = -1.0,
			min = -1.0,
			max = 32.0,
			step = 1.0,
		},
		{
			name = "dilate",
			type = "boolean",
			default = true,
		},
		{
			name = "denoise",
			type = "boolean",
			default = false,
		},
	]
func set_parameter(n : String, v) -> void:
	super.set_parameter(n,v)
	notify_output_change(0)
	call_deferred("_request_rebake")
	
	
func get_output_defs(_show_hidden : bool = false) -> Array:
	var output_type : String = "rgb"
	# Curvature, distance, thickness
	if int(get_parameter("map_mode")) in [10,11]:
		output_type = "f"
	return [
		{name="output",type=output_type,shortdesc="baked map"}
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
	var color : Color = Color.TOMATO # lol
	
	var genname = "o%d" % get_instance_id()
	var variant = context.get_variant(self,uv)
	
	
	if variant == -1:
		variant = context.get_variant(self, uv)
		print("Bake shader requested: ", get_instance_id()," map=", baked_map)
		if baked_map != null:
			var texture_name = get_texture_parameter_name("output")
			rv.add_uniform(texture_name,"sampler2D",baked_map)
			
			if rv.output_type == "f":
				rv.code = "float %s_%d = texture(%s, %s).r;\n" % [genname, variant, texture_name, uv]
			else:
				rv.code = "vec3 %s_%d = texture(%s, %s).rgb;\n" % [genname, variant, texture_name, uv]
		else:
			if rv.output_type == "f":
				rv.code = "float %s_%d = %f;\n" % [genname, variant, color.r]
			else:
				rv.code = "vec3 %s_%d = vec3(%f, %f, %f);\n" % [genname, variant, color.r, color.g, color.b]
	rv.output_values[rv.output_type] = "%s_%d" % [genname, variant]
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
	var bake_size = Vector2i(sizes[size],sizes[size])
	match int(get_parameter("map_mode")):
		0: await bake_world_position(bake_size)
		1: await bake_world_normal(bake_size)
		2: await bake_uv(bake_size)
		3: await bake_uv2(bake_size)
		4: await bake_vertex_color(bake_size)
		5: await bake_surface_id(bake_size)
		6: await bake_hit_normal(bake_size)
		7: await bake_ao(bake_size)
		8: await bake_tangent_space_normal(bake_size)
		9: await bake_thickness(bake_size)
		10: await bake_distance(bake_size)
		11: await bake_curvature(bake_size)
		_ : push_error("not yet implemented")

func render_input_texture(input_index : int,size:Vector2i)->MMTexture:
	var source = get_source(input_index)
	if source == null:
		print("woot2")
		return null
	
	if source.generator is MMGenMeshMap2:
		var map : MMGenMeshMap2 = source.generator
		if map.current_map == null:
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
	
	# this is injected in the ray hit detection:
	# if the surface does not match, it is ignored, and the ray travels further
	replaces["@SURFACE_FILTER"] = ""
	var surface_filter: int = int(get_parameter("surface_filter"))
	if surface_filter >=0:
		var surface_lut: MMTexture = _wrap_texture(attributes.get(MMMeshExtractor.KEY_SURFACE_ID_LUT))
		if surface_lut == null:
			push_error("Surface ID LUT missing")
			return
		pipeline.add_parameter_or_texture("surface_id_lut", "sampler2D", surface_lut)
		replaces["@SURFACE_FILTER"] = """
			int vid = int(hit_info.x);
			ivec2 lut_size = textureSize(surface_id_lut, 0);
			ivec2 lut_coord = ivec2(vid %% lut_size.x, vid / lut_size.x);
			int surface_id = int(round(texelFetch(surface_id_lut, lut_coord, 0).r));
			if (surface_id != %d) {
				continue;
			}
			""" % surface_filter
	
	# transforms normalized ray origins into the BVH coordinate system
	# not needed for meshmap or meshmap2!
	replaces["@AABB_TRANSFORM"] = ""
	if get_parameter("scale_aabb"):
		var aabb : AABB = current_mesh.get_aabb()
		pipeline.add_parameter_or_texture("aabb_min", "vec3", aabb.position)
		pipeline.add_parameter_or_texture("aabb_size", "vec3", aabb.size)
		replaces["@AABB_TRANSFORM"] = """
			int offset_to_nodes = int(get_data(0).x);
			int root_offset = int(get_data(1).x) + offset_to_nodes;
			vec3 aabb_min = get_data(root_offset).xyz;
			vec3 aabb_max = get_data(root_offset + 1).xyz;
			vec3 aabb_size = aabb_max - aabb_min;
			origin = origin * aabb_size + aabb_min;
		"""
	
	# injects the offset map, when no offset map is set, 
	# we use a constant
	if await add_input_texture(pipeline,"offset_map",3,bake_size):
		replaces["@OFFSET_EXPR"]= "texture(offset_map,uv).r"
	else:
		replaces["@OFFSET_EXPR"]= "1.0"

	# injects the mask: when the mask value of this uv coordinate is <0.5,
	# the output is set to 0,0,0,0 (transparent, ignored)
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
		"curvature":
			replaces["@BAKE_RESULT"] = """
				outColor = vec4(normalize(interpolated.xyz),1.0);
			"""
		"surface_id":
			replaces["@BAKE_RESULT"] = """
				outColor = vec4(vec3(interpolated.r),1.0);
			"""
		"hit_normal":
			replaces["@BAKE_RESULT"] = """
				outColor = vec4(normal_hit * 0.5 + 0.5, 1.0);
			"""
		"tangent_normal":
			# i sample 4 points of the low poly position map to generate 
			# tangent and bitangent
			replaces["@BAKE_RESULT"] = """
				vec3 smooth_hit_normal = normalize(interpolated.xyz);
				vec3 N = normalize(texture(ray_dir, uv).xyz);
				vec2 texel = 1.0 / vec2(textureSize(ray_origin, 0));
				vec3 dPdu =
					texture(ray_origin, uv + vec2(texel.x, 0.0)).xyz -
					texture(ray_origin, uv - vec2(texel.x, 0.0)).xyz;
				vec3 dPdv =
					texture(ray_origin, uv + vec2(0.0, texel.y)).xyz -
					texture(ray_origin, uv - vec2(0.0, texel.y)).xyz;
				vec3 T = normalize(dPdu - N * dot(N, dPdu));
				vec3 B = cross(N, T) * sign(dot(cross(N, T), dPdv));
				vec3 normal_ts = normalize(vec3(
					dot(smooth_hit_normal, T),
					dot(smooth_hit_normal, B),
					dot(smooth_hit_normal, N)
				));
				normal_ts.z = -normal_ts.z;
				outColor = vec4(normal_ts * 0.5 + 0.5, 1.0);
				"""
		"ambient_occlusion":
			replaces["@BAKE_RESULT"] = """
			vec3 model_norm = normalize(interpolated.xyz);
			vec3 ray_start = hit_pos + model_norm * 0.001;

			const int SAMPLES = 16;
			float ao = 0.0;
			
			for (int iteration = 1; iteration <= SAMPLES; iteration++) {
				vec3 ray_dir;
				
				for (int i = 0; i < 5; i++) {
					ray_dir = random_hemi_point(vec3(
					rand(uv + float(iteration)),
					rand(-uv.yx + float(iteration)),
					0.0
					), model_norm);
					
					if (dot(ray_dir, model_norm) > 0.0) {
						break;
					}
				}
				
				vec3 sample_normal;
				ivec3 sample_vids;
				int sample_face;
				vec3 a, b, c;
				
				float hit = intersects_bvh(
				ray_start, ray_dir,
				sample_normal, sample_vids, sample_face,
				a, b, c
				);
				if (hit == 65536.0 || hit < 0.0 || hit > max_raylength) {
					hit = 1.0;
				} else {
					hit = 1.0 - clamp(dot(model_norm, ray_dir), 0.0, 1.0);
				}
				ao += hit;
			}
			ao /= float(SAMPLES);
			outColor = vec4(vec3(ao), 1.0);
			"""
		"thickness":
			replaces["@BAKE_RESULT"] = """
			// start a bit under the last rayhit position
			vec3 N = normalize(interpolated.xyz);
			vec3 ray_start = hit_pos - N* 0.001; 
			vec3 second_normal;
			ivec3 second_vids;
			int second_face;
			vec3 a,b,c;
			float thickness = intersects_bvh(
				ray_start,
				-N,
				second_normal,
				second_vids,
				second_face,
				a,b,c
			);
			if (thickness >= 65536.0 || thickness < 0.0) {
			    outColor = vec4(vec3(0.0),1.0); // No hit
			} else {
				thickness = clamp(thickness / max(max_raylength * 0.75, 1e-6), 0.0, 1.0);
			    outColor = vec4(vec3(thickness), 1.0);
			}
			"""
		"distance":
			replaces["@BAKE_RESULT"] = """
				float distance_value = hit - offset * offset_scale;
				outColor = vec4(vec3(
    			clamp(0.5 + distance_value / max(max_raylength, 1e-6), 0.0, 1.0)), 1.0);
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
	
	var postprocess : Array = []
	if get_parameter("dilate"):
		postprocess.append("dilate")
	if get_parameter("denoise"):
		postprocess.append("denoise")
	
	if not postprocess.is_empty():
		var filters : MMMeshRenderingPipeline2 = MMMeshRenderingPipeline2.new()
		baked_map = await mm_renderer.thread_run(filters._postprocess,[baked_map,bake_size,postprocess])
	
	
	if output_name == "curvature":
		var position_map: MMTexture = await render_input_texture(1,bake_size)
		if position_map == null:
			push_error("Curvature requires a position map")
			return
	
		var filters := MMMeshRenderingPipeline2.new()
		var kernel := """
			vec3 dPdu =
				texture(position_map, uv + vec2(texel.x, 0.0)).xyz -
				texture(position_map, uv - vec2(texel.x, 0.0)).xyz;
			vec3 dPdv =
				texture(position_map, uv + vec2(0.0, texel.y)).xyz -
				texture(position_map, uv - vec2(0.0, texel.y)).xyz;

			vec3 dNdu =
				normalize(texture(normal_map, uv + vec2(texel.x, 0.0)).xyz) -
				normalize(texture(normal_map, uv - vec2(texel.x, 0.0)).xyz);
			vec3 dNdv =
				normalize(texture(normal_map, uv + vec2(0.0, texel.y)).xyz) -
				normalize(texture(normal_map, uv - vec2(0.0, texel.y)).xyz);

			float E = dot(dPdu, dPdu);
			float F = dot(dPdu, dPdv);
			float G = dot(dPdv, dPdv);

			float e = -dot(dNdu, dPdu);
			float f = -0.5 * (dot(dNdu, dPdv) + dot(dNdv, dPdu));
			float g = -dot(dNdv, dPdv);

			float det = E * G - F * F;
			float curvature = 0.0;

			if (det > 1e-12) {
				curvature = (e * G - 2.0 * f * F + g * E) / (2.0 * det);
			}

			float mapped = clamp(0.5 + curvature * 0.2, 0.0, 1.0);
			outColor = vec4(mapped, 0.0, 0.0, 1.0);
		"""

		var result: MMTexture = await filters.sample_map(position_map,baked_map,bake_size,kernel)
		if result == null:
			push_error("Curvature sampling failed")
			return
		baked_map = result
	
	print("Bake finished: ", get_instance_id()," map=", baked_map," rid=", baked_map.rid.is_valid())
	mm_deps.dependency_update(get_texture_parameter_name("output"),baked_map,true)
	notify_output_change(0)
		
	print("%s complete",output_name)
	
func _request_rebake()->void:
	if _baking:
		_rebake_pending = true
		return
	var ready: bool = is_output_ready(0)
	print("BAKE REQUEST: ", get_instance_id(), " ready=", ready)

	if not ready:
		for i: int in range(get_input_defs().size()):
			var source: OutputPort = get_source(i)
			if source == null:
				continue
			print(
				"  input=", i,
				" source=", source.generator.name,
				" type=", source.generator.get_type(),
				" ready=", source.generator.is_output_ready(source.output_index)
			)
	if not is_output_ready(0):
		return
		
	_baking = true
	while true:
		_rebake_pending = false
		await bake_maps()
		if not _rebake_pending:
			break
		if not is_output_ready(0):
			break
	_baking = false

func bake_world_position(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_POSITION_LUT,"world_position",bake_size)	
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
func bake_hit_normal(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_POSITION_LUT,"hit_normal",bake_size)
func bake_tangent_space_normal(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_NORMAL_LUT,"tangent_normal",bake_size)
func bake_thickness(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_NORMAL_LUT,"thickness",bake_size)
func bake_distance(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_POSITION_LUT,"distance",bake_size)
func bake_curvature(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_NORMAL_LUT,"curvature",bake_size)
func bake_ao(bake_size:Vector2i):
	await bake_attribute(MMMeshExtractor.KEY_NORMAL_LUT,"ambient_occlusion",bake_size)
