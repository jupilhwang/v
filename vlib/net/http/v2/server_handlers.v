// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

import net

// max_header_block_size is the maximum number of bytes that may be accumulated
// across a HEADERS + CONTINUATION sequence before a PROTOCOL_ERROR is returned.
// Based on the typical default for SETTINGS_MAX_HEADER_LIST_SIZE (RFC 7540 §6.5.2).
const max_header_block_size = 64 * 1024 // 64 KB

// HeaderBlockState accumulates a fragmented header block received across
// HEADERS + CONTINUATION frames until END_HEADERS is set.
struct HeaderBlockState {
mut:
	buf        []u8
	stream_id  u32
	end_stream bool
}

// handle_headers processes a HEADERS frame.
// If END_HEADERS is set, the header block is decoded immediately and a ServerRequest
// is stored in pending_requests (keyed by stream ID) awaiting optional DATA frames.
// If END_HEADERS is NOT set, the raw header block fragment is saved in hbs
// for accumulation by subsequent CONTINUATION frames; no request is stored yet.
// When END_STREAM is also set on a complete (END_HEADERS) frame, dispatch_request
// is called immediately to invoke the handler without waiting for DATA.
fn (mut s Server) handle_headers(mut conn net.TcpConn, frame Frame, mut st ConnState) ! {
	stream_id := frame.header.stream_id

	if stream_id == 0 {
		return error('HEADERS on stream 0')
	}

	block := extract_headers_block(frame)!

	if !frame.header.has_flag(.end_headers) {
		// Header block is fragmented across CONTINUATION frames; accumulate raw bytes.
		st.hbs.buf = block
		st.hbs.stream_id = stream_id
		st.hbs.end_stream = frame.header.has_flag(.end_stream)
		return
	}

	// END_HEADERS is set — decode the complete header block now.
	headers := st.decoder.decode(block)!
	req := build_server_request(stream_id, headers, []u8{})

	$if trace_http2 ? {
		eprintln('[HTTP/2] Request: ${req.method} ${req.path}')
	}

	if frame.header.has_flag(.end_stream) {
		// No DATA frames will follow; dispatch immediately.
		s.dispatch_request(mut conn, req, mut st.encoder, mut st.send_win)!
		st.last_stream_id = stream_id
	} else {
		// DATA frames are expected; park the request until END_STREAM arrives.
		st.pending_requests[stream_id] = req
	}
}

// extract_headers_block strips optional padding and PRIORITY fields from a HEADERS
// frame payload per RFC 7540 §6.2, returning the raw HPACK header block bytes.
fn extract_headers_block(frame Frame) ![]u8 {
	mut block := frame.payload.clone()

	// Strip padding if PADDED flag is set (RFC 7540 §6.2)
	if frame.header.has_flag(.padded) {
		block = strip_padding(block)!
	}

	// Skip PRIORITY fields if PRIORITY flag is set (RFC 7540 §6.2):
	// 4 bytes stream dependency + 1 byte weight must be skipped before HPACK.
	if frame.header.has_flag(.priority_flag) {
		if block.len < 5 {
			return error('PROTOCOL_ERROR: HEADERS PRIORITY flag set but payload too short')
		}
		block = block[5..].clone()
	}

	return block
}

// handle_continuation processes a CONTINUATION frame that extends a HEADERS block.
// Per RFC 7540 §6.10, CONTINUATION frames must follow a HEADERS or another
// CONTINUATION frame on the same stream until END_HEADERS is set.
// Once END_HEADERS is seen, the complete block is decoded and the resulting
// ServerRequest is stored in pending_requests.
fn (mut s Server) handle_continuation(mut conn net.TcpConn, frame Frame, mut st ConnState) ! {
	stream_id := frame.header.stream_id

	if stream_id == 0 {
		return error('CONTINUATION on stream 0')
	}

	if st.hbs.stream_id == 0 {
		return error('unexpected CONTINUATION: no pending HEADERS')
	}

	if stream_id != st.hbs.stream_id {
		return error('CONTINUATION stream id ${stream_id} does not match pending HEADERS stream id ${st.hbs.stream_id}')
	}

	// Guard against unbounded header block accumulation (RFC 7540 §6.5.2 / M12)
	if st.hbs.buf.len + frame.payload.len > max_header_block_size {
		return error('PROTOCOL_ERROR: header block exceeds max_header_block_size (${max_header_block_size} bytes)')
	}

	st.hbs.buf << frame.payload

	if !frame.header.has_flag(.end_headers) {
		// More CONTINUATION frames expected; keep accumulating.
		return
	}

	// All fragments collected — decode and dispatch.
	s.decode_and_dispatch_headers(mut conn, stream_id, mut st)!
}

