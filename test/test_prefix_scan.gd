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
	assert_eq(output.decode_u32(0), 0)
	assert_eq(output.decode_u32(4), 3)
	assert_eq(output.decode_u32(8), 6)
	assert_eq(output.decode_u32(12), 12)
	assert_eq(output.decode_u32(16), 15)
