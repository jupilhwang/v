// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

import time

// request sends an HTTP/2 request and returns the response from the server
pub fn (mut c Client) request(req Request) !Response {
	// Guard against stream ID space exhaustion (RFC 7540 §5.1.1).
	// Client uses odd-numbered stream IDs; max is 0x7FFFFFFF.
	if c.conn.next_stream_id > 0x7fffffff {
		return error('stream ID space exhausted; open a new connection')
	}

	// Allocate new stream ID (client uses odd stream IDs)
	stream_id := c.conn.next_stream_id
	c.conn.next_stream_id += 2

	// Track the highest stream ID for GOAWAY
	c.conn.last_stream_id = stream_id

	// Create and register stream
	mut stream := &Stream{
		id:    stream_id
		state: .idle
	}
	c.conn.streams[stream_id] = stream

	// Build and send HEADERS frame(s)
	has_body := req.data.len > 0
	c.send_headers(req, stream_id, has_body)!

	stream.state = if !has_body { .half_closed_local } else { .open }

	// Send DATA frame(s) if there is a body
	if has_body {
		c.send_body(req.data, stream_id)!
		stream.state = .half_closed_local
	}

	return c.read_response(stream_id)!
}

// send_headers encodes and transmits HEADERS (and optional CONTINUATION) frames.
// When encoded headers exceed max_frame_size they are fragmented per RFC 7540 §6.10.
fn (mut c Client) send_headers(req Request, stream_id u32, has_body bool) ! {
	mut headers := [
		HeaderField{':method', req.method.str()},
		HeaderField{':scheme', 'https'},
		HeaderField{':path', req.url},
		HeaderField{':authority', req.host},
	]
	for key, value in req.headers {
		headers << HeaderField{key.to_lower(), value}
	}

	encoded_headers := c.conn.encoder.encode(headers)

	$if trace_http2 ? {
		eprintln('[HTTP/2] HPACK encoded ${headers.len} headers -> ${encoded_headers.len} bytes: ${encoded_headers.hex()}')
		for h in headers {
			eprintln('[HTTP/2]   ${h.name}: ${h.value}')
		}
	}

	max_frame := int(c.conn.remote_settings.max_frame_size)

	if encoded_headers.len <= max_frame {
		c.send_headers_single_frame(encoded_headers, stream_id, has_body)!
	} else {
		c.send_headers_fragmented(encoded_headers, stream_id, has_body, max_frame)!
	}
}

// send_headers_single_frame sends headers that fit in a single HEADERS frame.
fn (mut c Client) send_headers_single_frame(encoded_headers []u8, stream_id u32, has_body bool) ! {
	mut flags := u8(FrameFlags.end_headers)
	if !has_body {
		flags |= u8(FrameFlags.end_stream)
	}
	c.conn.write_frame(Frame{
		header:  FrameHeader{
			length:     u32(encoded_headers.len)
			frame_type: .headers
			flags:      flags
			stream_id:  stream_id
		}
		payload: encoded_headers
	})!
}

// send_headers_fragmented sends a HEADERS frame followed by CONTINUATION frames
// when encoded headers exceed max_frame_size (RFC 7540 §6.2, §6.10).
// END_STREAM on HEADERS is allowed even when END_HEADERS is absent (RFC 7540 §6.2).
fn (mut c Client) send_headers_fragmented(encoded_headers []u8, stream_id u32, has_body bool, max_frame int) ! {
	first_chunk := encoded_headers[..max_frame]
	mut headers_flags := u8(0) // no END_HEADERS, no END_STREAM yet
	if !has_body {
		headers_flags |= u8(FrameFlags.end_stream)
	}
	c.conn.write_frame(Frame{
		header:  FrameHeader{
			length:     u32(first_chunk.len)
			frame_type: .headers
			flags:      headers_flags
			stream_id:  stream_id
		}
		payload: first_chunk
	})!

	mut offset := max_frame
	for offset < encoded_headers.len {
		end := if offset + max_frame < encoded_headers.len {
			offset + max_frame
		} else {
			encoded_headers.len
		}
		chunk := encoded_headers[offset..end]
		is_last := end == encoded_headers.len
		cont_flags := if is_last { u8(FrameFlags.end_headers) } else { u8(0) }
		c.conn.write_frame(Frame{
			header:  FrameHeader{
				length:     u32(chunk.len)
				frame_type: .continuation
				flags:      cont_flags
				stream_id:  stream_id
			}
			payload: chunk
		})!
		offset = end
	}
}

