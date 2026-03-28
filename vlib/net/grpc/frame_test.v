module grpc

fn test_encode_grpc_frame_uncompressed() {
	data := [u8(0x0a), 0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f]
	result := encode_grpc_frame(data, false)
	// 5-byte header + 7 data bytes = 12
	assert result.len == 12
	// compressed flag = 0
	assert result[0] == 0x00
	// big-endian length = 7
	assert result[1] == 0x00
	assert result[2] == 0x00
	assert result[3] == 0x00
	assert result[4] == 0x07
	// payload
	assert result[5..] == data
}

fn test_encode_grpc_frame_compressed() {
	data := [u8(0x01), 0x02]
	result := encode_grpc_frame(data, true)
	assert result.len == 7
	// compressed flag = 1
	assert result[0] == 0x01
	// big-endian length = 2
	assert result[1] == 0x00
	assert result[2] == 0x00
	assert result[3] == 0x00
	assert result[4] == 0x02
	assert result[5..] == data
}

fn test_decode_grpc_frame() {
	// Build a valid frame: uncompressed, 3 bytes data
	raw := [u8(0x00), 0x00, 0x00, 0x00, 0x03, 0x41, 0x42, 0x43]
	frame, consumed := decode_grpc_frame(raw)!
	assert frame.compressed == false
	assert frame.data == [u8(0x41), 0x42, 0x43]
	assert consumed == 8
}

fn test_encode_decode_roundtrip() {
	original := [u8(0xDE), 0xAD, 0xBE, 0xEF]
	encoded := encode_grpc_frame(original, false)
	frame, consumed := decode_grpc_frame(encoded)!
	assert frame.compressed == false
	assert frame.data == original
	assert consumed == encoded.len
}

fn test_decode_grpc_frame_insufficient_data() {
	// Less than 5 bytes should error
	short := [u8(0x00), 0x01]
	if _, _ := decode_grpc_frame(short) {
		assert false, 'expected error for insufficient data'
	}
}

fn test_decode_grpc_frame_empty_data() {
	// 5-byte header, 0-length message
	raw := [u8(0x00), 0x00, 0x00, 0x00, 0x00]
	frame, consumed := decode_grpc_frame(raw)!
	assert frame.compressed == false
	assert frame.data.len == 0
	assert consumed == 5
}

fn test_encode_grpc_frames_multiple() {
	frames := [
		GrpcFrame{
			compressed: false
			data: [u8(0x01)]
		},
		GrpcFrame{
			compressed: true
			data: [u8(0x02), 0x03]
		},
	]
	result := encode_grpc_frames(frames)
	// frame1: 5 + 1 = 6, frame2: 5 + 2 = 7, total = 13
	assert result.len == 13
	// First frame header
	assert result[0] == 0x00
	// Second frame starts at offset 6
	assert result[6] == 0x01
}
