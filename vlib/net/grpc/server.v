module grpc

import net
import net.mbedtls
import net.grpc.transport
import net.grpc.transport.h2

// ServerConfig holds server configuration
pub struct ServerConfig {
pub:
	port      int = 50051
	cert_file string // path to PEM certificate for TLS
	key_file  string // path to PEM private key for TLS
}

// Server is a gRPC server that handles incoming RPC calls
pub struct Server {
mut:
	config         ServerConfig
	addr           string
	port           int
	methods        map[string]UnaryHandler
	stream_methods map[string]StreamMethodDesc
	listener       &net.TcpListener = unsafe { nil }
	running        bool
	registry       CompressorRegistry
}

// new_server creates a new gRPC server
pub fn new_server(config ServerConfig) &Server {
	return &Server{
		config: config
		port: config.port
		addr: ':${config.port}'
		registry: new_compressor_registry()
	}
}

// register_unary_method registers a handler for a specific method path
pub fn (mut s Server) register_unary_method(path string, handler UnaryHandler) {
	s.methods[path] = handler
}

// register_service registers all methods from a ServiceDesc
pub fn (mut s Server) register_service(desc ServiceDesc) {
	for method in desc.methods {
		s.methods['/${desc.name}/${method.name}'] = method.handler
	}
}

// register_server_streaming_method registers a server streaming handler
pub fn (mut s Server) register_server_streaming_method(full_method string, handler ServerStreamHandler) {
	s.stream_methods[full_method] = StreamMethodDesc{
		name: full_method
		server_streams: true
		stream_handler: handler
	}
}

// register_client_streaming_method registers a client streaming RPC handler
pub fn (mut s Server) register_client_streaming_method(full_method string, handler ClientStreamHandler) {
	s.stream_methods[full_method] = StreamMethodDesc{
		name: full_method
		client_streams: true
		client_stream_handler: handler
	}
}

// serve starts the server and blocks, accepting connections
pub fn (mut s Server) serve() ! {
	mut listener := net.listen_tcp(.ip, ':${s.port}')!
	s.listener = listener
	s.running = true
	for s.running {
		tcp_conn := listener.accept() or { continue }
		spawn s.handle_connection(tcp_conn)
	}
}

// stop gracefully stops the server
pub fn (mut s Server) stop() {
	s.running = false
}

// serve_tls starts the server with TLS (h2 over TLS).
pub fn (mut s Server) serve_tls() ! {
	if s.config.cert_file == '' {
		return error('cert_file required for TLS')
	}
	if s.config.key_file == '' {
		return error('key_file required for TLS')
	}
	mut ssl_listener := mbedtls.new_ssl_listener(':${s.port}', mbedtls.SSLConnectConfig{
		cert:           s.config.cert_file
		cert_key:       s.config.key_file
		alpn_protocols: ['h2']
	})!
	s.running = true
	for s.running {
		ssl_conn := ssl_listener.accept() or { continue }
		spawn s.handle_raw_conn(ssl_conn, true)
	}
	ssl_listener.shutdown()!
}

// handle_connection processes one HTTP/2 plaintext connection.
fn (s &Server) handle_connection(tcp_conn &net.TcpConn) {
	s.handle_raw_conn(h2.new_tcp_raw_conn(tcp_conn), false)
}

// handle_raw_conn creates an H2ServerTransport and dispatches streams.
fn (s &Server) handle_raw_conn(conn h2.RawConn, tls bool) {
	mut tr := h2.new_h2_server_transport_with_conn(conn, tls) or { return }
	defer { tr.close() or {} }
	for {
		incoming := tr.accept_stream() or { break }
		spawn s.handle_stream(incoming)
	}
}

// handle_stream dispatches one incoming RPC to the appropriate handler
fn (s &Server) handle_stream(incoming transport.IncomingStream) {
	mut stream := incoming.stream
	if incoming.method in s.methods {
		handler := s.methods[incoming.method]
		process_unary_call_with_opts(mut stream, handler, incoming.headers, &s.registry)
	} else if incoming.method in s.stream_methods {
		desc := s.stream_methods[incoming.method]
		if desc.client_streams {
			process_client_streaming_call(mut stream, desc)
		} else {
			process_server_streaming_call(mut stream, desc)
		}
	} else {
		send_unimplemented(mut stream, incoming.method)
	}
}

// send_unimplemented sends UNIMPLEMENTED error using Trailers-Only response.
fn send_unimplemented(mut stream transport.Stream, path string) {
	send_full_status_trailer(mut stream, Status{
		code:    .unimplemented
		message: 'Method not found: ${path}'
	})
}

// process_unary_call handles unary RPC without compression/timeout (backward compat)
fn process_unary_call(mut stream transport.Stream, handler UnaryHandler) {
	process_unary_call_with_opts(mut stream, handler, {}, unsafe { nil })
}

