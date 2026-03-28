module h2

import net
import net.http.v2
import net.grpc.transport
import sync

// StreamEvent notifies accept_stream that a new gRPC stream has arrived.
// Sent by the demuxer goroutine when a HEADERS frame is received.
pub struct StreamEvent {
pub:
	stream_id u32
	headers   map[string]string
	frame_ch  chan v2.Frame
}

// H2ServerTransport handles one HTTP/2 connection from a gRPC client.
// Uses a central demuxer goroutine to read frames and route to per-stream channels.
pub struct H2ServerTransport {
pub mut:
	conn            RawConn
	encoder         v2.Encoder         = v2.new_encoder()
	decoder         v2.Decoder         = v2.new_decoder()
	closed          bool
	tls             bool
	pending         []&H2ServerStream
	write_mu        sync.Mutex
	stream_channels map[u32]chan v2.Frame
	new_stream_ch   chan StreamEvent
	demuxer_running bool
}

// write_frame encodes and writes a complete HTTP/2 frame to the TCP connection.
// Serializes concurrent writes from multiple stream handlers.
pub fn (mut t H2ServerTransport) write_frame(frame v2.Frame) ! {
	t.write_mu.@lock()
	defer { t.write_mu.unlock() }
	bytes := frame.encode()
	t.conn.write(bytes)!
}

// read_frame reads a 9-byte header + payload from the TCP connection.
pub fn (mut t H2ServerTransport) read_frame() !v2.Frame {
	mut header_buf := []u8{len: v2.frame_header_size}
	read_exact_from(mut t.conn, mut header_buf, v2.frame_header_size)!
	header := v2.parse_frame_header(header_buf) or {
		return error('failed to parse frame header')
	}
	mut payload := []u8{len: int(header.length)}
	if header.length > 0 {
		read_exact_from(mut t.conn, mut payload, int(header.length))!
	}
	return v2.Frame{
		header:  header
		payload: payload
	}
}

// new_h2_server_transport creates a server transport from an accepted TCP connection.
// Backward compatible: always creates a non-TLS (h2c) transport.
pub fn new_h2_server_transport(tcp_conn &net.TcpConn) !&H2ServerTransport {
	return new_h2_server_transport_with_conn(new_tcp_raw_conn(tcp_conn), false)
}

// new_h2_server_transport_with_conn creates a server transport from an existing RawConn.
// tls indicates whether the connection is TLS-secured.
// Performs HTTP/2 server-side handshake:
// 1. Read client connection preface (24 bytes)
// 2. Read client SETTINGS
// 3. Send server SETTINGS + SETTINGS ACK
pub fn new_h2_server_transport_with_conn(conn RawConn, tls bool) !&H2ServerTransport {
	mut t := &H2ServerTransport{
		conn:          conn
		tls:           tls
		new_stream_ch: chan StreamEvent{cap: 16}
	}
	mut preface_buf := []u8{len: 24}
	read_exact_from(mut t.conn, mut preface_buf, 24)!
	if preface_buf.bytestr() != v2.preface {
		return error('invalid HTTP/2 connection preface')
	}
	frame := t.read_frame()!
	if frame.header.frame_type != .settings {
		return error('expected SETTINGS, got ${frame.header.frame_type}')
	}
	settings := v2.SettingsFrame{}.to_frame()
	t.write_frame(settings)!
	ack := v2.new_settings_ack_frame()
	t.write_frame(ack)!
	return t
}

// start_demuxer launches the frame-reading goroutine that routes frames
// to per-stream channels. Called lazily on first accept_stream.
pub fn (mut t H2ServerTransport) start_demuxer() {
	t.demuxer_running = true
	spawn t.demux_loop()
}

// demux_loop reads all frames from the connection and routes them:
// HEADERS → create per-stream channel, notify accept_stream
// DATA → route to per-stream channel
// SETTINGS/PING → handle inline
fn (mut t H2ServerTransport) demux_loop() {
	for {
		frame := t.read_frame() or { break }
		match frame.header.frame_type {
			.headers { t.handle_demux_headers(frame) or { break } }
			.data { t.handle_demux_data(frame) }
			.settings { t.handle_demux_settings(frame) }
			.ping { t.respond_to_ping(frame) or {} }
			.rst_stream { t.handle_demux_rst(frame) }
			.goaway { break }
			.window_update {}
			else {}
		}
	}
	t.close_all_stream_channels()
}

// handle_demux_headers processes a HEADERS frame in the demuxer loop.
fn (mut t H2ServerTransport) handle_demux_headers(frame v2.Frame) ! {
	hf := v2.HeadersFrame.from_frame(frame)!
	decoded := t.decoder.decode(hf.headers)!
	mut hdrs := map[string]string{}
	for h in decoded {
		hdrs[h.name] = h.value
	}
	sid := frame.header.stream_id
	ch := chan v2.Frame{cap: 64}
	t.stream_channels[sid] = ch
	// For HEADERS-only requests (no body), send END_STREAM via a marker
	if hf.end_stream {
		marker := v2.DataFrame{
			stream_id:  sid
			data:       []u8{}
			end_stream: true
		}
		ch <- marker.to_frame()
	}
	t.new_stream_ch <- StreamEvent{
		stream_id: sid
		headers:   hdrs
		frame_ch:  ch
	}
}

