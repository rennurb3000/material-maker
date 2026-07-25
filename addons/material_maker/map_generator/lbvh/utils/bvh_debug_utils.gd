extends Object
class_name MMBVHDebugUtils

# helper funciton to access one texel
static func _texel(img:Image,idx:int)->Color:
	var w:= img.get_width()
	return img.get_pixel(idx%w,idx/w)

static func write_graphviz(bvh:ImageTexture,file:String)->void:
	var img := bvh.get_image()
	var f:= FileAccess.open(file,FileAccess.WRITE)
	var offset_to_nodes := int(_texel(img,0).r)
	var node_count := offset_to_nodes -1
	
	f.store_line("digraph BVH {")
	f.store_line("	rankdir=TB;")
	f.store_line("	node[shape=record];")
	for node in range(node_count):
		var node_offset := int(_texel(img,1+node).r)+ offset_to_nodes
		var d0 := _texel(img,node_offset)
		var d1 := _texel(img,node_offset+1)
		var level := int(d0.a)
		var primitive_count := int(d1.a)
		if primitive_count > 0:
			f.store_line('	n%d [shape=box,style=filled,fillcolor=lightgreen,label="{%d|lvl=%d|off=%d|leaf|tris=%d}"];'
							%[node,node,level,node_offset,primitive_count])
		else:
			var children := _texel(img,node_offset+2)
			var left := int(children.r)
			var right := int(children.g)
			f.store_line(
				'    n%d [style=filled,fillcolor=lightblue,label="{%d|lvl=%d|off=%d}"];'
				% [node, node, level, node_offset]
			)
			f.store_line("    n%d -> n%d [label=\"L\"];" % [node, left])
			f.store_line("    n%d -> n%d [label=\"R\"];" % [node, right])
	f.store_line("}")
	f.close()
