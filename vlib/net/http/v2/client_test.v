// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// client_test.v — unit tests for HTTP/2 client structures and behaviour.
// These tests operate on in-memory objects only; no network connections are made.

// test_request_method_strings verifies that every Method variant produces the
// correct uppercase string expected by HTTP/2 pseudo-headers.
fn test_request_method_strings() {
	assert Method.get.str() == 'GET'
	assert Method.post.str() == 'POST'
	assert Method.put.str() == 'PUT'
	assert Method.patch.str() == 'PATCH'
	assert Method.delete.str() == 'DELETE'
	assert Method.head.str() == 'HEAD'
	assert Method.options.str() == 'OPTIONS'
}

// test_request_struct_defaults verifies that a zero-value Request is valid
// and that its fields are accessible.
fn test_request_struct_defaults() {
	req := Request{}
	assert req.method == .get
	assert req.url == ''
	assert req.host == ''
	assert req.data == ''
	assert req.headers.len == 0
}

// test_request_with_headers verifies that custom headers are stored correctly
// on a Request value.
fn test_request_with_headers() {
	req := Request{
		method:  .post
		url:     '/api/data'
		host:    'example.com'
		data:    '{"key":"value"}'
		headers: {
			'content-type': 'application/json'
			'x-request-id': 'test-001'
		}
	}
	assert req.method == .post
	assert req.url == '/api/data'
	assert req.host == 'example.com'
	assert req.data == '{"key":"value"}'
	assert req.headers['content-type'] == 'application/json'
	assert req.headers['x-request-id'] == 'test-001'
	assert req.headers.len == 2
}

// test_response_struct verifies that a Response value stores all fields.
fn test_response_struct() {
	resp := Response{
		status_code: 200
		headers:     {
			'content-type': 'text/plain'
		}
		body:        'hello'
	}
	assert resp.status_code == 200
	assert resp.headers['content-type'] == 'text/plain'
	assert resp.body == 'hello'
}

// test_response_non_200_status verifies that non-200 status codes are stored
// accurately — important for error-handling paths (4xx, 5xx).
fn test_response_non_200_status() {
	not_found := Response{
		status_code: 404
		body:        'Not Found'
	}
	assert not_found.status_code == 404

	server_err := Response{
		status_code: 500
		body:        'Internal Server Error'
	}
	assert server_err.status_code == 500
}

// test_settings_defaults verifies that a Settings struct is initialised with
// the RFC 7540 §6.5.2 default values.
fn test_settings_defaults() {
	s := Settings{}
	assert s.header_table_size == 4096
	assert s.enable_push == true
	assert s.max_concurrent_streams == 100
	assert s.initial_window_size == 65535
	assert s.max_frame_size == 16384
	assert s.max_header_list_size == 0 // 0 = unlimited
}

// test_client_config_zero_timeout verifies that a zero-value ClientConfig
// represents the "use default timeout" state.
fn test_client_config_zero_timeout() {
	cfg := ClientConfig{}
	assert cfg.response_timeout == 0
}

// test_stream_initial_state verifies that a new Stream starts in .idle state
// and that its window_size matches the RFC 7540 default of 65535.
fn test_stream_initial_state() {
	s := Stream{
		id: 1
	}
	assert s.id == 1
	assert s.state == .idle
	assert s.window_size == 65535
	assert s.headers.len == 0
	assert s.data.len == 0
	assert s.end_stream == false
	assert s.end_headers == false
}
