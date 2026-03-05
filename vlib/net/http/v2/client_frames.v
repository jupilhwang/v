// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// strip_padding removes padding from a frame payload per RFC 7540 §6.1.
// The first byte of a padded payload is pad_length; the actual content
// follows and the trailing pad_length bytes are padding and must be discarded.
fn strip_padding(payload []u8) ![]u8 {
	if payload.len == 0 {
		return error('PROTOCOL_ERROR: empty padded frame')
	}
	pad_length := int(payload[0])
	if pad_length >= payload.len {
		return error('PROTOCOL_ERROR: padding exceeds payload')
	}
	return payload[1..payload.len - pad_length]
}

// handle_headers_frame processes a HEADERS frame for a stream.
// When END_HEADERS is not set, the raw header block fragment is stored in
// stream.raw_header_block; subsequent CONTINUATION frames will append to it
// until END_HEADERS is seen, at which point the complete block is decoded.
fn (mut c Client) handle_headers_frame(frame Frame, mut stream Stream, stream_id u32) ! {
	if frame.header.stream_id != stream_id {
		$if trace_http2 ? {
			eprintln('[HTTP/2] ignoring ${frame.header.frame_type} for stream ${frame.header.stream_id} (waiting for ${stream_id})')
		}
		return
	}

	// Strip PADDED prefix (RFC 7540 §6.2): if PADDED flag is set, the first byte
	// is pad_length and the trailing pad_length bytes are padding to be discarded.
	mut block := frame.payload.clone()
	if frame.header.has_flag(.padded) {
		block = strip_padding(block)!
	}

	// Skip PRIORITY fields (RFC 7540 §6.2): if PRIORITY flag is set, the first
	// 5 bytes encode stream dependency (4 bytes) and weight (1 byte) and must be
	// skipped before HPACK decoding.
	if frame.header.has_flag(.priority_flag) {
		if block.len < 5 {
			return error('PROTOCOL_ERROR: HEADERS PRIORITY flag set but payload too short')
		}
		block = block[5..].clone()
	}

	if frame.header.has_flag(.end_headers) {
		// All header data is present in this single frame — decode immediately.
		headers := c.conn.decoder.decode(block)!
		stream.headers << headers
		stream.end_headers = true
	} else {
		// Header block is fragmented across CONTINUATION frames; accumulate raw bytes.
		stream.raw_header_block << block
	}

	if frame.header.has_flag(.end_stream) {
		stream.end_stream = true
		stream.state = .half_closed_remote
	}
}

// handle_continuation_frame processes CONTINUATION frames that extend a HEADERS block.
// Per RFC 7540 §6.10, CONTINUATION frames must follow a HEADERS frame (or another
// CONTINUATION frame) on the same stream until END_HEADERS is set.
fn (mut c Client) handle_continuation_frame(frame Frame, mut stream Stream, stream_id u32) ! {
	if frame.header.stream_id != stream_id {
		$if trace_http2 ? {
			eprintln('[HTTP/2] ignoring ${frame.header.frame_type} for stream ${frame.header.stream_id} (waiting for ${stream_id})')
		}
		return
	}

	if stream.raw_header_block.len + frame.payload.len > max_header_block_size {
		return error('PROTOCOL_ERROR: header block exceeds max size (${max_header_block_size} bytes)')
	}
	stream.raw_header_block << frame.payload

	if frame.header.has_flag(.end_headers) {
		// All fragments collected — decode the complete header block now.
		headers := c.conn.decoder.decode(stream.raw_header_block)!
		stream.headers << headers
		stream.raw_header_block = []u8{}
		stream.end_headers = true
	}
}

// handle_data_frame processes DATA frame for a stream.
// Tracks consumed bytes and sends WINDOW_UPDATE when the receive window is
// half-depleted to prevent flow control deadlock (RFC 7540 §6.9).
fn (mut c Client) handle_data_frame(frame Frame, mut stream Stream, stream_id u32) ! {
	if frame.header.stream_id != stream_id {
		return
	}

	// Strip PADDED prefix (RFC 7540 §6.1): if PADDED flag is set, the first byte
	// is pad_length and the trailing pad_length bytes are padding to be discarded.
	mut data_payload := frame.payload.clone()
	if frame.header.has_flag(.padded) {
		data_payload = strip_padding(data_payload)!
	}

	data_len := i64(data_payload.len)
	stream.data << data_payload
	original_window := stream.window_size
	stream.window_size -= data_len
	c.conn.send_recv_window_updates(data_len, original_window, stream_id)!

	if frame.header.has_flag(.end_stream) {
		stream.end_stream = true
		stream.state = .closed
	}
}