// send_body sends request body as DATA frame(s), respecting max_frame_size and
// the connection-level flow control window (RFC 7540 §6.9).
fn (mut c Client) send_body(data string, stream_id u32) ! {
	data_bytes := data.bytes()
	max_frame := int(c.conn.remote_settings.max_frame_size)
	mut offset := 0
	for offset < data_bytes.len {
		// Respect connection-level flow control window
		available_window := int(c.conn.remote_window_size)
		if available_window <= 0 {
			return error('flow control window exhausted; peer has not sent WINDOW_UPDATE')
		}
		// Chunk size is the minimum of: remaining data, max frame size, available window
		remaining := data_bytes.len - offset
		mut chunk_size := remaining
		if chunk_size > max_frame {
			chunk_size = max_frame
		}
		if chunk_size > available_window {
			chunk_size = available_window
		}
		end := offset + chunk_size
		chunk := data_bytes[offset..end]
		is_last := end == data_bytes.len
		data_flags := if is_last { u8(FrameFlags.end_stream) } else { u8(0) }
		c.conn.write_frame(Frame{
			header:  FrameHeader{
				length:     u32(chunk.len)
				frame_type: .data
				flags:      data_flags
				stream_id:  stream_id
			}
			payload: chunk
		})!
		// Decrement connection-level window after successful send
		c.conn.remote_window_size -= i64(chunk.len)
		offset = end
	}
}

// response_timeout_duration returns the effective response timeout duration.
// Defaults to 30 seconds when not configured.
fn (c Client) response_timeout_duration() time.Duration {
	if c.config.response_timeout == 0 {
		return 30 * time.second
	}
	return c.config.response_timeout
}

// read_response reads and assembles the response for a specific stream.
// Returns an error if the response is not received within the configured timeout.
fn (mut c Client) read_response(stream_id u32) !Response {
	mut stream := c.conn.streams[stream_id] or { return error('stream ${stream_id} not found') }

	deadline := time.now().add(c.response_timeout_duration())

	for !stream.end_stream || !stream.end_headers {
		// Check timeout on each iteration
		if time.now() > deadline {
			return error('read_response timeout after ${c.response_timeout_duration()}')
		}

		frame := c.conn.read_frame()!
		c.process_response_frame(frame, mut stream, stream_id)!
	}

	resp := c.build_response(stream)!
	// Remove completed stream from map to prevent unbounded growth (Issue #10)
	c.conn.streams.delete(stream_id)
	return resp
}

// handle_window_update_frame processes a WINDOW_UPDATE frame during response reading.
// Adjusts the flow-control window for the connection (stream_id=0) or a specific stream
// (RFC 7540 §6.9).
fn (mut c Client) handle_window_update_frame(frame Frame, mut stream Stream, stream_id u32) ! {
	if frame.payload.len != 4 {
		return error('WINDOW_UPDATE frame must have exactly 4-byte payload, got ${frame.payload.len}')
	}
	increment := i64(read_be_u32(frame.payload)) & 0x7fffffff
	if increment == 0 {
		return error('PROTOCOL_ERROR: zero WINDOW_UPDATE increment')
	}
	if frame.header.stream_id == 0 {
		if c.conn.remote_window_size + increment > 0x7FFFFFFF {
			return error('FLOW_CONTROL_ERROR: flow control window overflow')
		}
		c.conn.remote_window_size += increment
	} else if frame.header.stream_id == stream_id {
		if stream.window_size + increment > 0x7FFFFFFF {
			return error('FLOW_CONTROL_ERROR: flow control window overflow')
		}
		stream.window_size += increment
	} else if mut s := c.conn.streams[frame.header.stream_id] {
		if s.window_size + increment > 0x7FFFFFFF {
			return error('FLOW_CONTROL_ERROR: flow control window overflow')
		}
		s.window_size += increment
	}
}

// build_response constructs Response from stream data.
// Returns an error if the mandatory :status pseudo-header is absent (RFC 7540 §8.1.2.4).
fn (c Client) build_response(stream &Stream) !Response {
	mut status_code := 0
	mut found_status := false
	mut response_headers := map[string]string{}

	for header in stream.headers {
		if header.name == ':status' {
			status_code = header.value.int()
			found_status = true
		} else if !header.name.starts_with(':') {
			response_headers[header.name] = header.value
		}
	}

	if !found_status {
		return error('missing mandatory :status pseudo-header (RFC 7540 §8.1.2.4)')
	}

	return Response{
		body:        stream.data.bytestr()
		status_code: status_code
		headers:     response_headers
	}
}
