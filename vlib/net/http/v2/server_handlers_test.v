// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// Tests for extract_headers_block and build_server_request.

// make_headers_frame is a helper that constructs a HEADERS Frame with the given
// flags and payload, setting stream_id=1 and length to payload.len.
fn make_headers_frame(flags u8, payload []u8) Frame {
	return Frame{
		header:  FrameHeader{
			length:     u32(payload.len)
			frame_type: .headers
			flags:      flags
			stream_id:  1
		}
		payload: payload
	}
}

// test_extract_headers_block_no_flags verifies that without PADDED or PRIORITY
// flags the entire payload is returned verbatim.
fn test_extract_headers_block_no_flags() {
	data := [u8(0x01), 0x02, 0x03, 0x04]
	frame := make_headers_frame(0, data)
	result := extract_headers_block(frame) or {
		assert false, 'extract_headers_block should not error: ${err}'
		return
	}
	assert result == data, 'expected full payload, got ${result}'
}

// test_extract_headers_block_padded strips the pad_length prefix and trailing pad bytes.
fn test_extract_headers_block_padded() {
	// PADDED flag = 0x08; payload = [pad_length=2, 0xAA, 0xBB, pad, pad]
	padded_flag := u8(FrameFlags.padded)
	payload := [u8(2), 0xAA, 0xBB, 0x00, 0x00]
	frame := make_headers_frame(padded_flag, payload)
	result := extract_headers_block(frame) or {
		assert false, 'extract_headers_block should not error: ${err}'
		return
	}
	assert result == [u8(0xAA), 0xBB], 'expected stripped data [0xAA, 0xBB], got ${result}'
}

// test_extract_headers_block_priority skips the 5-byte PRIORITY prefix.
fn test_extract_headers_block_priority() {
	// PRIORITY flag = 0x20; first 5 bytes are stream-dependency + weight
	priority_flag := u8(FrameFlags.priority_flag)
	// 5 priority bytes + 3 data bytes
	payload := [u8(0), u8(0), u8(0), u8(1), u8(15), 0xDE, 0xAD, 0xBE]
	frame := make_headers_frame(priority_flag, payload)
	result := extract_headers_block(frame) or {
		assert false, 'extract_headers_block should not error: ${err}'
		return
	}
	assert result == [u8(0xDE), 0xAD, 0xBE], 'expected data after priority, got ${result}'
}

// test_extract_headers_block_padded_and_priority handles both flags together.
// Padding is stripped first, then the 5-byte PRIORITY prefix is skipped.
fn test_extract_headers_block_padded_and_priority() {
	padded_flag := u8(FrameFlags.padded)
	priority_flag := u8(FrameFlags.priority_flag)
	flags := padded_flag | priority_flag

	// pad_length=2 | 5 priority bytes | 2 data bytes | 2 pad bytes = 10 bytes total
	payload := [
		u8(2), // pad_length
		u8(0), // priority: stream dep (4 bytes)
		u8(0),
		u8(0),
		u8(1),
		u8(15), // weight
		0xCA, // data byte 1
		0xFE, // data byte 2
		0x00, // pad byte 1
		0x00, // pad byte 2
	]
	frame := make_headers_frame(flags, payload)
	result := extract_headers_block(frame) or {
		assert false, 'extract_headers_block should not error: ${err}'
		return
	}
	assert result == [u8(0xCA), 0xFE], 'expected [0xCA, 0xFE], got ${result}'
}

// test_build_server_request_standard_pseudo_headers verifies that the four
// standard HTTP/2 pseudo-headers are mapped correctly.
fn test_build_server_request_standard_pseudo_headers() {
	stream_id := u32(3)
	headers := [
		HeaderField{':method', 'GET'},
		HeaderField{':path', '/hello'},
		HeaderField{':authority', 'example.com'},
		HeaderField{':scheme', 'https'},
		HeaderField{'accept', 'text/html'},
	]
	req := build_server_request(stream_id, headers, []u8{})

	assert req.method == 'GET', 'expected method GET, got ${req.method}'
	assert req.path == '/hello', 'expected path /hello, got ${req.path}'
	assert req.stream_id == stream_id, 'expected stream_id ${stream_id}, got ${req.stream_id}'
	// :authority must be mapped to the "host" header
	assert req.headers['host'] == 'example.com', 'expected host=example.com, got ${req.headers['host']}'
	// :scheme must NOT appear in headers
	assert ':scheme' !in req.headers, ':scheme should not appear in headers map'
	// regular headers are forwarded
	assert req.headers['accept'] == 'text/html', 'expected accept=text/html, got ${req.headers['accept']}'
}

// test_build_server_request_missing_method verifies that a missing :method pseudo-header
// results in an empty string for method (default zero value).
fn test_build_server_request_missing_method() {
	stream_id := u32(5)
	headers := [
		HeaderField{':path', '/'},
		HeaderField{':scheme', 'https'},
		HeaderField{':authority', 'localhost'},
	]
	req := build_server_request(stream_id, headers, []u8{})

	assert req.method == '', 'expected empty method when :method is absent, got "${req.method}"'
	assert req.path == '/', 'expected path /, got ${req.path}'
}
