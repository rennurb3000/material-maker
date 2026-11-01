@tool
extends MMGenBase
class_name MMGenPatchProject3D
var _manager : MMMeshManager
func _ready() -> void:
	super._ready()

func get_type() -> String:
	return "patch_project_3d"

func get_type_name() -> String:
	return "Patch Project 3D"

func get_input_defs() -> Array:
	return [
		{name="mesh", type="mesh", shortdesc="Mesh"},
		{name = "image",type = "rgba",shortdesc = "input image"},
	]
func get_output_defs(_show_hidden:bool = false)->Array:
	return [
		{name="output",type="rgb",shortdesc="Projected image or UV"},
		{name="mask",type="f",shortdesc="Projection Mask"}
		]

func get_parameter_defs() -> Array:
	return[
		{name="surface",type="float",label="Surface",default=-1.0,min=-1.0,max=128.0,step=1.0},
		{name="tx",type="float",label="Tx",default=0.0,min=-100.0,max=100.0,step=0.01},
		{name="ty",type="float",label="Ty",default=0.0,min=-100.0,max=100.0,step=0.01},
		{name="tz",type="float",label="Tz",default=0.0,min=-100.0,max=100.0,step=0.01},
		{name="rx",type="float",label="Rx",default=0.0,min=-180.0,max=180.0,step=1.0},
		{name="ry",type="float",label="Ry",default=0.0,min=-180.0,max=180.0,step=1.0},
		{name="rz",type="float",label="Rz",default=0.0,min=-180.0,max=180.0,step=1.0},
		{name="su",type="float",label="Su",default=1.0,min=0.0,max=100.0,step=0.01},
		{name="sv",type="float",label="Sv",default=1.0,min=0.0,max=100.0,step=0.01},
		{name= "map_size",type="enum",label="Resolution",default=2048,values=[
			{name="256",value=256},
			{name="512",value=512},
			{name="1024",value=1024},
			{name="2048",value=2048},
			{name="4096",value=4096},
			]}
	]
func set_parameter(n : String, v) -> void:
	super.set_parameter(n,v)
	if n in ["surface","tx","ty","tz","rx","ry","rz","su","sv","map_size"]:
		notify_output_change(0)
		notify_output_change(1)
