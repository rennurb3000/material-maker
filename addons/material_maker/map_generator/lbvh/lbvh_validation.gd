# TODO Refactor me!!! 
# shoved all the validation pieces to this class
# This class generates test case setups and validates it to the known cpu versions
extends Node
class_name MMLBVHValidation
# helper node class for testing the lbvh result
class LBVHNode:
	var left : int
	var right :int
	var primitive :int
	var aabb: AABB
# cpu helper node for testing only
class LBVHConstructionInfo:
	var parent: int
	var visitationCount;

# TODO actually make pipeline steps XD
static func generate_hierarchy_test(mesh:Mesh,
										rendering_device : RenderingDevice,
										ctx:Dictionary)->MMBvhGeneratorGPU.BVHStatus:
	assert(ctx.is_empty())
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	ctx.merge(generator._extract_mesh(mesh),true)
	var status := generator._create_buffers(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs_stage(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._generate_morton_codes(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._sort_morton_codes(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._generate_leaf_clusters(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._sort_morton_codes(
		ctx,
		MMBvhGeneratorGPU.KEY_CLUSTER_MORTON_BUFFER,
		MMBvhGeneratorGPU.KEY_CLUSTER_MORTON_BUFFER_TMP,
		ctx[MMBvhGeneratorGPU.KEY_CLUSTER_COUNT]
	)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._build_hierarchy(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._build_bounding_boxes(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
		
	var num_elements : int = ctx[MMBvhGeneratorGPU.KEY_CLUSTER_COUNT]
	var leaf_offset := num_elements - 1
	var lbvh_bytes : PackedByteArray = rendering_device.buffer_get_data(ctx[MMBvhGeneratorGPU.KEY_LBVH_BUFFER])
	print("==============Leaf check ==========")
	
	for i in range(min(20, num_elements)):
		var node := read_lbvh_node(lbvh_bytes, leaf_offset + i)
		print(
		"leaf ", i,
		" node=", leaf_offset + i,
		" left=", node.left,
		" right=", node.right,
		" primitive=", node.primitive,
		" min=", node.aabb.position,
		" max=", node.aabb.end
		)
	print("============= Internal Nodes =============")
	
	for i in range(min(20, num_elements - 1)):
		var node := read_lbvh_node(lbvh_bytes, i)
		
		print(
			"node=", i,
			" left=", node.left,
			" right=", node.right,
			" primitive=", node.primitive
		)
	return MMBvhGeneratorGPU.BVHStatus.OK
	
static func generate_triangle_aabbs_test(mesh:Mesh,rendering_device:RenderingDevice,ctx :Dictionary)->MMBvhGeneratorGPU.BVHStatus:
	# context needs to be {} at this stage
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	var _ctx = generator._extract_mesh(mesh)
	ctx.merge(_ctx,true)
	var status = generator._create_buffers(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs_stage(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	return MMBvhGeneratorGPU.BVHStatus.OK

static func calculate_triangle_aabb_cpu(vertices:PackedVector3Array,indices:PackedInt32Array,tri:int)->AABB:
	var index_offset = tri*3
	var v0 := vertices[indices[index_offset+0]]
	var v1 := vertices[indices[index_offset+1]]
	var v2 := vertices[indices[index_offset+2]]
	
	var min_v := Vector3(min(v0.x,min(v1.x,v2.x)),min(v0.y,min(v1.y,v2.y)),min(v0.z,min(v1.z,v2.z)))
	var max_v := Vector3(max(v0.x,max(v1.x,v2.x)),max(v0.y,max(v1.y,v2.y)),max(v0.z,max(v1.z,v2.z)))
	return AABB(min_v,max_v-min_v)
	

static func generate_morton_codes_test(mesh:Mesh,
										rendering_device : RenderingDevice,
										ctx:Dictionary)->MMBvhGeneratorGPU.BVHStatus:
	assert(ctx.is_empty())
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	ctx.merge(generator._extract_mesh(mesh),true)
	var status := generator._create_buffers(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs_stage(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._generate_morton_codes(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	return MMBvhGeneratorGPU.BVHStatus.OK
	

# cpu version of the morton code, for testing
static func _expandBits(v:int)->int:
	v = (v * 0x00010001) & 0xFF0000FF
	v = (v * 0x00000101) & 0x0F00F00F
	v = (v * 0x00000011) & 0xC30C30C3
	v = (v * 0x00000005) & 0x49249249
	return v
static func _morton3d(x:float,y:float,z:float)->int:
	x = min(max(x * 1024.0, 0.0), 1023.0)
	y = min(max(y * 1024.0, 0.0), 1023.0)
	z = min(max(z * 1024.0, 0.0), 1023.0)
	var xx = _expandBits(int(x))
	var yy = _expandBits(int(y))
	var zz = _expandBits(int(z))
	return xx * 4 + yy * 2 + zz
	
static func calculate_morton_code_cpu(aabb:AABB,scene_aabb:AABB)->int:
	var center := aabb.get_center()
	var mapped := (center-scene_aabb.position)/scene_aabb.size
	return _morton3d(mapped.x,mapped.y,mapped.z)
	
static func generate_leaf_clusters_test(
	mesh:Mesh,
	rendering_device: RenderingDevice,
	ctx:Dictionary
)-> MMBvhGeneratorGPU.BVHStatus:
	assert(ctx.is_empty())
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	ctx.merge(generator._extract_mesh(mesh),true)
	var status := generator._create_buffers(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs_stage(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._generate_morton_codes(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._sort_morton_codes(ctx)
	return generator._generate_leaf_clusters(ctx)
	
static func generate_sort_morton_test(mesh:Mesh,
										rendering_device : RenderingDevice,
										ctx:Dictionary)->MMBvhGeneratorGPU.BVHStatus:
	assert(ctx.is_empty())
	var generator := MMBvhGeneratorGPU.get_instance(rendering_device)
	ctx.merge(generator._extract_mesh(mesh),true)
	var status := generator._create_buffers(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._generate_element_aabbs_stage(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._generate_morton_codes(ctx)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	status = generator._sort_morton_codes(ctx)
	#TEST
	var data := rendering_device.buffer_get_data(ctx[MMBvhGeneratorGPU.KEY_MORTON_BUFFER])
	for i in range(min(20, data.size() / 8)):
		print(
		i,
		" morton=",
		data.decode_u32(i * 8),
		" element=",
		data.decode_u32(i * 8 + 4)
		)
	if status != MMBvhGeneratorGPU.BVHStatus.OK:
		return status
	return MMBvhGeneratorGPU.BVHStatus.OK
	
static func read_lbvh_node(data:PackedByteArray,node_idx:int)->LBVHNode:
	var offset := node_idx * MMBvhGeneratorGPU.LBVH_NODE_SIZE
	var node := LBVHNode.new()
	node.left = data.decode_s32(offset+0)
	node.right = data.decode_s32(offset+4)
	node.primitive = data.decode_u32(offset+8)
	var min := Vector3(
		data.decode_float(offset+12),
		data.decode_float(offset+16),
		data.decode_float(offset+20))
	var max := Vector3(
		data.decode_float(offset+24),
		data.decode_float(offset+28),
		data.decode_float(offset+32))
	node.aabb = AABB(min,max-min)
	return node
	
static func read_lbvh_nodes(data:PackedByteArray)->Array[LBVHNode]:
	var num_nodes = data.size()/MMBvhGeneratorGPU.LBVH_NODE_SIZE
	var retvar : Array[LBVHNode] = []
	retvar.resize(num_nodes)
	for idx in range(num_nodes):
		retvar[idx] = read_lbvh_node(data,idx)
	return retvar

static func traverse_lbvh_cpu(nodes:Array[LBVHNode],node_idx:int,visitor:Callable)->void:
	var node := nodes[node_idx]
	visitor.call(node_idx,node)
	if node.left !=MMBvhGeneratorGPU.INVALID_POINTER:
		traverse_lbvh_cpu(nodes,node.left,visitor)
	if node.right !=MMBvhGeneratorGPU.INVALID_POINTER:
		traverse_lbvh_cpu(nodes,node.right,visitor)
		
static func read_lbvh_construction_infos(data:PackedByteArray)->Array[LBVHConstructionInfo]:
	var count := data.size() /MMBvhGeneratorGPU.LBVH_CONSTRUCTION_INFO_SIZE
	var result : Array[LBVHConstructionInfo] = []
	result.resize(count)
	for idx in count:
		var offset := idx * MMBvhGeneratorGPU.LBVH_CONSTRUCTION_INFO_SIZE
		var info := LBVHConstructionInfo.new()
		info.parent = data.decode_u32(offset)
		info.visitationCount = data.decode_u32(offset+4)
		result[idx] = info
	return result


#static func generate(mesh: Mesh,add_vertex_info : bool = false) -> ImageTexture:
#	pass
static func validate_hierarchy(nodes:Array[LBVHNode],construction:Array,primitive_count:int)->bool:
	var node_count := primitive_count *2-1
	var leaf_offset := primitive_count -1
	var incoming := PackedInt32Array()
	incoming.resize(node_count)
	
	for idx in range(leaf_offset):
		var node:=nodes[idx]
		for child in [node.left,node.right]:
			#valid children
			if(child<0 or child>=node_count):
				print("node %d has invalid child %d"%[idx,child])
				return false
			#children parent loop
			if (child==idx):
				print("node %d references itself"%idx)
				return false
			incoming[child]+=1
			#construction info mismatch regarding parent children relationship
			if(construction[child].parent!=idx):
				print("node %d -> child %d , but child parent is %d"%[idx,child,construction[child].parent])
				return false
		# root should not have parents
	if(incoming[0]!=0):
		print("root has %d parents!"%incoming[0])
		return false
	for idx in range(1, node_count):
		if (incoming[idx]!=1):
			print("node %d has %d parents"%[idx,incoming[idx]])
			return false
	#verify tree by dfs
	var state:= PackedByteArray()
	state.resize(node_count)
	var stack: Array[Array] = [[0,false]]
	while not stack.is_empty():
		var entry := stack.pop_back()
		var idx :int = entry[0]
		var exiting: bool = entry[1]
		if exiting:
			state[idx] = 2
			continue
		if (state[idx] ==1):
			print("cycle detected at node %d"%idx)
			return false
		if state[idx] == 2:
			continue
		state[idx] = 1
		stack.append([idx,true])
		if idx<leaf_offset:
			stack.append([nodes[idx].right,false])
			stack.append([nodes[idx].left,false])
	for idx in range(node_count):
		if state[idx] != 2:
			print("node %d is unreachable from root"%idx)
			return false
	return true
