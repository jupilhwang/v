// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

import encoding.binary

// FrameType represents HTTP/2 frame types per RFC 7540 Section 6
pub enum FrameType as u8 {
	data          = 0x0
	headers       = 0x1
	priority      = 0x2
	rst_stream    = 0x3
	settings      = 0x4
	push_promise  = 0x5
	ping          = 0x6
	goaway        = 0x7
	window_update = 0x8
	continuation  = 0x9
}

// FrameFlags represents HTTP/2 frame flags per RFC 7540 Section 4.1.
// Note: `ack` and `end_stream` intentionally share the value 0x1 — the HTTP/2
// specification assigns the same bit different semantics depending on frame type:
//   0x1 = END_STREAM for DATA and HEADERS frames (§6.1, §6.2)
//   0x1 = ACK        for SETTINGS and PING frames (§6.5, §6.7)
@[_allow_multiple_values]
pub enum FrameFlags as u8 {
	none          = 0x0
	ack           = 0x1  // SETTINGS, PING
	end_stream    = 0x1  // DATA, HEADERS
	end_headers   = 0x4  // HEADERS, PUSH_PROMISE, CONTINUATION
	padded        = 0x8  // DATA, HEADERS, PUSH_PROMISE
	priority_flag = 0x20 // HEADERS
}

// ErrorCode represents HTTP/2 error codes per RFC 7540 Section 7
pub enum ErrorCode as u32 {
	no_error            = 0x0
	protocol_error      = 0x1
	internal_error      = 0x2
	flow_control_error  = 0x3
	settings_timeout    = 0x4
	stream_closed       = 0x5
	frame_size_error    = 0x6
	refused_stream      = 0x7
	cancel              = 0x8
	compression_error   = 0x9
	connect_error       = 0xa
	enhance_your_calm   = 0xb
	inadequate_security = 0xc
	http_1_1_required   = 0xd
}

// Frame header constants per RFC 7540
pub const frame_header_size = 9
// max_frame_size is the maximum allowed HTTP/2 frame payload size (2^24-1, per RFC 7540 §4.2).
pub const max_frame_size = 16777215 // 2^24 - 1
// default_frame_size is the default HTTP/2 frame payload size (2^14, per RFC 7540 §6.5.2).
pub const default_frame_size = 16384 // 16KB default
// max_settings_payload_size is the maximum allowed SETTINGS frame payload (10 settings × 6 bytes per RFC 7540 §6.5).
pub const max_settings_payload_size = u32(10 * 6)

// HTTP/2 connection preface string
pub const preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'

// FrameHeader represents the 9-byte HTTP/2 frame header
pub struct FrameHeader {
pub mut:
	length     u32       // 24-bit payload length
	frame_type FrameType // 8-bit frame type
	flags      u8        // 8-bit flags
	stream_id  u32       // 31-bit stream ID (1 bit reserved)
}

// Frame represents a complete HTTP/2 frame with header and payload
pub struct Frame {
pub mut:
	header  FrameHeader
	payload []u8
}

// parse_frame_header parses the 9-byte HTTP/2 frame header from raw bytes.
// Returns none if the data is too short or the frame type is unknown.
// Per RFC 7540 §4.1: implementations MUST ignore and discard any frame
// that has a type that is unknown to the implementation.
pub fn parse_frame_header(data []u8) ?FrameHeader {
	if data.len < frame_header_size {
		return none
	}

	// Parse 24-bit length in network byte order (big-endian)
	length := (u32(data[0]) << 16) | (u32(data[1]) << 8) | u32(data[2])

	// Parse 8-bit frame type — none means unknown, must be discarded per RFC 7540 §4.1
	frame_type := frame_type_from_byte(data[3]) or { return none }
	flags := data[4]

	// Parse 31-bit stream ID (mask out reserved bit)
	stream_id := binary.big_endian_u32(data[5..9]) & 0x7fffffff

	return FrameHeader{
		length:     length
		frame_type: frame_type
		flags:      flags
		stream_id:  stream_id
	}
}

// encode encodes the frame header to 9 bytes
pub fn (h FrameHeader) encode() []u8 {
	mut buf := []u8{len: frame_header_size}

	// Encode 24-bit length (big-endian)
	buf[0] = u8(h.length >> 16)
	buf[1] = u8(h.length >> 8)
	buf[2] = u8(h.length)

	// Encode type and flags
	buf[3] = u8(h.frame_type)
	buf[4] = h.flags

	// Encode 31-bit stream ID
	binary.big_endian_put_u32(mut buf[5..9], h.stream_id & 0x7fffffff)

	return buf
}

// has_flag checks if a specific flag is set in the frame header
@[inline]
pub fn (h FrameHeader) has_flag(flag FrameFlags) bool {
	return (h.flags & u8(flag)) != 0
}

// parse_frame parses a complete HTTP/2 frame from raw bytes.
// Returns none if the data is too short or the frame type is unknown.
// Per RFC 7540 §4.1: frames with unknown types must be silently discarded.
pub fn parse_frame(data []u8) ?Frame {
	header := parse_frame_header(data) or { return none }

	expected_len := frame_header_size + int(header.length)
	if data.len < expected_len {
		return none
	}

	payload := data[frame_header_size..expected_len]

	return Frame{
		header:  header
		payload: payload
	}
}

