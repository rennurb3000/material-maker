@tool
extends MMGenBase
class_name MMGenMeshLoader

var timer : Timer
var filetime : int = 0

func _ready() -> void:
	timer = Timer.new()
	add_child(timer)
	timer.wait_time = 2
	timer.start()
	timer.connect("timeout", Callable(self, "_on_timeout"))

func get_type() -> String:
	return "image"

func get_type_name() -> String:
	return "Image"

func get_parameter_defs() -> Array:
	return [
		{
			name="mesh",
			type = "file",
			label="Mesh",
			default="",
			filters=MMMeshLoader.get_file_dialog_filters(),
		},
	]

func get_filetime(file_path : String) -> int:
	if FileAccess.file_exists(file_path):
		return FileAccess.get_modified_time(file_path)
	return 0
