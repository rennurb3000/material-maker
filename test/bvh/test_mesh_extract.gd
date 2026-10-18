extends GutTest

func test_extract_gpu():
	var start := Time.get_ticks_usec()
	var mesh := load("res://material_maker/meshes/simple_multisurface_vcolor.obj") as ArrayMesh
	var loaded := Time.get_ticks_usec()
	assert_not_null(mesh)
	var rd := RenderingServer.create_local_rendering_device()
	var extractor := MMMeshExtractor.new(rd)
	var initialized := Time.get_ticks_usec()
	var res := extractor.extract_gpu(mesh)
	var extracted := Time.get_ticks_usec()
	
	
	print("Mesh loading: %.3f s" % ((loaded - start) / 1_000_000.0))
	print("RD + pipeline initialization: %.3f s" % ((initialized - loaded) / 1_000_000.0))
	print("GPU extraction: %.3f s" % ((extracted - initialized) / 1_000_000.0))
	print("Total: %.3f s" % ((extracted - start) / 1_000_000.0))
	
	for i in range(mesh.get_surface_count()):
		print(
			"Surface ", i,
			" | vertices: ", mesh.surface_get_array_len(i),
			" | indices: ", mesh.surface_get_array_index_len(i)
		)
	var vertex_count: int = res[MMMeshExtractor.KEY_VERTEX_COUNT]
	var index_count: int = res[MMMeshExtractor.KEY_INDEX_COUNT]

	assert_gt(vertex_count, 0)
	assert_eq(index_count % 3, 0)
	
	var vertices := rd.buffer_get_data(res[MMMeshExtractor.KEY_VERTICES]).to_float32_array()
	var indices := rd.buffer_get_data(res[MMMeshExtractor.KEY_INDICES]).to_int32_array()
	var surface_ids := rd.buffer_get_data(res[MMMeshExtractor.KEY_SURFACE_IDS]).to_int32_array()
	print("buffer reading done")
	assert_eq(vertices.size(), vertex_count * 4)
	assert_eq(indices.size(), index_count)
	assert_eq(surface_ids.size(), vertex_count)

	var vertex_offset := 0
	var index_offset := 0
	print("testing...")
	for surface_idx in range(mesh.get_surface_count()):
		print("testing surface %d"%surface_idx)
		var arrays := mesh.surface_get_arrays(surface_idx)
		if arrays.is_empty():
			continue
		
		var source_vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if source_vertices.is_empty():
			continue
		
		var source_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var indexed := not source_indices.is_empty()
		var surface_index_count := source_indices.size() if indexed else source_vertices.size()
		for i in range(source_vertices.size()):
			var dst:= vertex_offset +i
			var source := source_vertices[i]
			
			if surface_ids[dst] != surface_idx:
				print(
					"Mismatch: dst=", dst,
					" expected_surface=", surface_idx,
					" actual_surface=", surface_ids[dst]
				)
			
			assert_almost_eq(vertices[dst * 4], source.x, 0.00001)
			assert_almost_eq(vertices[dst * 4 + 1], source.y, 0.00001)
			assert_almost_eq(vertices[dst * 4 + 2], source.z, 0.00001)
			assert_eq(surface_ids[dst], surface_idx)
		for i in range(surface_index_count):
			var expected_index := source_indices[i] if indexed else i
			assert_eq(indices[index_offset+i],vertex_offset+ expected_index)
		
		vertex_offset += source_vertices.size()
		index_offset += surface_index_count
	for value in res.values():
		if value is RID and value.is_valid():
			rd.free_rid(value)
	extractor.cleanup()
	rd.free()

func test_exctract_gpu_lbvh():
	var t_start = Time.get_ticks_usec()
	var mesh := load("res://material_maker/meshes/simple_multisurface_vcolor.obj") as ArrayMesh
	assert_not_null(mesh)
	var rd := RenderingServer.create_local_rendering_device()
	var extractor := MMMeshExtractor.new(rd)
	var generator := MMBvhGeneratorGPU.new(rd)
	var extracted := extractor.extract_gpu(mesh)
	assert_gt(extracted[MMMeshExtractor.KEY_VERTEX_COUNT],0)
	assert_gt(extracted[MMMeshExtractor.KEY_INDEX_COUNT],0)
	var ctx = {}
	var status := generator._create_buffers_from_extraction(ctx,extracted)
	assert_eq(status,MMBvhGeneratorGPU.BVHStatus.OK)
	
	if status == MMBvhGeneratorGPU.BVHStatus.OK:
		status = generator._generate_lbvh(ctx)
		assert_eq(status,MMBvhGeneratorGPU.BVHStatus.OK)
	
	if status == MMBvhGeneratorGPU.BVHStatus.OK:
		status = generator._generate_mm_bvh(ctx)
		assert_eq(status,MMBvhGeneratorGPU.BVHStatus.OK)

	var t_done_extract = Time.get_ticks_usec()	
	print("extraction successful %.3f"%((t_done_extract-t_start)/1000000.0))
		# Extractor owns the input buffers.
	ctx.erase(MMBvhGeneratorGPU.KEY_VERTEX_BUFFER)
	ctx.erase(MMBvhGeneratorGPU.KEY_INDEX_BUFFER)
	generator._cleanup(ctx)
	for value in extracted.values():
		if value is RID and value.is_valid():
			rd.free_rid(value)
	generator.cleanup()
	extractor.cleanup()
	rd.free()
