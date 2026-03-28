module h2

import net

// accept_conn accepts a TCP connection and sends it via channel.
fn accept_conn(mut listener net.TcpListener, c chan &net.TcpConn) {
	c <- listener.accept() or { return }
}

// MockRawConn is a test double that records operations for verification.
struct MockRawConn {
mut:
	read_data  []u8
	read_pos   int
	write_data []u8
	closed     bool
}

fn (mut m MockRawConn) read(mut buf []u8) !int {
	if m.read_pos >= m.read_data.len {
		return error('no more data')
	}
	remaining := m.read_data[m.read_pos..]
	n := if remaining.len < buf.len { remaining.len } else { buf.len }
	for i in 0 .. n {
		buf[i] = remaining[i]
	}
	m.read_pos += n
	return n
}

fn (mut m MockRawConn) write(data []u8) !int {
	m.write_data << data
	return data.len
}

fn (mut m MockRawConn) close() ! {
	m.closed = true
}

// Test 1: MockRawConn satisfies RawConn interface via structural typing
fn test_mock_raw_conn_satisfies_interface() {
	mut mock := MockRawConn{
		read_data: [u8(1), 2, 3]
	}
	mut conn := RawConn(mock)
	mut buf := []u8{len: 3}
	n := conn.read(mut buf) or {
		assert false, 'read through interface failed: ${err}'
		return
	}
	assert n == 3
	assert buf == [u8(1), 2, 3]
}

// Test 2: MockRawConn write via interface records data
fn test_raw_conn_mock_write_via_interface() {
	mut mock := MockRawConn{}
	mut conn := RawConn(mock)
	data := [u8(10), 20, 30]
	n := conn.write(data) or {
		assert false, 'write through interface failed: ${err}'
		return
	}
	assert n == 3
}

// Test 3: MockRawConn close sets closed flag
fn test_mock_raw_conn_close_sets_flag() {
	mut mock := MockRawConn{}
	mock.close() or {
		assert false, 'close failed: ${err}'
		return
	}
	assert mock.closed == true
}

// Test 4: TcpRawConn delegates read to underlying TcpConn
fn test_tcp_raw_conn_delegates_read() {
	mut listener := net.listen_tcp(.ip, ':0') or {
		assert false, 'listen failed: ${err}'
		return
	}
	addr := listener.addr() or {
		assert false, 'addr failed: ${err}'
		return
	}
	port := addr.port() or {
		assert false, 'port failed: ${err}'
		return
	}
	c := chan &net.TcpConn{}
	spawn accept_conn(mut listener, c)
	mut client := net.dial_tcp('127.0.0.1:${port}') or {
		assert false, 'dial failed: ${err}'
		return
	}
	mut server := <-c
	listener.close() or {}
	defer {
		client.close() or {}
		server.close() or {}
	}

	server.write([u8(0xAA), 0xBB, 0xCC]) or {
		assert false, 'server write failed: ${err}'
		return
	}

	mut conn := new_tcp_raw_conn(client)
	mut buf := []u8{len: 3}
	n := conn.read(mut buf) or {
		assert false, 'TcpRawConn.read failed: ${err}'
		return
	}
	assert n == 3
	assert buf == [u8(0xAA), 0xBB, 0xCC]
}

// Test 5: TcpRawConn delegates write to underlying TcpConn
fn test_tcp_raw_conn_delegates_write() {
	mut listener := net.listen_tcp(.ip, ':0') or {
		assert false, 'listen failed: ${err}'
		return
	}
	addr := listener.addr() or {
		assert false, 'addr failed: ${err}'
		return
	}
	port := addr.port() or {
		assert false, 'port failed: ${err}'
		return
	}
	c := chan &net.TcpConn{}
	spawn accept_conn(mut listener, c)
	mut client := net.dial_tcp('127.0.0.1:${port}') or {
		assert false, 'dial failed: ${err}'
		return
	}
	mut server := <-c
	listener.close() or {}
	defer {
		client.close() or {}
		server.close() or {}
	}

	mut conn := new_tcp_raw_conn(client)
	n := conn.write([u8(0xDD), 0xEE]) or {
		assert false, 'TcpRawConn.write failed: ${err}'
		return
	}
	assert n == 2

	mut buf := []u8{len: 2}
	server.read(mut buf) or {
		assert false, 'server read failed: ${err}'
		return
	}
	assert buf == [u8(0xDD), 0xEE]
}
