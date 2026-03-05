// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

import net

// Simple HTTP/2 Server Implementation

// Server is an HTTP/2 server.
//
// NOTE: This implementation uses plain TCP (net.TcpConn), NOT TLS.
// Real HTTP/2 deployments require TLS with ALPN "h2" negotiation for
// browser clients (RFC 7540 §3.3).
//
// TODO: Implement TLS with ALPN h2 negotiation (e.g. via net.ssl.SSLConn)
// to support browser-compatible HTTP/2 over TLS (h2).
// The plain-TCP mode ("h2c") is only supported by clients that explicitly
// opt in (e.g. `curl --http2-prior-knowledge`).
pub struct Server {
pub mut:
	// send_window_size is the initial connection-level send flow-control window size.
	// Each spawned connection copies this at startup and tracks it locally — do not
	// modify this field after calling listen_and_serve.
	send_window_size i64 = 65535
mut:
	config   ServerConfig
	handler  ?Handler
	listener net.TcpListener
	running  bool
}

// new_server creates a new HTTP/2 server with the given configuration and handler.
// The returned server uses plain TCP (h2c). TLS is not yet implemented.
pub fn new_server(config ServerConfig, handler Handler) !&Server {
	listener := net.listen_tcp(.ip, config.addr)!

	return &Server{
		config:   config
		handler:  handler
		listener: listener
	}
}

// listen_and_serve starts the HTTP/2 server and begins accepting connections.
// It blocks until stop() is called. The server uses plain TCP (h2c mode).
// For TLS-based h2, TLS with ALPN negotiation must be implemented first.
pub fn (mut s Server) listen_and_serve() ! {
	s.running = true
	$if debug {
		eprintln('[HTTP/2] Server listening on ${s.config.addr}')
	}

	for s.running {
		mut conn := s.listener.accept() or {
			if s.running {
				eprintln('[HTTP/2] Accept error: ${err}')
			}
			continue
		}

		spawn s.handle_connection(mut conn)
	}
}

// stop stops the HTTP/2 server and closes the listener.
pub fn (mut s Server) stop() {
	s.running = false
	s.listener.close() or {}
}

// read_exact_tcp reads exactly `needed` bytes from a TCP connection into buf[0..needed].
// It loops on partial reads as required for TCP streams (TCP is a stream protocol and
// a single read() call may return fewer bytes than requested).
// Returns the number of bytes read (always == needed on success).
// Returns an error if the connection closes or an I/O error occurs before needed bytes arrive.
fn read_exact_tcp(mut conn net.TcpConn, mut buf []u8, needed int) !int {
	mut total := 0
	for total < needed {
		n := conn.read(mut buf[total..needed]) or { return error('read_exact_tcp: ${err}') }
		if n == 0 {
			return error('read_exact_tcp: connection closed after ${total}/${needed} bytes')
		}
		total += n
	}
	return total
}

// read_preface_and_settings reads the HTTP/2 client connection preface (24-byte magic),
// sends the server's initial SETTINGS frame, then reads and acknowledges the client's
// initial SETTINGS frame per RFC 7540 §3.5.
fn (mut s Server) read_preface_and_settings(mut conn net.TcpConn) ! {
	mut preface_buf := []u8{len: preface.len}
	conn.set_read_timeout(s.config.read_timeout)

	read_exact_tcp(mut conn, mut preface_buf, preface.len) or {
		return error('Failed to read preface: ${err}')
	}

	if preface_buf.bytestr() != preface {
		return error('Invalid preface')
	}

	$if trace_http2 ? {
		eprintln('[HTTP/2] Preface received')
	}

	// Send server's initial SETTINGS frame.
	s.write_settings(mut conn) or { return error('Failed to send settings: ${err}') }

	// Read client's initial SETTINGS frame (RFC 7540 §3.5).
	initial_frame := s.read_frame(mut conn) or {
		return error('Failed to read client SETTINGS: ${err}')
	}
	if initial_frame.header.frame_type == .settings {
		mut dummy_settings := ClientSettings{}
		s.handle_settings(mut conn, initial_frame, mut dummy_settings) or {
			eprintln('[HTTP/2] Client SETTINGS error: ${err}')
		}
	}
}

