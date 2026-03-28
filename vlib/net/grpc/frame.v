module grpc

// gRPC message frame format:
// [1-byte compressed flag][4-byte big-endian message length][message bytes]

pub struct GrpcFrame {
pub:
	compressed bool
	data       []u8
}

// Encode a message into gRPC Length-Prefixed Message format
pub fn encode_grpc_frame(data []u8, compressed bool) []u8 {
	len_ := data.len
	mut buf := []u8{len: 5 + len_}
	buf[0] = if compressed { u8(1) } else { u8(0) }
	buf[1] = u8(len_ >> 24)
	buf[2] = u8(len_ >> 16)
	buf[3] = u8(len_ >> 8)
	buf[4] = u8(len_)
	for i, b in data {
		buf[5 + i] = b
	}
	return buf
}

// Decode a gRPC Length-Prefixed Message frame
// Returns the frame and total bytes consumed
pub fn decode_grpc_frame(data []u8) !(GrpcFrame, int) {
	if data.len < 5 {
		return error('insufficient data: need at least 5 bytes, got ${data.len}')
	}
	compressed := data[0] == 1
	msg_len := (int(data[1]) << 24) | (int(data[2]) << 16) | (int(data[3]) << 8) | int(data[4])
	total := 5 + msg_len
	if data.len < total {
		return error('incomplete frame: need ${total} bytes, got ${data.len}')
	}
	frame_data := if msg_len > 0 { data[5..total].clone() } else { []u8{} }
	return GrpcFrame{
		compressed: compressed
		data: frame_data
	}, total
}

// Encode multiple frames into a single buffer
pub fn encode_grpc_frames(frames []GrpcFrame) []u8 {
	mut buf := []u8{}
	for f in frames {
		buf << encode_grpc_frame(f.data, f.compressed)
	}
	return buf
}
