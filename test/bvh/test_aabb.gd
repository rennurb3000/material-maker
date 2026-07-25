extends GutTest

const SAMPLE_COUNT := 10
const EPSILON := 0.0001
# STAGE 1: 
# create triangle wise AABBs using the compute shader,
# test with cpu version 
func test_triangle_aabbs():
	var mesh := load("res://material_maker/meshes/pillow.obj") as ArrayMesh
	assert_not_null(mesh)
	var rd := RenderingServer.create_local_rendering_device()
	var ctx := {}
	var status = MMBvhGeneratorGPU.generate_triangle_aabbs_test(mesh,rd,ctx)
	assert_eq(status,MMBvhGeneratorGPU.BVHStatus.OK)
	var gpu_data := rd.buffer_get_data(ctx[MMBvhGeneratorGPU.KEY_ELEMENT_BUFFER])
	var rng := RandomNumberGenerator.new()
	rng.seed = 666
	var triangle_count = ctx[MMBvhGeneratorGPU.KEY_INDICES].size()/3
	for i in SAMPLE_COUNT:
		var triangle := rng.randi_range(0,triangle_count-1)
		var expected := MMBvhGeneratorGPU.calculate_triangle_aabb_cpu(ctx[MMBvhGeneratorGPU.KEY_VERTICES],ctx[MMBvhGeneratorGPU.KEY_INDICES],triangle)
		var offset := triangle*28
		var primitive := gpu_data.decode_u32(offset+0)
		var gpu_min := Vector3(
			gpu_data.decode_float(offset+4),
			gpu_data.decode_float(offset+8),
			gpu_data.decode_float(offset+12)
		)
		var gpu_max := Vector3(
			gpu_data.decode_float(offset+16),
			gpu_data.decode_float(offset+20),
			gpu_data.decode_float(offset+24)
		)
		assert_eq(primitive,triangle)
		assert_almost_eq(gpu_min.x,expected.position.x,EPSILON)
		assert_almost_eq(gpu_min.y,expected.position.y,EPSILON)
		assert_almost_eq(gpu_min.z,expected.position.z,EPSILON)
		assert_almost_eq(gpu_max.x,expected.end.x,EPSILON)
		assert_almost_eq(gpu_max.y,expected.end.y,EPSILON)
		assert_almost_eq(gpu_max.z,expected.end.z,EPSILON)
		
#Stage 2 Generate morton codes
func test_morton_codes():
	var mesh := load("res://material_maker/meshes/pillow.obj") as ArrayMesh
	assert_not_null(mesh)
	var rd := RenderingServer.create_local_rendering_device()
	var ctx := {}
	var status := MMBvhGeneratorGPU.generate_morton_codes_test(mesh,rd,ctx)
	assert_eq(status,MMBvhGeneratorGPU.BVHStatus.OK)
	var gpu_data := rd.buffer_get_data(ctx[MMBvhGeneratorGPU.KEY_MORTON_BUFFER])
	var rng := RandomNumberGenerator.new()
	rng.seed = 666
	var triangle_count : int = ctx[MMBvhGeneratorGPU.KEY_INDICES].size()/3
	for i in SAMPLE_COUNT:
		var triangle := rng.randi_range(0,triangle_count-1)
		var triangle_aabb := MMBvhGeneratorGPU.calculate_triangle_aabb_cpu(
			ctx[MMBvhGeneratorGPU.KEY_VERTICES],
			ctx[MMBvhGeneratorGPU.KEY_INDICES],
			triangle
		)
		var expected := MMBvhGeneratorGPU.calculate_morton_code_cpu(triangle_aabb,ctx[MMBvhGeneratorGPU.KEY_SCENE_AABB])
		var offset := triangle * 8
		var gpu_morton := gpu_data.decode_u32(offset)
		var gpu_primitive := gpu_data.decode_u32(offset+4)
		assert_eq(gpu_primitive,triangle)
		assert_eq(gpu_morton,expected)

func test_radix_sort_morton_codes():
	# NOTE sort is based on subgroup size, we need to test that on NVIDIA as well!
	var mesh := load("res://material_maker/meshes/pillow.obj") as ArrayMesh
	assert_not_null(mesh)
	var rd := RenderingServer.create_local_rendering_device()
	var ctx := {}
	var status := MMBvhGeneratorGPU.generate_sort_morton_test(mesh,rd,ctx)
	assert_eq(status,MMBvhGeneratorGPU.BVHStatus.OK)
	var gpu_data := rd.buffer_get_data(ctx[MMBvhGeneratorGPU.KEY_MORTON_BUFFER])
	var rng := RandomNumberGenerator.new()
	rng.seed = 666
	var triangle_count : int = ctx[MMBvhGeneratorGPU.KEY_INDICES].size()/3
	
	var seen := {} 
	var prev := -1
	for i in triangle_count:
		var offset := i*8
		var morton := gpu_data.decode_u32(offset)
		var primitive := gpu_data.decode_u32(offset+4)
		
		assert_true(morton>=prev,"morton code not sorted idx %d" % i)
		prev = morton
		
		assert_true(primitive<triangle_count)
		assert_false(seen.has(primitive), "duplicate primitive id %d" % primitive)
		seen[primitive] = true
	# are all tris there?
	assert_eq(seen.size(),triangle_count)

