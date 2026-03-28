module proto

struct SimpleMessage {
	name string @[proto: 1]
	age  int    @[proto: 2]
}

struct BoolMessage {
	active bool   @[proto: 1]
	name   string @[proto: 2]
}

struct BytesMessage {
	data []u8   @[proto: 1]
	name string @[proto: 2]
}

struct EmptyMessage {}

struct AllTypesMessage {
	a_string string @[proto: 1]
	a_int    int    @[proto: 2]
	a_i64    i64    @[proto: 3]
	a_u32    u32    @[proto: 4]
	a_u64    u64    @[proto: 5]
	a_bool   bool   @[proto: 6]
	a_f32    f32    @[proto: 7]
	a_f64    f64    @[proto: 8]
	a_bytes  []u8   @[proto: 9]
}

fn test_marshal_unmarshal_basic() {
	msg := SimpleMessage{
		name: 'hello'
		age:  42
	}
	data := marshal(msg)!
	decoded := unmarshal[SimpleMessage](data)!
	assert decoded.name == 'hello'
	assert decoded.age == 42
}

fn test_marshal_unmarshal_bool_true() {
	msg := BoolMessage{
		active: true
		name:   'test'
	}
	data := marshal(msg)!
	decoded := unmarshal[BoolMessage](data)!
	assert decoded.active == true
	assert decoded.name == 'test'
}

fn test_marshal_unmarshal_bool_false() {
	// proto3: false is default, should be skipped in encoding
	msg := BoolMessage{
		active: false
		name:   'test'
	}
	data := marshal(msg)!
	decoded := unmarshal[BoolMessage](data)!
	assert decoded.active == false
	assert decoded.name == 'test'
}

fn test_marshal_unmarshal_bytes() {
	msg := BytesMessage{
		data: [u8(0xDE), 0xAD, 0xBE, 0xEF]
		name: 'binary'
	}
	data := marshal(msg)!
	decoded := unmarshal[BytesMessage](data)!
	assert decoded.data == [u8(0xDE), 0xAD, 0xBE, 0xEF]
	assert decoded.name == 'binary'
}

fn test_marshal_empty_struct() {
	msg := EmptyMessage{}
	data := marshal(msg)!
	assert data.len == 0
}

fn test_marshal_zero_values_skipped() {
	// Proto3: zero/default values are not serialized
	msg := SimpleMessage{
		name: ''
		age:  0
	}
	data := marshal(msg)!
	assert data.len == 0
}

fn test_marshal_unmarshal_all_types() {
	msg := AllTypesMessage{
		a_string: 'hello'
		a_int:    42
		a_i64:    i64(9999999999)
		a_u32:    u32(100)
		a_u64:    u64(200)
		a_bool:   true
		a_f32:    f32(3.14)
		a_f64:    f64(2.718281828)
		a_bytes:  [u8(1), 2, 3]
	}
	data := marshal(msg)!
	decoded := unmarshal[AllTypesMessage](data)!
	assert decoded.a_string == 'hello'
	assert decoded.a_int == 42
	assert decoded.a_i64 == i64(9999999999)
	assert decoded.a_u32 == u32(100)
	assert decoded.a_u64 == u64(200)
	assert decoded.a_bool == true
	assert decoded.a_bytes == [u8(1), 2, 3]
}

fn test_marshal_wire_format_correctness() {
	// Verify the actual wire format bytes for a known message
	msg := SimpleMessage{
		name: 'hi'
		age:  1
	}
	data := marshal(msg)!
	// field 1, wire type 2 (length-delimited): tag=0x0a
	assert data[0] == 0x0a
	// length of "hi" = 2: 0x02
	assert data[1] == 0x02
	// "hi" bytes
	assert data[2] == u8(`h`)
	assert data[3] == u8(`i`)
	// field 2, wire type 0 (varint): tag=0x10
	assert data[4] == 0x10
	// value 1
	assert data[5] == 0x01
}
