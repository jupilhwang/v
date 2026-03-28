module grpc

// MockServerStream captures calls for testing server error handling behavior
struct MockServerStream {
	id u32
mut:
	sent_headers  []map[string]string
	sent_trailers []map[string]string
	sent_msgs     [][]u8
	close_sent    bool
}

fn (m MockServerStream) stream_id() u32 {
	return m.id
}

fn (mut m MockServerStream) send_header(headers map[string]string) ! {
	m.sent_headers << headers
}

fn (mut m MockServerStream) send_msg(data []u8) ! {
	m.sent_msgs << data
}

fn (mut m MockServerStream) recv_msg() ![]u8 {
	return error('no data')
}

fn (mut m MockServerStream) send_trailer(trailers map[string]string) ! {
	m.sent_trailers << trailers
}

fn (mut m MockServerStream) recv_trailer() !map[string]string {
	return error('not supported')
}

fn (mut m MockServerStream) recv_header() !map[string]string {
	return error('not supported')
}

fn (mut m MockServerStream) close_send() ! {
	m.close_sent = true
}

// --- Server creation tests ---

fn test_new_server_default_port() {
	s := new_server(ServerConfig{})
	assert s.port == 50051
}

fn test_new_server_custom_port() {
	s := new_server(ServerConfig{ port: 8080 })
	assert s.port == 8080
}

// --- Method registration tests ---

fn test_register_unary_method() {
	mut s := new_server(ServerConfig{})
	s.register_unary_method('/test.Svc/Method', fn (data []u8) ![]u8 {
		return data
	})
	assert '/test.Svc/Method' in s.methods
}

fn test_register_service() {
	mut s := new_server(ServerConfig{})
	desc := ServiceDesc{
		name: 'test.Greeter'
		methods: [
			MethodDesc{
				name: 'SayHello'
				handler: fn (data []u8) ![]u8 { return data }
			},
			MethodDesc{
				name: 'SayGoodbye'
				handler: fn (data []u8) ![]u8 { return data }
			},
		]
	}
	s.register_service(desc)
	assert '/test.Greeter/SayHello' in s.methods
	assert '/test.Greeter/SayGoodbye' in s.methods
}

fn test_register_multiple_services() {
	mut s := new_server(ServerConfig{})
	s.register_unary_method('/svc1/m1', fn (d []u8) ![]u8 { return d })
	s.register_unary_method('/svc2/m2', fn (d []u8) ![]u8 { return d })
	assert s.methods.len == 2
}

// --- Server lifecycle tests ---

fn test_server_stop() {
	mut s := new_server(ServerConfig{})
	s.running = true
	s.stop()
	assert s.running == false
}

// --- Handler behavior tests ---

fn test_handler_echo() {
	handler := fn (data []u8) ![]u8 {
		return data
	}
	result := handler([u8(1), 2, 3])!
	assert result == [u8(1), 2, 3]
}

// --- B1: Trailers-only error handling tests ---

fn test_send_error_trailer_includes_status_200() {
	mut mock := MockServerStream{id: 1}
	send_error_trailer(mut mock, 'test error')
	assert mock.sent_trailers.len == 1
	trailer := mock.sent_trailers[0].clone()
	// Per gRPC Trailers-Only spec: single HEADERS frame must include
	// initial response headers AND trailer metadata
	assert ':status' in trailer, 'trailers-only must include :status'
	assert trailer[':status'] == '200'
	assert 'content-type' in trailer, 'trailers-only must include content-type'
	assert trailer['content-type'] == 'application/grpc+proto'
	assert trailer['grpc-status'] == '${int(StatusCode.internal)}'
	assert trailer['grpc-message'] == 'test error'
}

fn test_send_unimplemented_uses_trailers_only() {
	mut mock := MockServerStream{id: 1}
	send_unimplemented(mut mock, '/test.Svc/Unknown')
	// Per gRPC Trailers-Only spec: should be a single trailer frame,
	// NOT separate header + trailer frames
	assert mock.sent_headers.len == 0, 'trailers-only should not send separate headers'
	assert mock.sent_trailers.len == 1, 'should send exactly one trailer frame'
	trailer := mock.sent_trailers[0].clone()
	assert ':status' in trailer
	assert trailer[':status'] == '200'
	assert 'content-type' in trailer
	assert trailer['content-type'] == 'application/grpc+proto'
	assert trailer['grpc-status'] == '${int(StatusCode.unimplemented)}'
}

// DataMockServerStream provides canned recv_msg data for testing handler flows
struct DataMockServerStream {
	id         u32
	recv_queue [][]u8
mut:
	recv_idx      int
	sent_headers  []map[string]string
	sent_trailers []map[string]string
	sent_msgs     [][]u8
	close_sent    bool
}

