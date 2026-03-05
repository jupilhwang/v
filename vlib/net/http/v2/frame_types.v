// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// NOTE: The following structured frame types are defined for future use.
// Currently all frame processing works directly on Frame.payload bytes.
// These types will be integrated into the processing pipeline in a future version.

// DataFrame represents the payload of an HTTP/2 DATA frame (RFC 7540 §6.1).
// Available for structured frame handling.
// TODO: integrate structured frame types into processing pipeline
pub struct DataFrame {
pub mut:
	stream_id  u32
	data       []u8
	end_stream bool
	padded     bool
	pad_length u8
}

// HeadersFrame represents the payload of an HTTP/2 HEADERS frame (RFC 7540 §6.2).
// Available for structured frame handling.
// TODO: integrate structured frame types into processing pipeline
pub struct HeadersFrame {
pub mut:
	stream_id   u32
	headers     []u8 // Encoded header block
	end_stream  bool
	end_headers bool
	padded      bool
	priority    bool
	pad_length  u8
	stream_dep  u32
	weight      u8
	exclusive   bool
}

// SettingsFrame represents the payload of an HTTP/2 SETTINGS frame (RFC 7540 §6.5).
// Available for structured frame handling.
// TODO: integrate structured frame types into processing pipeline
pub struct SettingsFrame {
pub mut:
	ack      bool
	settings map[u16]u32
}

// SettingId represents setting identifiers per RFC 7540 Section 6.5.2
pub enum SettingId as u16 {
	header_table_size      = 0x1
	enable_push            = 0x2
	max_concurrent_streams = 0x3
	initial_window_size    = 0x4
	max_frame_size         = 0x5
	max_header_list_size   = 0x6
}

// PingFrame represents the payload of an HTTP/2 PING frame (RFC 7540 §6.7).
// Available for structured frame handling.
// TODO: integrate structured frame types into processing pipeline
pub struct PingFrame {
pub mut:
	ack  bool
	data [8]u8
}

// GoAwayFrame represents the payload of an HTTP/2 GOAWAY frame (RFC 7540 §6.8).
// Available for structured frame handling.
// TODO: integrate structured frame types into processing pipeline
pub struct GoAwayFrame {
pub mut:
	last_stream_id u32
	error_code     ErrorCode
	debug_data     []u8
}

// WindowUpdateFrame represents the payload of an HTTP/2 WINDOW_UPDATE frame (RFC 7540 §6.9).
// Available for structured frame handling.
// TODO: integrate structured frame types into processing pipeline
pub struct WindowUpdateFrame {
pub mut:
	stream_id        u32
	window_increment u32
}

// RstStreamFrame represents the payload of an HTTP/2 RST_STREAM frame (RFC 7540 §6.4).
// Available for structured frame handling.
// TODO: integrate structured frame types into processing pipeline
pub struct RstStreamFrame {
pub mut:
	stream_id  u32
	error_code ErrorCode
}

// setting_id_from_u16 converts a u16 to a SettingId enum value.
// Returns none for unknown or unsupported identifiers — per RFC 7540 §6.5.2,
// endpoints MUST ignore settings with unknown identifiers.
pub fn setting_id_from_u16(id u16) ?SettingId {
	return match id {
		0x1 { .header_table_size }
		0x2 { .enable_push }
		0x3 { .max_concurrent_streams }
		0x4 { .initial_window_size }
		0x5 { .max_frame_size }
		0x6 { .max_header_list_size }
		else { none }
	}
}
