module h2

import net
import net.http.v2

// Helper: accepts a TCP connection and sends it via channel
fn protocol_do_accept(mut listener net.TcpListener, c chan &net.TcpConn) {
	c <- listener.accept() or { return }
}

// create_tcp_pair creates a connected TCP client/server pair for testing.
fn create_tcp_pair() !(RawConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, ':0')!
	listener_addr := listener.addr()!
	port := listener_addr.port()!
	c := chan &net.TcpConn{}
	spawn protocol_do_accept(mut listener, c)
	mut client_conn := net.dial_tcp('127.0.0.1:${port}')!
	mut server_conn := <-c
	listener.close() or {}
	return new_tcp_raw_conn(client_conn), server_conn
}

// make_grpc_lpm creates a gRPC Length-Prefixed Message: [compress=0][len BE][payload]
fn make_grpc_lpm(payload []u8) []u8 {
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

// build_response_headers_frame creates an HPACK-encoded HEADERS frame
// simulating a server response with :status 200, content-type, and extras.
fn build_response_headers_frame(stream_id u32, extra map[string]string) []u8 {
	mut encoder := v2.new_encoder()
	encoded := encode_grpc_response_headers(mut encoder, extra)
	hf := v2.HeadersFrame{
		stream_id:   stream_id
		headers:     encoded
		end_headers: true
	}
	return hf.to_frame().encode()
}

// --- Test G2-01: recv_msg handles initial HEADERS frame before DATA ---
fn test_recv_msg_handles_initial_response_headers() {
	raw_conn, mut server_conn := create_tcp_pair() or {
		assert false, 'create_tcp_pair failed: ${err}'
		return
	}
	defer {
		server_conn.close() or {}
	}

	// Build response: HEADERS then DATA
	headers_bytes := build_response_headers_frame(1, {})
	grpc_msg := make_grpc_lpm([u8(0xAA), 0xBB, 0xCC])
	data_bytes := build_data_frame(1, grpc_msg, true).encode()

	// Server sends HEADERS then DATA
	server_conn.write(headers_bytes) or {
		assert false, 'write headers: ${err}'
		return
	}
	server_conn.write(data_bytes) or {
		assert false, 'write data: ${err}'
		return
	}

	// Client reads via H2Stream.recv_msg — must handle initial HEADERS
	mut t := &H2ClientTransport{
		conn: raw_conn
	}
	mut stream := H2Stream{
		sid:       1
		transport: unsafe { t }
	}

	result := stream.recv_msg() or {
		assert false, 'recv_msg should handle initial HEADERS: ${err}'
		return
	}
	assert result == grpc_msg
}

// --- Test G2-01: recv_msg stores response headers for later access ---
fn test_recv_msg_stores_response_headers() {
	raw_conn, mut server_conn := create_tcp_pair() or {
		assert false, 'create_tcp_pair failed: ${err}'
		return
	}
	defer {
		server_conn.close() or {}
	}

	// Build response with grpc-encoding in HEADERS
	headers_bytes := build_response_headers_frame(1, {
		'grpc-encoding': 'gzip'
	})
	grpc_msg := make_grpc_lpm([u8(0x01)])
	data_bytes := build_data_frame(1, grpc_msg, true).encode()

	server_conn.write(headers_bytes) or {
		assert false, 'write headers: ${err}'
		return
	}
	server_conn.write(data_bytes) or {
		assert false, 'write data: ${err}'
		return
	}

	mut t := &H2ClientTransport{
		conn: raw_conn
	}
	mut stream := H2Stream{
		sid:       1
		transport: unsafe { t }
	}

	stream.recv_msg() or {
		assert false, 'recv_msg failed: ${err}'
		return
	}
	// Response headers should be stored in resp_headers
	assert stream.resp_headers[':status'] == '200'
	assert stream.resp_headers['content-type'] == 'application/grpc+proto'
	assert stream.resp_headers['grpc-encoding'] == 'gzip'
}
