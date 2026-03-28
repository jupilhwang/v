module h2

import net.ssl

// SslRawConn wraps ssl.SSLConn to satisfy the RawConn interface.
// Enables gRPC client connections over TLS with ALPN h2 negotiation.
pub struct SslRawConn {
mut:
	conn &ssl.SSLConn
}

// new_ssl_raw_conn creates a RawConn from an SSL connection.
pub fn new_ssl_raw_conn(conn &ssl.SSLConn) RawConn {
	return SslRawConn{
		conn: unsafe { conn }
	}
}

pub fn (mut s SslRawConn) read(mut buf []u8) !int {
	return s.conn.read(mut buf)!
}

pub fn (mut s SslRawConn) write(data []u8) !int {
	return s.conn.write(data)!
}

pub fn (mut s SslRawConn) close() ! {
	s.conn.shutdown()!
}
