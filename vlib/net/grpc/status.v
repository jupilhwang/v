module grpc

import encoding.base64
import encoding.proto

// gRPC status codes per https://grpc.io/docs/guides/status-codes/
pub enum StatusCode {
	ok                  = 0
	cancelled           = 1
	unknown             = 2
	invalid_argument    = 3
	deadline_exceeded   = 4
	not_found           = 5
	already_exists      = 6
	permission_denied   = 7
	resource_exhausted  = 8
	failed_precondition = 9
	aborted             = 10
	out_of_range        = 11
	unimplemented       = 12
	internal            = 13
	unavailable         = 14
	data_loss           = 15
	unauthenticated     = 16
}

// Status represents a gRPC call status with optional rich error details
pub struct Status {
pub:
	code    StatusCode
	message string
	details [][]u8
}

// Create a new Status
pub fn new_status(code StatusCode, message string) Status {
	return Status{
		code: code
		message: message
	}
}

// Convenience: OK status
pub fn status_ok() Status {
	return Status{
		code: .ok
		message: 'OK'
	}
}

// Convenience: error status
pub fn status_error(code StatusCode, message string) Status {
	return Status{
		code: code
		message: message
	}
}

// Check if status is OK
pub fn (s Status) is_ok() bool {
	return s.code == .ok
}

// String representation
pub fn (s Status) str() string {
	return '${s.code}: ${s.message}'
}

// Convert StatusCode to string name
pub fn (c StatusCode) str() string {
	return match c {
		.ok { 'ok' }
		.cancelled { 'cancelled' }
		.unknown { 'unknown' }
		.invalid_argument { 'invalid_argument' }
		.deadline_exceeded { 'deadline_exceeded' }
		.not_found { 'not_found' }
		.already_exists { 'already_exists' }
		.permission_denied { 'permission_denied' }
		.resource_exhausted { 'resource_exhausted' }
		.failed_precondition { 'failed_precondition' }
		.aborted { 'aborted' }
		.out_of_range { 'out_of_range' }
		.unimplemented { 'unimplemented' }
		.internal { 'internal' }
		.unavailable { 'unavailable' }
		.data_loss { 'data_loss' }
		.unauthenticated { 'unauthenticated' }
	}
}

// --- Rich error details support (google.rpc.Status wire format) ---

// status_code_from_int converts an integer to a StatusCode
pub fn status_code_from_int(code int) StatusCode {
	if code < 0 || code > 16 {
		return .unknown
	}
	return unsafe { StatusCode(code) }
}

// Create a Status with rich error details
pub fn new_status_with_details(code StatusCode, message string, details [][]u8) Status {
	return Status{
		code: code
		message: message
		details: details
	}
}

// Encode status to google.rpc.Status proto wire format.
// Proto3: field 1 (int32 code), field 2 (string message),
// field 3 (repeated Any details). Default values are omitted.
pub fn (s &Status) encode_details_bin() ![]u8 {
	mut buf := []u8{}
	code_val := int(s.code)
	if code_val != 0 {
		buf << proto.encode_tag(1, .varint)
		buf << proto.encode_varint(u64(code_val))
	}
	if s.message.len > 0 {
		buf << proto.encode_length_delimited(2, s.message.bytes())
	}
	for detail in s.details {
		buf << proto.encode_length_delimited(3, detail)
	}
	return buf
}

// Decode google.rpc.Status proto wire format to Status.
// Handles repeated field 3 for multiple detail entries.
pub fn decode_status_details_bin(data []u8) !Status {
	if data.len == 0 {
		return Status{}
	}
	mut code_val := 0
	mut message := ''
	mut details := [][]u8{}
	mut pos := 0
	for pos < data.len {
		field_num, wire_type, tag_size := proto.decode_tag(data[pos..])!
		pos += tag_size
		match field_num {
			1 {
				if wire_type != .varint {
					return error('expected varint for code field')
				}
				val, consumed := proto.decode_varint(data[pos..])!
				code_val = int(val)
				pos += consumed
			}
			2 {
				raw, end_pos := read_length_field(data, pos, wire_type)!
				message = raw.bytestr()
				pos = end_pos
			}
			3 {
				raw, end_pos := read_length_field(data, pos, wire_type)!
				details << raw
				pos = end_pos
			}
			else {
				pos = skip_unknown_field(data, pos, wire_type)!
			}
		}
	}
	if code_val < 0 || code_val > 16 {
		return error('invalid status code: ${code_val}')
	}
	return Status{
		code: unsafe { StatusCode(code_val) }
		message: message
		details: details
	}
}

// Read a length-delimited field value and return (bytes, new_position)
fn read_length_field(data []u8, pos int, wire_type proto.WireType) !([]u8, int) {
	if wire_type != .length_delimited {
		return error('expected length-delimited wire type')
	}
	length, size := proto.decode_varint(data[pos..])!
	start := pos + size
	end := start + int(length)
	if end > data.len {
		return error('length-delimited field exceeds data bounds')
	}
	return data[start..end].clone(), end
}

// Skip an unknown field during proto wire format parsing
fn skip_unknown_field(data []u8, pos int, wire_type proto.WireType) !int {
	match wire_type {
		.varint {
			_, consumed := proto.decode_varint(data[pos..])!
			return pos + consumed
		}
		.length_delimited {
			length, size := proto.decode_varint(data[pos..])!
			return pos + size + int(length)
		}
		.fixed_32 { return pos + 4 }
		.fixed_64 { return pos + 8 }
	}
}

// Encode status details as base64 trailer value (no padding per gRPC spec)
pub fn (s &Status) encode_trailer_value() !string {
	data := s.encode_details_bin()!
	encoded := base64.encode(data)
	return encoded.trim_right('=')
}

// Decode base64 trailer value to Status
pub fn decode_trailer_value(value string) !Status {
	if value.len == 0 {
		return decode_status_details_bin([]u8{})
	}
	if !is_valid_base64_chars(value) {
		return error('invalid base64 characters in trailer value')
	}
	remainder := value.len % 4
	if remainder == 1 {
		return error('invalid base64 length in trailer value')
	}
	padded := match remainder {
		2 { value + '==' }
		3 { value + '=' }
		else { value }
	}
	data := base64.decode(padded)
	return decode_status_details_bin(data)
}

// Validate that a string contains only valid standard base64 characters
fn is_valid_base64_chars(s string) bool {
	for c in s.bytes() {
		is_alpha := (c >= `A` && c <= `Z`) || (c >= `a` && c <= `z`)
		is_digit := c >= `0` && c <= `9`
		is_special := c == `+` || c == `/`
		if !is_alpha && !is_digit && !is_special {
			return false
		}
	}
	return true
}
