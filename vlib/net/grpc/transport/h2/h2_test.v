module h2

import net
import net.http.v2

// Test 1: H2Stream returns correct stream ID
fn test_h2_stream_id() {
	stream := H2Stream{
		sid: 5
	}
	assert stream.stream_id() == 5
}

// Test 2: HPACK encoding produces correct gRPC request headers
fn test_h2_grpc_headers_encode() {
	mut encoder := v2.new_encoder()
	path := '/pkg.Svc/Method'
	headers := encode_grpc_request_headers(mut encoder, path, map[string]string{}, false)

	mut decoder := v2.new_decoder()
	decoded := decoder.decode(headers) or {
		assert false, 'decode failed: ${err}'
		return
	}

	mut found := map[string]string{}
	for h in decoded {
		found[h.name] = h.value
	}

	assert found[':method'] == 'POST'
	assert found[':scheme'] == 'http'
	assert found[':path'] == '/pkg.Svc/Method'
	assert found['content-type'] == 'application/grpc+proto'
	assert found['te'] == 'trailers'
}

// Test 3: DATA frame creation from message bytes
fn test_h2_data_frame_creation() {
	data := [u8(1), 2, 3, 4, 5]
	frame := build_data_frame(3, data, false)

	assert frame.header.frame_type == .data
	assert frame.header.stream_id == 3
	assert frame.payload == data
	assert !frame.header.has_flag(.end_stream)
}

// Test 4: Trailing HEADERS encode grpc-status and grpc-message
fn test_h2_trailing_headers_encode() {
	mut encoder := v2.new_encoder()
	trailers := {
		'grpc-status':  '0'
		'grpc-message': 'OK'
	}
	frame := encode_trailing_headers(mut encoder, 1, trailers)

	assert frame.header.frame_type == .headers
	assert frame.header.has_flag(.end_stream)
	assert frame.header.has_flag(.end_headers)

	mut decoder := v2.new_decoder()
	decoded := decoder.decode(frame.payload) or {
		assert false, 'decode failed: ${err}'
		return
	}

	mut found := map[string]string{}
	for h in decoded {
		found[h.name] = h.value
	}

	assert found['grpc-status'] == '0'
	assert found['grpc-message'] == 'OK'
}

// Test 5: Stream ID allocation — odd IDs incrementing by 2
fn test_h2_stream_id_allocation() {
	mut alloc := StreamIdAllocator{}
	id1 := alloc.next()
	id2 := alloc.next()
	id3 := alloc.next()

	assert id1 == 1
	assert id2 == 3
	assert id3 == 5

	// All must be odd (client-initiated streams per RFC 7540 §5.1.1)
	assert id1 % 2 == 1
	assert id2 % 2 == 1
	assert id3 % 2 == 1
}

// Test 6: Frame encode then parse_frame roundtrip
fn test_h2_frame_encode_decode_roundtrip() {
	original := v2.Frame{
		header:  v2.FrameHeader{
			length:     5
			frame_type: .data
			flags:      u8(v2.FrameFlags.end_stream)
			stream_id:  7
		}
		payload: [u8(10), 20, 30, 40, 50]
	}
	encoded := original.encode()
	decoded := v2.parse_frame(encoded) or {
		assert false, 'parse_frame returned none'
		return
	}

	assert decoded.header.frame_type == .data
	assert decoded.header.stream_id == 7
	assert decoded.header.has_flag(.end_stream)
	assert decoded.payload == [u8(10), 20, 30, 40, 50]
}

// Test 7: HTTP/2 connection preface constant
fn test_h2_connection_preface() {
	assert v2.preface == 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'
	assert v2.preface.len == 24
}

// Helper: accepts a TCP connection and sends it via channel
fn do_test_accept(mut listener net.TcpListener, c chan &net.TcpConn) {
	c <- listener.accept() or { return }
}

// Test B4: encode_grpc_request_headers must not produce duplicate content-type/te
// when those headers are passed in the extra map.
fn test_grpc_headers_no_duplicates() {
	mut encoder := v2.new_encoder()
	// These headers are already added by encode_grpc_request_headers,
	// so passing them in extra should NOT produce duplicates.
	extra := {
		'content-type': 'application/grpc+proto'
		'te':           'trailers'
		'x-custom':     'value'
	}
	encoded := encode_grpc_request_headers(mut encoder, '/pkg.Svc/Method', extra, false)

	mut decoder := v2.new_decoder()
	decoded := decoder.decode(encoded) or {
		assert false, 'decode failed: ${err}'
		return
	}

	mut ct_count := 0
	mut te_count := 0
	mut found_custom := false
	for h in decoded {
		if h.name == 'content-type' {
			ct_count++
		}
		if h.name == 'te' {
			te_count++
		}
		if h.name == 'x-custom' && h.value == 'value' {
			found_custom = true
		}
	}
	assert ct_count == 1, 'expected 1 content-type, got ${ct_count}'
	assert te_count == 1, 'expected 1 te, got ${te_count}'
	assert found_custom, 'x-custom header missing'
}

