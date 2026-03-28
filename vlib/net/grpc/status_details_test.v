module grpc

fn test_status_with_details_creation() {
	detail1 := [u8(0x0a), 0x03, 0x66, 0x6f, 0x6f]
	detail2 := [u8(0x0a), 0x03, 0x62, 0x61, 0x72]
	s := new_status_with_details(.internal, 'server error', [detail1, detail2])
	assert s.code == .internal
	assert s.message == 'server error'
	assert s.details.len == 2
	assert s.details[0] == detail1
	assert s.details[1] == detail2
}

fn test_encode_details_bin_minimal() {
	s := new_status_with_details(.not_found, 'not found', [])
	data := s.encode_details_bin()!
	// Field 1 (code=5): tag=0x08, varint=0x05
	assert data[0] == 0x08
	assert data[1] == 0x05
	// Field 2 (message='not found'): tag=0x12, length=0x09
	assert data[2] == 0x12
	assert data[3] == 0x09
	assert data[4..13] == 'not found'.bytes()
	assert data.len == 13
}

fn test_encode_decode_details_bin_roundtrip() {
	original := new_status_with_details(.permission_denied, 'access denied', [])
	data := original.encode_details_bin()!
	decoded := decode_status_details_bin(data)!
	assert decoded.code == original.code
	assert decoded.message == original.message
	assert decoded.details.len == 0
}

fn test_encode_decode_with_details_roundtrip() {
	detail1 := [u8(0x0a), 0x03, 0x66, 0x6f, 0x6f]
	detail2 := [u8(0x12), 0x03, 0x62, 0x61, 0x72]
	original := new_status_with_details(.internal, 'error', [detail1, detail2])
	data := original.encode_details_bin()!
	decoded := decode_status_details_bin(data)!
	assert decoded.code == original.code
	assert decoded.message == original.message
	assert decoded.details.len == 2
	assert decoded.details[0] == detail1
	assert decoded.details[1] == detail2
}

fn test_encode_trailer_value_base64() {
	s := new_status_with_details(.not_found, 'x', [])
	trailer := s.encode_trailer_value()!
	assert !trailer.contains('=')
	assert trailer.len > 0
}

fn test_decode_trailer_value_roundtrip() {
	original := new_status_with_details(.unavailable, 'try again', [[u8(0xff)]])
	trailer := original.encode_trailer_value()!
	decoded := decode_trailer_value(trailer)!
	assert decoded.code == original.code
	assert decoded.message == original.message
	assert decoded.details.len == 1
	assert decoded.details[0] == [u8(0xff)]
}

fn test_decode_invalid_base64_returns_error() {
	decode_trailer_value('!!!invalid!!!') or {
		assert err.msg().contains('base64')
		return
	}
	assert false, 'expected error for invalid base64'
}

fn test_status_ok_has_empty_details() {
	s := status_ok()
	assert s.details.len == 0
}

fn test_encode_empty_details() {
	s := new_status_with_details(.ok, '', [])
	data := s.encode_details_bin()!
	// All fields at default values → proto3 omits all → empty
	assert data.len == 0
}
