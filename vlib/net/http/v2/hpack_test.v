// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// Test for HPACK header compression

fn test_encode_decode_integer() {
	// Test small integer (< max_prefix)
	encoded := encode_hpack_integer(10, 5)
	decoded, bytes_read := decode_integer(encoded, 5) or {
		assert false, 'Failed to decode integer'
		return
	}
	assert decoded == 10
	assert bytes_read == 1

	// Test large integer (>= max_prefix)
	encoded2 := encode_hpack_integer(1337, 5)
	decoded2, bytes_read2 := decode_integer(encoded2, 5) or {
		assert false, 'Failed to decode large integer'
		return
	}
	assert decoded2 == 1337
	assert bytes_read2 > 1
}

fn test_encode_decode_string() {
	test_str := 'www.example.com'
	encoded := encode_string(test_str, false)
	decoded, bytes_read := decode_string(encoded) or {
		assert false, 'Failed to decode string'
		return
	}
	assert decoded == test_str
	assert bytes_read == encoded.len
}

fn test_static_table() {
	// Test that static table is properly initialized
	assert static_table.len > 0
	assert static_table[1].name == ':authority'
	assert static_table[2].name == ':method'
	assert static_table[2].value == 'GET'
}

fn test_dynamic_table() {
	mut dt := DynamicTable{}

	field := HeaderField{'custom-header', 'custom-value'}
	dt.add(field)

	retrieved := dt.get(1) or {
		assert false, 'Failed to get from dynamic table'
		return
	}

	assert retrieved.name == field.name
	assert retrieved.value == field.value
}

fn test_dynamic_table_eviction() {
	mut dt := DynamicTable{
		max_size: 100
	}

	// Add entries until eviction occurs
	for i in 0 .. 10 {
		field := HeaderField{'header-${i}', 'value-${i}'}
		dt.add(field)
	}

	// Table size should not exceed max_size
	assert dt.size <= dt.max_size
}

fn test_encoder_decoder() {
	mut encoder := new_encoder()
	mut decoder := new_decoder()

	headers := [
		HeaderField{':method', 'GET'},
		HeaderField{':path', '/'},
		HeaderField{':scheme', 'https'},
		HeaderField{'custom-header', 'custom-value'},
	]

	encoded := encoder.encode(headers)
	decoded := decoder.decode(encoded) or {
		assert false, 'Failed to decode headers'
		return
	}

	assert decoded.len == headers.len
	for i, header in headers {
		assert decoded[i].name == header.name
		assert decoded[i].value == header.value
	}
}

fn test_indexed_header() {
	mut encoder := new_encoder()
	mut decoder := new_decoder()

	// Use static table entry
	headers := [
		HeaderField{':method', 'GET'}, // Index 2 in static table
	]

	encoded := encoder.encode(headers)

	// Indexed header should be compact (1-2 bytes)
	assert encoded.len <= 2

	decoded := decoder.decode(encoded) or {
		assert false, 'Failed to decode indexed header'
		return
	}

	assert decoded.len == 1
	assert decoded[0].name == ':method'
	assert decoded[0].value == 'GET'
}

// Issue #12: RFC 7541 §6.2.3 — Literal Header Field Never Indexed
fn test_decode_never_indexed_literal_new_name() {
	mut decoder := new_decoder()

	// Manually craft a "never indexed" header with new name (index=0, prefix=4-bit):
	//   0x10 = 0001 0000  → never indexed, index=0 (new name)
	// Then two literal strings: name and value (non-Huffman, 1-byte length prefix)
	name := 'x-secret'
	value := 'top-secret'
	mut data := []u8{}
	data << u8(0x10) // never indexed, new name
	data << u8(name.len)
	data << name.bytes()
	data << u8(value.len)
	data << value.bytes()

	headers := decoder.decode(data) or {
		assert false, 'Failed to decode never-indexed header: ${err}'
		return
	}

	assert headers.len == 1
	assert headers[0].name == name
	assert headers[0].value == value
	// Field must NOT be added to the dynamic table
	assert decoder.dynamic_table.entries.len == 0
}

// Issue #12: Never indexed with indexed name reference (static table)
fn test_decode_never_indexed_indexed_name() {
	mut decoder := new_decoder()

	// 0x10 | 2 = 0x12 → never indexed, name from static table index 2 (:method)
	value := 'DELETE'
	mut data := []u8{}
	data << u8(0x12) // never indexed, name index=2 (:method)
	data << u8(value.len)
	data << value.bytes()

	headers := decoder.decode(data) or {
		assert false, 'Failed to decode never-indexed header with indexed name: ${err}'
		return
	}

	assert headers.len == 1
	assert headers[0].name == ':method'
	assert headers[0].value == value
	// Must NOT be added to dynamic table
	assert decoder.dynamic_table.entries.len == 0
}

