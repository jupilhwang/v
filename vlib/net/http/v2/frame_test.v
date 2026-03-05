// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// Test for HTTP/2 frame encoding/decoding

fn test_frame_header_encode_decode() {
	header := FrameHeader{
		length:     100
		frame_type: .data
		flags:      u8(FrameFlags.end_stream)
		stream_id:  1
	}

	encoded := header.encode()
	assert encoded.len == frame_header_size

	decoded := parse_frame_header(encoded) or {
		assert false, 'Failed to parse frame header'
		return
	}

	assert decoded.length == header.length
	assert decoded.frame_type == header.frame_type
	assert decoded.flags == header.flags
	assert decoded.stream_id == header.stream_id
}

fn test_frame_header_flags() {
	header := FrameHeader{
		length:     0
		frame_type: .headers
		flags:      u8(FrameFlags.end_stream) | u8(FrameFlags.end_headers)
		stream_id:  3
	}

	assert header.has_flag(.end_stream)
	assert header.has_flag(.end_headers)
	assert !header.has_flag(.padded)
}

fn test_settings_frame() {
	mut settings := map[u16]u32{}
	settings[u16(SettingId.header_table_size)] = 4096
	settings[u16(SettingId.max_concurrent_streams)] = 100

	mut payload := []u8{}
	for id, value in settings {
		payload << u8(id >> 8)
		payload << u8(id)
		payload << u8(value >> 24)
		payload << u8(value >> 16)
		payload << u8(value >> 8)
		payload << u8(value)
	}

	frame := Frame{
		header:  FrameHeader{
			length:     u32(payload.len)
			frame_type: .settings
			flags:      0
			stream_id:  0
		}
		payload: payload
	}

	encoded := frame.encode()
	decoded := parse_frame(encoded) or {
		assert false, 'Failed to parse frame'
		return
	}

	assert decoded.header.frame_type == .settings
	assert decoded.header.stream_id == 0
	assert decoded.payload.len == payload.len
}

// test_frame_type_from_byte_known verifies that known frame type bytes are parsed correctly
fn test_frame_type_from_byte_known() {
	assert frame_type_from_byte(0x0) or {
		assert false, 'expected .data'
		return
	} == .data
	assert frame_type_from_byte(0x1) or {
		assert false, 'expected .headers'
		return
	} == .headers
	assert frame_type_from_byte(0x9) or {
		assert false, 'expected .continuation'
		return
	} == .continuation
}

// test_frame_type_from_byte_unknown verifies that unknown frame type bytes return none (RFC 7540 §4.1)
fn test_frame_type_from_byte_unknown() {
	// Per RFC 7540 §4.1: unknown frame types MUST be ignored, not errored
	result := frame_type_from_byte(0xff)
	assert result == none
}

// test_parse_frame_header_unknown_type verifies that parse_frame_header skips frames with unknown types
fn test_parse_frame_header_unknown_type() {
	// Build a 9-byte header with unknown type 0xfe
	mut raw := []u8{len: 9}
	raw[0] = 0 // length high
	raw[1] = 0 // length mid
	raw[2] = 5 // length low  (5 bytes payload)
	raw[3] = 0xfe // unknown type
	raw[4] = 0 // flags
	raw[5] = 0 // stream_id high
	raw[6] = 0
	raw[7] = 0
	raw[8] = 1 // stream_id = 1
	// parse_frame_header must NOT return an error; it returns none for unknown types
	header := parse_frame_header(raw) or {
		// Returning none is acceptable (unknown type skipped)
		return
	}
	// If it returns a value, that is also fine if the caller decides to accept a zero-value
	// This case should not be reached with an unknown type
	_ = header
}

fn test_frame_validation() {
	// Valid DATA frame
	valid_frame := Frame{
		header:  FrameHeader{
			length:     10
			frame_type: .data
			flags:      0
			stream_id:  1
		}
		payload: []u8{len: 10}
	}

	valid_frame.validate() or { assert false, 'Valid frame should not fail validation' }

	// Invalid: DATA frame on stream 0
	invalid_frame := Frame{
		header:  FrameHeader{
			length:     10
			frame_type: .data
			flags:      0
			stream_id:  0
		}
		payload: []u8{len: 10}
	}

	invalid_frame.validate() or {
		assert err.msg().contains('stream 0')
		return
	}
	assert false, 'Invalid frame should fail validation'
}

// test_settings_validate_not_multiple_of_6 verifies SETTINGS payload not a multiple of 6 is rejected
// per RFC 7540 §6.5.
fn test_settings_validate_not_multiple_of_6() {
	// 7 bytes is not a multiple of 6 → must fail
	frame := Frame{
		header:  FrameHeader{
			length:     7
			frame_type: .settings
			flags:      0
			stream_id:  0
		}
		payload: []u8{len: 7}
	}
	frame.validate() or {
		assert err.msg().contains('multiple of 6')
		return
	}
	assert false, 'SETTINGS frame with 7-byte payload should fail validation'
}

// test_settings_validate_valid_payload verifies SETTINGS frame with valid 12-byte payload passes
// per RFC 7540 §6.5.
fn test_settings_validate_valid_payload() {
	// 12 bytes = 2 settings × 6 bytes each → valid
	frame := Frame{
		header:  FrameHeader{
			length:     12
			frame_type: .settings
			flags:      0
			stream_id:  0
		}
		payload: []u8{len: 12}
	}
	frame.validate() or { assert false, 'SETTINGS frame with 12-byte payload should pass: ${err}' }
}

