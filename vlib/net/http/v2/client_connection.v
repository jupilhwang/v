// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

import net.ssl

// write_settings sends a SETTINGS frame to configure connection parameters
pub fn (mut c Connection) write_settings() ! {
	// Pre-allocate payload with exact size (5 settings * 6 bytes each = 30 bytes)
	mut payload := []u8{cap: 30}

	// Helper function to encode a setting
	encode_setting := fn (mut payload []u8, id SettingId, value u32) {
		payload << u8(u16(id) >> 8)
		payload << u8(u16(id))
		payload << u8(value >> 24)
		payload << u8(value >> 16)
		payload << u8(value >> 8)
		payload << u8(value)
	}

	// Encode each setting
	encode_setting(mut payload, .header_table_size, c.settings.header_table_size)
	encode_setting(mut payload, .enable_push, if c.settings.enable_push { u32(1) } else { u32(0) })
	encode_setting(mut payload, .max_concurrent_streams, c.settings.max_concurrent_streams)
	encode_setting(mut payload, .initial_window_size, c.settings.initial_window_size)
	encode_setting(mut payload, .max_frame_size, c.settings.max_frame_size)

	frame := Frame{
		header:  FrameHeader{
			length:     u32(payload.len)
			frame_type: .settings
			flags:      0
			stream_id:  0
		}
		payload: payload
	}

	c.write_frame(frame)!
}

// read_settings reads and processes a SETTINGS frame from the server,
// skipping over non-SETTINGS frames (e.g. WINDOW_UPDATE) that may precede it.
pub fn (mut c Connection) read_settings() ! {
	// Limit the number of frames to read before receiving SETTINGS
	// to prevent infinite loop if the server never sends one.
	max_frames := 10
	for frame_count := 0; frame_count < max_frames; frame_count++ {
		frame := c.read_frame()!

		match frame.header.frame_type {
			.settings {
				if frame.header.has_flag(.ack) {
					// ACK frame has no payload
					return
				}
				c.apply_settings_payload(frame.payload)!
				// Send SETTINGS ACK
				c.write_frame(new_settings_ack())!
				return
			}
			.window_update {
				c.apply_connection_window_update(frame)!
				continue
			}
			.goaway {
				mut error_code := u32(0)
				if frame.payload.len >= 8 {
					error_code = read_be_u32(frame.payload[4..8])
				}
				debug_data := if frame.payload.len > 8 {
					frame.payload[8..].bytestr()
				} else {
					''
				}
				return error('server sent GOAWAY (error code: ${error_code}, debug: ${debug_data})')
			}
			else {
				// Skip unexpected frames during setup
				continue
			}
		}
	}
	return error('did not receive SETTINGS frame within ${max_frames} frames')
}

// apply_settings_payload parses and applies settings from a SETTINGS frame payload.
// Per RFC 7540 §6.5.2, unknown settings are ignored.
fn (mut c Connection) apply_settings_payload(payload []u8) ! {
	// Parse settings (each setting is 6 bytes: 2-byte ID + 4-byte value)
	mut idx := 0
	for idx < payload.len {
		if idx + 6 > payload.len {
			return error('invalid SETTINGS frame: incomplete setting at byte ${idx}')
		}

		id := (u16(payload[idx]) << 8) | u16(payload[idx + 1])
		value := read_be_u32(payload[idx + 2..idx + 6])

		setting_id := setting_id_from_u16(id) or {
			// Per RFC 7540 Section 6.5.2, unknown settings must be ignored
			idx += 6
			continue
		}

		c.apply_single_setting(setting_id, value)!
		idx += 6
	}
}

