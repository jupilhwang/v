module grpc

// Encoding tests: nanoseconds → gRPC timeout header string

fn test_encode_timeout_seconds() {
	assert encode_timeout(1_000_000_000) == '1S'
}

fn test_encode_timeout_milliseconds() {
	assert encode_timeout(500_000_000) == '500m'
}

fn test_encode_timeout_microseconds() {
	assert encode_timeout(100_000) == '100u'
}

fn test_encode_timeout_nanoseconds() {
	assert encode_timeout(123) == '123n'
}

fn test_encode_timeout_hours() {
	assert encode_timeout(3_600_000_000_000) == '1H'
}

fn test_encode_timeout_minutes() {
	assert encode_timeout(120_000_000_000) == '2M'
}

fn test_encode_timeout_prefers_largest_unit() {
	// 60 billion ns = 1 minute, should pick "1M" not "60S"
	assert encode_timeout(60_000_000_000) == '1M'
}

// Decoding tests: gRPC timeout header string → nanoseconds

fn test_decode_timeout_seconds() {
	result := decode_timeout('5S')!
	assert result == 5_000_000_000
}

fn test_decode_timeout_milliseconds() {
	result := decode_timeout('100m')!
	assert result == 100_000_000
}

fn test_decode_timeout_hours() {
	result := decode_timeout('2H')!
	assert result == 7_200_000_000_000
}

fn test_decode_timeout_nanoseconds() {
	result := decode_timeout('999n')!
	assert result == 999
}

fn test_decode_timeout_roundtrip() {
	// encode then decode should return the original value
	values := [i64(1_000_000_000), 500_000_000, 100_000, 123, 3_600_000_000_000,
		120_000_000_000]
	for v in values {
		encoded := encode_timeout(v)
		decoded := decode_timeout(encoded)!
		assert decoded == v
	}
}

// Error cases

fn test_decode_timeout_invalid_unit() {
	if _ := decode_timeout('5X') {
		assert false, 'expected error for invalid unit'
	}
}

fn test_decode_timeout_empty() {
	if _ := decode_timeout('') {
		assert false, 'expected error for empty string'
	}
}

fn test_decode_timeout_no_digits() {
	if _ := decode_timeout('S') {
		assert false, 'expected error for missing digits'
	}
}

fn test_decode_timeout_too_many_digits() {
	// gRPC spec: max 8 digits
	if _ := decode_timeout('123456789S') {
		assert false, 'expected error for >8 digits'
	}
}

// Struct and helper tests

fn test_timeout_struct_str() {
	t := Timeout{
		value: 5
		unit: .seconds
	}
	assert t.str() == '5S'
}

fn test_timeout_struct_str_hours() {
	t := Timeout{
		value: 10
		unit: .hours
	}
	assert t.str() == '10H'
}

fn test_timeout_struct_str_nanoseconds() {
	t := Timeout{
		value: 42
		unit: .nanoseconds
	}
	assert t.str() == '42n'
}

fn test_encode_timeout_zero() {
	assert encode_timeout(0) == '0n'
}
