extends RefCounted
class_name MMBvhData

var mesh_path: String
var bvh: MMTexture
var attributes : Dictionary = {}

func serialize()->Dictionary:
	return{
		"type":"BvhData",
		"mesh_path":mesh_path
	}
	
func deserialize(data: Dictionary) ->void:
	mesh_path = data.get("mesh_path","")
