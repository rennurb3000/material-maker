@tool
extends MMGenBase
class_name MMGenMeshLoader

var _manager : MMMeshManager
var _mesh_path : String = ""
var timer : Timer
var filetime : int = 0

func _ready() -> void:
	super._ready()
	_manager = MMMeshManager.get_instance()
	_manager.mesh_changed.connect(on_mesh_changed)
	if get_parameter("use_graph_mesh_input"):
		_set_graph_mesh.call_deferred()
	else:
		_set_mesh(get_parameter("mesh"))

func _exit_tree() -> void:
	if _manager != null:
		if _manager.mesh_changed.is_connected(on_mesh_changed):
			_manager.mesh_changed.disconnect(on_mesh_changed)
		if not _mesh_path.is_empty():
			_manager.release_mesh(_mesh_path,self)
			
func get_type() -> String:
	return "mesh_loader"

func get_type_name() -> String:
	return "Mesh Loader"

func get_description() -> String:
	return "Loads a mesh and exposes its data for mesh maps and baking"
func get_parameter_defs() -> Array:
	return [
		{
			name="mesh",
			type = "file",
			label="Mesh",
			default="",
			filters=MMMeshLoader.get_file_dialog_filters(),
		},
		{
			name="use_graph_mesh_input",
			type="boolean",
			label="Use Graph Mesh",
			default=false
		}
	]
func get_output_defs(_show_hidden : bool = false) -> Array:
	return[{name="mesh",type="mesh",shortdesc="Mesh"}]
	
func set_parameter(n : String, v) -> void:
	super.set_parameter(n,v)
	if _manager == null:
		return
	if n!="mesh" and n != "use_graph_mesh_input":
		return
		
	if get_parameter("use_graph_mesh_input"):
		_set_graph_mesh()
	else:
		_set_mesh(get_parameter("mesh"))
			
func _set_graph_mesh()->void:
	var graph := get_parent() as MMGenGraph
	if graph == null:
		_clear_mesh()
		return
	var mesh : ArrayMesh = graph.get_current_mesh() as ArrayMesh
	if mesh == null:
		_clear_mesh()
		return
		
	var path := "graph://%d" %graph.get_instance_id()
	if  path  == _mesh_path:
		_manager.update_mesh(path,mesh)
	else:
		if _manager.acquire_mesh(path,self,mesh) == null:
			return
		if not _mesh_path.is_empty():
			_manager.release_mesh(_mesh_path,self)
		_mesh_path = path
	notify_output_change(0)

func _clear_mesh()->void:
	if _mesh_path.is_empty():
		return
	_manager.release_mesh(_mesh_path,self)
	_mesh_path = ""
	notify_output_change(0)
	

func on_graph_mesh_changed()->void:
	if get_parameter("use_graph_mesh_input"):
		_set_graph_mesh()
		
func _set_mesh(path:String)->void:
	if path == _mesh_path:
		return
	if path.is_empty():
		_clear_mesh()
		return
		
	if _manager.acquire_mesh(path,self)==null:
		_clear_mesh()
		return
		
	if not _mesh_path.is_empty():
		_manager.release_mesh(_mesh_path,self)
	
	_mesh_path = path
	print("MeshLoader updated: ", _mesh_path)
	notify_output_change(0)
	
func on_mesh_changed(path: String)->void:
	if path == _mesh_path:
		notify_output_change(0)

func get_mesh_data()->MMBvhData:
	if _mesh_path.is_empty():
		return null
	var data := MMBvhData.new()
	data.mesh_path = _mesh_path
	return data

func _serialize(data: Dictionary) -> Dictionary:
	return data
