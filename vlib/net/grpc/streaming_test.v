module grpc

import net.grpc.transport

// MockStreamingStream implements transport.Stream for streaming tests.
// Tracks sent data and provides recv_queue for reader tests.
struct MockStreamingStream {
	id u32
mut:
	sent_headers  []map[string]string
	sent_trailers []map[string]string
	sent_msgs     [][]u8
	recv_queue    [][]u8
	trailer_queue []map[string]string
	close_sent    bool
}

fn (m MockStreamingStream) stream_id() u32 {
	return m.id
}

fn (mut m MockStreamingStream) send_header(headers map[string]string) ! {
	m.sent_headers << headers
}

fn (mut m MockStreamingStream) send_msg(data []u8) ! {
	m.sent_msgs << data
}

fn (mut m MockStreamingStream) recv_msg() ![]u8 {
	if m.recv_queue.len == 0 {
		return error('no messages in queue')
	}
	msg := m.recv_queue[0]
	m.recv_queue.delete(0)
	return msg
}

fn (mut m MockStreamingStream) send_trailer(trailers map[string]string) ! {
	m.sent_trailers << trailers
}

fn (mut m MockStreamingStream) recv_trailer() !map[string]string {
	if m.trailer_queue.len == 0 {
		return error('no trailers in queue')
	}
	t := m.trailer_queue[0].clone()
	m.trailer_queue.delete(0)
	return t
}

fn (mut m MockStreamingStream) recv_header() !map[string]string {
	return error('not supported')
}

fn (mut m MockStreamingStream) close_send() ! {
	m.close_sent = true
}

// --- Test 1: ServerStream.send() encodes gRPC frame ---
fn test_server_stream_send() {
	mut mock := MockStreamingStream{id: 1}
	mut ss := new_server_stream(mut mock)
	ss.send([u8(10), 20, 30]) or {
		assert false, 'send should not fail: ${err}'
		return
	}
	// Should have sent exactly one message
	assert mock.sent_msgs.len == 1
	// The sent message should be a valid gRPC frame
	frame, _ := decode_grpc_frame(mock.sent_msgs[0]) or {
		assert false, 'sent data should be valid gRPC frame: ${err}'
		return
	}
	assert frame.data == [u8(10), 20, 30]
	assert frame.compressed == false
}

// --- Test 2: ServerStream auto-sends header on first send() ---
fn test_server_stream_auto_sends_header() {
	mut mock := MockStreamingStream{id: 2}
	mut ss := new_server_stream(mut mock)
	// Before any send, no headers
	assert mock.sent_headers.len == 0
	// First send should auto-send headers
	ss.send([u8(1)]) or {
		assert false, 'send should not fail: ${err}'
		return
	}
	assert mock.sent_headers.len == 1
	// Second send should NOT send headers again
	ss.send([u8(2)]) or {
		assert false, 'second send should not fail: ${err}'
		return
	}
	assert mock.sent_headers.len == 1
}

// --- Test 3: Multiple send() calls work ---
fn test_server_stream_multiple_sends() {
	mut mock := MockStreamingStream{id: 3}
	mut ss := new_server_stream(mut mock)
	ss.send([u8(1)]) or {
		assert false, 'send 1 failed: ${err}'
		return
	}
	ss.send([u8(2)]) or {
		assert false, 'send 2 failed: ${err}'
		return
	}
	ss.send([u8(3)]) or {
		assert false, 'send 3 failed: ${err}'
		return
	}
	assert mock.sent_msgs.len == 3
	// Verify each frame's data
	for i in 0 .. 3 {
		frame, _ := decode_grpc_frame(mock.sent_msgs[i]) or {
			assert false, 'frame ${i} invalid: ${err}'
			return
		}
		assert frame.data == [u8(i + 1)]
	}
}

