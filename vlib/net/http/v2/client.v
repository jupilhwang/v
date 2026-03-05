// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

import net
import net.ssl
import time

// Method represents HTTP request methods.
// Note: this enum mirrors net.http.Method and exists independently to avoid
// circular imports between net.http and net.http.v2.
// TODO: Unify with net.http.Method once cross-module import constraints allow.
pub enum Method {
	get
	post
	put
	patch
	delete
	head
	options
}

// str returns the string representation of the HTTP method
pub fn (m Method) str() string {
	return match m {
		.get { 'GET' }
		.post { 'POST' }
		.put { 'PUT' }
		.patch { 'PATCH' }
		.delete { 'DELETE' }
		.head { 'HEAD' }
		.options { 'OPTIONS' }
	}
}

// Request represents a simplified HTTP/2 request
pub struct Request {
pub:
	method  Method
	url     string
	host    string
	data    string
	headers map[string]string
}

// Response represents a simplified HTTP/2 response
pub struct Response {
pub:
	status_code int
	headers     map[string]string
	body        string
}

// Connection represents an HTTP/2 connection with full duplex streaming over TLS
pub struct Connection {
mut:
	// ssl_conn is always non-nil after new_client() completes its TLS handshake;
	// it must never be used before new_client() returns.
	ssl_conn           &ssl.SSLConn = unsafe { nil }
	encoder            Encoder
	decoder            Decoder
	streams            map[u32]&Stream
	next_stream_id     u32 = 1
	settings           Settings
	remote_settings    Settings
	window_size        i64 = 65535
	remote_window_size i64 = 65535
	last_stream_id     u32
	closed             bool
	// Flow control: track inbound data to replenish the receive window
	recv_window          i64 = 65535
	recv_window_consumed i64
}

// Settings holds HTTP/2 connection settings per RFC 7540 Section 6.5
pub struct Settings {
pub mut:
	header_table_size      u32  = 4096
	enable_push            bool = true
	max_concurrent_streams u32  = 100
	initial_window_size    u32  = 65535
	max_frame_size         u32  = 16384
	max_header_list_size   u32 // 0 = unlimited
}

// Stream represents an HTTP/2 stream with flow control
pub struct Stream {
pub mut:
	id          u32
	state       StreamState
	window_size i64 = 65535
	headers     []HeaderField
	data        []u8
	end_stream  bool
	end_headers bool
	// raw_header_block accumulates header block fragments when HEADERS arrives
	// without END_HEADERS; cleared once END_HEADERS is seen on a CONTINUATION frame.
	raw_header_block []u8
}

// StreamState represents HTTP/2 stream states per RFC 7540 Section 5.1
pub enum StreamState {
	idle
	reserved_local
	reserved_remote
	open
	half_closed_local
	half_closed_remote
	closed
}

// ClientConfig holds configuration options for the HTTP/2 client
pub struct ClientConfig {
pub:
	// response_timeout is the maximum time to wait for a complete response.
	// A zero value is treated as 30 seconds by response_timeout_duration().
	response_timeout time.Duration
}

// Client represents an HTTP/2 client
// TODO: buffer pooling can be added later for performance (see optimization.v BufferPool)
pub struct Client {
mut:
	conn   Connection
	config ClientConfig
}

// new_client creates a new HTTP/2 client with TLS + ALPN 'h2' negotiation,
// connection preface, and settings exchange.
// The address should be in the form 'hostname:port' (e.g. 'example.com:443').
pub fn new_client(address string) !Client {
	host, port := net.split_address(address)!

	// Create TLS connection with ALPN 'h2' for HTTP/2 negotiation (RFC 7540 Section 3.3)
	mut ssl_conn := ssl.new_ssl_conn(
		alpn_protocols: ['h2']
	)!
	ssl_conn.dial(host, port)!

	// Send HTTP/2 connection preface over TLS (PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n)
	ssl_conn.write_string(preface)!

	// Initialize connection with HPACK encoder/decoder
	mut conn := Connection{
		ssl_conn: ssl_conn
		encoder:  new_encoder()
		decoder:  new_decoder()
		settings: Settings{
			enable_push: false // clients must not enable push
		}
	}

	// Exchange SETTINGS frames
	conn.write_settings()!
	conn.read_settings()!

	return Client{
		conn: conn
	}
}

// new_client_with_config creates a new HTTP/2 client with custom configuration.
// The address should be in the form 'hostname:port' (e.g. 'example.com:443').
pub fn new_client_with_config(address string, config ClientConfig) !Client {
	mut client := new_client(address)!
	client.config = config
	return client
}

// close closes the HTTP/2 connection gracefully with GOAWAY frame.
// The last_stream_id field in the GOAWAY frame is set to the highest
// stream ID processed on this connection (RFC 7540 §6.8).
pub fn (mut c Client) close() {
	if c.conn.closed {
		return
	}

	// Encode last_stream_id into the GOAWAY payload (RFC 7540 §6.8)
	last_id := c.conn.last_stream_id
	goaway := Frame{
		header:  FrameHeader{
			length:     8
			frame_type: .goaway
			flags:      0
			stream_id:  0
		}
		payload: [
			u8((last_id >> 24) & 0x7f),
			u8(last_id >> 16),
			u8(last_id >> 8),
			u8(last_id),
			// error code = 0 (NO_ERROR)
			u8(0),
			u8(0),
			u8(0),
			u8(0),
		]
	}

	c.conn.write_frame(goaway) or {
		$if trace_http2 ? {
			eprintln('[HTTP/2] close: failed to send GOAWAY frame: ${err}')
		}
	}
	c.conn.ssl_conn.shutdown() or {
		$if trace_http2 ? {
			eprintln('[HTTP/2] close: TLS shutdown error: ${err}')
		}
	}
	c.conn.closed = true
}
