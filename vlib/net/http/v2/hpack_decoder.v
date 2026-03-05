// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// Decoder decodes headers using HPACK
pub struct Decoder {
mut:
	dynamic_table        DynamicTable
	max_table_size_limit int = 4096 // mirrors SETTINGS_HEADER_TABLE_SIZE; 0 means unlimited
}

// new_decoder creates a new HPACK decoder
pub fn new_decoder() Decoder {
	return Decoder{
		dynamic_table: DynamicTable{}
	}
}

// set_max_table_size_limit sets the maximum allowed dynamic table size for this
// decoder, as negotiated via SETTINGS_HEADER_TABLE_SIZE. Any dynamic table size
// update in the header block that exceeds this limit is treated as a connection
// error per RFC 7541 §4.2.
pub fn (mut d Decoder) set_max_table_size_limit(limit int) {
	d.max_table_size_limit = limit
}

// decode decodes a header block
pub fn (mut d Decoder) decode(data []u8) ![]HeaderField {
	mut headers := []HeaderField{}
	mut idx := 0

	for idx < data.len {
		first_byte := data[idx]

		if (first_byte & 0x80) != 0 {
			// Indexed header field (RFC 7541 Section 6.1)
			n := d.decode_indexed(data[idx..])!
			idx += n.bytes_read
			headers << n.field
		} else if (first_byte & 0x40) != 0 {
			// Literal header field with incremental indexing (RFC 7541 Section 6.2.1)
			n := d.decode_literal_with_indexing(data[idx..])!
			idx += n.bytes_read
			headers << n.field
			d.dynamic_table.add(n.field)
		} else if (first_byte & 0x20) != 0 {
			// Dynamic table size update (RFC 7541 Section 6.3)
			size, bytes_read := decode_integer(data[idx..], 5)!
			idx += bytes_read
			// Validate against the SETTINGS_HEADER_TABLE_SIZE limit (RFC 7541 §4.2).
			if d.max_table_size_limit > 0 && size > d.max_table_size_limit {
				return error('dynamic table size update (${size}) exceeds limit (${d.max_table_size_limit})')
			}
			d.dynamic_table.set_max_size(size)
		} else if (first_byte & 0xf0) == 0x10 {
			// Literal Header Field Never Indexed (RFC 7541 §6.2.3)
			// Semantically identical to "without indexing" but intermediaries must
			// never re-encode this field with indexing (important for sensitive headers).
			n := d.decode_literal_name_value(data[idx..], 4)!
			idx += n.bytes_read
			// Never add to dynamic table; preserve never-indexed semantics
			headers << n.field
		} else {
			// Literal header field without indexing (RFC 7541 Section 6.2.2)
			n := d.decode_literal_name_value(data[idx..], 4)!
			idx += n.bytes_read
			headers << n.field
		}
	}

	return headers
}

// DecodeResult holds a decoded field and how many bytes were consumed
struct DecodeResult {
	field      HeaderField
	bytes_read int
}

// decode_indexed decodes an indexed header field (RFC 7541 §6.1)
fn (mut d Decoder) decode_indexed(data []u8) !DecodeResult {
	index, bytes_read := decode_integer(data, 7)!
	field := get_indexed(&d.dynamic_table, index) or { return error('invalid index: ${index}') }
	return DecodeResult{field, bytes_read}
}

// decode_literal_with_indexing decodes a literal header with incremental indexing (RFC 7541 §6.2.1)
fn (mut d Decoder) decode_literal_with_indexing(data []u8) !DecodeResult {
	index, bytes_read := decode_integer(data, 6)!
	mut idx := bytes_read

	mut name := ''
	if index == 0 {
		mut name_bytes_read := 0
		name, name_bytes_read = decode_string(data[idx..])!
		idx += name_bytes_read
	} else {
		field := get_indexed(&d.dynamic_table, index) or { return error('invalid index: ${index}') }
		name = field.name
	}

	value, bytes_read2 := decode_string(data[idx..])!
	idx += bytes_read2

	return DecodeResult{HeaderField{name, value}, idx}
}

// decode_literal_name_value decodes a literal header with given prefix bits (never-indexed or without-indexing)
fn (mut d Decoder) decode_literal_name_value(data []u8, prefix_bits int) !DecodeResult {
	index, bytes_read := decode_integer(data, prefix_bits)!
	mut idx := bytes_read

	mut name := ''
	if index == 0 {
		mut name_bytes_read := 0
		name, name_bytes_read = decode_string(data[idx..])!
		idx += name_bytes_read
	} else {
		field := get_indexed(&d.dynamic_table, index) or { return error('invalid index: ${index}') }
		name = field.name
	}

	value, bytes_read2 := decode_string(data[idx..])!
	idx += bytes_read2

	return DecodeResult{HeaderField{name, value}, idx}
}

// decode_integer decodes an integer using HPACK integer representation
fn decode_integer(data []u8, prefix_bits int) !(int, int) {
	if data.len == 0 {
		return error('empty data')
	}

	max_prefix := (1 << prefix_bits) - 1
	mask := u8(max_prefix)

	value := int(data[0] & mask)

	if value < max_prefix {
		return value, 1
	}

	mut result := value
	mut m := 0
	mut idx := 1

	for idx < data.len {
		b := data[idx]

		// Check before shifting: 7 bits shifted left by m overflows i32 when m >= 28
		// (0x7f << 28 exceeds the positive range of a 32-bit signed integer).
		if m >= 28 {
			return error('integer overflow')
		}

		result += int(u32(b & 0x7f) << u32(m))
		m += 7
		idx++

		if (b & 0x80) == 0 {
			return result, idx
		}
	}

	return error('incomplete integer')
}

// decode_string decodes a string (with optional Huffman coding)
fn decode_string(data []u8) !(string, int) {
	if data.len == 0 {
		return error('empty data')
	}

	huffman := (data[0] & 0x80) != 0
	length, bytes_read := decode_integer(data, 7)!

	if data.len < bytes_read + length {
		return error('incomplete string')
	}

	str_data := data[bytes_read..bytes_read + length]

	if huffman {
		decoded := decode_huffman(str_data)!
		return decoded.bytestr(), bytes_read + length
	}

	return str_data.bytestr(), bytes_read + length
}
