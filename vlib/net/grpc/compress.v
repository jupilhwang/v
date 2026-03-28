module grpc

import compress.gzip

// Compressor defines compression/decompression for gRPC messages (OCP)
pub interface Compressor {
	name() string
	compress(data []u8) ![]u8
	decompress(data []u8) ![]u8
}

// GzipCompressor implements gzip compression
pub struct GzipCompressor {}

pub fn (g GzipCompressor) name() string {
	return 'gzip'
}

pub fn (g GzipCompressor) compress(data []u8) ![]u8 {
	if data.len == 0 {
		return []u8{}
	}
	return gzip.compress(data) or { return error('gzip compress failed: ${err}') }
}

pub fn (g GzipCompressor) decompress(data []u8) ![]u8 {
	if data.len == 0 {
		return []u8{}
	}
	return gzip.decompress(data) or { return error('gzip decompress failed: ${err}') }
}

// IdentityCompressor passes data through unchanged
pub struct IdentityCompressor {}

pub fn (i IdentityCompressor) name() string {
	return 'identity'
}

pub fn (i IdentityCompressor) compress(data []u8) ![]u8 {
	return data.clone()
}

pub fn (i IdentityCompressor) decompress(data []u8) ![]u8 {
	return data.clone()
}

// CompressorRegistry stores available compressors by name (SRP)
pub struct CompressorRegistry {
mut:
	compressors map[string]Compressor
}

pub fn new_compressor_registry() CompressorRegistry {
	mut r := CompressorRegistry{}
	r.compressors['identity'] = IdentityCompressor{}
	r.compressors['gzip'] = GzipCompressor{}
	return r
}

pub fn (r &CompressorRegistry) get(name string) ?Compressor {
	return r.compressors[name] or { return none }
}

pub fn (mut r CompressorRegistry) register(c Compressor) {
	r.compressors[c.name()] = c
}

pub fn (r &CompressorRegistry) supported_encodings() string {
	mut names := []string{}
	for n, _ in r.compressors {
		names << n
	}
	names.sort()
	return names.join(',')
}
