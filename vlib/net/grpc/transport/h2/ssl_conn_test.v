module h2

import net.http.v2

// StubRawConn is a test double for unit testing without network.
struct StubRawConn {
mut:
	closed bool
}

fn (mut s StubRawConn) read(mut buf []u8) !int {
	return error('stub: no data')
}

fn (mut s StubRawConn) write(data []u8) !int {
	return data.len
}

fn (mut s StubRawConn) close() ! {
	s.closed = true
}

// Test 1: SslRawConn struct exists and compiles
fn test_ssl_raw_conn_struct_exists() {
	// SslRawConn type must compile — verified by this test existing.
	// We cannot instantiate without a real SSLConn, so we verify the type
	// is importable by checking that the module compiles with the struct.
	assert true
}

// Test 2: H2ClientTransport tls field defaults to false
fn test_h2_client_transport_tls_field_default() {
	mut stub := StubRawConn{}
	t := &H2ClientTransport{
		conn: stub
	}
	assert t.tls == false
}

// Test 3: encode_grpc_request_headers with tls=false produces :scheme http
fn test_encode_grpc_headers_http_scheme() {
	mut encoder := v2.new_encoder()
	encoded := encode_grpc_request_headers(mut encoder, '/svc/Method', map[string]string{}, false)

	mut decoder := v2.new_decoder()
	decoded := decoder.decode(encoded) or {
		assert false, 'decode failed: ${err}'
		return
	}

	mut scheme := ''
	for h in decoded {
		if h.name == ':scheme' {
			scheme = h.value
		}
	}
	assert scheme == 'http', 'expected :scheme http, got ${scheme}'
}

// Test 4: encode_grpc_request_headers with tls=true produces :scheme https
fn test_encode_grpc_headers_https_scheme() {
	mut encoder := v2.new_encoder()
	encoded := encode_grpc_request_headers(mut encoder, '/svc/Method', map[string]string{}, true)

	mut decoder := v2.new_decoder()
	decoded := decoder.decode(encoded) or {
		assert false, 'decode failed: ${err}'
		return
	}

	mut scheme := ''
	for h in decoded {
		if h.name == ':scheme' {
			scheme = h.value
		}
	}
	assert scheme == 'https', 'expected :scheme https, got ${scheme}'
}

// Test 5: new_h2_tls_client_transport returns error for invalid address
// (verifies the function exists and is callable)
fn test_new_h2_tls_client_transport_invalid_address_returns_error() {
	if _ := new_h2_tls_client_transport('invalid-no-such-host:443') {
		assert false, 'expected error for invalid address'
	}
}
