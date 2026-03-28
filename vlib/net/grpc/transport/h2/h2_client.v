module h2

import net
import net.http.v2
import net.ssl
import net.grpc.transport

// StreamIdAllocator manages HTTP/2 client stream ID allocation.
// Client stream IDs are odd and increment by 2 (RFC 7540 §5.1.1).
pub struct StreamIdAllocator {
mut:
	next_id u32 = 1
}

// next returns the next available client stream ID.
pub fn (mut a StreamIdAllocator) next() u32 {
	id := a.next_id
	a.next_id += 2
	return id
}

// H2ClientTransport manages a client-side HTTP/2 connection for gRPC.
pub struct H2ClientTransport {
pub mut:
	conn                  RawConn
	encoder               v2.Encoder       = v2.new_encoder()
	decoder               v2.Decoder       = v2.new_decoder()
	stream_alloc          StreamIdAllocator
	closed                bool
	remote_max_frame_size u32 = v2.default_frame_size
	tls                   bool
}

// new_h2_client_transport connects to the address and performs HTTP/2 handshake.
pub fn new_h2_client_transport(address string) !&H2ClientTransport {
	mut conn := net.dial_tcp(address)!
	return new_h2_client_transport_with_conn(new_tcp_raw_conn(conn))
}

// new_h2_client_transport_with_conn creates a client transport from an existing RawConn.
// Enables injection of SSL or custom connections.
pub fn new_h2_client_transport_with_conn(conn RawConn) !&H2ClientTransport {
	mut t := &H2ClientTransport{
		conn: conn
	}
	t.handshake()!
	return t
}

// new_h2_tls_client_transport creates an HTTP/2 client over TLS with ALPN h2.
// Parses host:port from address, establishes SSL with ALPN ['h2'],
// wraps in SslRawConn, and delegates to new_h2_client_transport_with_conn.
pub fn new_h2_tls_client_transport(address string) !&H2ClientTransport {
	host, port := net.split_address(address)!
	mut sconn := ssl.new_ssl_conn(ssl.SSLConnectConfig{
		alpn_protocols: ['h2']
	})!
	sconn.dial(host, port)!
	raw := new_ssl_raw_conn(sconn)
	mut t := &H2ClientTransport{
		conn: raw
		tls:  true
	}
	t.handshake()!
	return t
}

// handshake sends the connection preface + SETTINGS, reads server SETTINGS, sends ACK.
fn (mut t H2ClientTransport) handshake() ! {
	t.conn.write(v2.preface.bytes())!
	settings := v2.SettingsFrame{}.to_frame()
	t.write_frame(settings)!
	server_frame := t.read_frame()!
	if server_frame.header.frame_type != .settings {
		return error('expected SETTINGS, got ${server_frame.header.frame_type}')
	}
	sf := v2.SettingsFrame.from_frame(server_frame)!
	max_fs_key := u16(v2.SettingId.max_frame_size)
	if max_fs_key in sf.settings {
		t.remote_max_frame_size = sf.settings[max_fs_key]
	}
	ack := v2.new_settings_ack_frame()
	t.write_frame(ack)!
}

// new_stream allocates a new H2Stream for an RPC call.
pub fn (mut t H2ClientTransport) new_stream(method string, headers map[string]string) !transport.Stream {
	sid := t.stream_alloc.next()
	return &H2Stream{
		sid:       sid
		method:    method
		transport: unsafe { &t }
	}
}

// close closes the underlying TCP connection.
pub fn (mut t H2ClientTransport) close() ! {
	if t.closed {
		return
	}
	t.closed = true
	t.conn.close()!
}

// write_frame encodes and writes a complete HTTP/2 frame to the TCP connection.
pub fn (mut t H2ClientTransport) write_frame(frame v2.Frame) ! {
	bytes := frame.encode()
	t.conn.write(bytes)!
}

// read_frame reads a 9-byte header + payload from the TCP connection and parses it.
pub fn (mut t H2ClientTransport) read_frame() !v2.Frame {
	mut header_buf := []u8{len: v2.frame_header_size}
	read_exact_from(mut t.conn, mut header_buf, v2.frame_header_size)!
	header := v2.parse_frame_header(header_buf) or {
		return error('failed to parse frame header')
	}
	mut payload := []u8{len: int(header.length)}
	if header.length > 0 {
		read_exact_from(mut t.conn, mut payload, int(header.length))!
	}
	return v2.Frame{
		header:  header
		payload: payload
	}
}

// read_exact_from reads exactly `needed` bytes from a RawConn.
fn read_exact_from(mut conn RawConn, mut buf []u8, needed int) ! {
	mut total := 0
	for total < needed {
		n := conn.read(mut buf[total..needed]) or {
			return error('read failed: ${err}')
		}
		if n == 0 {
			return error('connection closed after ${total}/${needed} bytes')
		}
		total += n
	}
}
