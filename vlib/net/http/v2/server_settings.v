// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

import net

// write_settings sends the server's initial SETTINGS frame with a pre-allocated buffer.
fn (mut s Server) write_settings(mut conn net.TcpConn) ! {
	// Pre-allocate payload with exact size (3 settings * 6 bytes = 18 bytes)
	mut payload := []u8{cap: 18}

	// SETTINGS_MAX_CONCURRENT_STREAMS (0x03)
	payload << [u8(0), u8(3)]
	payload << [u8(s.config.max_concurrent_streams >> 24), u8(s.config.max_concurrent_streams >> 16),
		u8(s.config.max_concurrent_streams >> 8), u8(s.config.max_concurrent_streams)]

	// SETTINGS_INITIAL_WINDOW_SIZE (0x04)
	payload << [u8(0), u8(4)]
	payload << [u8(s.config.initial_window_size >> 24), u8(s.config.initial_window_size >> 16),
		u8(s.config.initial_window_size >> 8), u8(s.config.initial_window_size)]

	// SETTINGS_MAX_FRAME_SIZE (0x05)
	payload << [u8(0), u8(5)]
	payload << [u8(s.config.max_frame_size >> 24), u8(s.config.max_frame_size >> 16),
		u8(s.config.max_frame_size >> 8), u8(s.config.max_frame_size)]

	frame := Frame{
		header:  FrameHeader{
			length:     u32(payload.len)
			frame_type: .settings
			flags:      0
			stream_id:  0
		}
		payload: payload
	}

	s.write_frame(mut conn, frame)!
	$if trace_http2 ? {
		eprintln('[HTTP/2] Sent SETTINGS')
	}
}

// apply_settings_value validates and applies a single SETTINGS key-value pair.
fn apply_settings_value(id u16, val u32, mut cs ClientSettings) ! {
	match id {
		u16(SettingId.header_table_size) {
			// Any value is valid per RFC 7540 §6.5.2
			cs.header_table_size = val
		}
		u16(SettingId.enable_push) {
			// Only 0 or 1 are valid (RFC 7540 §6.5.2)
			if val != 0 && val != 1 {
				return error('SETTINGS_ENABLE_PUSH ${val} must be 0 or 1 (PROTOCOL_ERROR)')
			}
		}
		u16(SettingId.max_concurrent_streams) {
			// Any value is valid per RFC 7540 §6.5.2
			cs.max_concurrent_streams = val
		}
		u16(SettingId.initial_window_size) {
			// Values above 2^31-1 are a flow-control error (RFC 7540 §6.5.2)
			if val > 0x7fffffff {
				return error('SETTINGS_INITIAL_WINDOW_SIZE ${val} exceeds 2^31-1 (FLOW_CONTROL_ERROR)')
			}
			cs.initial_window_size = val
		}
		u16(SettingId.max_frame_size) {
			// Valid range: [16384, 16777215] (RFC 7540 §6.5.2)
			if val < 16384 || val > 16777215 {
				return error('SETTINGS_MAX_FRAME_SIZE ${val} outside valid range [16384, 16777215] (PROTOCOL_ERROR)')
			}
			cs.max_frame_size = val
		}
		u16(SettingId.max_header_list_size) {
			// Any value is valid per RFC 7540 §6.5.2
			cs.max_header_list_size = val
		}
		else {
			// Unknown setting identifiers must be ignored per RFC 7540 §6.5
		}
	}
}

// handle_settings processes a SETTINGS frame from the client.
// If the frame is an ACK, it is silently accepted.
// Otherwise, each setting key-value pair is validated and applied to client_settings,
// and a SETTINGS ACK is sent back per RFC 7540 §6.5.
fn (mut s Server) handle_settings(mut conn net.TcpConn, frame Frame, mut client_settings ClientSettings) ! {
	// Check for ACK
	if frame.header.flags & u8(FrameFlags.ack) != 0 {
		$if trace_http2 ? {
			eprintln('[HTTP/2] Received SETTINGS ACK')
		}
		return
	}

	$if trace_http2 ? {
		eprintln('[HTTP/2] Received SETTINGS')
	}

	// Parse and validate client settings (each setting is 6 bytes: 2-byte ID + 4-byte value)
	payload := frame.payload
	mut i := 0
	for i + 6 <= payload.len {
		id := (u16(payload[i]) << 8) | u16(payload[i + 1])
		val := read_be_u32(payload[i + 2..i + 6])
		i += 6
		apply_settings_value(id, val, mut client_settings)!
	}

	// Send SETTINGS ACK
	s.write_frame(mut conn, new_settings_ack())!
	$if trace_http2 ? {
		eprintln('[HTTP/2] Sent SETTINGS ACK')
	}
}
