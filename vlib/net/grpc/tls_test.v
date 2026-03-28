module grpc

import net.grpc.transport.h2

// Test 1: ServerConfig has cert_file and key_file TLS fields
fn test_server_config_tls_fields() {
	config := ServerConfig{
		cert_file: '/path/to/cert.pem'
		key_file:  '/path/to/key.pem'
	}
	assert config.cert_file == '/path/to/cert.pem'
	assert config.key_file == '/path/to/key.pem'
}

// Test 2: serve_tls returns error when cert_file is empty
fn test_serve_tls_requires_cert() {
	mut s := new_server(ServerConfig{ key_file: '/path/to/key.pem' })
	s.serve_tls() or {
		assert err.msg().contains('cert_file')
		return
	}
	assert false, 'expected error when cert_file is empty'
}

// Test 3: serve_tls returns error when key_file is empty
fn test_serve_tls_requires_key() {
	mut s := new_server(ServerConfig{ cert_file: '/path/to/cert.pem' })
	s.serve_tls() or {
		assert err.msg().contains('key_file')
		return
	}
	assert false, 'expected error when key_file is empty'
}

// Test 4: H2ServerTransport has tls field that can be set
fn test_server_transport_tls_field() {
	t := h2.H2ServerTransport{
		tls: true
	}
	assert t.tls == true
}

// Test 5: Default H2ServerTransport has tls=false
fn test_server_transport_default_not_tls() {
	t := h2.H2ServerTransport{}
	assert t.tls == false
}
