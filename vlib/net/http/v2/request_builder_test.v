// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// request_builder_test.v — tests for HTTP/2 request header construction.
// Validates that the HPACK pseudo-headers and custom headers produced for
// outgoing requests conform to RFC 7540 §8.1.2.

// build_request_headers assembles the ordered header list that the client
// sends for a given Request.  This mirrors the logic in Client.request().
fn build_request_headers(req Request) []HeaderField {
	mut headers := [
		HeaderField{':method', req.method.str()},
		HeaderField{':scheme', 'https'},
		HeaderField{':path', req.url},
		HeaderField{':authority', req.host},
	]
	for key, value in req.headers {
		headers << HeaderField{key.to_lower(), value}
	}
	return headers
}

// test_get_request_pseudo_headers verifies that a GET request produces the
// four mandatory HTTP/2 pseudo-headers in the correct order.
fn test_get_request_pseudo_headers() {
	req := Request{
		method: .get
		url:    '/'
		host:   'example.com'
	}
	headers := build_request_headers(req)

	// Pseudo-headers must be first and in order (RFC 7540 §8.1.2.3)
	assert headers[0].name == ':method'
	assert headers[0].value == 'GET'
	assert headers[1].name == ':scheme'
	assert headers[1].value == 'https'
	assert headers[2].name == ':path'
	assert headers[2].value == '/'
	assert headers[3].name == ':authority'
	assert headers[3].value == 'example.com'
	// No extra headers — only 4 pseudo-headers
	assert headers.len == 4
}

// test_post_request_pseudo_headers verifies that a POST request emits the
// correct :method pseudo-header value.
fn test_post_request_pseudo_headers() {
	req := Request{
		method: .post
		url:    '/submit'
		host:   'api.example.com'
		data:   '{"hello":"world"}'
	}
	headers := build_request_headers(req)

	assert headers[0].name == ':method'
	assert headers[0].value == 'POST'
	assert headers[2].name == ':path'
	assert headers[2].value == '/submit'
	assert headers[3].name == ':authority'
	assert headers[3].value == 'api.example.com'
}

// test_custom_headers_appended verifies that user-supplied headers are
// appended after the pseudo-headers, and that header names are lower-cased.
fn test_custom_headers_appended() {
	req := Request{
		method:  .get
		url:     '/data'
		host:    'example.com'
		headers: {
			'User-Agent':   'V-HTTP2/1.0'
			'Accept':       'application/json'
			'X-Request-Id': 'req-42'
		}
	}
	headers := build_request_headers(req)

	// 4 pseudo-headers + 3 custom headers
	assert headers.len == 7

	// All custom header names must be lower-case (HTTP/2 requires this)
	for h in headers[4..] {
		assert h.name == h.name.to_lower(), 'header name "${h.name}" is not lower-case'
	}
}

// test_empty_url_path verifies that an empty URL is forwarded as-is.
// Callers are responsible for sending a valid path; the builder must not alter it.
fn test_empty_url_path() {
	req := Request{
		method: .get
		url:    ''
		host:   'example.com'
	}
	headers := build_request_headers(req)
	assert headers[2].name == ':path'
	assert headers[2].value == ''
}

// test_hpack_roundtrip_for_request verifies that request headers survive a
// full HPACK encode → decode cycle without data loss.
fn test_hpack_roundtrip_for_request() {
	req := Request{
		method:  .post
		url:     '/api/upload'
		host:    'upload.example.com'
		headers: {
			'content-type':   'application/octet-stream'
			'content-length': '1024'
			'authorization':  'Bearer token-xyz'
		}
	}
	headers := build_request_headers(req)

	mut encoder := new_encoder()
	mut decoder := new_decoder()

	encoded := encoder.encode(headers)
	assert encoded.len > 0

	decoded := decoder.decode(encoded) or {
		assert false, 'HPACK decode failed: ${err}'
		return
	}

	assert decoded.len == headers.len
	for i, h in headers {
		assert decoded[i].name == h.name, 'name mismatch at index ${i}'
		assert decoded[i].value == h.value, 'value mismatch at index ${i}'
	}
}

// test_method_variants_in_headers verifies that every HTTP method produces
// the correct :method value after going through build_request_headers.
fn test_method_variants_in_headers() {
	methods := [Method.get, .post, .put, .patch, .delete, .head, .options]
	expected := ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']

	for i, method in methods {
		req := Request{
			method: method
			url:    '/'
			host:   'example.com'
		}
		headers := build_request_headers(req)
		assert headers[0].value == expected[i], 'method ${method} produced "${headers[0].value}", want "${expected[i]}"'
	}
}
