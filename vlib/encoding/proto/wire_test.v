module proto

fn test_encode_varint_small_values() {
	// 0 encodes as single byte 0x00
	assert encode_varint(0) == [u8(0x00)]
	// 1 encodes as single byte 0x01
	assert encode_varint(1) == [u8(0x01)]
	// 127 encodes as single byte 0x7f (max single-byte varint)
	assert encode_varint(127) == [u8(0x7f)]
}

fn test_encode_varint_multi_byte() {
	// 128 = 0x80 → needs 2 bytes: 0x80 0x01
	assert encode_varint(128) == [u8(0x80), 0x01]
	// 300 = 0x012c → 0xac 0x02
	assert encode_varint(300) == [u8(0xac), 0x02]
	// 16384 = 0x4000 → 0x80 0x80 0x01
	assert encode_varint(16384) == [u8(0x80), 0x80, 0x01]
}

fn test_encode_varint_max_u64() {
	// max u64 = 18446744073709551615 → 10 bytes all 0xff except last 0x01
	result := encode_varint(u64(0xFFFFFFFFFFFFFFFF))
	assert result.len == 10
	assert result[9] == 0x01
}

fn test_decode_varint_single_byte() {
	value, consumed := decode_varint([u8(0x00)])!
	assert value == 0
	assert consumed == 1

	value2, consumed2 := decode_varint([u8(0x7f)])!
	assert value2 == 127
	assert consumed2 == 1
}

fn test_decode_varint_multi_byte() {
	value, consumed := decode_varint([u8(0x80), 0x01])!
	assert value == 128
	assert consumed == 2

	value2, consumed2 := decode_varint([u8(0xac), 0x02])!
	assert value2 == 300
	assert consumed2 == 2
}

fn test_decode_varint_empty_returns_error() {
	decode_varint([]u8{}) or {
		assert err.msg() == 'empty data for varint decode'
		return
	}
	assert false, 'expected error for empty data'
}

fn test_encode_decode_varint_roundtrip() {
	test_values := [u64(0), 1, 127, 128, 255, 300, 16384, 1000000, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF]
	for expected in test_values {
		encoded := encode_varint(expected)
		decoded, _ := decode_varint(encoded)!
		assert decoded == expected, 'roundtrip failed for ${expected}'
	}
}

fn test_zigzag_encode() {
	assert zigzag_encode(0) == 0
	assert zigzag_encode(-1) == 1
	assert zigzag_encode(1) == 2
	assert zigzag_encode(-2) == 3
	assert zigzag_encode(2) == 4
	assert zigzag_encode(2147483647) == 4294967294  // max i32
	assert zigzag_encode(-2147483648) == 4294967295 // min i32
}

fn test_zigzag_decode() {
	assert zigzag_decode(0) == 0
	assert zigzag_decode(1) == -1
	assert zigzag_decode(2) == 1
	assert zigzag_decode(3) == -2
	assert zigzag_decode(4) == 2
	assert zigzag_decode(4294967294) == 2147483647
	assert zigzag_decode(4294967295) == -2147483648
}

fn test_zigzag_roundtrip() {
	test_values := [i64(0), 1, -1, 100, -100, 2147483647, -2147483648]
	for expected in test_values {
		assert zigzag_decode(zigzag_encode(expected)) == expected
	}
}

fn test_encode_tag() {
	// field 1, varint → (1 << 3) | 0 = 0x08
	assert encode_tag(1, .varint) == [u8(0x08)]
	// field 2, length_delimited → (2 << 3) | 2 = 0x12
	assert encode_tag(2, .length_delimited) == [u8(0x12)]
	// field 15, varint → (15 << 3) | 0 = 0x78
	assert encode_tag(15, .varint) == [u8(0x78)]
	// field 16, varint → (16 << 3) | 0 = 0x80 0x01
	assert encode_tag(16, .varint) == [u8(0x80), 0x01]
}

fn test_decode_tag() {
	field_num, wire_type, consumed := decode_tag([u8(0x08)])!
	assert field_num == 1
	assert wire_type == .varint
	assert consumed == 1

	field_num2, wire_type2, consumed2 := decode_tag([u8(0x12)])!
	assert field_num2 == 2
	assert wire_type2 == .length_delimited
	assert consumed2 == 1
}

fn test_decode_tag_two_byte() {
	field_num, wire_type, consumed := decode_tag([u8(0x80), 0x01])!
	assert field_num == 16
	assert wire_type == .varint
	assert consumed == 2
}

fn test_encode_decode_fixed32() {
	assert encode_fixed32(0) == [u8(0x00), 0x00, 0x00, 0x00]
	assert encode_fixed32(1) == [u8(0x01), 0x00, 0x00, 0x00]
	assert encode_fixed32(0xDEADBEEF) == [u8(0xEF), 0xBE, 0xAD, 0xDE]

	assert decode_fixed32([u8(0x00), 0x00, 0x00, 0x00])! == 0
	assert decode_fixed32([u8(0x01), 0x00, 0x00, 0x00])! == 1
	assert decode_fixed32([u8(0xEF), 0xBE, 0xAD, 0xDE])! == 0xDEADBEEF
}

fn test_decode_fixed32_insufficient_data() {
	decode_fixed32([u8(0x01), 0x02]) or {
		assert err.msg() == 'need 4 bytes for fixed32, got 2'
		return
	}
	assert false, 'expected error for insufficient data'
}

fn test_encode_decode_fixed64() {
	assert encode_fixed64(0) == [u8(0x00), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
	assert encode_fixed64(1) == [u8(0x01), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

	assert decode_fixed64([u8(0x00), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])! == u64(0)
	assert decode_fixed64([u8(0x01), 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])! == u64(1)
}

fn test_decode_fixed64_insufficient_data() {
	decode_fixed64([u8(0x01), 0x02, 0x03]) or {
		assert err.msg() == 'need 8 bytes for fixed64, got 3'
		return
	}
	assert false, 'expected error for insufficient data'
}

fn test_encode_length_delimited() {
	data := 'hello'.bytes()
	result := encode_length_delimited(2, data)
	// tag for field 2, wire type 2: (2 << 3) | 2 = 0x12
	// length: 5 = 0x05
	// data: 'hello' bytes
	assert result[0] == 0x12 // tag
	assert result[1] == 0x05 // length
	assert result[2..] == data
}

fn test_encode_length_delimited_empty() {
	result := encode_length_delimited(1, []u8{})
	// tag for field 1, wire type 2: (1 << 3) | 2 = 0x0a
	// length: 0 = 0x00
	assert result[0] == 0x0a
	assert result[1] == 0x00
	assert result.len == 2
}
