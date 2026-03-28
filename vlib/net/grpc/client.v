module grpc

import net.grpc.transport
import net.grpc.transport.h2

// InvokeOptions configures per-call behavior for gRPC invocations
pub struct InvokeOptions {
pub:
	encoding   string // compression encoding (e.g. 'gzip', '' for none)
	timeout_ns i64    // timeout in nanoseconds (0 = no timeout)
}

// ServerStreamReader reads multiple response messages from a server stream
pub struct ServerStreamReader {
mut:
	stream transport.Stream
	done   bool
}

// recv reads the next response message; returns none when stream ends
pub fn (mut r ServerStreamReader) recv() ?[]u8 {
	if r.done {
		return none
	}
	data := r.stream.recv_msg() or {
		r.done = true
		return none
	}
	frame, _ := decode_grpc_frame(data) or {
		r.done = true
		return none
	}
	return frame.data
}

// trailer returns the gRPC status after stream ends
pub fn (mut r ServerStreamReader) trailer() !Status {
	trailers := r.stream.recv_trailer()!
	code_str := trailers['grpc-status'] or { '0' }
	message := trailers['grpc-message'] or { '' }
	return new_status(status_code_from_int(code_str.int()), message)
}

// ClientConn represents a gRPC client connection
pub struct ClientConn {
mut:
	transport transport.ClientTransport
	target    string
	closed    bool
	registry  CompressorRegistry
}

// dial creates a new gRPC client connection to the target address.
pub fn dial(target string) !&ClientConn {
	t := h2.new_h2_client_transport(target)!
	return &ClientConn{
		transport: t
		target: target
		registry: new_compressor_registry()
	}
}

// dial_tls creates a gRPC client connection over TLS.
pub fn dial_tls(target string) !&ClientConn {
	t := h2.new_h2_tls_client_transport(target)!
	return &ClientConn{
		transport: t
		target: target
		registry: new_compressor_registry()
	}
}

// close closes the client connection.
pub fn (mut c ClientConn) close() ! {
	if c.closed {
		return
	}
	c.transport.close()!
	c.closed = true
}

// invoke performs a unary RPC call with optional compression, timeout, and rich errors.
pub fn (mut c ClientConn) invoke(method string, req_data []u8, opts InvokeOptions) ![]u8 {
	if c.closed {
		return error('connection is closed')
	}

	mut extra := map[string]string{}
	extra['grpc-accept-encoding'] = c.registry.supported_encodings()

	// Compress request if encoding specified
	payload, compressed := compress_outgoing(req_data, opts.encoding, &c.registry)!
	if compressed {
		extra['grpc-encoding'] = opts.encoding
	}

	// Add timeout header
	if opts.timeout_ns > 0 {
		extra['grpc-timeout'] = encode_timeout(opts.timeout_ns)
	}

	mut stream := c.transport.new_stream(method, extra)!
	stream.send_header(extra)!

	framed := encode_grpc_frame(payload, compressed)
	stream.send_msg(framed)!
	stream.close_send()!

	resp_headers := stream.recv_header()!
	resp_framed := stream.recv_msg()!

	trailers := stream.recv_trailer()!
	status_str := trailers['grpc-status'] or { '0' }
	status_code := status_str.int()
	if status_code != 0 {
		msg := trailers['grpc-message'] or { '' }
		return check_rich_error(trailers, status_code, msg)
	}

	// Decode and optionally decompress response
	frame, _ := decode_grpc_frame(resp_framed)!
	return decompress_response(frame, resp_headers, &c.registry)
}

// check_rich_error extracts rich error details from trailers if present
fn check_rich_error(trailers map[string]string, code int, msg string) ![]u8 {
	if details_bin := trailers['grpc-status-details-bin'] {
		status := decode_trailer_value(details_bin)!
		sc := status_code_from_int(code)
		return error('gRPC ${sc}: ${msg} (${status.details.len} detail(s))')
	}
	return error('gRPC error ${code}: ${msg}')
}

// decompress_response handles response frame decompression using response headers.
fn decompress_response(frame GrpcFrame, resp_headers map[string]string, registry &CompressorRegistry) ![]u8 {
	if !frame.compressed {
		return frame.data
	}
	encoding := resp_headers['grpc-encoding'] or { 'identity' }
	compressor := registry.get(encoding) or {
		return error('unknown response encoding: ${encoding}')
	}
	return compressor.decompress(frame.data)
}

// compress_outgoing compresses data if encoding is specified and available
fn compress_outgoing(data []u8, encoding string, registry &CompressorRegistry) !([]u8, bool) {
	if encoding == '' || encoding == 'identity' {
		return data, false
	}
	compressor := registry.get(encoding) or {
		return error('unknown encoding: ${encoding}')
	}
	compressed := compressor.compress(data)!
	return compressed, true
}

// ClientStreamWriter allows sending multiple request messages
pub struct ClientStreamWriter {
mut:
	stream transport.Stream
	closed bool
}

// new_client_stream_writer creates a ClientStreamWriter wrapping a transport.Stream
pub fn new_client_stream_writer(mut stream transport.Stream) ClientStreamWriter {
	return ClientStreamWriter{stream: stream}
}

// send sends a single request message
pub fn (mut w ClientStreamWriter) send(data []u8) ! {
	if w.closed {
		return error('stream already closed')
	}
	frame_data := encode_grpc_frame(data, false)
	w.stream.send_msg(frame_data)!
}

// close_and_recv closes the send side and receives the single response
pub fn (mut w ClientStreamWriter) close_and_recv() ![]u8 {
	w.stream.close_send()!
	w.closed = true
	resp_data := w.stream.recv_msg()!
	frame, _ := decode_grpc_frame(resp_data)!
	trailers := w.stream.recv_trailer()!
	code_str := trailers['grpc-status'] or { '0' }
	if code_str != '0' {
		msg := trailers['grpc-message'] or { '' }
		return error('gRPC error ${code_str}: ${msg}')
	}
	return frame.data
}

// invoke_client_streaming opens a client streaming call
pub fn (mut conn ClientConn) invoke_client_streaming(method string) !ClientStreamWriter {
	if conn.closed {
		return error('connection is closed')
	}
	mut stream := conn.transport.new_stream(method, map[string]string{})!
	stream.send_header(map[string]string{})!
	return new_client_stream_writer(mut stream)
}
