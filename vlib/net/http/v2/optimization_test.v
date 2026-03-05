// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// Tests for encode_optimized correctness (Issue #14 and dynamic table update)

// test_encode_optimized_small_index_single_byte verifies that static table indices < 127
// still use the fast single-byte path and produce correct HPACK output.
fn test_encode_optimized_small_index_single_byte() {
	mut encoder := new_encoder()
	mut buf := []u8{len: 4096}

	// :method GET is static index 2 — must fit in one byte: 0x80 | 2 = 0x82
	headers := [HeaderField{':method', 'GET'}]
	n := encoder.encode_optimized(headers, mut buf)
	assert n == 1, ':method GET (index 2) should encode to exactly 1 byte, got ${n}'
	assert buf[0] == u8(0x82), 'expected 0x82, got 0x${buf[0].hex()}'
}

// test_encode_optimized_updates_dynamic_table verifies that new headers added
// via encode_optimized are stored in the dynamic table so subsequent calls
// can reference them by index instead of re-encoding the literal.
fn test_encode_optimized_updates_dynamic_table() {
	mut encoder := new_encoder()
	mut buf := []u8{len: 4096}

	// First call: encodes x-custom as a literal (new name).
	headers := [HeaderField{'x-custom', 'my-value'}]
	n1 := encoder.encode_optimized(headers, mut buf)
	assert n1 > 1, 'first encoding of new header should be a literal (>1 byte)'

	// Second call: if dynamic table was updated, x-custom should now be
	// referenced by index, producing a shorter (indexed) encoding.
	n2 := encoder.encode_optimized(headers, mut buf)
	assert n2 < n1, 'second encoding should be shorter (indexed), got n1=${n1} n2=${n2}'
}

// test_encode_optimized_high_index_multi_byte verifies that when encode_optimized
// references a dynamic table entry at index >= 128, it uses multi-byte HPACK
// integer encoding (7-bit prefix) rather than truncating to a single byte.
// This test requires dynamic table updates to be working first.
fn test_encode_optimized_high_index_multi_byte() {
	// static_table.len == 62 (index 0 is dummy; real entries are 1..61).
	// A dynamic entry N positions in has index = 62 + N - 1.
	// To get index >= 128 we need N >= 67, i.e. at least 67 dynamic entries.
	// We add 70 distinct entries, then look up the oldest (lowest-priority) one.

	mut encoder := new_encoder()
	mut buf := []u8{len: 16384}

	// Fill dynamic table with 70 distinct entries. Each is a new-name literal
	// so encode_optimized will add it to the dynamic table (after the fix).
	for i in 0 .. 70 {
		filler := [HeaderField{'x-fill-${i}', 'v-${i}'}]
		encoder.encode_optimized(filler, mut buf)
	}

	// x-fill-0 was inserted first, so it is now at the highest dynamic index
	// (62 + 70 - 1 = 131), which is >= 128 and requires multi-byte encoding.
	target := [HeaderField{'x-fill-0', 'v-0'}]
	n := encoder.encode_optimized(target, mut buf)
	assert n > 0, 'encode_optimized must write at least one byte'

	// A valid single-byte indexed encoding covers indices 1..127 only.
	// For index 131 the first byte must be 0xFF (7-bit prefix saturated)
	// and at least one continuation byte must follow.
	assert n > 1, 'index 131 must be encoded with multi-byte HPACK integer (got ${n} byte(s))'
	assert buf[0] == 0xff, 'first byte for index >= 128 must be 0xFF (prefix saturated), got 0x${buf[0].hex()}'
}

// test_encode_optimized_result_decodable verifies that output from encode_optimized
// can be decoded back to the original headers by the standard HPACK decoder.
fn test_encode_optimized_result_decodable() {
	mut encoder := new_encoder()
	mut decoder := new_decoder()
	mut buf := []u8{len: 4096}

	headers := [
		HeaderField{':method', 'GET'},
		HeaderField{':path', '/'},
		HeaderField{':scheme', 'https'},
		HeaderField{'x-custom', 'hello'},
	]

	n := encoder.encode_optimized(headers, mut buf)
	assert n > 0, 'encode_optimized must write bytes'

	encoded := buf[..n].clone()
	decoded := decoder.decode(encoded) or {
		assert false, 'HPACK decode failed: ${err}'
		return
	}

	assert decoded.len == headers.len, 'decoded header count mismatch: want ${headers.len}, got ${decoded.len}'
	for i, h in headers {
		assert decoded[i].name == h.name, 'name mismatch at ${i}: want ${h.name}, got ${decoded[i].name}'
		assert decoded[i].value == h.value, 'value mismatch at ${i}: want ${h.value}, got ${decoded[i].value}'
	}
}

