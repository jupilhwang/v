module grpc

import net.grpc.transport

// MockClientTestStream implements transport.Stream for client streaming tests.
// Tracks sent data and provides recv_queue for reader tests.
struct MockClientTestStream {
	id u32
mut:
	sent_headers  []map[string]string
	sent_trailers []map[string]string
	sent_msgs     [][]u8
	recv_queue    [][]u8
	trailer_queue []map[string]string
	close_sent    bool
}

fn (m MockClientTestStream) stream_id() u32 {
	return m.id
}

fn (mut m MockClientTestStream) send_header(headers map[string]string) ! {
	m.sent_headers << headers
}

fn (mut m MockClientTestStream) send_msg(data []u8) ! {
	m.sent_msgs << data
}

fn (mut m MockClientTestStream) recv_msg() ![]u8 {
	if m.recv_queue.len == 0 {
		return error('no messages in queue')
	}
	msg := m.recv_queue[0]
	m.recv_queue.delete(0)
	return msg
}

fn (mut m MockClientTestStream) send_trailer(trailers map[string]string) ! {
	m.sent_trailers << trailers
}

fn (mut m MockClientTestStream) recv_trailer() !map[string]string {
	if m.trailer_queue.len == 0 {
		return error('no trailers in queue')
	}
	t := m.trailer_queue[0].clone()
	m.trailer_queue.delete(0)
	return t
}

fn (mut m MockClientTestStream) recv_header() !map[string]string {
	return error('not supported')
}

fn (mut m MockClientTestStream) close_send() ! {
	m.close_sent = true
}

// MockClientStreamTransport implements transport.ClientTransport for testing
struct MockClientStreamTransport {
mut:
	mock_stream MockClientTestStream
	close_called bool
}

fn (mut m MockClientStreamTransport) new_stream(method string, headers map[string]string) !transport.Stream {
	return m.mock_stream
}

fn (mut m MockClientStreamTransport) close() ! {
	m.close_called = true
}

// --- Test 1: ClientStream.recv() reads one message ---
fn test_client_stream_recv() {
	payload := [u8(10), 20, 30]
	framed := encode_grpc_frame(payload, false)
	mut mock := MockClientTestStream{
		id: 1
		recv_queue: [framed]
	}
	mut cs := new_client_stream(mut mock)
	data := cs.recv() or {
		assert false, 'recv should return data'
		return
	}
	assert data == payload
}

// --- Test 2: ClientStream reads 3 messages sequentially ---
fn test_client_stream_recv_multiple() {
	msg1 := encode_grpc_frame([u8(1)], false)
	msg2 := encode_grpc_frame([u8(2)], false)
	msg3 := encode_grpc_frame([u8(3)], false)
	mut mock := MockClientTestStream{
		id: 2
		recv_queue: [msg1, msg2, msg3]
	}
	mut cs := new_client_stream(mut mock)
	for i in 0 .. 3 {
		data := cs.recv() or {
			assert false, 'recv ${i} should return data'
			return
		}
		assert data == [u8(i + 1)]
	}
}

// --- Test 3: ClientStream returns none when stream ends ---
fn test_client_stream_recv_end() {
	mut mock := MockClientTestStream{id: 3}
	mut cs := new_client_stream(mut mock)
	if _ := cs.recv() {
		assert false, 'recv on empty stream should return none'
	}
}

// --- Test 4: ClientStreamWriter.send() sends gRPC-framed message ---
fn test_client_stream_writer_send() {
	mut mock := MockClientTestStream{id: 4}
	mut writer := new_client_stream_writer(mut mock)
	writer.send([u8(42)]) or {
		assert false, 'send should not fail: ${err}'
		return
	}
	assert mock.sent_msgs.len == 1
	frame, _ := decode_grpc_frame(mock.sent_msgs[0]) or {
		assert false, 'sent data should be valid gRPC frame: ${err}'
		return
	}
	assert frame.data == [u8(42)]
}

// --- Test 5: ClientStreamWriter.close_and_recv() closes send, reads response ---
fn test_client_stream_writer_close_and_recv() {
	resp_payload := [u8(99)]
	framed_resp := encode_grpc_frame(resp_payload, false)
	mut mock := MockClientTestStream{
		id: 5
		recv_queue: [framed_resp]
		trailer_queue: [
			{
				'grpc-status': '0'
			},
		]
	}
	mut writer := new_client_stream_writer(mut mock)
	data := writer.close_and_recv() or {
		assert false, 'close_and_recv should not fail: ${err}'
		return
	}
	assert data == resp_payload
	assert mock.close_sent == true
	assert writer.closed == true
}

// --- Test 6: send after close returns error ---
fn test_client_stream_writer_send_after_close() {
	mut mock := MockClientTestStream{id: 6}
	mut writer := ClientStreamWriter{
		stream: mock
		closed: true
	}
	if _ := writer.send([u8(1)]) {
		assert false, 'send after close should return error'
	}
}

// --- Test 7: register_client_streaming_method registers in stream_methods ---
fn test_register_client_streaming_method() {
	mut s := new_server(ServerConfig{})
	s.register_client_streaming_method('/test.Svc/Upload', fn (mut stream ClientStream) ![]u8 {
		mut buf := []u8{}
		for {
			data := stream.recv() or { break }
			buf << data
		}
		return buf
	})
	assert '/test.Svc/Upload' in s.stream_methods
	desc := s.stream_methods['/test.Svc/Upload']
	assert desc.client_streams == true
}

// --- Test 8: StreamMethodDesc with client_streams flag ---
fn test_stream_method_desc_client_streams() {
	desc := StreamMethodDesc{
		name: '/test.Svc/Upload'
		server_streams: false
		client_streams: true
	}
	assert desc.name == '/test.Svc/Upload'
	assert desc.client_streams == true
	assert desc.server_streams == false
}

// --- Test 9: invoke_client_streaming returns writer ---
fn test_invoke_client_streaming_returns_writer() {
	mut conn := ClientConn{
		transport: &MockClientStreamTransport{
			mock_stream: MockClientTestStream{id: 9}
		}
		target: 'test:50051'
	}
	mut writer := conn.invoke_client_streaming('/test.Svc/Upload') or {
		assert false, 'invoke should not fail: ${err}'
		return
	}
	assert writer.closed == false
}

// --- Test 10: invoke_client_streaming on closed conn returns error ---
fn test_invoke_client_streaming_on_closed_conn() {
	mut conn := ClientConn{
		transport: &MockClientStreamTransport{}
		target: 'test'
		closed: true
	}
	if _ := conn.invoke_client_streaming('/test.Svc/Upload') {
		assert false, 'expected error on closed connection'
	}
}