// apply_single_setting validates and applies a single setting value to remote_settings.
fn (mut c Connection) apply_single_setting(setting_id SettingId, value u32) ! {
	match setting_id {
		.initial_window_size {
			// Values above 2^31-1 are a flow-control error (RFC 7540 §6.5.2)
			if value > 0x7fffffff {
				return error('SETTINGS_INITIAL_WINDOW_SIZE ${value} exceeds 2^31-1 (FLOW_CONTROL_ERROR)')
			}
			c.remote_settings.initial_window_size = value
		}
		.max_frame_size {
			// Valid range: [16384, 16777215] (RFC 7540 §6.5.2)
			if value < 16384 || value > 16777215 {
				return error('SETTINGS_MAX_FRAME_SIZE ${value} outside valid range [16384, 16777215] (PROTOCOL_ERROR)')
			}
			c.remote_settings.max_frame_size = value
		}
		.enable_push {
			// Only 0 or 1 are valid (RFC 7540 §6.5.2)
			if value != 0 && value != 1 {
				return error('SETTINGS_ENABLE_PUSH ${value} must be 0 or 1 (PROTOCOL_ERROR)')
			}
			c.remote_settings.enable_push = value != 0
		}
		.header_table_size {
			c.remote_settings.header_table_size = value
		}
		.max_concurrent_streams {
			c.remote_settings.max_concurrent_streams = value
		}
		.max_header_list_size {
			c.remote_settings.max_header_list_size = value
		}
	}
}

// apply_connection_window_update processes a WINDOW_UPDATE frame at connection level.
// Stream-level WINDOW_UPDATE during settings exchange is intentionally dropped:
// no streams are open, so there is nothing to update.
fn (mut c Connection) apply_connection_window_update(frame Frame) ! {
	if frame.header.stream_id == 0 && frame.payload.len >= 4 {
		increment := i64(read_be_u32(frame.payload)) & 0x7fffffff
		if increment == 0 {
			return error('PROTOCOL_ERROR: zero WINDOW_UPDATE increment')
		}
		if c.remote_window_size + increment > 0x7FFFFFFF {
			return error('FLOW_CONTROL_ERROR: flow control window overflow')
		}
		c.remote_window_size += increment
	}
}

// write_frame writes an HTTP/2 frame to the TLS connection
fn (mut c Connection) write_frame(frame Frame) ! {
	data := frame.encode()
	$if trace_http2 ? {
		eprintln('[HTTP/2] write frame: type=${frame.header.frame_type} len=${frame.header.length} flags=0x${frame.header.flags:02x} stream=${frame.header.stream_id} raw_len=${data.len}')
	}
	c.ssl_conn.write(data)!
}

// read_frame reads an HTTP/2 frame from the TLS connection.
// Unknown frame types are silently discarded per RFC 7540 §4.1.
fn (mut c Connection) read_frame() !Frame {
	for {
		mut header_buf := []u8{len: frame_header_size}
		read_exact(mut c.ssl_conn, mut header_buf)!

		payload_len := (u32(header_buf[0]) << 16) | (u32(header_buf[1]) << 8) | u32(header_buf[2])

		if header := parse_frame_header(header_buf) {
			// Validate payload size against our local max_frame_size to prevent
			// excessive memory allocation from a malicious or misbehaving server.
			// SETTINGS frames are connection-level control frames; we apply a generous
			// upper bound (10 * 6 bytes per setting) rather than the data-frame limit.
			max_allowed := if header.frame_type == .settings {
				max_settings_payload_size
			} else {
				c.settings.max_frame_size
			}
			if header.length > max_allowed {
				return error('frame size ${header.length} exceeds local max_frame_size ${max_allowed}')
			}

			mut payload := []u8{len: int(header.length)}
			if header.length > 0 {
				read_exact(mut c.ssl_conn, mut payload)!
			}

			$if trace_http2 ? {
				eprintln('[HTTP/2] read frame: type=${header.frame_type} len=${header.length} flags=0x${header.flags:02x} stream=${header.stream_id}')
			}

			return Frame{
				header:  header
				payload: payload
			}
		} else {
			// RFC 7540 §4.1: unknown frame type — discard payload and continue
			if payload_len > 0 {
				mut discard := []u8{len: int(payload_len)}
				read_exact(mut c.ssl_conn, mut discard) or {}
			}
			$if trace_http2 ? {
				eprintln('[HTTP/2] discarded unknown frame type, len=${payload_len}')
			}
			continue
		}
	}
	return error('unreachable')
}

// read_exact reads exactly buf.len bytes from the SSL connection.
// SSL read may return fewer bytes than requested, so this loops until full.
fn read_exact(mut conn ssl.SSLConn, mut buf []u8) ! {
	mut total := 0
	for total < buf.len {
		n := conn.read(mut buf[total..]) or {
			if total == 0 {
				return err
			}
			return error('unexpected EOF after ${total} of ${buf.len} bytes')
		}
		if n == 0 {
			return error('unexpected EOF after ${total} of ${buf.len} bytes')
		}
		total += n
	}
}