// test_encode_optimized_long_value encodes a header whose value is >= 128 bytes,
// requiring multi-byte HPACK integer encoding for the value-length field.
// The encoded output must be decodable back to the original header.
fn test_encode_optimized_long_value() {
	mut encoder := new_encoder()
	mut decoder := new_decoder()
	// Buffer large enough for the encoded output
	mut buf := []u8{len: 16384}

	// Build a value string of exactly 128 bytes (> 7-bit single-byte limit of 127)
	long_value := 'x'.repeat(128)
	headers := [HeaderField{'x-long-value', long_value}]

	n := encoder.encode_optimized(headers, mut buf)
	assert n > 0, 'encode_optimized must write at least one byte'

	encoded := buf[..n].clone()
	decoded := decoder.decode(encoded) or {
		assert false, 'HPACK decode of long-value header failed: ${err}'
		return
	}

	assert decoded.len == 1, 'expected 1 decoded header, got ${decoded.len}'
	assert decoded[0].name == 'x-long-value', 'name mismatch: got ${decoded[0].name}'
	assert decoded[0].value == long_value, 'value mismatch: length expected=${long_value.len} got=${decoded[0].value.len}'
}

// test_encode_optimized_long_name encodes a header whose name is >= 128 bytes,
// requiring multi-byte HPACK integer encoding for the name-length field.
// The encoded output must be decodable back to the original header.
fn test_encode_optimized_long_name() {
	mut encoder := new_encoder()
	mut decoder := new_decoder()
	mut buf := []u8{len: 16384}

	// Build a name string of exactly 128 bytes (> 7-bit single-byte limit of 127)
	long_name := 'x' + '-'.repeat(127) // 128 chars total, not in static table
	headers := [HeaderField{long_name, 'value'}]

	n := encoder.encode_optimized(headers, mut buf)
	assert n > 0, 'encode_optimized must write at least one byte'

	encoded := buf[..n].clone()
	decoded := decoder.decode(encoded) or {
		assert false, 'HPACK decode of long-name header failed: ${err}'
		return
	}

	assert decoded.len == 1, 'expected 1 decoded header, got ${decoded.len}'
	assert decoded[0].name == long_name, 'name mismatch: expected len=${long_name.len}, got len=${decoded[0].name.len}'
	assert decoded[0].value == 'value', 'value mismatch: got ${decoded[0].value}'
}

// test_encode_optimized_decodable_multiple_headers verifies that encode_optimized
// output for a realistic HTTP/2 request header set can be round-tripped through
// the standard HPACK decoder without loss.
fn test_encode_optimized_decodable_multiple_headers() {
	mut encoder := new_encoder()
	mut decoder := new_decoder()
	mut buf := []u8{len: 8192}

	headers := [
		HeaderField{':method', 'POST'},
		HeaderField{':path', '/api/v1/resource'},
		HeaderField{':scheme', 'https'},
		HeaderField{':authority', 'api.example.com'},
		HeaderField{'content-type', 'application/json'},
		HeaderField{'x-request-id', 'abc-123'},
	]

	n := encoder.encode_optimized(headers, mut buf)
	assert n > 0, 'encode_optimized must write bytes'

	encoded := buf[..n].clone()
	decoded := decoder.decode(encoded) or {
		assert false, 'HPACK decode failed: ${err}'
		return
	}

	assert decoded.len == headers.len, 'decoded header count mismatch: want ${headers.len}, got ${decoded.len}'
	for i, h in headers {
		assert decoded[i].name == h.name, 'name mismatch at ${i}: want "${h.name}", got "${decoded[i].name}"'
		assert decoded[i].value == h.value, 'value mismatch at ${i}: want "${h.value}", got "${decoded[i].value}"'
	}
}
