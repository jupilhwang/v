// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// Tests for strip_padding (RFC 7540 §6.1)

// test_strip_padding_no_padding verifies that a payload with pad_length=0
// returns the full data region (payload[1..]) without any trailing removal.
fn test_strip_padding_no_padding() {
	// payload[0] = pad_length = 0; payload[1..] is the data
	payload := [u8(0), 0x01, 0x02, 0x03]
	result := strip_padding(payload) or {
		assert false, 'strip_padding should not error: ${err}'
		return
	}
	assert result == [u8(0x01), 0x02, 0x03], 'expected data bytes, got ${result}'
}

// test_strip_padding_valid removes trailing pad bytes correctly.
// payload = [pad_length=2, data_byte, pad, pad]
fn test_strip_padding_valid() {
	// pad_length=2: data is payload[1..payload.len-2] = [0xAB]
	payload := [u8(2), 0xAB, 0x00, 0x00]
	result := strip_padding(payload) or {
		assert false, 'strip_padding should not error: ${err}'
		return
	}
	assert result == [u8(0xAB)], 'expected [0xAB], got ${result}'
}

// test_strip_padding_exceeds_payload expects PROTOCOL_ERROR when pad_length >= payload.len.
fn test_strip_padding_exceeds_payload() {
	// pad_length=4, but payload.len=4 → pad_length >= payload.len → error
	payload := [u8(4), 0x01, 0x02, 0x03]
	strip_padding(payload) or {
		assert err.msg().contains('PROTOCOL_ERROR'), 'expected PROTOCOL_ERROR, got: ${err}'
		return
	}
	assert false, 'strip_padding should have returned an error'
}

// test_strip_padding_empty_payload expects PROTOCOL_ERROR on zero-length input.
fn test_strip_padding_empty_payload() {
	strip_padding([]u8{}) or {
		assert err.msg().contains('PROTOCOL_ERROR'), 'expected PROTOCOL_ERROR, got: ${err}'
		return
	}
	assert false, 'strip_padding should have returned an error for empty payload'
}

// test_strip_padding_zero_length_pad verifies that pad_length=0 on a single-byte
// payload yields an empty data slice (not an error).
fn test_strip_padding_zero_length_pad() {
	// payload = [0x00] → pad_length=0, data = payload[1..1] = []
	payload := [u8(0)]
	result := strip_padding(payload) or {
		assert false, 'strip_padding should not error for single zero byte: ${err}'
		return
	}
	assert result.len == 0, 'expected empty result, got len ${result.len}'
}

// test_strip_padding_fills_entire_payload verifies that when pad_length exactly
// fills all remaining bytes the returned data slice is empty.
// payload = [pad_length=3, pad, pad, pad] → data = []
fn test_strip_padding_fills_entire_payload() {
	payload := [u8(3), 0xFF, 0xFF, 0xFF]
	result := strip_padding(payload) or {
		assert false, 'strip_padding should not error: ${err}'
		return
	}
	assert result.len == 0, 'expected empty slice when padding fills payload, got len ${result.len}'
}