// Issue #13: DynamicTable.add must evict entries when new entry alone exceeds max_size
fn test_dynamic_table_add_entry_larger_than_max_size() {
	mut dt := DynamicTable{
		max_size: 50
	}

	// A header whose size (32 + name.len + value.len) > 50
	big_field := HeaderField{'big-name', 'big-value-that-overflows-max'}
	// big_field.size() = 32 + 8 + 28 = 68 > 50
	dt.add(big_field)

	// Table must be empty — the entry is too large to fit
	assert dt.entries.len == 0
	assert dt.size == 0
}

// Issue #13: Eviction order — oldest (end) entries evicted first
fn test_dynamic_table_eviction_order() {
	mut dt := DynamicTable{
		max_size: 200
	}

	// Each entry: 32 + 6 + 1 = 39 bytes
	dt.add(HeaderField{'first!', '1'})
	dt.add(HeaderField{'secnd!', '2'})
	dt.add(HeaderField{'third!', '3'})
	dt.add(HeaderField{'fourt!', '4'})
	dt.add(HeaderField{'fifth!', '5'})
	// 5 * 39 = 195 bytes — fits within 200

	// Now add a 6th — total would be 234, need to evict 1 oldest (first!)
	dt.add(HeaderField{'sixth!', '6'})

	// 6 entries would be 234 > 200, so oldest must be gone
	assert dt.size <= dt.max_size
	// Newest (sixth!) must be at index 1
	newest := dt.get(1) or {
		assert false, 'Could not get newest entry'
		return
	}
	assert newest.name == 'sixth!'
	// Oldest (first!) must have been evicted — index 5 should be second-oldest
	oldest := dt.get(dt.entries.len) or {
		assert false, 'Could not get oldest remaining entry'
		return
	}
	assert oldest.name != 'first!', 'first! should have been evicted'
}

// Issue 1: decode_integer overflow — crafted multi-byte sequence whose shift would
// overflow a 32-bit int (m=28 with 0x7f bits set) must return an error, not silently
// produce a wrong value or panic.
fn test_decode_integer_overflow_guard() {
	// Build a sequence that requires m >= 28 before the shift.
	// First byte: all prefix bits set → value = max_prefix, multi-byte continuation.
	// Then 4 continuation bytes each with the MSB set (more bytes follow).
	// The 5th continuation byte (m=28) would shift 0x7f left by 28, overflowing i32.
	// The decoder must reject this with an error before performing the overflow shift.
	data := [u8(0x1f), 0xff, 0xff, 0xff, 0xff, 0x0f] // 5-bit prefix; 5 continuation bytes
	_, _ := decode_integer(data, 5) or {
		// Expected: an error is returned (overflow detected)
		return
	}
	// If we reach here without error the overflow guard is absent — fail the test.
	assert false, 'decode_integer must return an error on overflow input'
}

// Issue 2: sensitive headers must be encoded as "never indexed" (0x10 prefix).
// An encoder must NOT add authorization/cookie/set-cookie/proxy-authorization to
// the dynamic table and must set the 0x10 flag on the first byte.
fn test_encode_sensitive_headers_never_indexed() {
	mut encoder := new_encoder()
	headers_to_encode := [
		HeaderField{'authorization', 'Bearer secret'},
		HeaderField{'cookie', 'session=abc'},
		HeaderField{'set-cookie', 'id=1; HttpOnly'},
		HeaderField{'proxy-authorization', 'Basic creds'},
	]

	encoded := encoder.encode(headers_to_encode)

	// Dynamic table must remain empty — sensitive headers must not be indexed.
	assert encoder.dynamic_table.entries.len == 0, 'sensitive headers must not be added to the dynamic table'

	// Verify the encoded bytes can be decoded back correctly and that the
	// decoder also does not add them to its dynamic table.
	mut decoder := new_decoder()
	decoded := decoder.decode(encoded) or {
		assert false, 'Failed to decode sensitive headers: ${err}'
		return
	}
	assert decoded.len == headers_to_encode.len
	for i, h in headers_to_encode {
		assert decoded[i].name == h.name
		assert decoded[i].value == h.value
	}
	assert decoder.dynamic_table.entries.len == 0, 'decoder must not index never-indexed headers'
}

// Issue 3: Decoder must reject a dynamic table size update that exceeds the
// SETTINGS_HEADER_TABLE_SIZE limit configured on the connection.
fn test_decoder_rejects_size_update_exceeding_limit() {
	mut decoder := new_decoder()
	// Set a tight limit (e.g., 256 bytes) simulating a SETTINGS_HEADER_TABLE_SIZE value.
	decoder.set_max_table_size_limit(256)

	// Craft a size-update byte sequence: 0x20 prefix (5-bit), value = 512 > 256.
	// encode 512 with 5-bit prefix: max_prefix = 31, so first byte = 0x20 | 31 = 0x3f,
	// then continuation: 512 - 31 = 481; 481 % 128 = 97 | 0x80 = 0xe1; 481 / 128 = 3.
	data := [u8(0x3f), 0xe1, 0x03]
	_ := decoder.decode(data) or {
		// Expected: error because 512 > limit of 256
		return
	}
	assert false, 'decoder must reject size update exceeding max_table_size_limit'
}

