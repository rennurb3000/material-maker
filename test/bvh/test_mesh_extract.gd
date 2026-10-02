extends GutTest

func test_extract_gpu():
	var mesh := load("res://material_maker/meshes/suzanne.obj") as ArrayMesh
	assert_not_null(mesh)
	var rd := RenderingServer.create_local_rendering_device()
	var extractor := MMMeshExtractor.new(rd)
	var res := extractor.extract_gpu(mesh)
