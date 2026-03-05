// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// Encoder encodes headers using HPACK
pub struct Encoder {
mut:
	dynamic_table DynamicTable
}

// new_encoder creates a new HPACK encoder
pub fn new_encoder() Encoder {
	return Encoder{
		dynamic_table: DynamicTable{}
	}
}

// encode encodes a list of header fields
pub fn (mut e Encoder) encode(headers []HeaderField) []u8 {
	// Pre-allocate result with estimated size
	mut estimated_size := 0
	for header in headers {
		estimated_size += header.name.len + header.value.len + 10 // +10 for encoding overhead
	}
	mut result := []u8{cap: estimated_size}

	for header in headers {
		result << e.encode_header(header)
	}

	return result
}

// encode_header encodes a single header field into its HPACK representation
fn (mut e Encoder) encode_header(header HeaderField) []u8 {
	mut result := []u8{}
	found_index, found_name_index := e.find_header_index(header)

	if found_index > 0 {
		result << encode_indexed_field(found_index)
	} else if header.name in sensitive_headers {
		result << encode_never_indexed_field(header, found_name_index)
	} else {
		result << encode_literal_with_indexing(header, found_name_index)
		// Add to dynamic table
		e.dynamic_table.add(header)
	}

	return result
}

// find_header_index looks up a header in static and dynamic tables.
// Returns (exact_index, name_only_index), both 0 if not found.
fn (e Encoder) find_header_index(header HeaderField) (int, int) {
	mut found_index := 0
	mut found_name_index := 0

	// Try exact match in static table using hashmap (O(1))
	exact_key := '${header.name}:${header.value}'
	if exact_key in static_table_exact_map {
		found_index = static_table_exact_map[exact_key]
	}

	// If no exact match, try name-only match in static table
	if found_index == 0 && header.name in static_table_name_map {
		indices := static_table_name_map[header.name]
		if indices.len > 0 {
			found_name_index = indices[0] // Use first match
		}
	}

	// Search dynamic table (still linear, but typically much smaller)
	if found_index == 0 {
		for i := 0; i < e.dynamic_table.entries.len; i++ {
			entry := e.dynamic_table.entries[i]
			if entry.name == header.name {
				if entry.value == header.value {
					found_index = static_table.len + i
					break
				} else if found_name_index == 0 {
					found_name_index = static_table.len + i
				}
			}
		}
	}

	return found_index, found_name_index
}

// encode_indexed_field encodes an indexed header field (RFC 7541 §6.1)
fn encode_indexed_field(index int) []u8 {
	encoded := encode_hpack_integer(index, 7)
	mut result := []u8{cap: encoded.len}
	result << (encoded[0] | 0x80)
	if encoded.len > 1 {
		result << encoded[1..]
	}
	return result
}

// encode_never_indexed_field encodes a header as never-indexed (RFC 7541 §6.2.3)
fn encode_never_indexed_field(header HeaderField, name_index int) []u8 {
	mut result := []u8{}
	if name_index > 0 {
		encoded := encode_hpack_integer(name_index, 4)
		result << (encoded[0] | 0x10)
		if encoded.len > 1 {
			result << encoded[1..]
		}
	} else {
		result << u8(0x10)
		result << encode_string(header.name, true)
	}
	result << encode_string(header.value, true)
	return result
}

// encode_literal_with_indexing encodes a literal header with incremental indexing (RFC 7541 §6.2.1)
fn encode_literal_with_indexing(header HeaderField, name_index int) []u8 {
	mut result := []u8{}
	if name_index > 0 {
		encoded := encode_hpack_integer(name_index, 6)
		result << (encoded[0] | 0x40)
		if encoded.len > 1 {
			result << encoded[1..]
		}
	} else {
		result << u8(0x40)
		result << encode_string(header.name, true)
	}
	result << encode_string(header.value, true)
	return result
}

// encode_hpack_integer encodes an integer using HPACK integer representation
fn encode_hpack_integer(value int, prefix_bits int) []u8 {
	// Pre-allocate with capacity for worst case (5 bytes for 32-bit int)
	mut result := []u8{cap: 5}
	max_prefix := (1 << prefix_bits) - 1

	if value < max_prefix {
		result << u8(value)
	} else {
		result << u8(max_prefix)
		mut remaining := value - max_prefix

		for remaining >= 128 {
			result << u8((remaining % 128) + 128)
			remaining = remaining / 128
		}
		result << u8(remaining)
	}

	return result
}

// encode_string encodes a string (with optional Huffman coding)
fn encode_string(s string, huffman bool) []u8 {
	if huffman {
		huffman_encoded := encode_huffman(s.bytes())
		encoded_len := encode_hpack_integer(huffman_encoded.len, 7)
		mut result := []u8{cap: encoded_len.len + huffman_encoded.len}
		result << (encoded_len[0] | 0x80)
		if encoded_len.len > 1 {
			result << encoded_len[1..]
		}
		result << huffman_encoded
		return result
	} else {
		encoded := encode_hpack_integer(s.len, 7)
		mut result := []u8{cap: encoded.len + s.len}
		result << encoded
		result << s.bytes()
		return result
	}
}
