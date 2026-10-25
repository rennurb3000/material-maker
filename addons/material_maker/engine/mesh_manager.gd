extends Object
class_name MMMeshManager

static var _instance : MMMeshManager

signal mesh_changed(path:String)
var _rd: RenderingDevice
var timer
var _extractor : MMMeshExtractor = null
var mesh_extract : Callable
var bvh_generate : Callable

var _cache:Dictionary = {}

static func get_instance()->MMMeshManager:
	if _instance == null:
		_instance = MMMeshManager.new()
	return  _instance

func update_backend()-> void:
	var use_gpu_extraction = mm_globals.get_config("use_gpu_mesh_extraction")
	var use_gpu_bvh = mm_globals.get_config("bake_use_lbvh")
	if (use_gpu_extraction or use_gpu_bvh) and _rd == null:
		_rd = RenderingServer.create_local_rendering_device()
	if _extractor == null:
		_extractor = MMMeshExtractor.new(_rd)
	mesh_extract = Callable()
	if use_gpu_extraction and _rd != null:
		mesh_extract = _extractor.extract_gpu
	if not mesh_extract.is_valid():
		print("using cpu extractor!")
		mesh_extract = _extractor.extract_cpu
	bvh_generate = (MMBvhGeneratorGPU.generate.bind(true, _rd) if use_gpu_bvh else MMBvhGenerator.generate.bind(true) )

func _init() -> void:
	update_backend()
	timer = Timer.new()
	timer.wait_time = 2.0
	timer.timeout.connect(_on_timeout)
	_start_timer.call_deferred()
	
func _start_timer()->void:
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(timer)
	timer.start()
	

func _on_timeout()->void:
	update_backend()
	for path in _cache.keys():
		var entry: Dictionary = _cache[path]
		# erase no longer existing owners
		for id in entry["owners"].keys():
			if entry["owners"][id].get_ref() == null:
				entry["owners"].erase(id)
		if entry["owners"].is_empty():
			_free_results(path)
			_cache.erase(path)
			continue
		if path.begins_with("graph://"):
			continue
		var filetime := FileAccess.get_modified_time(path)
		if filetime == entry["filetime"]:
			# no change
			continue
		else:
			var mesh := MMMeshLoader.load_mesh(path)
			if mesh == null:
				continue
			_free_results(path)
			entry["mesh"] = mesh
			entry["bvh"] = null # todo cleanup old bvh
			entry["filetime"] = filetime
			mesh_changed.emit(path)

func _extract_mesh(path:String)->Dictionary:
	var mesh : ArrayMesh = get_mesh(path)
	if mesh == null:
		return {}
	var extracted : Dictionary = mesh_extract.call(mesh)
	if extracted.is_empty():
		return {}
		
	if not extracted.has(MMMeshExtractor.KEY_POSITION_LUT):
		return extracted
	var attributes := {}
	attributes["indices"] = _rd.buffer_get_data(extracted[MMMeshExtractor.KEY_INDICES]).to_int32_array()
	attributes["index_count"] = extracted[MMMeshExtractor.KEY_INDEX_COUNT]
	var width:int = extracted["lut_width"]
	var height:int = extracted["lut_height"]
	var lut_keys :=[
		MMMeshExtractor.KEY_POSITION_LUT,
		MMMeshExtractor.KEY_NORMAL_LUT,
		MMMeshExtractor.KEY_TANGENT_LUT,
		MMMeshExtractor.KEY_COLOR_LUT,
		MMMeshExtractor.KEY_UV_LUT,
		MMMeshExtractor.KEY_UV2_LUT,
		MMMeshExtractor.KEY_SURFACE_ID_LUT
	]
	for key in lut_keys:
		var rid:RID = extracted[key]
		var data:= _rd.texture_get_data(rid,0)
		var image := Image.create_from_data(width,height,false,Image.FORMAT_RGBAF,data)
		attributes[key] = ImageTexture.create_from_image(image)
	# TODO create a rid cleanup function
	for rid in extracted.values():
		if rid is RID and rid.is_valid():
			# get rid of it hehe
			_rd.free_rid(rid)
	return attributes
func update_mesh(path:String,mesh:ArrayMesh)->void:
	if not _cache.has(path):
		return
	_free_results(path)
	_cache[path]["mesh"] = mesh
	mesh_changed.emit(path)
	
func get_attributes(path:String)->Dictionary:
	if not _cache.has(path):
		return {}
	var entry: Dictionary = _cache[path]
	if entry["attributes"].is_empty():
		entry["attributes"] = _extract_mesh(path)
	return entry["attributes"]

func acquire_mesh(path:String,owner:Object,mesh:ArrayMesh=null)->ArrayMesh:
	if not _cache.has(path):
		if mesh == null:
			mesh = MMMeshLoader.load_mesh(path)
		if mesh == null:
			return null
		_cache[path] = {
			"mesh":mesh,
			"filetime":0 if path.begins_with("graph://") else FileAccess.get_modified_time(path),
			"owners":{},
			"bvh":null,
			"variants":{}, # TODO later for bvh variation with differnt surfaces
			"attributes":{}
		}
	_cache[path]["owners"][owner.get_instance_id()] = weakref(owner)
	return _cache[path]["mesh"]

func release_mesh(path:String,owner:Object)->void:
	if not _cache.has(path):
		return
	var owners:Dictionary = _cache[path]["owners"]
	owners.erase(owner.get_instance_id())
	if owners.is_empty():
		_free_results(path)
		_cache.erase(path)

func get_mesh(path:String)->ArrayMesh:
	if not _cache.has(path):
		return null
	return _cache[path]["mesh"]

func get_bvh(path:String):
	if not _cache.has(path):
		return null
	var entry:Dictionary =_cache[path]
	if entry["bvh"]==null:
		entry["bvh"] = bvh_generate.call(entry["mesh"])
	return entry["bvh"]
	
func _free_results(path: String)->void:
	var entry: Dictionary = _cache[path]
	entry["bvh"] = null
	_cache[path]["attributes"].clear()
	_cache[path]["variants"].clear()

func cleanup() ->void:
	if is_instance_valid(timer):
		timer.stop()
		timer.queue_free()
		timer = null
	for path in _cache.keys():
		_free_results(path)
	_cache.clear()
	if _extractor!= null:
		_extractor.cleanup()
		_extractor = null
	if _rd != null:
		_rd.free()
		_rd = null
	if _instance == self:
		_instance = null
