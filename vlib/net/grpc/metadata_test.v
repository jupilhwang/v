module grpc

fn test_metadata_add_and_get() {
	mut md := new_metadata()
	md.add('content-type', 'application/grpc')!
	val := md.get('content-type') or {
		assert false, 'expected value for content-type'
		return
	}
	assert val == 'application/grpc'
	assert md.len() == 1
}

fn test_metadata_get_all() {
	mut md := new_metadata()
	md.add('x-custom', 'value1')!
	md.add('x-custom', 'value2')!
	md.add('x-other', 'value3')!
	vals := md.get_all('x-custom')
	assert vals.len == 2
	assert vals[0] == 'value1'
	assert vals[1] == 'value2'
}

fn test_metadata_add_binary() {
	mut md := new_metadata()
	md.add_binary('data-bin', [u8(0xDE), 0xAD])!
	// Binary values are base64-encoded when stored
	val := md.get('data-bin') or {
		assert false, 'expected value for data-bin'
		return
	}
	assert val.len > 0
}

fn test_metadata_get_binary() {
	mut md := new_metadata()
	md.add_binary('data-bin', [u8(0xDE), 0xAD, 0xBE, 0xEF])!
	decoded := md.get_binary('data-bin') or {
		assert false, 'expected binary value for data-bin'
		return
	}
	assert decoded == [u8(0xDE), 0xAD, 0xBE, 0xEF]
}

fn test_metadata_from_pairs() {
	md := metadata_from_pairs(MetadataPair{
		key: 'k1'
		value: 'v1'
	}, MetadataPair{
		key: 'k2'
		value: 'v2'
	})
	assert md.len() == 2
	v1 := md.get('k1') or {
		assert false, 'expected k1'
		return
	}
	assert v1 == 'v1'
}

fn test_validate_metadata_key() {
	// Valid keys
	assert validate_metadata_key('content-type') == true
	assert validate_metadata_key('x_custom_key') == true
	assert validate_metadata_key('abc123') == true
	assert validate_metadata_key('key.name') == true
	// Invalid keys
	assert validate_metadata_key('') == false
	assert validate_metadata_key('UPPERCASE') == false
	assert validate_metadata_key('has space') == false
	assert validate_metadata_key('special!char') == false
}

fn test_metadata_reserved_prefix() {
	// Keys starting with "grpc-" are reserved
	assert validate_metadata_key('grpc-timeout') == false
	assert validate_metadata_key('grpc-encoding') == false
	// "grpc" without dash is allowed
	assert validate_metadata_key('grpcstuff') == true
}

fn test_add_rejects_invalid_key() {
	mut md := new_metadata()
	md.add('UPPERCASE', 'value') or {
		assert err.msg().contains('invalid metadata key')
		return
	}
	assert false, 'uppercase key should be rejected by add()'
}

fn test_add_rejects_reserved_prefix() {
	mut md := new_metadata()
	md.add('grpc-timeout', '1000') or {
		assert err.msg().contains('invalid metadata key')
		return
	}
	assert false, 'grpc- prefix key should be rejected by add()'
}

fn test_add_binary_requires_bin_suffix() {
	mut md := new_metadata()
	md.add_binary('no-suffix', [u8(0x01)]) or {
		assert err.msg().contains('-bin')
		return
	}
	assert false, 'key without -bin suffix should be rejected by add_binary()'
}

fn test_add_binary_rejects_invalid_base_key() {
	mut md := new_metadata()
	md.add_binary('INVALID-bin', [u8(0x01)]) or {
		assert err.msg().contains('invalid metadata key')
		return
	}
	assert false, 'invalid base key should be rejected by add_binary()'
}
