module grpc

import net.grpc.transport

// WiringMockStream implements transport.Stream for wiring integration tests.
struct WiringMockStream {
	id u32
mut:
	creation_headers  map[string]string
	sent_headers      []map[string]string
	sent_msgs         [][]u8
	sent_trailers     []map[string]string
	close_sent        bool
	recv_queue        [][]u8
	resp_header_queue []map[string]string
	trailer_queue     []map[string]string
}

fn (m WiringMockStream) stream_id() u32 {
	return m.id
}

fn (mut m WiringMockStream) send_header(headers map[string]string) ! {
	m.sent_headers << headers
}

fn (mut m WiringMockStream) recv_header() !map[string]string {
	if m.resp_header_queue.len == 0 {
		return map[string]string{}
	}
	h := m.resp_header_queue[0].clone()
	m.resp_header_queue.delete(0)
	return h
}

fn (mut m WiringMockStream) send_msg(data []u8) ! {
	m.sent_msgs << data
}

fn (mut m WiringMockStream) recv_msg() ![]u8 {
	if m.recv_queue.len == 0 {
		return error('no messages')
	}
	msg := m.recv_queue[0]
	m.recv_queue.delete(0)
	return msg
}

fn (mut m WiringMockStream) send_trailer(trailers map[string]string) ! {
	m.sent_trailers << trailers
}

fn (mut m WiringMockStream) recv_trailer() !map[string]string {
	if m.trailer_queue.len == 0 {
		return error('no trailers')
	}
	t := m.trailer_queue[0].clone()
	m.trailer_queue.delete(0)
	return t
}

fn (mut m WiringMockStream) close_send() ! {
	m.close_sent = true
}

// WiringMockTransport creates WiringMockStreams with pre-configured responses
struct WiringMockTransport {
mut:
	close_called bool
	last_method  string
	last_headers map[string]string
	mock_stream  &WiringMockStream = unsafe { nil }
}

fn (mut t WiringMockTransport) new_stream(method string, headers map[string]string) !transport.Stream {
	t.last_method = method
	t.last_headers = headers.clone()
	if t.mock_stream != unsafe { nil } {
		t.mock_stream.creation_headers = headers.clone()
		return t.mock_stream
	}
	return error('no mock stream configured')
}

fn (mut t WiringMockTransport) close() ! {
	t.close_called = true
}

// ok_trailer returns a minimal successful trailer map
fn ok_trailer() []map[string]string {
	return [{'grpc-status': '0'}]
}

// make_client builds a ClientConn wired to the given mock transport
fn make_client(mt &WiringMockTransport) ClientConn {
	return ClientConn{
		transport: mt
		target: 'test:50051'
		registry: new_compressor_registry()
	}
}

// --- Test 1: InvokeOptions defaults ---
fn test_invoke_options_default() {
	opts := InvokeOptions{}
	assert opts.encoding == ''
	assert opts.timeout_ns == i64(0)
}

// --- Test 2: ClientConn has CompressorRegistry ---
fn test_client_conn_has_registry() {
	conn := make_client(&WiringMockTransport{})
	assert conn.registry.get('gzip') != none
	assert conn.registry.get('identity') != none
	encodings := conn.registry.supported_encodings()
	assert encodings.contains('gzip')
	assert encodings.contains('identity')
}

// --- Test 3: invoke sends grpc-encoding header when compression requested ---
fn test_invoke_with_compression() {
	mut ms := &WiringMockStream{
		id: 1
		recv_queue: [encode_grpc_frame([u8(10), 20], false)]
		trailer_queue: ok_trailer()
	}
	mut mt := &WiringMockTransport{mock_stream: ms}
	mut conn := make_client(mt)
	conn.invoke('/test.Svc/Method', [u8(1), 2, 3], InvokeOptions{ encoding: 'gzip' }) or {
		assert false, 'invoke should not fail: ${err}'
		return
	}
	assert mt.last_headers['grpc-encoding'] == 'gzip'
	assert 'grpc-accept-encoding' in mt.last_headers
	assert ms.sent_msgs.len == 1
	frame, _ := decode_grpc_frame(ms.sent_msgs[0])!
	assert frame.compressed == true
}

// --- Test 4: invoke decompresses compressed response ---
fn test_invoke_decompresses_response() {
	original := [u8(42), 43, 44, 45, 46, 47, 48, 49]
	compressed := GzipCompressor{}.compress(original)!
	mut ms := &WiringMockStream{
		id: 2
		recv_queue: [encode_grpc_frame(compressed, true)]
		resp_header_queue: [{'grpc-encoding': 'gzip'}]
		trailer_queue: [{'grpc-status': '0'}]
	}
	mut mt := &WiringMockTransport{mock_stream: ms}
	mut conn := make_client(mt)
	result := conn.invoke('/test.Svc/Method', [u8(1)], InvokeOptions{})!
	assert result == original
}

// --- Test 5: invoke adds grpc-timeout header ---
fn test_invoke_with_timeout_header() {
	mut ms := &WiringMockStream{
		id: 3
		recv_queue: [encode_grpc_frame([u8(1)], false)]
		trailer_queue: ok_trailer()
	}
	mut mt := &WiringMockTransport{mock_stream: ms}
	mut conn := make_client(mt)
	opts := InvokeOptions{timeout_ns: i64(5_000_000_000)}
	conn.invoke('/test.Svc/Method', [u8(1)], opts) or {
		assert false, 'invoke should not fail: ${err}'
		return
	}
	assert 'grpc-timeout' in mt.last_headers
	assert mt.last_headers['grpc-timeout'] == '5S'
}