// Issue 3 (positive): size update within limit must be accepted.
fn test_decoder_accepts_size_update_within_limit() {
	mut decoder := new_decoder()
	decoder.set_max_table_size_limit(4096)

	// Craft size update to 256: 5-bit prefix, max_prefix=31, first byte = 0x20|31 = 0x3f.
	// 256 - 31 = 225 >= 128, so: byte = (225 % 128) | 0x80 = 97 | 0x80 = 0xe1, remaining = 1.
	// 1 < 128, so final byte = 0x01. Full sequence: [0x3f, 0xe1, 0x01].
	data := [u8(0x3f), u8(0xe1), u8(0x01)]
	decoder.decode(data) or {
		assert false, 'decoder must accept size update within limit: ${err}'
		return
	}
	assert decoder.dynamic_table.max_size == 256, 'dynamic table max_size should be updated to 256'
}

// test_decode_integer_incomplete verifies that a truncated multi-byte integer returns an error.
// RFC 7541 §5.1: a multi-byte integer with all continuation bytes missing is malformed.
fn test_decode_integer_incomplete() {
	// First byte has all prefix bits set (signals multi-byte), but no continuation byte follows.
	// 5-bit prefix: max_prefix = 0x1f; byte = 0x1f triggers multi-byte path.
	data := [u8(0x1f)] // no continuation bytes
	_, _ := decode_integer(data, 5) or {
		// Expected: 'incomplete integer' error
		assert err.msg().contains('incomplete')
		return
	}
	assert false, 'decode_integer must return an error for truncated multi-byte integer'
}

// test_decode_string_empty_data verifies that decode_string returns an error on empty input.
// RFC 7541 §5.2: a string must start with a length byte; empty data is malformed.
fn test_decode_string_empty_data() {
	data := []u8{}
	_, _ := decode_string(data) or {
		assert err.msg().contains('empty')
		return
	}
	assert false, 'decode_string must return an error for empty input'
}

// test_decode_string_incomplete verifies that decode_string returns an error when the
// declared string length exceeds the available data.
fn test_decode_string_incomplete() {
	// Length byte says 10 bytes follow, but only 3 are present.
	mut data := []u8{}
	data << u8(10) // non-Huffman, length = 10
	data << u8(`a`)
	data << u8(`b`)
	data << u8(`c`)
	_, _ := decode_string(data) or {
		assert err.msg().contains('incomplete')
		return
	}
	assert false, 'decode_string must return an error for truncated string data'
}

// test_decoder_max_table_size_zero_means_unlimited verifies that a max_table_size_limit
// of 0 is treated as "no limit" — any size update is accepted.
// This matches the Decoder field comment: "0 means unlimited".
fn test_decoder_max_table_size_zero_means_unlimited() {
	mut decoder := new_decoder()
	// Default max_table_size_limit is 4096; override with 0 to disable enforcement.
	decoder.set_max_table_size_limit(0)

	// Craft a size update to 8192.
	// 5-bit prefix: max_prefix=31; first byte = 0x20|31 = 0x3f.
	// 8192 - 31 = 8161; 8161 in base-128 LE: 8161 % 128 = 97 → 97|0x80 = 0xe1;
	// 8161 / 128 = 63 (no more continuation) → 0x3f.
	// Sequence: [0x3f, 0xe1, 0x3f].
	data := [u8(0x3f), u8(0xe1), u8(0x3f)]
	decoder.decode(data) or {
		assert false, 'zero limit means unlimited — large size update must be accepted: ${err}'
		return
	}
	assert decoder.dynamic_table.max_size == 8192, 'dynamic table should be updated to 8192'
}

// test_decoder_set_max_table_size_limit_rejects_over_limit verifies the decoder
// rejects a size update above a custom limit set via set_max_table_size_limit.
fn test_decoder_set_max_table_size_limit_rejects_over_limit() {
	mut decoder := new_decoder()
	decoder.set_max_table_size_limit(512)

	// Craft a size update to 1024 (> 512).
	// 5-bit prefix: max_prefix=31; first byte = 0x3f.
	// 1024 - 31 = 993; 993 % 128 = 97 | 0x80 = 0xe1; 993 / 128 = 7 → 0x07.
	data := [u8(0x3f), u8(0xe1), u8(0x07)]
	_ := decoder.decode(data) or {
		assert err.msg().contains('exceeds limit')
		return
	}
	assert false, 'decoder must reject size update (1024) exceeding limit (512)'
}