// --- Test 4: register_server_streaming_method registers in stream_methods ---
fn test_register_server_streaming_method() {
	mut s := new_server(ServerConfig{})
	s.register_server_streaming_method('/test.Svc/StreamMethod', fn (req []u8, mut stream ServerStream) ! {
		stream.send(req)!
	})
	assert '/test.Svc/StreamMethod' in s.stream_methods
	desc := s.stream_methods['/test.Svc/StreamMethod']
	assert desc.server_streams == true
}

// --- Test 5: handle_stream dispatches to streaming handler ---
fn test_handle_stream_dispatches_to_streaming() {
	mut s := new_server(ServerConfig{})
	// Register a server streaming handler that echoes back request 3 times
	s.register_server_streaming_method('/test.Svc/Stream', fn (req []u8, mut stream ServerStream) ! {
		for _ in 0 .. 3 {
			stream.send(req)!
		}
	})
	// Create a mock stream with a valid gRPC frame as recv data
	req_data := [u8(42)]
	framed_req := encode_grpc_frame(req_data, false)
	mut mock := MockStreamingStream{
		id: 10
		recv_queue: [framed_req]
	}
	incoming := transport.IncomingStream{
		stream: mock
		method: '/test.Svc/Stream'
	}
	s.handle_stream(incoming)
	// Should have sent header (auto), 3 messages, and trailer
	assert mock.sent_headers.len == 1
	assert mock.sent_msgs.len == 3
	assert mock.sent_trailers.len == 1
	// Trailer should have grpc-status: 0
	trailer := mock.sent_trailers[0].clone()
	assert trailer['grpc-status'] == '0'
}

// --- Test 6: ServerStreamReader reads one message ---
fn test_server_stream_reader_recv() {
	payload := [u8(5), 6, 7]
	framed := encode_grpc_frame(payload, false)
	mut mock := MockStreamingStream{
		id: 20
		recv_queue: [framed]
	}
	mut reader := ServerStreamReader{
		stream: mock
	}
	data := reader.recv() or {
		assert false, 'recv should return data'
		return
	}
	assert data == payload
}

// --- Test 7: ServerStreamReader reads multiple messages ---
fn test_server_stream_reader_recv_multiple() {
	msg1 := encode_grpc_frame([u8(1)], false)
	msg2 := encode_grpc_frame([u8(2)], false)
	msg3 := encode_grpc_frame([u8(3)], false)
	mut mock := MockStreamingStream{
		id: 21
		recv_queue: [msg1, msg2, msg3]
	}
	mut reader := ServerStreamReader{
		stream: mock
	}
	for i in 0 .. 3 {
		data := reader.recv() or {
			assert false, 'recv ${i} should return data'
			return
		}
		assert data == [u8(i + 1)]
	}
}

// --- Test 8: ServerStreamReader returns none after stream ends ---
fn test_server_stream_reader_done() {
	// Empty recv_queue → stream is done
	mut mock := MockStreamingStream{id: 22}
	mut reader := ServerStreamReader{
		stream: mock
	}
	if _ := reader.recv() {
		assert false, 'recv on empty stream should return none'
	}
	assert reader.done == true
}

// --- Test 9: StreamMethodDesc has correct fields ---
fn test_stream_method_desc() {
	desc := StreamMethodDesc{
		name: '/test.Svc/ListItems'
		server_streams: true
		client_streams: false
		stream_handler: fn (req []u8, mut stream ServerStream) ! {
			stream.send(req)!
		}
	}
	assert desc.name == '/test.Svc/ListItems'
	assert desc.server_streams == true
	assert desc.client_streams == false
}

// --- Test 10: ServerStreamReader.trailer() reads grpc-status ---
fn test_server_stream_reader_trailer() {
	mut mock := MockStreamingStream{
		id: 30
		trailer_queue: [
			{
				'grpc-status':  '0'
				'grpc-message': ''
			},
		]
	}
	mut reader := ServerStreamReader{
		stream: mock
		done: true
	}
	status := reader.trailer()!
	assert status.code == .ok
	assert status.message == ''
}