// Test B2: recv_msg must accumulate data across multiple DATA frames
// to return a complete gRPC Length-Prefixed Message.
fn test_recv_msg_accumulates_fragmented_data() {
	// Build a gRPC Length-Prefixed Message: [compress=0][len=10 BE][10 bytes payload]
	payload := [u8(0xAA), 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44]
	mut grpc_msg := []u8{len: 5 + payload.len}
	grpc_msg[0] = 0 // not compressed
	grpc_msg[1] = 0
	grpc_msg[2] = 0
	grpc_msg[3] = 0
	grpc_msg[4] = u8(payload.len)
	for i, b in payload {
		grpc_msg[5 + i] = b
	}

	// Split into two chunks at byte 7
	chunk1 := grpc_msg[..7].clone()
	chunk2 := grpc_msg[7..].clone()

	// Build HTTP/2 DATA frames
	frame1 := build_data_frame(1, chunk1, false)
	frame2 := build_data_frame(1, chunk2, true) // END_STREAM on last frame
	frame1_bytes := frame1.encode()
	frame2_bytes := frame2.encode()

	// Create TCP pair
	mut listener := net.listen_tcp(.ip, ':0') or {
		assert false, 'listen failed: ${err}'
		return
	}
	listener_addr := listener.addr() or {
		assert false, 'addr failed: ${err}'
		return
	}
	port := listener_addr.port() or {
		assert false, 'port failed: ${err}'
		return
	}
	c := chan &net.TcpConn{}
	spawn do_test_accept(mut listener, c)
	mut client_conn := net.dial_tcp('127.0.0.1:${port}') or {
		assert false, 'dial failed: ${err}'
		return
	}
	mut server_conn := <-c
	listener.close() or {}
	defer {
		client_conn.close() or {}
		server_conn.close() or {}
	}

	// Server side writes fragmented DATA frames
	server_conn.write(frame1_bytes) or {
		assert false, 'write frame1: ${err}'
		return
	}
	server_conn.write(frame2_bytes) or {
		assert false, 'write frame2: ${err}'
		return
	}

	// Client reads via H2Stream.recv_msg
	mut t := &H2ClientTransport{
		conn: new_tcp_raw_conn(client_conn)
	}
	mut stream := H2Stream{
		sid:       1
		transport: unsafe { t }
	}

	result := stream.recv_msg() or {
		assert false, 'recv_msg failed: ${err}'
		return
	}

	assert result == grpc_msg, 'expected complete gRPC message across 2 DATA frames'
}

// Test B2: recv_msg must handle interleaved SETTINGS frames between DATA frames
fn test_recv_msg_handles_interleaved_settings() {
	// Build a gRPC Length-Prefixed Message: [compress=0][len=10 BE][10 bytes payload]
	payload := [u8(0x01), 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A]
	mut grpc_msg := []u8{len: 5 + payload.len}
	grpc_msg[0] = 0
	grpc_msg[1] = 0
	grpc_msg[2] = 0
	grpc_msg[3] = 0
	grpc_msg[4] = u8(payload.len)
	for i, b in payload {
		grpc_msg[5 + i] = b
	}

	// Split into two chunks
	chunk1 := grpc_msg[..7].clone()
	chunk2 := grpc_msg[7..].clone()

	// Build frames: DATA, SETTINGS, DATA
	data_frame1 := build_data_frame(1, chunk1, false)
	settings_frame := v2.SettingsFrame{}.to_frame()
	data_frame2 := build_data_frame(1, chunk2, true)
	data1_bytes := data_frame1.encode()
	settings_bytes := settings_frame.encode()
	data2_bytes := data_frame2.encode()

	// Create TCP pair
	mut listener := net.listen_tcp(.ip, ':0') or {
		assert false, 'listen failed: ${err}'
		return
	}
	listener_addr := listener.addr() or {
		assert false, 'addr failed: ${err}'
		return
	}
	port := listener_addr.port() or {
		assert false, 'port failed: ${err}'
		return
	}
	c := chan &net.TcpConn{}
	spawn do_test_accept(mut listener, c)
	mut client_conn := net.dial_tcp('127.0.0.1:${port}') or {
		assert false, 'dial failed: ${err}'
		return
	}
	mut server_conn := <-c
	listener.close() or {}
	defer {
		client_conn.close() or {}
		server_conn.close() or {}
	}

	// Server writes: DATA, SETTINGS, DATA
	server_conn.write(data1_bytes) or {
		assert false, 'write data1: ${err}'
		return
	}
	server_conn.write(settings_bytes) or {
		assert false, 'write settings: ${err}'
		return
	}
	server_conn.write(data2_bytes) or {
		assert false, 'write data2: ${err}'
		return
	}

	// Client reads via recv_msg — should accumulate across the interleaved SETTINGS
	mut t := &H2ClientTransport{
		conn: new_tcp_raw_conn(client_conn)
	}
	mut stream := H2Stream{
		sid:       1
		transport: unsafe { t }
	}

	result := stream.recv_msg() or {
		assert false, 'recv_msg failed: ${err}'
		return
	}

	assert result == grpc_msg, 'expected complete gRPC message despite interleaved SETTINGS'
}

// Test N2: parse_grpc_msg_length correctly reads 4-byte big-endian length
fn test_parse_grpc_msg_length_small() {
	// [compress_flag, 0, 0, 0, 10] → length = 10
	buf := [u8(0), u8(0), u8(0), u8(0), u8(10)]
	assert parse_grpc_msg_length(buf) == 10
}

fn test_parse_grpc_msg_length_large() {
	// [compress_flag, 0, 1, 0, 0] → length = 65536
	buf := [u8(0), u8(0), u8(1), u8(0), u8(0)]
	assert parse_grpc_msg_length(buf) == 65536
}

fn test_parse_grpc_msg_length_zero() {
	// [compress_flag, 0, 0, 0, 0] → length = 0
	buf := [u8(0), u8(0), u8(0), u8(0), u8(0)]
	assert parse_grpc_msg_length(buf) == 0
}

fn test_parse_grpc_msg_length_max_byte() {
	// [compress_flag, 0, 0, 1, 0xFF] → length = 511
	buf := [u8(1), u8(0), u8(0), u8(1), u8(0xFF)]
	assert parse_grpc_msg_length(buf) == 511
}
