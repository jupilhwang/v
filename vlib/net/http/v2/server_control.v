// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

import net

// handle_data_frame accumulates DATA frame payloads and dispatches requests once
// END_STREAM is received. Enforces per-stream and connection-level data limits.
fn (mut s Server) handle_data_frame(frame Frame, mut conn net.TcpConn, mut st ConnState) !FrameResult {
	stream_id := frame.header.stream_id
	end_stream := frame.header.has_flag(.end_stream)

	// Strip padding from DATA frames if PADDED flag is set (RFC 7540 §6.1)
	mut data_payload := frame.payload.clone()
	if frame.header.has_flag(.padded) {
		data_payload = strip_padding(data_payload) or {
			eprintln('[HTTP/2] DATA padding error: ${err}')
			s.send_rst_stream(mut conn, stream_id, .protocol_error) or {}
			return .cont
		}
	}

	data_len := data_payload.len
	if data_len > 0 {
		// Guard against unbounded data accumulation per stream (M11)
		current_size := st.pending_data[stream_id].len
		if current_size + data_len > max_pending_data_size {
			s.send_rst_stream(mut conn, stream_id, .flow_control_error) or {
				eprintln('[HTTP/2] RST_STREAM send error: ${err}')
			}
			if stream_id in st.pending_data {
				st.total_pending_bytes -= i64(st.pending_data[stream_id].len)
			}
			st.pending_data.delete(stream_id)
			return .cont
		}
		// Guard against unbounded aggregate data across all streams (H6)
		st.total_pending_bytes += i64(data_len)
		if st.total_pending_bytes > s.config.max_total_pending_bytes {
			s.send_goaway(mut conn, st.last_stream_id, .flow_control_error, 'connection data limit exceeded') or {}
			return .close
		}
		st.pending_data[stream_id] << data_payload
	}
	if end_stream {
		s.dispatch_completed_stream(stream_id, mut conn, mut st)!
	}
	return .cont
}

// dispatch_completed_stream dispatches a fully received stream to the application
// handler, sends the response, and cleans up pending state.
fn (mut s Server) dispatch_completed_stream(stream_id u32, mut conn net.TcpConn, mut st ConnState) ! {
	body := st.pending_data[stream_id].clone()
	st.total_pending_bytes -= i64(body.len)
	st.pending_data.delete(stream_id)
	if stream_id in st.pending_requests {
		mut req := st.pending_requests[stream_id]
		st.pending_requests.delete(stream_id)
		// Attach accumulated body to the request
		req = ServerRequest{
			method:    req.method
			path:      req.path
			headers:   req.headers
			body:      body
			stream_id: req.stream_id
		}
		s.dispatch_request(mut conn, req, mut st.encoder, mut st.send_win) or {
			eprintln('[HTTP/2] Handler error: ${err}')
		}
		st.last_stream_id = stream_id
	}
	if st.active_streams > 0 {
		st.active_streams--
	}
}

// handle_window_update processes a WINDOW_UPDATE frame, updating the connection-level
// send flow-control window per RFC 7540 §6.9.
fn (mut s Server) handle_window_update(frame Frame, mut conn net.TcpConn, mut st ConnState) !FrameResult {
	// FRAME_SIZE_ERROR per RFC 7540 §6.9: payload must be exactly 4 bytes.
	if frame.payload.len != 4 {
		if frame.header.stream_id != 0 {
			s.send_rst_stream(mut conn, frame.header.stream_id, .frame_size_error) or {}
		} else {
			s.send_goaway(mut conn, st.last_stream_id, .frame_size_error, '') or {}
			return .close
		}
		return .cont
	}
	increment := read_be_u32(frame.payload) & 0x7fffffff
	stream_id := frame.header.stream_id

	// RFC 7540 §6.9.1: a zero increment is a PROTOCOL_ERROR.
	// Stream-level: RST_STREAM; connection-level: GOAWAY.
	if increment == 0 {
		if stream_id != 0 {
			s.send_rst_stream(mut conn, stream_id, .protocol_error) or {
				eprintln('[HTTP/2] RST_STREAM send error: ${err}')
			}
		} else {
			s.send_goaway(mut conn, st.last_stream_id, .protocol_error, '') or {
				eprintln('[HTTP/2] GOAWAY send error: ${err}')
			}
			return .close
		}
	} else {
		// Update the connection-level send window.
		// Stream-level windows are not yet tracked individually.
		if stream_id == 0 {
			// RFC 7540 §6.9.1: overflow is a FLOW_CONTROL_ERROR.
			if st.send_win.v + i64(increment) > 0x7FFFFFFF {
				s.send_goaway(mut conn, st.last_stream_id, .flow_control_error, '') or {}
				return .close
			}
			st.send_win.v += i64(increment)
		}
		$if trace_http2 ? {
			eprintln('[HTTP/2] WINDOW_UPDATE stream=${stream_id} increment=${increment}')
		}
	}
	return .cont
}

// handle_rst_stream processes an RST_STREAM frame, cleaning up per-stream state.
fn (mut s Server) handle_rst_stream(frame Frame, mut conn net.TcpConn, mut st ConnState) !FrameResult {
	// RST_STREAM must be exactly 4 bytes; otherwise FRAME_SIZE_ERROR.
	if frame.payload.len != 4 {
		s.send_goaway(mut conn, st.last_stream_id, .frame_size_error, '') or {}
		return .close
	}
	$if trace_http2 ? {
		error_code := read_be_u32(frame.payload)
		eprintln('[HTTP/2] RST_STREAM stream=${frame.header.stream_id} error_code=${error_code}')
	}
	// Clean up tracking state for the closed stream
	stream_id := frame.header.stream_id
	st.pending_requests.delete(stream_id)
	if stream_id in st.pending_data {
		st.total_pending_bytes -= i64(st.pending_data[stream_id].len)
	}
	st.pending_data.delete(stream_id)
	if st.active_streams > 0 {
		st.active_streams--
	}
	return .cont
}
