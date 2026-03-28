module grpc

import net.grpc.transport
import encoding.proto

// MockTransport implements transport.ClientTransport for unit testing.
// Provides controllable behavior without real network connections.
struct MockTransport {
mut:
	close_called bool
}

fn (mut m MockTransport) new_stream(method string, headers map[string]string) !transport.Stream {
	return error('mock: not connected')
}

fn (mut m MockTransport) close() ! {
	m.close_called = true
}

// --- ClientConn state tests ---

fn test_client_conn_stores_target() {
	conn := ClientConn{
		transport: &MockTransport{}
		target:    'my-server:9090'
	}
	assert conn.target == 'my-server:9090'
	assert conn.closed == false
}

fn test_client_close_marks_closed() {
	mut conn := ClientConn{
		transport: &MockTransport{}
		target:    'localhost:50051'
	}
	assert conn.closed == false
	conn.close()!
	assert conn.closed == true
}

fn test_client_close_idempotent() {
	mut conn := ClientConn{
		transport: &MockTransport{}
		target:    'localhost:50051'
	}
	conn.close()!
	// Second close must not error
	conn.close() or {
		assert false, 'second close should not error: ${err}'
	}
}

fn test_client_invoke_on_closed_returns_error() {
	mut conn := ClientConn{
		transport: &MockTransport{}
		target:    'test'
		closed:    true
	}
	if _ := conn.invoke('/svc/Method', [u8(1), 2, 3], InvokeOptions{}) {
		assert false, 'expected error on closed connection'
	}
}

// --- Frame encoding for client context ---

fn test_grpc_frame_encode_for_client() {
	data := 'hello'.bytes()
	framed := encode_grpc_frame(data, false)
	assert framed[0] == 0 // not compressed
	assert framed.len == 5 + data.len
	// Verify roundtrip
	frame, consumed := decode_grpc_frame(framed)!
	assert frame.data == data
	assert consumed == framed.len
}

// --- Marshal/unmarshal for client types ---

struct ClientTestRequest {
	name string
}

struct ClientTestResponse {
	greeting string
}

fn test_marshal_unmarshal_roundtrip_for_client_types() {
	req := ClientTestRequest{name: 'world'}
	bytes := proto.marshal[ClientTestRequest](req)!
	back := proto.unmarshal[ClientTestRequest](bytes)!
	assert back.name == 'world'
}

fn test_marshal_unmarshal_empty_client_message() {
	req := ClientTestRequest{}
	bytes := proto.marshal[ClientTestRequest](req)!
	assert bytes.len == 0
	back := proto.unmarshal[ClientTestRequest](bytes)!
	assert back.name == ''
}
