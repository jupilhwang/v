module transport

// MockStream implements Stream interface for testing
struct MockStream {
	id u32
mut:
	sent_headers   []map[string]string
	sent_msgs      [][]u8
	sent_trailers  []map[string]string
	recv_queue     [][]u8
	header_queue   []map[string]string
	trailer_queue  []map[string]string
	closed         bool
}

fn (m MockStream) stream_id() u32 {
	return m.id
}

fn (mut m MockStream) send_header(headers map[string]string) ! {
	m.sent_headers << headers
}

fn (mut m MockStream) recv_header() !map[string]string {
	if m.header_queue.len == 0 {
		return map[string]string{}
	}
	h := m.header_queue[0].clone()
	m.header_queue.delete(0)
	return h
}

fn (mut m MockStream) send_msg(data []u8) ! {
	m.sent_msgs << data
}

fn (mut m MockStream) recv_msg() ![]u8 {
	if m.recv_queue.len == 0 {
		return error('no messages in queue')
	}
	msg := m.recv_queue[0]
	m.recv_queue.delete(0)
	return msg
}

fn (mut m MockStream) send_trailer(trailers map[string]string) ! {
	m.sent_trailers << trailers
}

fn (mut m MockStream) recv_trailer() !map[string]string {
	if m.trailer_queue.len == 0 {
		return error('no trailers in queue')
	}
	t := m.trailer_queue[0].clone()
	m.trailer_queue.delete(0)
	return t
}

fn (mut m MockStream) close_send() ! {
	m.closed = true
}

// MockClientTransport implements ClientTransport for testing
struct MockClientTransport {
mut:
	next_id u32
	closed  bool
}

fn (mut t MockClientTransport) new_stream(method string, headers map[string]string) !Stream {
	t.next_id++
	return Stream(MockStream{id: t.next_id})
}

fn (mut t MockClientTransport) close() ! {
	t.closed = true
}

// --- Tests ---

fn test_mock_stream_implements_stream() {
	mut mock := MockStream{id: 42}
	s := Stream(mock)
	assert s.stream_id() == 42
}

fn test_stream_send_recv_msg() {
	mut mock := MockStream{
		id: 1
		recv_queue: [[u8(1), 2, 3]]
	}
	mut s := Stream(mock)
	s.send_msg([u8(4), 5, 6]) or {
		assert false, 'send_msg should not fail'
		return
	}
	data := s.recv_msg() or {
		assert false, 'recv_msg should not fail'
		return
	}
	assert data == [u8(1), 2, 3]
}

fn test_stream_headers_and_trailers() {
	mut mock := MockStream{
		id: 2
		trailer_queue: [
			{
				'grpc-status':  '0'
				'grpc-message': 'OK'
			},
		]
	}
	mut s := Stream(mock)
	s.send_header({
		'content-type': 'application/grpc'
	}) or {
		assert false, 'send_header should not fail'
		return
	}
	s.send_trailer({
		'grpc-status': '0'
	}) or {
		assert false, 'send_trailer should not fail'
		return
	}
	trailers := s.recv_trailer() or {
		assert false, 'recv_trailer should not fail'
		return
	}
	assert trailers['grpc-status'] == '0'
	assert trailers['grpc-message'] == 'OK'
}

fn test_stream_close_send() {
	mut mock := MockStream{id: 3}
	mut s := Stream(mock)
	s.close_send() or {
		assert false, 'close_send should not fail'
		return
	}
	// Verify close_send succeeded (no error)
	assert true
}

fn test_mock_client_transport_new_stream() {
	mut t := MockClientTransport{}
	mut ct := ClientTransport(t)
	stream := ct.new_stream('/pkg.Svc/Method', {
		'content-type': 'application/grpc'
	}) or {
		assert false, 'new_stream should not fail'
		return
	}
	assert stream.stream_id() == 1
}

fn test_mock_client_transport_close() {
	mut t := MockClientTransport{}
	mut ct := ClientTransport(t)
	ct.close() or {
		assert false, 'close should not fail'
		return
	}
	assert true
}

fn test_stream_direction_enum() {
	assert int(StreamDirection.unary) == 0
	assert int(StreamDirection.server_streaming) == 1
	assert int(StreamDirection.client_streaming) == 2
	assert int(StreamDirection.bidi_streaming) == 3
}

fn test_incoming_stream_fields() {
	mut mock := MockStream{id: 10}
	incoming := IncomingStream{
		stream: mock
		method: '/pkg.Svc/Method'
		headers: {
			'content-type': 'application/grpc'
		}
	}
	assert incoming.method == '/pkg.Svc/Method'
	assert incoming.headers['content-type'] == 'application/grpc'
	assert incoming.stream.stream_id() == 10
}