// encode encodes a frame to bytes (header + payload)
pub fn (f Frame) encode() []u8 {
	mut buf := f.header.encode()
	buf << f.payload
	return buf
}

// validate validates frame constraints per RFC 7540
pub fn (f Frame) validate() ! {
	// Check frame size limit
	if f.header.length > max_frame_size {
		return error('frame size ${f.header.length} exceeds maximum ${max_frame_size}')
	}

	// Validate payload sizes for fixed-layout frame types
	// RFC 7540 §6.5: SETTINGS payload must be a multiple of 6 bytes
	if f.header.frame_type == .settings && f.header.length % 6 != 0 {
		return error('SETTINGS frame payload length ${f.header.length} must be a multiple of 6')
	}
	// RFC 7540 §6.5: SETTINGS ACK frame must have an empty payload
	if f.header.frame_type == .settings && f.header.has_flag(.ack) && f.header.length != 0 {
		return error('SETTINGS frame with ACK flag must have empty payload (RFC 7540 §6.5)')
	}
	// RFC 7540 §6.7: PING payload must be exactly 8 bytes
	if f.header.frame_type == .ping && f.header.length != 8 {
		return error('PING frame payload length ${f.header.length} must be exactly 8')
	}
	// RFC 7540 §6.4: RST_STREAM payload must be exactly 4 bytes
	if f.header.frame_type == .rst_stream && f.header.length != 4 {
		return error('RST_STREAM frame payload length ${f.header.length} must be exactly 4')
	}
	// RFC 7540 §6.9: WINDOW_UPDATE payload must be exactly 4 bytes
	if f.header.frame_type == .window_update && f.header.length != 4 {
		return error('WINDOW_UPDATE frame payload length ${f.header.length} must be exactly 4')
	}

	// Validate stream ID usage per frame type
	if f.header.stream_id == 0 {
		match f.header.frame_type {
			.data, .headers, .priority, .rst_stream, .push_promise, .continuation {
				return error('${f.header.frame_type} frame cannot use stream 0')
			}
			else {}
		}
	} else {
		match f.header.frame_type {
			.settings, .ping, .goaway {
				return error('${f.header.frame_type} frame must use stream 0')
			}
			else {}
		}
	}
}

// encode_frame_to_buffer encodes a frame into a pre-allocated buffer.
// Returns the encoded frame data as a slice of the buffer.
// Note: provides buffer-reuse optimization over Frame.encode().
pub fn encode_frame_to_buffer(frame Frame, mut buf []u8) []u8 {
	required_size := frame_header_size + frame.payload.len
	if buf.len < required_size {
		// Buffer too small, allocate new one
		buf = []u8{len: required_size}
	}

	// Encode 9-byte header
	buf[0] = u8(frame.header.length >> 16)
	buf[1] = u8(frame.header.length >> 8)
	buf[2] = u8(frame.header.length)
	buf[3] = u8(frame.header.frame_type)
	buf[4] = frame.header.flags
	buf[5] = u8((frame.header.stream_id >> 24) & 0x7f)
	buf[6] = u8(frame.header.stream_id >> 16)
	buf[7] = u8(frame.header.stream_id >> 8)
	buf[8] = u8(frame.header.stream_id)

	// Copy payload using bulk copy
	if frame.payload.len > 0 {
		copy(mut buf[frame_header_size..], frame.payload)
	}

	return buf[..required_size]
}

// new_settings_ack creates a SETTINGS frame with the ACK flag set.
// Used to acknowledge a peer's SETTINGS frame per RFC 7540 §6.5.
pub fn new_settings_ack() Frame {
	return Frame{
		header:  FrameHeader{
			length:     0
			frame_type: .settings
			flags:      u8(FrameFlags.ack)
			stream_id:  0
		}
		payload: []u8{}
	}
}

// read_be_u32 reads a big-endian u32 from 4 bytes.
pub fn read_be_u32(data []u8) u32 {
	assert data.len >= 4, 'read_be_u32: need 4 bytes, got ${data.len}'
	return (u32(data[0]) << 24) | (u32(data[1]) << 16) | (u32(data[2]) << 8) | u32(data[3])
}

// frame_type_from_byte converts a byte to a FrameType enum value.
// Returns none for unrecognized frame type bytes.
// Per RFC 7540 §4.1: implementations MUST ignore and discard any frame
// that has a type that is unknown to the implementation.
pub fn frame_type_from_byte(b u8) ?FrameType {
	return match b {
		0x0 { FrameType.data }
		0x1 { FrameType.headers }
		0x2 { FrameType.priority }
		0x3 { FrameType.rst_stream }
		0x4 { FrameType.settings }
		0x5 { FrameType.push_promise }
		0x6 { FrameType.ping }
		0x7 { FrameType.goaway }
		0x8 { FrameType.window_update }
		0x9 { FrameType.continuation }
		else { none }
	}
}
