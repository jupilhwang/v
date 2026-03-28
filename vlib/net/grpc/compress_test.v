module grpc

fn test_gzip_compressor_name() {
	c := GzipCompressor{}
	assert c.name() == 'gzip'
}

fn test_gzip_compress_decompress_roundtrip() {
	c := GzipCompressor{}
	original := 'Hello, gRPC compression!'.bytes()
	compressed := c.compress(original) or {
		assert false, 'compress should not fail: ${err}'
		return
	}
	decompressed := c.decompress(compressed) or {
		assert false, 'decompress should not fail: ${err}'
		return
	}
	assert decompressed == original
}

fn test_gzip_compress_produces_different_output() {
	c := GzipCompressor{}
	original := 'abcdef'.repeat(100).bytes()
	compressed := c.compress(original) or {
		assert false, 'compress should not fail: ${err}'
		return
	}
	assert compressed != original
	assert compressed.len > 0
}

fn test_gzip_compress_empty() {
	c := GzipCompressor{}
	original := []u8{}
	compressed := c.compress(original) or {
		assert false, 'compress empty should not fail: ${err}'
		return
	}
	decompressed := c.decompress(compressed) or {
		assert false, 'decompress empty should not fail: ${err}'
		return
	}
	assert decompressed == original
}

fn test_identity_compressor_name() {
	c := IdentityCompressor{}
	assert c.name() == 'identity'
}

fn test_identity_compress_decompress_roundtrip() {
	c := IdentityCompressor{}
	original := 'Hello, identity!'.bytes()
	compressed := c.compress(original) or {
		assert false, 'compress should not fail: ${err}'
		return
	}
	assert compressed == original
	decompressed := c.decompress(compressed) or {
		assert false, 'decompress should not fail: ${err}'
		return
	}
	assert decompressed == original
}

fn test_registry_default_compressors() {
	r := new_compressor_registry()
	gzip_c := r.get('gzip') or {
		assert false, 'gzip should be registered by default'
		return
	}
	assert gzip_c.name() == 'gzip'

	identity_c := r.get('identity') or {
		assert false, 'identity should be registered by default'
		return
	}
	assert identity_c.name() == 'identity'
}

fn test_registry_get_unknown_returns_none() {
	r := new_compressor_registry()
	result := r.get('snappy')
	assert result == none
}

fn test_registry_register_custom() {
	mut r := new_compressor_registry()
	custom := IdentityCompressor{}
	r.register(custom)
	result := r.get('identity') or {
		assert false, 'custom compressor should be retrievable'
		return
	}
	assert result.name() == 'identity'
}

fn test_supported_encodings() {
	r := new_compressor_registry()
	encodings := r.supported_encodings()
	assert encodings.contains('gzip')
	assert encodings.contains('identity')
	// Should be sorted and comma-separated
	assert encodings == 'gzip,identity'
}
