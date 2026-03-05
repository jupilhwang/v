// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// Performance optimizations for HTTP/2 implementation

// encode_single_header writes one HPACK-encoded header field into buf starting at
// offset. Returns the new offset on success, or an error if the buffer is too small.
// The dynamic table is updated automatically for non-sensitive literal representations.
fn (mut e Encoder) encode_single_header(header HeaderField, mut buf []u8, offset int) !int {
	mut found_exact_idx := 0
	mut found_name_idx := 0

	// O(1) static-table exact match
	exact_key := '${header.name}:${header.value}'
	if exact_key in static_table_exact_map {
		found_exact_idx = static_table_exact_map[exact_key]
	}

	// O(1) static-table name-only match
	if found_exact_idx == 0 && header.name in static_table_name_map {
		indices := static_table_name_map[header.name]
		if indices.len > 0 {
			found_name_idx = indices[0]
		}
	}

	// Linear dynamic-table scan (typically small)
	if found_exact_idx == 0 {
		for i, entry in e.dynamic_table.entries {
			if entry.name == header.name {
				dyn_idx := static_table.len + i
				if entry.value == header.value {
					found_exact_idx = dyn_idx
					break
				} else if found_name_idx == 0 {
					found_name_idx = dyn_idx
				}
			}
		}
	}

	if found_exact_idx > 0 {
		// Indexed header field (RFC 7541 §6.1): 7-bit prefix, flag 0x80
		if offset >= buf.len {
			return error('encode_optimized: buffer too small')
		}
		encoded_len := encode_integer(u64(found_exact_idx), 7, mut buf, offset)!
		buf[offset] |= 0x80
		return offset + encoded_len
	} else if header.name in sensitive_headers {
		return e.encode_sensitive_header(header, found_name_idx, mut buf, offset)!
	} else if found_name_idx > 0 {
		return e.encode_literal_indexed_name(header, found_name_idx, mut buf, offset)!
	} else {
		return e.encode_literal_new_name(header, mut buf, offset)!
	}
}

// encode_sensitive_header writes a Never-Indexed literal (RFC 7541 §6.2.3).
// Sensitive headers are never added to the dynamic table.
fn (mut e Encoder) encode_sensitive_header(header HeaderField, name_idx int, mut buf []u8, offset int) !int {
	mut off := offset
	if name_idx > 0 {
		if off >= buf.len {
			return error('encode_optimized: buffer too small')
		}
		encoded_len := encode_integer(u64(name_idx), 4, mut buf, off)!
		buf[off] |= 0x10
		off += encoded_len
		value_len := header.value.len
		if off + 5 + value_len > buf.len {
			return error('encode_optimized: buffer too small')
		}
		off += encode_integer(u64(value_len), 7, mut buf, off)!
		for b in header.value.bytes() {
			buf[off] = b
			off++
		}
	} else {
		name_len := header.name.len
		value_len := header.value.len
		if off + 1 + 5 + name_len + 5 + value_len > buf.len {
			return error('encode_optimized: buffer too small')
		}
		buf[off] = 0x10
		off++
		off += encode_integer(u64(name_len), 7, mut buf, off)!
		for b in header.name.bytes() {
			buf[off] = b
			off++
		}
		off += encode_integer(u64(value_len), 7, mut buf, off)!
		for b in header.value.bytes() {
			buf[off] = b
			off++
		}
	}
	return off
}

// encode_literal_indexed_name writes a Literal with Incremental Indexing using an
// indexed name (RFC 7541 §6.2.1) and adds the header to the dynamic table.
fn (mut e Encoder) encode_literal_indexed_name(header HeaderField, name_idx int, mut buf []u8, offset int) !int {
	mut off := offset
	if off >= buf.len {
		return error('encode_optimized: buffer too small')
	}
	// 6-bit prefix, flag 0x40
	// TODO: use Huffman encoding for value when it produces shorter output (H bit 0x80).
	encoded_len := encode_integer(u64(name_idx), 6, mut buf, off)!
	buf[off] |= 0x40
	off += encoded_len
	value_len := header.value.len
	if off + 5 + value_len > buf.len {
		return error('encode_optimized: buffer too small')
	}
	off += encode_integer(u64(value_len), 7, mut buf, off)!
	for b in header.value.bytes() {
		buf[off] = b
		off++
	}
	e.dynamic_table.add(header)
	return off
}

// encode_literal_new_name writes a Literal with Incremental Indexing using a new
// name (RFC 7541 §6.2.1) and adds the header to the dynamic table.
fn (mut e Encoder) encode_literal_new_name(header HeaderField, mut buf []u8, offset int) !int {
	mut off := offset
	name_len := header.name.len
	value_len := header.value.len
	// 1 byte for 0x40 prefix + worst-case 5 bytes per length field
	// TODO: use Huffman encoding for name and value when it produces shorter output.
	if off + 1 + 5 + name_len + 5 + value_len > buf.len {
		return error('encode_optimized: buffer too small')
	}
	buf[off] = 0x40
	off++
	off += encode_integer(u64(name_len), 7, mut buf, off)!
	for b in header.name.bytes() {
		buf[off] = b
		off++
	}
	off += encode_integer(u64(value_len), 7, mut buf, off)!
	for b in header.value.bytes() {
		buf[off] = b
		off++
	}
	e.dynamic_table.add(header)
	return off
}

// encode_optimized performs HPACK encoding with buffer reuse for better performance.
// It uses the pre-built static_table_exact_map and static_table_name_map for O(1)
// static table lookups (matching the approach used by Encoder.encode()), then falls
// back to a linear scan of the dynamic table (which is typically small).
// Uses RFC 7541-compliant multi-byte integer encoding for indices >= 127.
// Updates the dynamic table when emitting literal representations.
// Returns the number of bytes written, or an error if the buffer is too small.
// TODO: Unify with Encoder.encode() to avoid long-term divergence.
pub fn (mut e Encoder) encode_optimized(headers []HeaderField, mut buf []u8) int {
	mut offset := 0
	for header in headers {
		offset = e.encode_single_header(header, mut buf, offset) or { return offset }
	}
	return offset
}

// encode_integer encodes a HPACK integer per RFC 7541 §5.1.
// Returns the number of bytes written, or an error if the buffer is too small.
pub fn encode_integer(value u64, prefix_bits u8, mut buf []u8, offset int) !int {
	max_prefix := (u64(1) << prefix_bits) - 1
	if value < max_prefix {
		if offset >= buf.len {
			return error('encode_integer: buffer too small')
		}
		buf[offset] = u8(value)
		return 1
	}
	// Pre-calculate bytes needed before writing (atomic write guarantee)
	mut needed := 1 // first byte: max_prefix
	mut r := value - max_prefix
	for r >= 128 {
		needed++
		r /= 128
	}
	needed++ // final byte
	if offset + needed > buf.len {
		return error('encode_integer: buffer too small (need ${needed} bytes at offset ${offset}, buf.len=${buf.len})')
	}
	buf[offset] = u8(max_prefix)
	mut pos := offset + 1
	mut remaining := value - max_prefix
	for remaining >= 128 {
		buf[pos] = u8((remaining % 128) + 128)
		remaining /= 128
		pos++
	}
	buf[pos] = u8(remaining)
	return pos - offset + 1
}