// --- Test 6: invoke with unknown encoding returns error ---
fn test_invoke_unsupported_encoding_error() {
	mut ms := &WiringMockStream{id: 4}
	mut mt := &WiringMockTransport{mock_stream: ms}
	mut conn := make_client(mt)
	if _ := conn.invoke('/test.Svc/Method', [u8(1)], InvokeOptions{ encoding: 'snappy' }) {
		assert false, 'should return error for unknown encoding'
	}
}

// --- Test 7: server decompresses gzip request ---
fn test_server_decompresses_request() {
	original := [u8(10), 20, 30, 40, 50, 60, 70, 80]
	compressed := GzipCompressor{}.compress(original)!
	mut mock := WiringMockStream{
		id: 10
		recv_queue: [encode_grpc_frame(compressed, true)]
	}
	handler := fn (data []u8) ![]u8 { return data }
	registry := new_compressor_registry()
	process_unary_call_with_opts(mut mock, handler, {'grpc-encoding': 'gzip'}, &registry)
	assert mock.sent_msgs.len == 1
	resp_frame, _ := decode_grpc_frame(mock.sent_msgs[0])!
	assert resp_frame.data == original
}

// --- Test 8: server compresses response when client accepts gzip ---
fn test_server_compresses_response() {
	mut mock := WiringMockStream{
		id: 11
		recv_queue: [encode_grpc_frame([u8(1), 2, 3], false)]
	}
	resp := [u8(99), 98, 97, 96, 95, 94, 93, 92]
	handler := fn (data []u8) ![]u8 {
		return [u8(99), 98, 97, 96, 95, 94, 93, 92]
	}
	registry := new_compressor_registry()
	process_unary_call_with_opts(mut mock, handler, {'grpc-accept-encoding': 'gzip,identity'}, &registry)
	assert mock.sent_msgs.len == 1
	resp_frame, _ := decode_grpc_frame(mock.sent_msgs[0])!
	assert resp_frame.compressed == true
	decompressed := GzipCompressor{}.decompress(resp_frame.data)!
	assert decompressed == resp
}

// --- Test 9: server sends UNIMPLEMENTED for unsupported encoding ---
fn test_server_unsupported_encoding() {
	mut mock := WiringMockStream{
		id: 12
		recv_queue: [encode_grpc_frame([u8(5)], true)]
	}
	handler := fn (data []u8) ![]u8 { return data }
	registry := new_compressor_registry()
	process_unary_call_with_opts(mut mock, handler, {'grpc-encoding': 'snappy'}, &registry)
	assert mock.sent_trailers.len == 1
	trailer := mock.sent_trailers[0].clone()
	assert trailer['grpc-status'] == '${int(StatusCode.unimplemented)}'
	assert trailer['grpc-message'].contains('snappy')
}

// --- Test 10: rich error details in trailer are parsed ---
fn test_rich_error_in_trailer() {
	detail_data := [u8(0x0a), 0x04, 0x74, 0x65, 0x73, 0x74]
	status := new_status_with_details(.not_found, 'resource missing', [detail_data])
	details_bin := status.encode_trailer_value()!
	mut ms := &WiringMockStream{
		id: 5
		recv_queue: [encode_grpc_frame([u8(1)], false)]
		trailer_queue: [
			{
				'grpc-status':             '${int(StatusCode.not_found)}'
				'grpc-message':            'resource missing'
				'grpc-status-details-bin': details_bin
			},
		]
	}
	mut mt := &WiringMockTransport{mock_stream: ms}
	mut conn := make_client(mt)
	if _ := conn.invoke('/test.Svc/Method', [u8(1)], InvokeOptions{}) {
		assert false, 'should have returned error for non-zero status'
	} else {
		err_msg := err.msg()
		assert err_msg.contains('not_found')
		assert err_msg.contains('resource missing')
		assert err_msg.contains('1 detail')
	}
}

// --- Test G2-02: invoke must pass extra headers to send_header, not empty map ---
fn test_invoke_passes_extras_to_send_header() {
	mut ms := &WiringMockStream{
		id: 1
		recv_queue: [encode_grpc_frame([u8(10)], false)]
		trailer_queue: ok_trailer()
	}
	mut mt := &WiringMockTransport{mock_stream: ms}
	mut conn := make_client(mt)
	conn.invoke('/test.Svc/Method', [u8(1)], InvokeOptions{encoding: 'gzip'}) or {
		assert false, 'invoke should not fail: ${err}'
		return
	}
	// send_header must receive the extra headers, not an empty map
	assert ms.sent_headers.len >= 1
	sent := ms.sent_headers[0].clone()
	assert 'grpc-encoding' in sent, 'grpc-encoding must be in send_header extras'
	assert sent['grpc-encoding'] == 'gzip'
	assert 'grpc-accept-encoding' in sent, 'grpc-accept-encoding must be in send_header extras'
}

// --- Test G2-03: invoke decompresses using response headers, not trailers ---
fn test_invoke_decompresses_from_response_headers() {
	raw_data := [u8(42), 43, 44, 45, 46, 47, 48, 49]
	// Identity encoding: if invoke reads from trailers (empty), defaults to gzip → FAIL
	identity_data := IdentityCompressor{}.compress(raw_data)!
	mut ms := &WiringMockStream{
		id: 6
		recv_queue: [encode_grpc_frame(identity_data, true)]
		resp_header_queue: [{'grpc-encoding': 'identity'}]
		trailer_queue: [{'grpc-status': '0'}]
	}
	mut mt := &WiringMockTransport{mock_stream: ms}
	mut conn := make_client(mt)
	result := conn.invoke('/test.Svc/Method', [u8(1)], InvokeOptions{})!
	assert result == raw_data
}