// handle_headers_dispatch enforces concurrency limits and dispatches a HEADERS frame.
// When the active stream count is at the limit, sends RST_STREAM(REFUSED_STREAM) and
// updates last_stream_id per RFC 7540 §6.8 so GOAWAY accuracy is maintained.
// Otherwise increments active_streams, calls handle_headers, and decrements on END_STREAM.
// Returns .close if a connection-level HPACK decode error forces a GOAWAY.
fn (mut s Server) handle_headers_dispatch(frame Frame, mut conn net.TcpConn, mut st ConnState) !FrameResult {
	stream_id := frame.header.stream_id
	if st.active_streams >= s.config.max_concurrent_streams {
		// RFC 7540 §6.8: last_stream_id must reflect streams received even if refused.
		st.last_stream_id = stream_id
		s.send_rst_stream(mut conn, stream_id, .refused_stream) or {
			eprintln('[HTTP/2] RST_STREAM send error: ${err}')
		}
		return .cont
	}
	st.active_streams++
	s.handle_headers(mut conn, frame, mut st) or {
		// HPACK decode failures are connection-level errors (RFC 7540 §4.3).
		s.send_goaway(mut conn, st.last_stream_id, .compression_error, 'hpack decode error') or {}
		return .close
	}
	// If END_STREAM was set, the stream closes immediately after headers.
	if frame.header.has_flag(.end_stream) {
		if st.active_streams > 0 {
			st.active_streams--
		}
	}
	return .cont
}

// handle_frame dispatches a single HTTP/2 frame by type and updates per-connection
// state (streams, flow-control windows, pending requests/data).
// Returns .close to signal the caller to terminate the connection loop gracefully,
// or .cont to keep processing frames.
fn (mut s Server) handle_frame(frame Frame, mut conn net.TcpConn, mut st ConnState) !FrameResult {
	match frame.header.frame_type {
		.settings {
			s.handle_settings(mut conn, frame, mut st.client_settings) or {
				// SETTINGS errors are connection-level (RFC 7540 §6.5); send GOAWAY.
				s.send_goaway(mut conn, st.last_stream_id, .protocol_error, 'settings error') or {}
				return .close
			}
		}
		.headers {
			return s.handle_headers_dispatch(frame, mut conn, mut st)!
		}
		.data {
			result := s.handle_data_frame(frame, mut conn, mut st)!
			if result == .close {
				return .close
			}
		}
		.ping {
			s.handle_ping(mut conn, frame) or { eprintln('[HTTP/2] Ping error: ${err}') }
		}
		.window_update {
			result := s.handle_window_update(frame, mut conn, mut st)!
			if result == .close {
				return .close
			}
		}
		.rst_stream {
			result := s.handle_rst_stream(frame, mut conn, mut st)!
			if result == .close {
				return .close
			}
		}
		.goaway {
			return s.handle_goaway_frame(frame, mut conn)!
		}
		.continuation {
			// Accumulate CONTINUATION header block fragments
			s.handle_continuation(mut conn, frame, mut st) or {
				eprintln('[HTTP/2] Continuation error: ${err}')
			}
		}
		else {
			// Ignore other frame types (e.g. PRIORITY, PUSH_PROMISE) per RFC 7540 §4.1
		}
	}
	return .cont
}

// handle_connection handles a single client TCP connection.
fn (mut s Server) handle_connection(mut conn net.TcpConn) {
	defer {
		conn.close() or {}
	}

	s.read_preface_and_settings(mut conn) or {
		eprintln('[HTTP/2] Connection preface error: ${err}')
		return
	}

	// Copy the initial send window size locally so each connection tracks its own
	// flow-control state without racing with other goroutines on s.send_window_size.
	mut st := ConnState{
		encoder:  new_encoder()
		decoder:  new_decoder()
		send_win: ConnWindow{
			v: s.send_window_size
		}
	}

	for {
		frame := s.read_frame(mut conn) or {
			err_msg := err.msg()
			if !err_msg.contains('EOF') && !err_msg.contains('closed') && !err_msg.contains('reset') {
				eprintln('[HTTP/2] Read frame error: ${err}')
			}
			break
		}
		result := s.handle_frame(frame, mut conn, mut st) or { break }
		if result == .close {
			break
		}
	}

	$if trace_http2 ? {
		eprintln('[HTTP/2] Connection closed')
	}
}

// handle_goaway_frame processes a GOAWAY frame by logging the last stream ID,
// error code, and optional debug data, then signals connection close.
fn (mut s Server) handle_goaway_frame(frame Frame, mut conn net.TcpConn) !FrameResult {
	if frame.payload.len < 8 {
		return error('GOAWAY frame too short')
	}
	// Decode last_stream_id and error_code per RFC 7540 §6.8
	// A truncated GOAWAY (< 8 bytes) is malformed; close the connection.
	last_stream_id := read_be_u32(frame.payload) & 0x7fffffff
	error_code := read_be_u32(frame.payload[4..8])
	$if trace_http2 ? {
		eprintln('[HTTP/2] GOAWAY last_stream_id=${last_stream_id} error_code=${error_code}')
	}
	// Peer is closing the connection; exit the main loop gracefully.
	return .close
}
