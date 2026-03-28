module h2

import net.http.v2

// build_grpc_lpm creates a gRPC Length-Prefixed Message: [compress=0][len BE][payload]
fn build_grpc_lpm(payload []u8) []u8 {
	len_ := payload.len
	mut buf := []u8{len: 5 + len_}
	buf[0] = 0
	buf[1] = u8(len_ >> 24)
	buf[2] = u8(len_ >> 16)
	buf[3] = u8(len_ >> 8)
	buf[4] = u8(len_)
	for i, b in payload {
		buf[5 + i] = b
	}
	return buf
}

// --- Test 1: StreamEvent holds stream_id, headers, and frame_ch ---
fn test_stream_event_creation() {
	ch := chan v2.Frame{cap: 1}
	event := StreamEvent{
		stream_id: 3
		headers:   {
			':path':   '/test.Svc/Method'
			':method': 'POST'
		}
		frame_ch:  ch
	}
	assert event.stream_id == 3
	assert event.headers[':path'] == '/test.Svc/Method'
	assert event.headers[':method'] == 'POST'
}

// --- Test 2: H2ServerTransport has demuxer fields with correct defaults ---
fn test_server_transport_demuxer_defaults() {
	t := H2ServerTransport{}
	assert t.demuxer_running == false
	assert t.stream_channels.len == 0
}

// --- Test 3: H2ServerStream has frame_ch field ---
fn test_h2_server_stream_has_frame_ch() {
	ch := chan v2.Frame{cap: 1}
	stream := H2ServerStream{
		sid:      1
		frame_ch: ch
	}
	assert stream.sid == 1
}

// --- Test 4: recv_msg reads a complete gRPC LPM from frame channel ---
fn test_recv_msg_reads_from_frame_channel() {
	grpc_msg := build_grpc_lpm([u8(0xAA), 0xBB, 0xCC])
	frame := build_data_frame(1, grpc_msg, true)

	ch := chan v2.Frame{cap: 1}
	ch <- frame

	mut stream := H2ServerStream{
		sid:      1
		frame_ch: ch
	}

	result := stream.recv_msg() or {
		assert false, 'recv_msg failed: ${err}'
		return
	}
	assert result == grpc_msg
}

// --- Test 5: recv_msg accumulates data from multiple DATA frames ---
fn test_recv_msg_accumulates_data_fragments() {
	grpc_msg := build_grpc_lpm([u8(0x01), 0x02, 0x03, 0x04, 0x05, 0x06])

	// Split: first frame has gRPC header (5 bytes), second has payload (6 bytes)
	chunk1 := grpc_msg[..5].clone()
	chunk2 := grpc_msg[5..].clone()

	frame1 := build_data_frame(1, chunk1, false)
	frame2 := build_data_frame(1, chunk2, true) // END_STREAM

	ch := chan v2.Frame{cap: 2}
	ch <- frame1
	ch <- frame2

	mut stream := H2ServerStream{
		sid:      1
		frame_ch: ch
	}

	result := stream.recv_msg() or {
		assert false, 'recv_msg failed: ${err}'
		return
	}
	assert result == grpc_msg
}

// --- Test 6: After END_STREAM, subsequent recv_msg returns error ---
fn test_recv_msg_end_stream_returns_error() {
	grpc_msg := build_grpc_lpm([u8(0xAA)])
	frame := build_data_frame(1, grpc_msg, true) // END_STREAM

	ch := chan v2.Frame{cap: 1}
	ch <- frame

	mut stream := H2ServerStream{
		sid:      1
		frame_ch: ch
	}

	// First recv_msg should succeed
	result := stream.recv_msg() or {
		assert false, 'first recv_msg should succeed: ${err}'
		return
	}
	assert result == grpc_msg

	// Second recv_msg should fail with end of stream
	stream.recv_msg() or {
		assert err.msg().contains('end of stream')
		return
	}
	assert false, 'expected error on second recv_msg after END_STREAM'
}

// --- Test 7: recv_msg handles two complete messages in sequence ---
fn test_recv_msg_two_messages_from_channel() {
	msg1 := build_grpc_lpm([u8(0x01)])
	msg2 := build_grpc_lpm([u8(0x02)])

	// Both messages in one DATA frame, no END_STREAM yet
	mut combined := []u8{}
	combined << msg1
	combined << msg2
	frame := build_data_frame(1, combined, true) // END_STREAM

	ch := chan v2.Frame{cap: 1}
	ch <- frame

	mut stream := H2ServerStream{
		sid:      1
		frame_ch: ch
	}

	// First recv_msg should return msg1
	r1 := stream.recv_msg() or {
		assert false, 'first recv_msg failed: ${err}'
		return
	}
	assert r1 == msg1

	// Second recv_msg should return msg2
	r2 := stream.recv_msg() or {
		assert false, 'second recv_msg failed: ${err}'
		return
	}
	assert r2 == msg2
}
