module grpc

import net.grpc.transport

// UnaryHandler is the signature for unary RPC handlers
// Takes raw request bytes, returns raw response bytes
pub type UnaryHandler = fn ([]u8) ![]u8

// ServerStreamHandler receives request bytes and writes responses to stream
pub type ServerStreamHandler = fn (req []u8, mut stream ServerStream) !

// ServerStream wraps transport.Stream for server-side streaming writes
pub struct ServerStream {
mut:
	stream      transport.Stream
	sent_header bool
}

// new_server_stream creates a ServerStream wrapping a transport.Stream
pub fn new_server_stream(mut stream transport.Stream) ServerStream {
	return ServerStream{stream: stream}
}

// send sends a single response message to the client
pub fn (mut ss ServerStream) send(data []u8) ! {
	if !ss.sent_header {
		ss.stream.send_header(map[string]string{})!
		ss.sent_header = true
	}
	frame_data := encode_grpc_frame(data, false)
	ss.stream.send_msg(frame_data)!
}

// Client streaming handler — reads multiple requests from stream, returns single response
pub type ClientStreamHandler = fn (mut stream ClientStream) ![]u8

// ClientStream wraps transport.Stream for server-side client-stream reading
pub struct ClientStream {
mut:
	stream transport.Stream
}

// new_client_stream creates a ClientStream wrapping a transport.Stream
pub fn new_client_stream(mut stream transport.Stream) ClientStream {
	return ClientStream{stream: stream}
}

// recv reads the next request message from the client
// Returns none when client sends END_STREAM
pub fn (mut cs ClientStream) recv() ?[]u8 {
	data := cs.stream.recv_msg() or { return none }
	frame, _ := decode_grpc_frame(data) or { return none }
	return frame.data
}

// MethodDesc describes a single RPC method
pub struct MethodDesc {
pub:
	name    string       // Method name (e.g., "SayHello")
	handler UnaryHandler // Handler function
}

// StreamMethodDesc describes a streaming RPC method
pub struct StreamMethodDesc {
pub:
	name                  string              // Full method name
	server_streams        bool                // true = server streaming
	client_streams        bool                // true = client streaming
	stream_handler        ServerStreamHandler // server streaming handler
	client_stream_handler ClientStreamHandler // client streaming handler
}

// ServiceDesc describes a gRPC service
pub struct ServiceDesc {
pub:
	name    string             // Full service name (e.g., "helloworld.Greeter")
	methods []MethodDesc       // Registered unary methods
	streams []StreamMethodDesc // Registered streaming methods
}