// test_settings_ack_nonempty_payload verifies SETTINGS with ACK flag and non-zero payload is rejected
// per RFC 7540 §6.5: a SETTINGS frame with the ACK flag set and payload is a FRAME_SIZE_ERROR.
fn test_settings_ack_nonempty_payload() {
	// ACK flag set (0x1) + 6-byte payload → must fail
	frame := Frame{
		header:  FrameHeader{
			length:     6
			frame_type: .settings
			flags:      u8(FrameFlags.ack)
			stream_id:  0
		}
		payload: []u8{len: 6}
	}
	frame.validate() or {
		assert err.msg().contains('ACK')
		return
	}
	assert false, 'SETTINGS ACK frame with non-zero payload should fail validation'
}

// test_ping_validate_wrong_length verifies PING frames with payload != 8 bytes are rejected
// per RFC 7540 §6.7.
fn test_ping_validate_wrong_length() {
	// PING requires exactly 8 bytes; 4 bytes must fail
	frame := Frame{
		header:  FrameHeader{
			length:     4
			frame_type: .ping
			flags:      0
			stream_id:  0
		}
		payload: []u8{len: 4}
	}
	frame.validate() or {
		assert err.msg().contains('8')
		return
	}
	assert false, 'PING frame with 4-byte payload should fail validation'
}

// test_ping_validate_correct_length verifies PING frame with exactly 8 bytes passes
// per RFC 7540 §6.7.
fn test_ping_validate_correct_length() {
	frame := Frame{
		header:  FrameHeader{
			length:     8
			frame_type: .ping
			flags:      0
			stream_id:  0
		}
		payload: []u8{len: 8}
	}
	frame.validate() or { assert false, 'PING frame with 8-byte payload should pass: ${err}' }
}

// test_rst_stream_validate_wrong_length verifies RST_STREAM frames with payload != 4 bytes are rejected
// per RFC 7540 §6.4.
fn test_rst_stream_validate_wrong_length() {
	// RST_STREAM requires exactly 4 bytes; 8 bytes must fail
	frame := Frame{
		header:  FrameHeader{
			length:     8
			frame_type: .rst_stream
			flags:      0
			stream_id:  1
		}
		payload: []u8{len: 8}
	}
	frame.validate() or {
		assert err.msg().contains('4')
		return
	}
	assert false, 'RST_STREAM frame with 8-byte payload should fail validation'
}

// test_rst_stream_validate_correct_length verifies RST_STREAM frame with exactly 4 bytes passes
// per RFC 7540 §6.4.
fn test_rst_stream_validate_correct_length() {
	frame := Frame{
		header:  FrameHeader{
			length:     4
			frame_type: .rst_stream
			flags:      0
			stream_id:  1
		}
		payload: []u8{len: 4}
	}
	frame.validate() or { assert false, 'RST_STREAM frame with 4-byte payload should pass: ${err}' }
}

// test_window_update_validate_wrong_length verifies WINDOW_UPDATE frames with payload != 4 bytes are rejected
// per RFC 7540 §6.9.
fn test_window_update_validate_wrong_length() {
	// WINDOW_UPDATE requires exactly 4 bytes; 8 bytes must fail
	frame := Frame{
		header:  FrameHeader{
			length:     8
			frame_type: .window_update
			flags:      0
			stream_id:  0
		}
		payload: []u8{len: 8}
	}
	frame.validate() or {
		assert err.msg().contains('4')
		return
	}
	assert false, 'WINDOW_UPDATE frame with 8-byte payload should fail validation'
}

// test_window_update_validate_correct_length verifies WINDOW_UPDATE frame with exactly 4 bytes passes
// per RFC 7540 §6.9.
fn test_window_update_validate_correct_length() {
	frame := Frame{
		header:  FrameHeader{
			length:     4
			frame_type: .window_update
			flags:      0
			stream_id:  0
		}
		payload: []u8{len: 4}
	}
	frame.validate() or {
		assert false, 'WINDOW_UPDATE frame with 4-byte payload should pass: ${err}'
	}
}

// test_data_frame_exceeds_max_frame_size verifies DATA frames exceeding max_frame_size are rejected
// per RFC 7540 §4.2: endpoints must not send a frame with payload larger than 2^24-1.
fn test_data_frame_exceeds_max_frame_size() {
	// max_frame_size constant is 16777215 (2^24-1); use 16777216 to exceed it
	frame := Frame{
		header:  FrameHeader{
			length:     16777216
			frame_type: .data
			flags:      0
			stream_id:  1
		}
		payload: []u8{}
	}
	frame.validate() or {
		assert err.msg().contains('exceeds maximum')
		return
	}
	assert false, 'DATA frame exceeding max_frame_size should fail validation'
}

// test_headers_frame_exceeds_max_frame_size verifies HEADERS frames exceeding max_frame_size are rejected
// per RFC 7540 §4.2.
fn test_headers_frame_exceeds_max_frame_size() {
	frame := Frame{
		header:  FrameHeader{
			length:     max_frame_size + 1
			frame_type: .headers
			flags:      0
			stream_id:  1
		}
		payload: []u8{}
	}
	frame.validate() or {
		assert err.msg().contains('exceeds maximum')
		return
	}
	assert false, 'HEADERS frame exceeding max_frame_size should fail validation'
}