fn (m DataMockServerStream) stream_id() u32 {
	return m.id
}

fn (mut m DataMockServerStream) send_header(headers map[string]string) ! {
	m.sent_headers << headers
}

fn (mut m DataMockServerStream) send_msg(data []u8) ! {
	m.sent_msgs << data
}

fn (mut m DataMockServerStream) recv_msg() ![]u8 {
	if m.recv_idx < m.recv_queue.len {
		result := m.recv_queue[m.recv_idx].clone()
		m.recv_idx++
		return result
	}
	return error('no data')
}

fn (mut m DataMockServerStream) send_trailer(trailers map[string]string) ! {
	m.sent_trailers << trailers
}

fn (mut m DataMockServerStream) recv_trailer() !map[string]string {
	return error('not supported')
}

fn (mut m DataMockServerStream) recv_header() !map[string]string {
	return error('not supported')
}

fn (mut m DataMockServerStream) close_send() ! {
	m.close_sent = true
}

// --- G2-04: send_full_status_trailer includes grpc-status-details-bin ---

fn test_send_full_status_trailer_includes_details_bin() {
	mut mock := MockServerStream{id: 1}
	detail := [u8(0x0a), 0x03, 0x66, 0x6f, 0x6f]
	status := new_status_with_details(.internal, 'error with details', [detail])
	send_full_status_trailer(mut mock, status)
	assert mock.sent_trailers.len == 1
	trailer := mock.sent_trailers[0].clone()
	assert trailer['grpc-status'] == '${int(StatusCode.internal)}'
	assert trailer['grpc-message'] == 'error with details'
	assert 'grpc-status-details-bin' in trailer
}

fn test_send_full_status_trailer_no_details_omits_bin() {
	mut mock := MockServerStream{id: 1}
	status := new_status(.not_found, 'not found')
	send_full_status_trailer(mut mock, status)
	assert mock.sent_trailers.len == 1
	trailer := mock.sent_trailers[0].clone()
	assert trailer['grpc-status'] == '${int(StatusCode.not_found)}'
	assert trailer['grpc-message'] == 'not found'
	assert 'grpc-status-details-bin' !in trailer
}

// --- G2-05: Success trailers must include grpc-message ---

fn test_success_unary_trailer_includes_grpc_message() {
	payload := encode_grpc_frame([u8(0x01)], false)
	mut mock := DataMockServerStream{
		id:         1
		recv_queue: [payload]
	}
	handler := fn (data []u8) ![]u8 {
		return [u8(0x02)]
	}
	process_unary_call_with_opts(mut mock, handler, {}, unsafe { nil })
	assert mock.sent_trailers.len == 1
	trailer := mock.sent_trailers[0].clone()
	assert trailer['grpc-status'] == '0'
	assert 'grpc-message' in trailer
}

fn test_success_server_streaming_trailer_includes_grpc_message() {
	payload := encode_grpc_frame([u8(0x01)], false)
	mut mock := DataMockServerStream{
		id:         1
		recv_queue: [payload]
	}
	desc := StreamMethodDesc{
		name:           '/test/Stream'
		server_streams: true
		stream_handler: fn (req []u8, mut ss ServerStream) ! {
		}
	}
	process_server_streaming_call(mut mock, desc)
	assert mock.sent_trailers.len == 1
	trailer := mock.sent_trailers[0].clone()
	assert trailer['grpc-status'] == '0'
	assert 'grpc-message' in trailer
}

fn test_success_client_streaming_trailer_includes_grpc_message() {
	mut mock := DataMockServerStream{id: 1}
	desc := StreamMethodDesc{
		name:                  '/test/ClientStream'
		client_streams:        true
		client_stream_handler: fn (mut cs ClientStream) ![]u8 {
			return [u8(0x02)]
		}
	}
	process_client_streaming_call(mut mock, desc)
	assert mock.sent_trailers.len == 1
	trailer := mock.sent_trailers[0].clone()
	assert trailer['grpc-status'] == '0'
	assert 'grpc-message' in trailer
}

// --- G2-07: Server reads grpc-timeout from headers ---

fn test_extract_grpc_timeout_from_headers() {
	headers := {
		'grpc-timeout': '5S'
	}
	timeout_ns := extract_grpc_timeout(headers)
	assert timeout_ns == i64(5_000_000_000)
}

fn test_extract_grpc_timeout_missing_header() {
	headers := map[string]string{}
	timeout_ns := extract_grpc_timeout(headers)
	assert timeout_ns == i64(0)
}

fn test_extract_grpc_timeout_milliseconds() {
	headers := {
		'grpc-timeout': '500m'
	}
	timeout_ns := extract_grpc_timeout(headers)
	assert timeout_ns == i64(500_000_000)
}
