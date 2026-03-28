module transport

// StreamDirection indicates the type of stream
pub enum StreamDirection {
	unary            // Single request, single response
	server_streaming // Single request, multiple responses
	client_streaming // Multiple requests, single response
	bidi_streaming   // Multiple requests, multiple responses
}

// Stream represents a single gRPC call over a transport.
// Implemented by h2/h2_stream.v for HTTP/2.
pub interface Stream {
	// stream_id returns the transport-level stream identifier
	stream_id() u32
mut:
	// send_header sends initial headers (request or response headers)
	send_header(headers map[string]string) !
	// recv_header receives initial response headers (complements send_header)
	recv_header() !map[string]string
	// send_msg sends a message (already framed as gRPC Length-Prefixed Message)
	send_msg(data []u8) !
	// recv_msg receives a message (returns gRPC Length-Prefixed Message bytes)
	recv_msg() ![]u8
	// send_trailer sends trailing metadata (grpc-status, grpc-message, custom trailers)
	send_trailer(trailers map[string]string) !
	// recv_trailer receives trailers
	recv_trailer() !map[string]string
	// close_send signals no more messages from sender
	close_send() !
}

// ClientTransport manages a client-side connection to a gRPC server.
// Implemented by h2/h2_client.v for HTTP/2.
pub interface ClientTransport {
mut:
	// new_stream creates a new stream for an RPC call
	new_stream(method string, headers map[string]string) !Stream
	// close closes the transport
	close() !
}

// ServerTransport manages a server-side connection from a gRPC client.
// Implemented by h2/h2_server.v for HTTP/2.
pub interface ServerTransport {
mut:
	// accept_stream accepts the next incoming stream (blocks until available)
	accept_stream() !IncomingStream
	// close closes the transport
	close() !
}

// IncomingStream holds information about an incoming RPC
pub struct IncomingStream {
pub:
	stream  Stream            // The underlying stream
	method  string            // Full method path (e.g., "/pkg.Svc/Method")
	headers map[string]string // Request headers/metadata
}
