module proto

// Wire types per proto3 spec
pub enum WireType {
	varint           = 0 // int32, int64, uint32, uint64, sint32, sint64, bool, enum
	fixed_64         = 1 // fixed64, sfixed64, double
	length_delimited = 2 // string, bytes, embedded messages, packed repeated
	fixed_32         = 5 // fixed32, sfixed32, float
}

// Encode varint using base-128 variable-length encoding.
// Each byte uses 7 bits for data and MSB as continuation flag.
pub fn encode_varint(value u64) []u8 {
	mut result := []u8{cap: 10}
	mut v := value
	for {
		mut b := u8(v & 0x7F)
		v >>= 7
		if v != 0 {
			b |= 0x80
		}
		result << b
		if v == 0 {
			break
		}
	}
	return result
}

// Decode varint from byte slice.
// Returns (decoded_value, bytes_consumed).
pub fn decode_varint(data []u8) !(u64, int) {
	if data.len == 0 {
		return error('empty data for varint decode')
	}
	mut result := u64(0)
	mut shift := u32(0)
	for i, b in data {
		if i >= 10 {
			return error('varint exceeds 10 bytes')
		}
		result |= u64(b & 0x7F) << shift
		if (b & 0x80) == 0 {
			return result, i + 1
		}
		shift += 7
	}
	return error('unterminated varint')
}

// ZigZag encode maps signed integers to unsigned.
// Positive values map to even numbers, negatives to odd.
pub fn zigzag_encode(value i64) u64 {
	// Arithmetic right shift preserves sign; cast to unsigned after shifts
	v := u64(value)
	return (v << 1) ^ u64(value >> 63)
}

// ZigZag decode reverses the zigzag encoding.
pub fn zigzag_decode(value u64) i64 {
	return i64(value >> 1) ^ -i64(value & 1)
}

// Encode field tag as (field_number << 3 | wire_type).
pub fn encode_tag(field_number u32, wire_type WireType) []u8 {
	tag_value := (u64(field_number) << 3) | u64(wire_type)
	return encode_varint(tag_value)
}

// Decode field tag, returns (field_number, wire_type, bytes_consumed).
pub fn decode_tag(data []u8) !(u32, WireType, int) {
	tag_value, consumed := decode_varint(data)!
	wire_type_val := u8(tag_value & 0x07)
	field_number := u32(tag_value >> 3)
	wire_type := unsafe { WireType(wire_type_val) }
	return field_number, wire_type, consumed
}

// Encode length-delimited field: tag + varint_length + data.
pub fn encode_length_delimited(field_number u32, data []u8) []u8 {
	mut result := encode_tag(field_number, .length_delimited)
	result << encode_varint(u64(data.len))
	result << data
	return result
}

// Encode fixed32 as 4 little-endian bytes.
pub fn encode_fixed32(value u32) []u8 {
	return [
		u8(value & 0xFF),
		u8((value >> 8) & 0xFF),
		u8((value >> 16) & 0xFF),
		u8((value >> 24) & 0xFF),
	]
}

// Decode fixed32 from 4 little-endian bytes.
pub fn decode_fixed32(data []u8) !u32 {
	if data.len < 4 {
		return error('need 4 bytes for fixed32, got ${data.len}')
	}
	return u32(data[0]) | (u32(data[1]) << 8) | (u32(data[2]) << 16) | (u32(data[3]) << 24)
}

// Encode fixed64 as 8 little-endian bytes.
pub fn encode_fixed64(value u64) []u8 {
	return [
		u8(value & 0xFF),
		u8((value >> 8) & 0xFF),
		u8((value >> 16) & 0xFF),
		u8((value >> 24) & 0xFF),
		u8((value >> 32) & 0xFF),
		u8((value >> 40) & 0xFF),
		u8((value >> 48) & 0xFF),
		u8((value >> 56) & 0xFF),
	]
}

// Decode fixed64 from 8 little-endian bytes.
pub fn decode_fixed64(data []u8) !u64 {
	if data.len < 8 {
		return error('need 8 bytes for fixed64, got ${data.len}')
	}
	return u64(data[0]) | (u64(data[1]) << 8) | (u64(data[2]) << 16) | (u64(data[3]) << 24) | (u64(data[4]) << 32) | (u64(data[5]) << 40) | (u64(data[6]) << 48) | (u64(data[7]) << 56)
}