// handle_demux_data routes a DATA frame to the per-stream channel.
fn (mut t H2ServerTransport) handle_demux_data(frame v2.Frame) {
	sid := frame.header.stream_id
	if ch := t.stream_channels[sid] {
		ch <- frame
	}
}

// handle_demux_settings responds to non-ACK SETTINGS frames.
fn (mut t H2ServerTransport) handle_demux_settings(frame v2.Frame) {
	if !frame.header.has_flag(.ack) {
		t.write_frame(v2.new_settings_ack_frame()) or {}
	}
}

// handle_demux_rst closes the per-stream channel on RST_STREAM.
fn (mut t H2ServerTransport) handle_demux_rst(frame v2.Frame) {
	sid := frame.header.stream_id
	if ch := t.stream_channels[sid] {
		ch.close()
		t.stream_channels.delete(sid)
	}
}

// close_all_stream_channels closes all per-stream channels on transport shutdown.
fn (mut t H2ServerTransport) close_all_stream_channels() {
	for _, ch in t.stream_channels {
		ch.close()
	}
	t.stream_channels.clear()
	t.new_stream_ch.close()
}

// cleanup_stream removes a completed stream's channel after handler finishes.
// Prevents memory leaks from accumulated stream_channels entries (G2-06).
pub fn (mut t H2ServerTransport) cleanup_stream(stream_id u32) {
	t.stream_channels.delete(stream_id)
}

// accept_stream waits for the next incoming gRPC stream from the demuxer.
// Returns after HEADERS frame arrives (not after all DATA).
pub fn (mut t H2ServerTransport) accept_stream() !transport.IncomingStream {
	if t.closed {
		return error('transport is closed')
	}
	if !t.demuxer_running {
		t.start_demuxer()
	}
	event := <-t.new_stream_ch or { return error('transport closed') }
	validate_grpc_headers(event.headers)!
	method := event.headers[':path'] or { '' }
	stream := &H2ServerStream{
		sid:       event.stream_id
		transport: unsafe { &t }
		headers:   event.headers
		frame_ch:  event.frame_ch
	}
	return transport.IncomingStream{
		stream:  stream
		method:  method
		headers: event.headers
	}
}

// close closes the underlying connection.
pub fn (mut t H2ServerTransport) close() ! {
	if t.closed {
		return
	}
	t.closed = true
	t.conn.close()!
}

// validate_grpc_headers checks that request headers satisfy gRPC requirements.
fn validate_grpc_headers(hdrs map[string]string) ! {
	if ':method' !in hdrs || hdrs[':method'] != 'POST' {
		m := if ':method' in hdrs { hdrs[':method'] } else { '<missing>' }
		return error('invalid gRPC request: method must be POST, got ${m}')
	}
	if 'content-type' !in hdrs || !hdrs['content-type'].starts_with('application/grpc') {
		ct := if 'content-type' in hdrs { hdrs['content-type'] } else { '<missing>' }
		return error('invalid gRPC request: content-type must start with application/grpc, got ${ct}')
	}
}

// decode_request_headers decodes a HEADERS frame into an H2ServerStream.
// Validates that the request is a valid gRPC request (POST method, gRPC content-type).
fn (mut t H2ServerTransport) decode_request_headers(frame v2.Frame) !(&H2ServerStream, string) {
	hf := v2.HeadersFrame.from_frame(frame)!
	decoded := t.decoder.decode(hf.headers)!
	mut hdrs := map[string]string{}
	mut method := ''
	for h in decoded {
		hdrs[h.name] = h.value
		if h.name == ':path' {
			method = h.value
		}
	}
	validate_grpc_headers(hdrs)!
	return &H2ServerStream{
		sid:        frame.header.stream_id
		transport:  unsafe { &t }
		headers:    hdrs
		end_stream: hf.end_stream
	}, method
}

// respond_to_ping sends a PING ACK if the incoming PING is not already an ACK.
fn (mut t H2ServerTransport) respond_to_ping(frame v2.Frame) ! {
	if frame.header.has_flag(.ack) {
		return
	}
	pf := v2.PingFrame.from_frame(frame)!
	ack_pf := v2.PingFrame{
		ack:  true
		data: pf.data
	}
	t.write_frame(ack_pf.to_frame())!
}

// encode_grpc_response_headers HPACK-encodes standard gRPC response headers:
// :status 200, content-type: application/grpc+proto, plus any extras.
pub fn encode_grpc_response_headers(mut encoder v2.Encoder, extra map[string]string) []u8 {
	mut headers := []v2.HeaderField{cap: 2 + extra.len}
	headers << v2.HeaderField{name: ':status', value: '200'}
	headers << v2.HeaderField{name: 'content-type', value: 'application/grpc+proto'}
	for k, val in extra {
		if k.starts_with(':') {
			continue
		}
		headers << v2.HeaderField{name: k, value: val}
	}
	return encoder.encode(headers)
}

// make_incoming_stream creates an IncomingStream from a completed H2ServerStream.
fn make_incoming_stream(s &H2ServerStream) transport.IncomingStream {
	method := if ':path' in s.headers { s.headers[':path'] } else { '' }
	return transport.IncomingStream{
		stream:  s
		method:  method
		headers: s.headers
	}
}
