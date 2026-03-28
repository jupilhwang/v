module proto

// Unions for safe float/integer bit reinterpretation
union FloatBits32 {
	f f32
	u u32
}

union FloatBits64 {
	f f64
	u u64
}

// Holds a parsed wire field value during unmarshal.
// Named WireField to avoid collision with V's comptime FieldData.
struct WireField {
	wtype      WireType
	varint_val u64
	raw_bytes  []u8
}

// Extract proto field number from @[proto: N] attribute.
// Falls back to 1-based field index if no attribute found.
fn parse_proto_field_number(attrs []string, fallback u32) u32 {
	for attr in attrs {
		if attr.starts_with('proto:') {
			num_str := attr[6..].trim_space()
			if num_str.len > 0 {
				return u32(num_str.int())
			}
		}
	}
	return fallback
}

// Encode a non-zero varint field (tag + value) into buffer.
fn encode_varint_field(mut buf []u8, field_num u32, value u64) {
	if value != 0 {
		buf << encode_tag(field_num, .varint)
		buf << encode_varint(value)
	}
}

// Read one wire field value starting at offset. Returns (field, bytes_consumed).
fn read_wire_value(data []u8, offset int, wtype WireType) !(WireField, int) {
	match wtype {
		.varint {
			val, size := decode_varint(data[offset..])!
			return WireField{ wtype: wtype, varint_val: val }, size
		}
		.fixed_32 {
			if offset + 4 > data.len {
				return error('truncated fixed32 at offset ${offset}')
			}
			return WireField{ wtype: wtype, raw_bytes: data[offset..offset + 4].clone() }, 4
		}
		.fixed_64 {
			if offset + 8 > data.len {
				return error('truncated fixed64 at offset ${offset}')
			}
			return WireField{ wtype: wtype, raw_bytes: data[offset..offset + 8].clone() }, 8
		}
		.length_delimited {
			length, size := decode_varint(data[offset..])!
			start := offset + size
			end := start + int(length)
			if end > data.len {
				return error('length-delimited exceeds data at offset ${offset}')
			}
			return WireField{ wtype: wtype, raw_bytes: data[start..end].clone() }, size + int(length)
		}
	}
}

// Parse wire data into a map of field_number → WireField.
fn parse_wire_data(data []u8) !map[u32]WireField {
	mut result := map[u32]WireField{}
	mut pos := 0
	for pos < data.len {
		field_num, wtype, tag_size := decode_tag(data[pos..])!
		pos += tag_size
		wf, consumed := read_wire_value(data, pos, wtype)!
		result[field_num] = wf
		pos += consumed
	}
	return result
}

// Marshal a V struct to protobuf wire format bytes.
// Uses $for compile-time reflection. Proto3 skips zero/default values.
pub fn marshal[T](msg T) ![]u8 {
	mut buf := []u8{}
	mut field_idx := u32(0)
	$for field in T.fields {
		field_idx++
		field_num := parse_proto_field_number(field.attrs, field_idx)
		$if field.typ is $string {
			value := msg.$(field.name)
			if value.len > 0 {
				buf << encode_length_delimited(field_num, value.bytes())
			}
		} $else $if field.typ is bool {
			if msg.$(field.name) {
				buf << encode_tag(field_num, .varint)
				buf << encode_varint(1)
			}
		} $else $if field.typ is f32 {
			value := msg.$(field.name)
			if value != f32(0) {
				buf << encode_tag(field_num, .fixed_32)
				buf << encode_fixed32(unsafe { FloatBits32{ f: value }.u })
			}
		} $else $if field.typ is f64 {
			value := msg.$(field.name)
			if value != f64(0) {
				buf << encode_tag(field_num, .fixed_64)
				buf << encode_fixed64(unsafe { FloatBits64{ f: value }.u })
			}
		} $else $if field.typ is $array {
			marshal_bytes_field(mut buf, field_num, msg.$(field.name))
		} $else $if field.typ is int {
			encode_varint_field(mut buf, field_num, u64(msg.$(field.name)))
		} $else $if field.typ is i64 {
			encode_varint_field(mut buf, field_num, u64(msg.$(field.name)))
		} $else $if field.typ is u32 {
			encode_varint_field(mut buf, field_num, u64(msg.$(field.name)))
		} $else $if field.typ is u64 {
			encode_varint_field(mut buf, field_num, msg.$(field.name))
		}
	}
	return buf
}

// Helper: marshal []u8 field as length-delimited bytes.
fn marshal_bytes_field[T](mut buf []u8, field_num u32, arr []T) {
	$if T is u8 {
		if arr.len > 0 {
			buf << encode_length_delimited(field_num, arr)
		}
	}
}

// Unmarshal protobuf wire format bytes into a V struct.
// Parses wire data first, then maps fields via $for reflection.
pub fn unmarshal[T](data []u8) !T {
	mut obj := T{}
	if data.len == 0 {
		return obj
	}
	fields := parse_wire_data(data)!
	mut field_idx := u32(0)
	$for field in T.fields {
		field_idx++
		field_num := parse_proto_field_number(field.attrs, field_idx)
		if field_num in fields {
			entry := fields[field_num]
			$if field.typ is $string {
				obj.$(field.name) = entry.raw_bytes.bytestr()
			} $else $if field.typ is bool {
				obj.$(field.name) = entry.varint_val != 0
			} $else $if field.typ is f32 {
				bits := decode_fixed32(entry.raw_bytes)!
				obj.$(field.name) = unsafe { FloatBits32{ u: bits }.f }
			} $else $if field.typ is f64 {
				bits := decode_fixed64(entry.raw_bytes)!
				obj.$(field.name) = unsafe { FloatBits64{ u: bits }.f }
			} $else $if field.typ is $array {
				obj.$(field.name) = unmarshal_bytes_field(entry.raw_bytes, obj.$(field.name))
			} $else $if field.typ is int {
				obj.$(field.name) = int(entry.varint_val)
			} $else $if field.typ is i64 {
				obj.$(field.name) = i64(entry.varint_val)
			} $else $if field.typ is u32 {
				obj.$(field.name) = u32(entry.varint_val)
			} $else $if field.typ is u64 {
				obj.$(field.name) = entry.varint_val
			}
		}
	}
	return obj
}

// Helper: unmarshal length-delimited bytes into []u8 field.
fn unmarshal_bytes_field[T](data []u8, _ []T) []T {
	$if T is u8 {
		return data.clone()
	}
	return []T{}
}
