// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

import net

// build_server_request builds a ServerRequest from decoded header fields and an optional body.
// Pseudo-headers are extracted and filtered: :method → method, :path → path,
// :authority → host header (RFC 7540 §8.1.2.3), :scheme is discarded.
fn build_server_request(stream_id u32, headers []HeaderField, body []u8) ServerRequest {
	mut method := ''
	mut path := ''
	mut header_map := map[string]string{}

	for h in headers {
		match h.name {
			':method' { method = h.value }
			':path' { path = h.value }
			// Map :authority to the standard Host header (RFC 7540 §8.1.2.3).
			':authority' { header_map['host'] = h.value }
			// :scheme is a required pseudo-header but carries no useful information as
			// a regular header, so it is intentionally omitted from the header map.
			':scheme' {}
			else { header_map[h.name] = h.value }
		}
	}

	return ServerRequest{
		method:    method
		path:      path
		headers:   header_map
		body:      body
		stream_id: stream_id
	}
}

// dispatch_request invokes the configured handler with the completed request and
// sends the response. Called once both headers and (if present) body are available.
fn (mut s Server) dispatch_request(mut conn net.TcpConn, req ServerRequest, mut encoder Encoder, mut send_win ConnWindow) ! {
	$if trace_http2 ? {
		eprintln('[HTTP/2] Dispatching: ${req.method} ${req.path} (stream ${req.stream_id})')
	}

	h := s.handler or {
		error_response := ServerResponse{
			status_code: 500
			headers:     {
				'content-type': 'text/plain'
			}
			body:        'no handler configured'.bytes()
		}
		s.send_response(mut conn, req.stream_id, error_response, mut encoder, mut send_win) or {
			eprintln('[HTTP/2] Failed to send error response: ${err}')
		}
		return
	}

	response := h(req)
	s.send_response(mut conn, req.stream_id, response, mut encoder, mut send_win)!
}

// send_response encodes and sends an HTTP/2 response (HEADERS + optional DATA frames).
// Large header blocks are split into HEADERS + CONTINUATION frames, and large
// bodies are split into multiple DATA frames, each capped at max_frame_size.
fn (mut s Server) send_response(mut conn net.TcpConn, stream_id u32, response ServerResponse, mut encoder Encoder, mut send_win ConnWindow) ! {
	encoded := s.encode_response_headers(response, mut encoder)
	s.send_response_headers(mut conn, stream_id, encoded, response.body.len > 0)!
	s.send_response_body(mut conn, stream_id, response.body, mut send_win)!

	$if trace_http2 ? {
		eprintln('[HTTP/2] Response sent: ${response.status_code} (${response.body.len} bytes)')
	}
}

// encode_response_headers builds the HPACK-encoded header block for an HTTP/2 response.
// Adds :status, any response headers, and auto-injects content-length if body is present.
fn (mut s Server) encode_response_headers(response ServerResponse, mut encoder Encoder) []u8 {
	mut resp_headers := []HeaderField{cap: 2 + response.headers.len}
	resp_headers << HeaderField{
		name:  ':status'
		value: response.status_code.str()
	}

	for key, value in response.headers {
		resp_headers << HeaderField{
			name:  key
			value: value
		}
	}

	if response.body.len > 0 && 'content-length' !in response.headers {
		resp_headers << HeaderField{
			name:  'content-length'
			value: response.body.len.str()
		}
	}

	return encoder.encode(resp_headers)
}

// send_response_headers sends an HPACK-encoded header block as a HEADERS frame,
// followed by CONTINUATION frames if the block exceeds max_frame_size.
// END_STREAM is set on the final header chunk when has_body is false.
fn (mut s Server) send_response_headers(mut conn net.TcpConn, stream_id u32, encoded []u8, has_body bool) ! {
	max_size := int(s.config.max_frame_size)
	first_chunk_end := if max_size < encoded.len { max_size } else { encoded.len }
	first_chunk := encoded[0..first_chunk_end]
	is_last_header_chunk := first_chunk_end == encoded.len

	end_headers_flag := if is_last_header_chunk { u8(FrameFlags.end_headers) } else { u8(0) }
	// END_STREAM is set on the HEADERS frame only when there is no body
	// and this is also the last (or only) header chunk.
	end_stream_flag := if !has_body && is_last_header_chunk {
		u8(FrameFlags.end_stream)
	} else {
		u8(0)
	}

	headers_frame := Frame{
		header:  FrameHeader{
			length:     u32(first_chunk.len)
			frame_type: .headers
			flags:      end_headers_flag | end_stream_flag
			stream_id:  stream_id
		}
		payload: first_chunk
	}
	s.write_frame(mut conn, headers_frame)!

	if !is_last_header_chunk {
		s.write_continuation_frames(mut conn, stream_id, encoded[first_chunk_end..], s.config.max_frame_size)!
	}
}

