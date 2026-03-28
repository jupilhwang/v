module grpc

import encoding.base64

// Metadata holds gRPC metadata key-value pairs
// Keys are lowercase ASCII (alphanum + _-.)
// Keys ending in "-bin" have base64-encoded binary values
pub struct Metadata {
mut:
	pairs_ []MetadataPair
}

pub struct MetadataPair {
pub:
	key   string
	value string
}

// Create empty metadata
pub fn new_metadata() Metadata {
	return Metadata{}
}

// Create metadata from key-value pairs
pub fn metadata_from_pairs(input ...MetadataPair) Metadata {
	mut m := Metadata{}
	for p in input {
		m.pairs_ << p
	}
	return m
}

// Add a key-value pair
pub fn (mut m Metadata) add(key string, value string) ! {
	if !validate_metadata_key(key) {
		return error('invalid metadata key: ${key}')
	}
	m.pairs_ << MetadataPair{
		key: key
		value: value
	}
}

// Add a binary value (auto base64-encodes, key must end with "-bin")
pub fn (mut m Metadata) add_binary(key string, value []u8) ! {
	if !key.ends_with('-bin') {
		return error('binary metadata key must end with "-bin": ${key}')
	}
	if !validate_metadata_key(key) {
		return error('invalid metadata key: ${key}')
	}
	m.pairs_ << MetadataPair{
		key: key
		value: base64.encode(value)
	}
}

// Get first value for key
pub fn (m Metadata) get(key string) ?string {
	for p in m.pairs_ {
		if p.key == key {
			return p.value
		}
	}
	return none
}

// Get all values for key
pub fn (m Metadata) get_all(key string) []string {
	mut result := []string{}
	for p in m.pairs_ {
		if p.key == key {
			result << p.value
		}
	}
	return result
}

// Get binary value (auto base64-decodes, key must end with "-bin")
pub fn (m Metadata) get_binary(key string) ?[]u8 {
	encoded := m.get(key)?
	return base64.decode(encoded)
}

// Get all pairs
pub fn (m Metadata) pairs() []MetadataPair {
	return m.pairs_
}

// Number of pairs
pub fn (m Metadata) len() int {
	return m.pairs_.len
}

// Validate key format (lowercase alphanum + _-.)
// Keys starting with "grpc-" are reserved
fn validate_metadata_key(key string) bool {
	if key.len == 0 {
		return false
	}
	if key.starts_with('grpc-') {
		return false
	}
	for c in key {
		is_lower := c >= `a` && c <= `z`
		is_digit := c >= `0` && c <= `9`
		is_special := c == `_` || c == `-` || c == `.`
		if !is_lower && !is_digit && !is_special {
			return false
		}
	}
	return true
}
