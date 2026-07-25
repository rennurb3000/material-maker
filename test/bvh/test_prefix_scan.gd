extends GutTest

func test_prefix_simple()->void:
	var rd := RenderingServer.create_local_rendering_device()
	
	var input := PackedByteArray()
	input.resize(5*4)
	input.encode_u32(0,3)
	input.encode_u32(4,3)
	input.encode_u32(8,6)
	input.encode_u32(12,3)
	input.encode_u32(16,6)
	
	var input_buffer := rd.storage_buffer_create(input.size(),input)
	var scan  := PrefixScan.new(rd)
	var output_buffer := scan.exclusive_scan_u32(input_buffer,5)
	var output := rd.buffer_get_data(output_buffer)
	# 3,3,6,3,6 -> 0,3,6,12,15
	assert_eq(output.decode_u32(0), 0)
	assert_eq(output.decode_u32(4), 3)
	assert_eq(output.decode_u32(8), 6)
	assert_eq(output.decode_u32(12), 12)
	assert_eq(output.decode_u32(16), 15)

func test_prefix_scan_multiple_blocks():
	var rd := RenderingServer.create_local_rendering_device()
	var scan := PrefixScan.new(rd)
	const COUNT := 513 # just another workgroup
	# my measurements : 513: 0.941ms , 100 000 : 0.92 ms, 1 000 000 : 2.07ms
	# threadripper 1920x (first gen), rx 9070xt, linux
	var input := PackedByteArray()
	input.resize(COUNT*4)
	for i in COUNT:
		input.encode_u32(i*4,1)
	#1,1,1,1...
	var input_buffer := rd.storage_buffer_create(input.size(),input)
	var start := Time.get_ticks_usec()
	var output_buffer := scan.exclusive_scan_u32(input_buffer,COUNT)
	var end := Time.get_ticks_usec()
	gut.p("Prefix scan (%d elements): %.3f ms"%[COUNT,(end-start)/1000.0])
	var output := rd.buffer_get_data(output_buffer)
	#0,1,2,3,...
	for i in COUNT:
			assert_eq(
				output.decode_u32(i * 4),
				i,
				"Mismatch at index %d" % i
			)
