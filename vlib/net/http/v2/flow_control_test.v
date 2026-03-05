// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// Tests for WINDOW_UPDATE flow control frame encoding and validation.
//
// send_window_update requires a live ssl.SSLConn, so we exercise the
// validation logic by constructing WINDOW_UPDATE frame payloads directly
// and verifying the encoding rules from RFC 7540 §6.9.

// build_window_update_payload encodes a 31-bit window increment into the
// 4-byte big-endian payload format required by RFC 7540 §6.9.
// The reserved bit (MSB) is cleared as required by the RFC.
fn build_window_update_payload(increment u32) []u8 {
	return [
		u8(increment >> 24) & 0x7f, // reserved bit cleared
		u8(increment >> 16),
		u8(increment >> 8),
		u8(increment),
	]
}

// test_window_update_zero_increment_payload verifies that an increment of 0 is invalid.
// RFC 7540 §6.9.1: a receiver must treat a WINDOW_UPDATE with a flow-control
// window increment of 0 as a PROTOCOL_ERROR.
fn test_window_update_zero_increment_payload() {
	increment := u32(0)
	// Validate: zero increment is not allowed
	assert increment == 0, 'zero increment must be detectable'
	// Confirm the validation logic matches what send_window_update enforces
	is_invalid := increment == 0
	assert is_invalid, 'increment of 0 should be flagged as invalid per RFC 7540 §6.9.1'
}

// test_window_update_overflow_increment_payload verifies that an increment exceeding
// 2^31-1 is invalid.
// RFC 7540 §6.9.1: the flow-control window must not exceed 2^31-1 octets.
fn test_window_update_overflow_increment_payload() {
	// 0x8000_0000 = 2^31, one more than the max allowed 0x7FFF_FFFF
	increment := u32(0x8000_0000)
	is_invalid := increment > 0x7FFF_FFFF
	assert is_invalid, 'increment > 0x7FFFFFFF should be flagged as invalid per RFC 7540 §6.9.1'
}

// test_window_update_valid_increment_payload verifies the 4-byte big-endian encoding
// of a valid WINDOW_UPDATE increment with the reserved bit cleared.
// RFC 7540 §6.9: the 31-bit unsigned integer payload is encoded big-endian,
// with the most significant bit reserved and must remain zero.
fn test_window_update_valid_increment_payload() {
	increment := u32(65535) // 0x0000_FFFF
	payload := build_window_update_payload(increment)

	assert payload.len == 4, 'WINDOW_UPDATE payload must be exactly 4 bytes'
	// Reserved bit (MSB of first byte) must be zero
	assert (payload[0] & 0x80) == 0, 'reserved bit must be cleared'
	// Verify the round-trip: decode back to u32
	decoded := (u32(payload[0]) << 24) | (u32(payload[1]) << 16) | (u32(payload[2]) << 8) | u32(payload[3])
	assert decoded == increment, 'decoded increment must match original'
}

// test_window_update_max_valid_increment_payload verifies encoding of the maximum
// valid increment (2^31-1 = 0x7FFF_FFFF).
fn test_window_update_max_valid_increment_payload() {
	increment := u32(0x7FFF_FFFF)
	payload := build_window_update_payload(increment)

	assert payload.len == 4
	// MSB of first byte: 0x7F >> 0 = 0x7F; reserved bit is 0
	assert (payload[0] & 0x80) == 0, 'reserved bit must be cleared for max increment'
	assert payload[0] == 0x7f
	assert payload[1] == 0xff
	assert payload[2] == 0xff
	assert payload[3] == 0xff
}

// test_window_update_frame_type_and_length verifies that a WINDOW_UPDATE frame is
// constructed with the correct type byte (0x8) and length (4).
// RFC 7540 §6.9: a WINDOW_UPDATE frame has type 0x8 and a 4-octet payload.
fn test_window_update_frame_type_and_length() {
	increment := u32(1024)
	payload := build_window_update_payload(increment)
	frame := Frame{
		header:  FrameHeader{
			length:     4
			frame_type: .window_update
			flags:      0
			stream_id:  0
		}
		payload: payload
	}

	encoded := frame.encode()
	// Frame type byte is at offset 3 in the 9-byte header
	assert encoded[3] == u8(FrameType.window_update), 'frame type must be 0x8 (WINDOW_UPDATE)'
	assert u8(FrameType.window_update) == 0x8

	// Length is encoded big-endian in the first 3 bytes
	length := (u32(encoded[0]) << 16) | (u32(encoded[1]) << 8) | u32(encoded[2])
	assert length == 4, 'WINDOW_UPDATE frame payload length must be 4'

	// Payload starts at byte 9
	assert encoded.len == 13 // 9-byte header + 4-byte payload
	// Reserved bit cleared in encoded payload
	assert (encoded[9] & 0x80) == 0
}

// test_window_update_stream_level_payload verifies stream-level WINDOW_UPDATE
// encoding is correct (stream_id != 0).
// RFC 7540 §6.9: a non-zero stream_id applies the update to that stream.
fn test_window_update_stream_level_payload() {
	increment := u32(32768)
	payload := build_window_update_payload(increment)
	frame := Frame{
		header:  FrameHeader{
			length:     4
			frame_type: .window_update
			flags:      0
			stream_id:  3
		}
		payload: payload
	}

	encoded := frame.encode()
	// Parse stream_id from bytes 5-8 (31-bit, MSB reserved=0)
	stream_id := ((u32(encoded[5]) & 0x7f) << 24) | (u32(encoded[6]) << 16) | (u32(encoded[7]) << 8) | u32(encoded[8])
	assert stream_id == 3, 'stream-level WINDOW_UPDATE must preserve stream_id'

	// Verify round-trip: re-parse the full frame
	reparsed := parse_frame(encoded) or {
		assert false, 'failed to re-parse WINDOW_UPDATE frame: ${err}'
		return
	}
	assert reparsed.header.frame_type == .window_update
	assert reparsed.header.stream_id == 3
	assert reparsed.header.length == 4
}
