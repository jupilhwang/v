module h2

import net

// RawConn abstracts a network connection (TCP or SSL).
// V structural typing: both TcpRawConn and future SslRawConn satisfy this.
pub interface RawConn {
mut:
	read(mut buf []u8) !int
	write(data []u8) !int
	close() !
}

// TcpRawConn wraps net.TcpConn to satisfy RawConn.
pub struct TcpRawConn {
mut:
	conn &net.TcpConn
}

// new_tcp_raw_conn creates a RawConn from a TCP connection.
pub fn new_tcp_raw_conn(conn &net.TcpConn) RawConn {
	return TcpRawConn{
		conn: conn
	}
}

pub fn (mut t TcpRawConn) read(mut buf []u8) !int {
	return t.conn.read(mut buf)!
}

pub fn (mut t TcpRawConn) write(data []u8) !int {
	return t.conn.write(data)!
}

pub fn (mut t TcpRawConn) close() ! {
	t.conn.close()!
}
