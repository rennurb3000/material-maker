class_name MMVertexLutPipeline
extends MMMeshRenderingPipeline

var vertex_count : int = 0

func get_input_texture_declarations() -> String:
	print("BAKE_DECLARATIONS")
	print("texture count : ",input_textures.size())
	for t in input_textures:
		print("  ",t.name)
	return super.get_input_texture_declarations()
	
func set_shader(vertex_source : String, fragment_source : String, replaces : Dictionary = {}) -> bool:
	print("BEFORE SET SHADER")
	print(get_input_texture_declarations())
	return await super.set_shader(vertex_source,fragment_source,replaces)

func draw_list_extra_setup(rd : RenderingDevice, draw_list : int, shader : RID, rids : RIDs):
	super.draw_list_extra_setup(rd,draw_list,shader,rids)
	print("Setting mesh buffers ", mesh)

func in_thread_render(size : Vector2i,
	texture_type : int,
	target_texture : MMTexture,
	with_depth : bool = false):
	print("LUT_PIPELINE drawing points: ",vertex_count)
	var rd : RenderingDevice = mm_renderer.rendering_device
	var rids : RIDs = RIDs.new()
	
	var target_texture_id : RID = create_output_texture(rd,size,texture_type,true)
	var framebuffer : RID = create_framebuffer(rd,target_texture_id)
	rids.add(framebuffer,"framebuffer")
	var blend := RDPipelineColorBlendState.new()
	blend.attachments.push_back(
		RDPipelineColorBlendStateAttachment.new()
	)
	var rasterization_state = RDPipelineRasterizationState.new()
	rasterization_state.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var pipeline : RID = rd.render_pipeline_create(
		shader,
		rd.framebuffer_get_format(framebuffer),
		-1,
		RenderingDevice.RENDER_PRIMITIVE_POINTS,
		rasterization_state,
		RDPipelineMultisampleState.new(),
		RDPipelineDepthStencilState.new(),
		blend
	)
	rids.add(pipeline,"pipeline")
	
	var clear_colors := PackedColorArray([Color()])
	var draw_flags := (RenderingDevice.DRAW_CLEAR_COLOR_ALL| RenderingDevice.DRAW_IGNORE_COLOR_ALL)
	
	var draw_list := rd.draw_list_begin(
		framebuffer,
		draw_flags,
		clear_colors,
		1.0,
		0)
	rd.draw_list_bind_render_pipeline(draw_list,pipeline)
	draw_list_extra_setup(rd,draw_list,shader,rids)
	var uniform_set_1: RID = RID()
	if parameter_values.size()>0:
		uniform_set_1 = get_parameter_uniforms(rd,shader,rids)	
	var uniform_set_2 : RID = get_texture_uniforms(rd,shader,rids)
	
	if uniform_set_1.is_valid():
		rd.draw_list_bind_uniform_set(draw_list,uniform_set_1,1)
	if uniform_set_2.is_valid():
		rd.draw_list_bind_uniform_set(draw_list,uniform_set_2,2)

	rd.draw_list_draw(draw_list,false,1,vertex_count)
	rd.draw_list_end()
	
	rd.submit()
	rd.sync()
	
	var texture_type_struct : Dictionary = TEXTURE_TYPE[texture_type]
	
	target_texture.set_texture_rid(
		target_texture_id,
		size,
		texture_type_struct.data_format,
		rd
	)
	rids.free_rids(rd)