// process_unary_call_with_opts handles unary RPC with compression and timeout support
fn process_unary_call_with_opts(mut stream transport.Stream, handler UnaryHandler, headers map[string]string, registry &CompressorRegistry) {
	// Parse grpc-timeout if present (G2-07)
	// TODO: enforce deadline cancellation when V supports timed channel reads
	_ = extract_grpc_timeout(headers)

	req_framed := stream.recv_msg() or {
		send_error_trailer(mut stream, 'Failed to receive request')
		return
	}
	frame, _ := decode_grpc_frame(req_framed) or {
		send_error_trailer(mut stream, 'Invalid gRPC frame')
		return
	}

	// Decompress request if compressed
	req_data := decompress_request(frame, headers, registry) or {
		send_status_trailer(mut stream, .unimplemented, err.msg())
		return
	}

	resp_bytes := handler(req_data) or {
		send_error_trailer(mut stream, '${err}')
		return
	}

	// Compress response if client accepts it
	resp_payload, resp_compressed := compress_response(resp_bytes, headers, registry)

	mut resp_headers := {
		':status':      '200'
		'content-type': 'application/grpc+proto'
	}
	if resp_compressed {
		resp_headers['grpc-encoding'] = 'gzip'
	}
	stream.send_header(resp_headers) or { return }
	stream.send_msg(encode_grpc_frame(resp_payload, resp_compressed)) or { return }
	stream.send_trailer({'grpc-status': '0', 'grpc-message': ''}) or {}
}

// decompress_request decompresses frame data if compressed flag is set
fn decompress_request(frame GrpcFrame, headers map[string]string, registry &CompressorRegistry) ![]u8 {
	if !frame.compressed {
		return frame.data
	}
	encoding := headers['grpc-encoding'] or { '' }
	if encoding == '' || encoding == 'identity' {
		return frame.data
	}
	if registry == unsafe { nil } {
		return error('unsupported encoding: ${encoding}')
	}
	compressor := registry.get(encoding) or {
		return error('unsupported encoding: ${encoding}')
	}
	return compressor.decompress(frame.data)
}

// compress_response compresses response if client accepts gzip
fn compress_response(data []u8, headers map[string]string, registry &CompressorRegistry) ([]u8, bool) {
	if registry == unsafe { nil } {
		return data, false
	}
	accept := headers['grpc-accept-encoding'] or { return data, false }
	if !accept.contains('gzip') {
		return data, false
	}
	compressor := registry.get('gzip') or { return data, false }
	compressed := compressor.compress(data) or { return data, false }
	return compressed, true
}

// process_server_streaming_call handles server-streaming RPC lifecycle
fn process_server_streaming_call(mut stream transport.Stream, desc StreamMethodDesc) {
	req_framed := stream.recv_msg() or {
		send_error_trailer(mut stream, 'Failed to receive request')
		return
	}
	frame, _ := decode_grpc_frame(req_framed) or {
		send_error_trailer(mut stream, 'Invalid gRPC frame')
		return
	}
	mut ss := new_server_stream(mut stream)
	desc.stream_handler(frame.data, mut ss) or {
		send_error_trailer(mut stream, '${err}')
		return
	}
	stream.send_trailer({'grpc-status': '0', 'grpc-message': ''}) or {}
}

// process_client_streaming_call handles client-streaming RPC lifecycle
fn process_client_streaming_call(mut stream transport.Stream, desc StreamMethodDesc) {
	mut cs := new_client_stream(mut stream)
	resp_bytes := desc.client_stream_handler(mut cs) or {
		send_error_trailer(mut stream, '${err}')
		return
	}
	stream.send_header({
		':status':      '200'
		'content-type': 'application/grpc+proto'
	}) or { return }
	stream.send_msg(encode_grpc_frame(resp_bytes, false)) or { return }
	stream.send_trailer({'grpc-status': '0', 'grpc-message': ''}) or {}
}

// send_error_trailer sends an internal error using Trailers-Only response.
fn send_error_trailer(mut stream transport.Stream, message string) {
	send_status_trailer(mut stream, .internal, message)
}

// send_status_trailer sends a specific status code using Trailers-Only response.
// Delegates to send_full_status_trailer so rich error details are wired when present.
fn send_status_trailer(mut stream transport.Stream, code StatusCode, message string) {
	send_full_status_trailer(mut stream, Status{code: code, message: message})
}

// send_full_status_trailer sends a Trailers-Only response from a Status object.
// Includes grpc-status-details-bin when Status has rich error details (G2-04).
fn send_full_status_trailer(mut stream transport.Stream, status Status) {
	mut trailer := {
		':status':      '200'
		'content-type': 'application/grpc+proto'
		'grpc-status':  '${int(status.code)}'
		'grpc-message': status.message
	}
	if status.details.len > 0 {
		trailer['grpc-status-details-bin'] = status.encode_trailer_value() or { '' }
	}
	stream.send_trailer(trailer) or {}
}

// extract_grpc_timeout reads grpc-timeout from request headers.
// Returns the timeout in nanoseconds, or 0 if not present or invalid.
fn extract_grpc_timeout(headers map[string]string) i64 {
	timeout_str := headers['grpc-timeout'] or { return 0 }
	if timeout_str == '' {
		return 0
	}
	return decode_timeout(timeout_str) or { 0 }
}