func test_build_hierarchy():
	var mesh := load("res://material_maker/meshes/suzanne.obj") as ArrayMesh
	assert_not_null(mesh)
	var rd := RenderingServer.create_local_rendering_device()
	var ctx := {}
	var start_time  = Time.get_ticks_usec()
	var status := MMBvhGeneratorGPU.generate_hierarchy_test(mesh,rd,ctx)
	print("execution_time %f" %(Time.get_ticks_usec()-start_time))
	assert_eq(status,MMBvhGeneratorGPU.BVHStatus.OK)
	var node_data := rd.buffer_get_data(ctx[MMBvhGeneratorGPU.KEY_LBVH_BUFFER])
	var tri_count : int = ctx[MMBvhGeneratorGPU.KEY_INDICES].size()/3
	var node_count : int = tri_count *2 -1
	var construction_data := rd.buffer_get_data(ctx[MMBvhGeneratorGPU.KEY_LBVH_CONSTRUCTION_INFO_BUFFER])
	var construction = MMBvhGeneratorGPU.read_lbvh_construction_infos(construction_data)
	#var root := _read_node(node_data,0)
	var nodes = MMBvhGeneratorGPU.read_lbvh_nodes(node_data)
	assert_eq(nodes.size(),node_count)
	assert_eq(construction.size(),node_count)

	assert_true(MMBvhGeneratorGPU.validate_hierarchy(nodes,construction,tri_count),"hierarchy failed")
	
	var visited := {}
	MMBvhGeneratorGPU.traverse_lbvh_cpu(nodes,0,
	func(idx:int,node:MMBvhGeneratorGPU.LBVHNode):
		assert_false(visited.has(idx), "cycle detected at node %d")
		visited[idx]=true
		if (node.left == 0) and(node.right == 0):
			assert_true(node.primitive>=0, "primitive id is not valid %d" %node.primitive)
			assert_true(node.primitive<tri_count, "primitive id is not valid %d" %node.primitive)
			var expected := MMBvhGeneratorGPU.calculate_triangle_aabb_cpu(
				ctx[MMBvhGeneratorGPU.KEY_VERTICES],
				ctx[MMBvhGeneratorGPU.KEY_INDICES],
				node.primitive
			)
			# leaf aabbs correct?
			assert_almost_eq(node.aabb.position.x, expected.position.x, EPSILON)
			assert_almost_eq(node.aabb.position.y, expected.position.y, EPSILON)
			assert_almost_eq(node.aabb.position.z, expected.position.z, EPSILON)
			assert_almost_eq(node.aabb.end.x, expected.end.x, EPSILON)
			assert_almost_eq(node.aabb.end.y, expected.end.y, EPSILON)
			assert_almost_eq(node.aabb.end.z, expected.end.z, EPSILON)
		else:
			# children valid?
			assert_true(node.left>0)
			assert_true(node.right>0)
			assert_true(node.left < nodes.size())
			assert_true(node.right < nodes.size())
			assert_eq(construction[node.left].parent,idx,"left parent mismatch")
			assert_eq(construction[node.right].parent,idx,"right parent mismatch")
			# combined children aabb ~ own aabb
			var merged : AABB = nodes[node.left].aabb.merge(nodes[node.right].aabb)
			assert_almost_eq(node.aabb.position.x, merged.position.x, EPSILON)
			assert_almost_eq(node.aabb.position.y, merged.position.y, EPSILON)
			assert_almost_eq(node.aabb.position.z, merged.position.z, EPSILON)
			assert_almost_eq(node.aabb.end.x, merged.end.x, EPSILON)
			assert_almost_eq(node.aabb.end.y, merged.end.y, EPSILON)
			assert_almost_eq(node.aabb.end.z, merged.end.z, EPSILON)
		)
	assert_eq(visited.size() ,nodes.size(), "not all nodes were reached")
		
func test_mm_bvh_create():
	var mesh := load("res://material_maker/meshes/suzanne.obj") as ArrayMesh
	assert_not_null(mesh)
	var rd := RenderingServer.create_local_rendering_device()
	var bvh_gpu = MMBvhGeneratorGPU.generate(mesh,false,rd)
	assert_not_null(bvh_gpu)
	var bvh_cpu = MMBvhGenerator.generate(mesh,true)
	assert_not_null(bvh_cpu)
	MMBVHDebugUtils.write_graphviz(bvh_gpu,"test_bvhgpu.dot")
	bvh_gpu.get_image().save_png("gpu_test.png")
	MMBVHDebugUtils.write_graphviz(bvh_cpu,"test_bvhcpu.dot")
	bvh_cpu.get_image().save_png("cpu_test.png")
