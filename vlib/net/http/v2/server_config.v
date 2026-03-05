// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

import time

// ServerConfig holds server configuration
pub struct ServerConfig {
pub:
	addr                   string        = '0.0.0.0:8080'
	max_concurrent_streams u32           = 100
	initial_window_size    u32           = 65535
	max_frame_size         u32           = 16384
	read_timeout           time.Duration = 30 * time.second
	write_timeout          time.Duration = 30 * time.second
	// max_total_pending_bytes is the maximum total bytes of unread request body data
	// buffered across all streams in a single connection (default 100 MB).
	max_total_pending_bytes i64 = 100 * 1024 * 1024
}

// ServerRequest represents an HTTP/2 request
pub struct ServerRequest {
pub:
	method    string
	path      string
	headers   map[string]string
	body      []u8
	stream_id u32
}

// ServerResponse represents an HTTP/2 response
pub struct ServerResponse {
pub:
	status_code int = 200
	headers     map[string]string
	body        []u8
}

// Handler processes requests
pub type Handler = fn (ServerRequest) ServerResponse

// ClientSettings holds the peer's SETTINGS values parsed from its SETTINGS frame.
// These are tracked per RFC 7540 §6.5.2 and may affect encoding, flow control, etc.
pub struct ClientSettings {
pub mut:
	header_table_size      u32 = 4096 // SETTINGS_HEADER_TABLE_SIZE (0x1)
	max_concurrent_streams u32 // SETTINGS_MAX_CONCURRENT_STREAMS (0x3); 0 = no limit (initial)
	initial_window_size    u32 = 65535 // SETTINGS_INITIAL_WINDOW_SIZE (0x4)
	max_frame_size         u32 = 16384 // SETTINGS_MAX_FRAME_SIZE (0x5)
	max_header_list_size   u32 // SETTINGS_MAX_HEADER_LIST_SIZE (0x6); 0 = unlimited (initial)
}

// max_pending_data_size is the maximum number of bytes that may be accumulated
// for a single stream's DATA frames before a FLOW_CONTROL_ERROR is returned.
const max_pending_data_size = 10 * 1024 * 1024 // 10 MB

// ConnWindow holds the per-connection send flow-control window value.
// Wrapping the i64 in a struct allows it to be passed as a mutable reference
// across function boundaries (V only allows `mut` on structs, arrays, and maps).
struct ConnWindow {
mut:
	v i64
}

// FrameResult signals what the main frame-processing loop should do after
// handling a single frame.
enum FrameResult {
	cont  // keep looping
	close // graceful close, break loop
}

// ConnState holds the mutable per-connection state shared across frame-handler
// helpers. Bundling them in a struct lets V pass them by mutable reference.
struct ConnState {
mut:
	encoder             Encoder
	decoder             Decoder
	client_settings     ClientSettings
	pending_requests    map[u32]ServerRequest
	pending_data        map[u32][]u8
	hbs                 HeaderBlockState
	send_win            ConnWindow
	active_streams      u32
	total_pending_bytes i64
	last_stream_id      u32
}