// write_continuation_frames writes CONTINUATION frames for the remaining encoded header bytes
// that did not fit into the initial HEADERS frame.
fn (mut s Server) write_continuation_frames(mut conn net.TcpConn, stream_id u32, remaining []u8, max_frame_size u32) ! {
	max_size := int(max_frame_size)
	mut offset := 0

	for offset < remaining.len {
		chunk_end := if offset + max_size < remaining.len {
			offset + max_size
		} else {
			remaining.len
		}
		chunk := remaining[offset..chunk_end]
		is_last := chunk_end == remaining.len

		end_headers_flag := if is_last { u8(FrameFlags.end_headers) } else { u8(0) }
		cont_frame := Frame{
			header:  FrameHeader{
				length:     u32(chunk.len)
				frame_type: .continuation
				flags:      end_headers_flag
				stream_id:  stream_id
			}
			payload: chunk
		}
		s.write_frame(mut conn, cont_frame)!
		offset = chunk_end
	}
}

// send_response_body sends a body slice as one or more DATA frames, each capped
// at max_frame_size. END_STREAM is set on the final DATA frame.
// If body is empty, no frames are sent. send_win.v is decremented by each
// chunk sent; an error is returned if the window is exhausted (RFC 7540 §6.9).
fn (mut s Server) send_response_body(mut conn net.TcpConn, stream_id u32, body []u8, mut send_win ConnWindow) ! {
	if body.len == 0 {
		return
	}

	max_size := int(s.config.max_frame_size)
	mut data_offset := 0

	for data_offset < body.len {
		chunk_end := if data_offset + max_size < body.len {
			data_offset + max_size
		} else {
			body.len
		}
		chunk := body[data_offset..chunk_end]
		chunk_size := chunk.len
		is_last := chunk_end == body.len

		// RFC 7540 §6.9: must not send more data than the flow-control window allows.
		if send_win.v < i64(chunk_size) {
			return error('http2: send flow-control window exhausted (window=${send_win.v}, needed=${chunk_size})')
		}
		send_win.v -= i64(chunk_size)

		data_frame := Frame{
			header:  FrameHeader{
				length:     u32(chunk_size)
				frame_type: .data
				flags:      if is_last { u8(FrameFlags.end_stream) } else { u8(0) }
				stream_id:  stream_id
			}
			payload: chunk
		}
		s.write_frame(mut conn, data_frame)!
		data_offset = chunk_end
	}
}

// handle_ping processes a PING frame and sends a PING ACK per RFC 7540 §6.7.
// Frames that already carry the ACK flag are silently ignored (they are
// responses to our own PINGs). Frames with an incorrect payload length are
// rejected with an error.
fn (mut s Server) handle_ping(mut conn net.TcpConn, frame Frame) ! {
	// Per RFC 7540 §6.7: do not echo back a PING that already has ACK set.
	if frame.header.has_flag(.ack) {
		return
	}

	// Per RFC 7540 §6.7: PING payload must be exactly 8 bytes.
	if frame.payload.len != 8 {
		return error('invalid PING frame: payload must be 8 bytes, got ${frame.payload.len}')
	}

	// Send PING ACK
	ack := Frame{
		header:  FrameHeader{
			length:     8
			frame_type: .ping
			flags:      u8(FrameFlags.ack)
			stream_id:  0
		}
		payload: frame.payload.clone()
	}

	s.write_frame(mut conn, ack)!
	$if trace_http2 ? {
		eprintln('[HTTP/2] PING/PONG')
	}
}

// send_rst_stream sends an RST_STREAM frame for the given stream with the specified error code.
fn (mut s Server) send_rst_stream(mut conn net.TcpConn, stream_id u32, error_code ErrorCode) ! {
	code := u32(error_code)
	payload := [u8(code >> 24), u8(code >> 16), u8(code >> 8), u8(code)]
	frame := Frame{
		header:  FrameHeader{
			length:     4
			frame_type: .rst_stream
			flags:      0
			stream_id:  stream_id
		}
		payload: payload
	}
	s.write_frame(mut conn, frame)!
}

// send_goaway sends a GOAWAY frame on the connection with the given error code.
// msg is an optional debug data string (empty string for no debug data).
fn (mut s Server) send_goaway(mut conn net.TcpConn, last_stream_id u32, error_code ErrorCode, msg string) ! {
	code := u32(error_code)
	mut payload := [
		u8((last_stream_id >> 24) & 0x7f),
		u8(last_stream_id >> 16),
		u8(last_stream_id >> 8),
		u8(last_stream_id),
		u8(code >> 24),
		u8(code >> 16),
		u8(code >> 8),
		u8(code),
	]
	if msg.len > 0 {
		payload << msg.bytes()
	}
	frame := Frame{
		header:  FrameHeader{
			length:     u32(payload.len)
			frame_type: .goaway
			flags:      0
			stream_id:  0
		}
		payload: payload
	}
	s.write_frame(mut conn, frame)!
}