// decode_and_dispatch_headers decodes the accumulated HPACK header block from hbs,
// constructs a ServerRequest, resets hbs, and either dispatches immediately (if
// END_STREAM was already set on the originating HEADERS frame) or parks the request
// in pending_requests to await DATA frames.
fn (mut s Server) decode_and_dispatch_headers(mut conn net.TcpConn, stream_id u32, mut st ConnState) ! {
	headers := st.decoder.decode(st.hbs.buf)!
	req := build_server_request(stream_id, headers, []u8{})

	// Reset hbs before any potential error from dispatch.
	end_stream := st.hbs.end_stream
	st.hbs.buf = []u8{}
	st.hbs.stream_id = 0
	st.hbs.end_stream = false

	$if trace_http2 ? {
		eprintln('[HTTP/2] Request (from CONTINUATION): ${req.method} ${req.path}')
	}

	if end_stream {
		// END_STREAM was set on the originating HEADERS frame; dispatch immediately.
		s.dispatch_request(mut conn, req, mut st.encoder, mut st.send_win)!
		st.last_stream_id = stream_id
	} else {
		// After CONTINUATION the stream is not END_STREAM yet; wait for DATA.
		// (A HEADERS+CONTINUATION sequence does not carry END_STREAM on CONTINUATION.)
		st.pending_requests[stream_id] = req
	}
}

// drain_unknown_frame discards the payload of an unknown frame type to keep
// the TCP stream synchronized per RFC 7540 §4.1.
fn drain_unknown_frame(mut conn net.TcpConn, payload_len u32) ! {
	if payload_len > 0 {
		mut discard := []u8{len: int(payload_len)}
		read_exact_tcp(mut conn, mut discard, int(payload_len))!
	}
}

// read_frame reads a complete HTTP/2 frame from the connection.
// Uses read_exact to ensure all bytes of both the 9-byte header and
// the variable-length payload are fully received before returning.
// Returns an error if the payload length exceeds the negotiated max_frame_size
// (SETTINGS frames are exempt up to max_settings_payload_size for 10 settings per RFC 7540 §6.5).
// Unknown frame types are drained and skipped per RFC 7540 §4.1.
fn (mut s Server) read_frame(mut conn net.TcpConn) !Frame {
	conn.set_read_timeout(s.config.read_timeout)
	for {
		// Read header (9 bytes) — use read_exact to handle partial TCP reads
		mut header_buf := []u8{len: frame_header_size}
		read_exact_tcp(mut conn, mut header_buf, frame_header_size) or {
			return error('read header: ${err}')
		}

		// Extract payload length from raw bytes BEFORE parse_frame_header so we can
		// drain the payload even when the frame type is unknown (RFC 7540 §4.1).
		payload_len := (u32(header_buf[0]) << 16) | (u32(header_buf[1]) << 8) | u32(header_buf[2])

		if header := parse_frame_header(header_buf) {
			// Validate payload size before allocating (Issue 4).
			// SETTINGS frames are permitted up to max_settings_payload_size (10 settings × 6 bytes)
			// regardless of max_frame_size, because the client's initial SETTINGS may arrive
			// before our own SETTINGS advertisement has been processed.
			max_allowed := if header.frame_type == .settings {
				max_settings_payload_size
			} else {
				s.config.max_frame_size
			}
			if header.length > max_allowed {
				return error('frame too large: ${header.length} > ${max_allowed}')
			}

			// Read payload — use read_exact to handle partial TCP reads
			mut payload := []u8{len: int(header.length)}
			if header.length > 0 {
				read_exact_tcp(mut conn, mut payload, int(header.length)) or {
					return error('read payload: ${err}')
				}
			}

			return Frame{
				header:  header
				payload: payload
			}
		} else {
			drain_unknown_frame(mut conn, payload_len)!
			$if trace_http2 ? {
				eprintln('[HTTP/2] discarded unknown frame type, len=${payload_len}')
			}
			continue
		}
	}
	return error('read_frame: unreachable')
}

// write_frame encodes a frame and writes it to the connection.
fn (mut s Server) write_frame(mut conn net.TcpConn, frame Frame) ! {
	data := frame.encode()
	conn.set_write_timeout(s.config.write_timeout)
	conn.write(data)!
}
