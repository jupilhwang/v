module h2

import net.http.v2
import sync

// Test 1: H2ServerStream returns correct stream ID
fn test_h2_server_stream_id() {
	stream := H2ServerStream{
		sid: 7
	}
	assert stream.stream_id() == 7
}

// Test 2: Response headers with extra metadata
fn test_h2_server_stream_send_header_encodes_response() {
	mut encoder := v2.new_encoder()
	extra := {
		'x-custom': 'value'
	}
	encoded := encode_grpc_response_headers(mut encoder, extra)

	mut decoder := v2.new_decoder()
	decoded := decoder.decode(encoded) or {
		assert false, 'decode failed: ${err}'
		return
	}

	mut found := map[string]string{}
	for h in decoded {
		found[h.name] = h.value
	}

	assert found[':status'] == '200'
	assert found['content-type'] == 'application/grpc+proto'
	assert found['x-custom'] == 'value'
}

// Test 3: Server trailer encodes grpc-status with END_STREAM + END_HEADERS
fn test_h2_server_stream_send_trailer_encodes_grpc_status() {
	mut encoder := v2.new_encoder()
	trailers := {
		'grpc-status':  '0'
		'grpc-message': 'OK'
	}
	frame := encode_trailing_headers(mut encoder, 3, trailers)

	assert frame.header.frame_type == .headers
	assert frame.header.stream_id == 3
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

// Test 4: recv_msg returns data from frame channel (channel-based architecture)
fn test_h2_server_stream_recv_msg_returns_data() {
	payload := [u8(0x0a), 0x0b, 0x0c, 0x0d]
	// Build gRPC LPM: [compress=0][len=4 BE][payload]
	mut grpc_msg := []u8{len: 5 + payload.len}
	grpc_msg[0] = 0
	grpc_msg[4] = u8(payload.len)
	for i, b in payload {
		grpc_msg[5 + i] = b
	}

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

// Test 5: Response headers format matches gRPC spec (no extras)
fn test_h2_server_response_headers_format() {
	mut encoder := v2.new_encoder()
	encoded := encode_grpc_response_headers(mut encoder, map[string]string{})

	mut decoder := v2.new_decoder()
	decoded := decoder.decode(encoded) or {
		assert false, 'decode failed: ${err}'
		return
	}

	mut found := map[string]string{}
	for h in decoded {
		found[h.name] = h.value
	}

	// gRPC spec: response always starts with :status 200 and content-type
	assert found[':status'] == '200'
	assert found['content-type'] == 'application/grpc+proto'
	assert decoded.len == 2
}

// Test 6: Error trailer format with non-zero grpc-status
fn test_h2_server_trailer_error_format() {
	mut encoder := v2.new_encoder()
	trailers := {
		'grpc-status':  '13'
		'grpc-message': 'Internal error'
	}
	frame := encode_trailing_headers(mut encoder, 5, trailers)

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

	assert found['grpc-status'] == '13'
	assert found['grpc-message'] == 'Internal error'
}

// --- B5: Request header validation tests ---

fn test_server_rejects_non_post_method() {
	mut encoder := v2.new_encoder()
	headers := encoder.encode([
		v2.HeaderField{name: ':method', value: 'GET'},
		v2.HeaderField{name: ':path', value: '/test.Svc/Method'},
		v2.HeaderField{name: ':scheme', value: 'http'},
		v2.HeaderField{name: 'content-type', value: 'application/grpc+proto'},
	])
	hf := v2.HeadersFrame{
		stream_id:   1
		headers:     headers
		end_headers: true
	}
	frame := hf.to_frame()

	mut t := H2ServerTransport{}
	t.decode_request_headers(frame) or {
		// Expected: should return error for non-POST method
		assert true
		return
	}
	assert false, 'expected error for non-POST method but got success'
}

fn test_server_rejects_non_grpc_content_type() {
	mut encoder := v2.new_encoder()
	headers := encoder.encode([
		v2.HeaderField{name: ':method', value: 'POST'},
		v2.HeaderField{name: ':path', value: '/test.Svc/Method'},
		v2.HeaderField{name: ':scheme', value: 'http'},
		v2.HeaderField{name: 'content-type', value: 'text/html'},
	])
	hf := v2.HeadersFrame{
		stream_id:   1
		headers:     headers
		end_headers: true
	}
	frame := hf.to_frame()

	mut t := H2ServerTransport{}
	t.decode_request_headers(frame) or {
		// Expected: should return error for non-gRPC content-type
		assert true
		return
	}
	assert false, 'expected error for non-gRPC content-type but got success'
}

fn test_server_accepts_valid_grpc_request() {
	mut encoder := v2.new_encoder()
	headers := encoder.encode([
		v2.HeaderField{name: ':method', value: 'POST'},
		v2.HeaderField{name: ':path', value: '/test.Svc/Method'},
		v2.HeaderField{name: ':scheme', value: 'http'},
		v2.HeaderField{name: 'content-type', value: 'application/grpc+proto'},
	])
	hf := v2.HeadersFrame{
		stream_id:   1
		headers:     headers
		end_headers: true
	}
	frame := hf.to_frame()

	mut t := H2ServerTransport{}
	stream, method := t.decode_request_headers(frame) or {
		assert false, 'valid gRPC request should not be rejected: ${err}'
		return
	}
	assert method == '/test.Svc/Method'
	assert stream.sid == 1
}

// --- B3: Write mutex structural verification ---

fn test_server_transport_has_write_mutex() {
	mut t := H2ServerTransport{}
	// Verify write_mu field exists and mutex is functional
	t.write_mu.@lock()
	t.write_mu.unlock()
	assert true
}

// --- G2-06: Stream channel cleanup after handler completes ---

fn test_cleanup_stream_removes_channel() {
	mut t := H2ServerTransport{}
	ch := chan v2.Frame{cap: 1}
	t.stream_channels[u32(3)] = ch
	assert u32(3) in t.stream_channels
	t.cleanup_stream(3)
	assert u32(3) !in t.stream_channels
}

fn test_cleanup_stream_noop_for_missing_stream() {
	mut t := H2ServerTransport{}
	// Should not panic for missing stream
	t.cleanup_stream(999)
	assert t.stream_channels.len == 0
}