// send_recv_window_updates sends WINDOW_UPDATE frames for connection and stream
// receive windows after processing a DATA frame.
fn (mut c Connection) send_recv_window_updates(data_len i64, original_window i64, stream_id u32) ! {
	// Update connection-level receive window tracking
	c.recv_window_consumed += data_len

	// Send WINDOW_UPDATE at connection level when half the window is consumed
	threshold := c.recv_window / 2
	if c.recv_window_consumed >= threshold && threshold > 0 {
		raw_increment := c.recv_window_consumed
		if raw_increment <= 0 {
			return
		}
		increment := u32(if raw_increment > 0x7FFFFFFF { i64(0x7FFFFFFF) } else { raw_increment })
		c.send_window_update(0, increment) or {
			// Non-fatal: log and continue
			$if trace_http2 ? {
				eprintln('[HTTP/2] failed to send connection WINDOW_UPDATE: ${err}')
			}
		}
		c.recv_window_consumed = 0
	}

	// Send WINDOW_UPDATE at stream level when half the stream window is consumed
	if data_len > 0 {
		stream_threshold := original_window / 2
		if data_len >= stream_threshold && stream_threshold > 0 {
			stream_increment := u32(if data_len > 0x7FFFFFFF { i64(0x7FFFFFFF) } else { data_len })
			c.send_window_update(stream_id, stream_increment) or {
				$if trace_http2 ? {
					eprintln('[HTTP/2] failed to send stream WINDOW_UPDATE: ${err}')
				}
			}
		}
	}
}

// handle_ping_frame responds to PING frame with ACK
fn (mut c Client) handle_ping_frame(frame Frame) ! {
	// Per RFC 7540 §6.7: ACK'd PINGs are responses to our own PINGs — do not echo back.
	if frame.header.has_flag(.ack) {
		return
	}
	// Per RFC 7540 §6.7: PING payload must be exactly 8 bytes.
	if frame.payload.len != 8 {
		return error('invalid PING frame: payload must be 8 bytes, got ${frame.payload.len}')
	}
	pong := Frame{
		header:  FrameHeader{
			length:     u32(frame.payload.len)
			frame_type: .ping
			flags:      u8(FrameFlags.ack)
			stream_id:  0
		}
		payload: frame.payload
	}
	c.conn.write_frame(pong)!
}

// handle_rst_stream_frame handles RST_STREAM frame
fn (mut c Client) handle_rst_stream_frame(frame Frame, stream_id u32) ! {
	if frame.header.stream_id == stream_id {
		// Clean up the stream from the connection map to prevent unbounded growth.
		c.conn.streams.delete(frame.header.stream_id)
		return error('stream reset by server (RST_STREAM)')
	}
}

// process_response_frame dispatches one received frame during response reading.
fn (mut c Client) process_response_frame(frame Frame, mut stream Stream, stream_id u32) ! {
	// Handle frames for this stream or connection-level frames
	match frame.header.frame_type {
		.headers {
			c.handle_headers_frame(frame, mut stream, stream_id)!
		}
		.continuation {
			// CONTINUATION frames extend a HEADERS block when END_HEADERS was not set
			c.handle_continuation_frame(frame, mut stream, stream_id)!
		}
		.data {
			c.handle_data_frame(frame, mut stream, stream_id)!
		}
		.settings {
			// SETTINGS ACK or unsolicited SETTINGS during response
			if !frame.header.has_flag(.ack) {
				// Apply new settings before acknowledging (RFC 7540 §6.5.3)
				c.conn.apply_settings_payload(frame.payload)!
				// Send ACK for unsolicited SETTINGS
				c.conn.write_frame(new_settings_ack())!
			}
		}
		.ping {
			c.handle_ping_frame(frame)!
		}
		.goaway {
			return error('connection closed by server (GOAWAY)')
		}
		.rst_stream {
			c.handle_rst_stream_frame(frame, stream_id)!
		}
		.window_update {
			c.handle_window_update_frame(frame, mut stream, stream_id)!
		}
		.push_promise {
			// RFC 7540 §8.2: A client that has set SETTINGS_ENABLE_PUSH=0
			// MUST treat receipt of a PUSH_PROMISE frame as a connection error.
			return error('received PUSH_PROMISE but push is disabled (RFC 7540 §8.2)')
		}
		else {} // Ignore unknown frame types per RFC 7540
	}
}
