// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module http

import net.urllib
import net.http.v2

// negotiate_version selects the HTTP version for a request.
//
// When req.version is explicitly set, that value is honoured directly.
// For plain HTTP the function falls back to HTTP/1.1 because HTTP/2
// requires TLS.
// For HTTPS it defaults to HTTP/2, which has the broadest server support.
//
// TODO: Implement real ALPN-based negotiation once TLS integration is
// available.  The correct approach is to perform a TLS handshake with the
// ALPN extension advertising ['h2', 'http/1.1'] and return the
// version that the server selects.
fn (req &Request) negotiate_version(url urllib.URL) Version {
	// If version is explicitly set, use it
	if req.version != .unknown {
		return req.version
	}

	// Only HTTPS supports HTTP/2
	if url.scheme != 'https' {
		return .v1_1
	}

	// Default to HTTP/2 for HTTPS connections.
	return .v2_0
}

// to_v2_method converts a net.http.Method to the v2 module's Method enum.
//
// TODO: Method is duplicated across net.http and net.http.v2.
// These definitions should eventually be unified into a single enum
// in net.http once the cross-module import story is settled.
fn to_v2_method(m Method) v2.Method {
	return match m {
		.get {
			v2.Method.get
		}
		.post {
			v2.Method.post
		}
		.put {
			v2.Method.put
		}
		.patch {
			v2.Method.patch
		}
		.delete {
			v2.Method.delete
		}
		.head {
			v2.Method.head
		}
		.options {
			v2.Method.options
		}
		else {
			// HTTP/2 only defines the 7 methods above; warn and fall back to GET
			// rather than silently mis-routing the request.
			eprintln('http: to_v2_method: unsupported method ${m}, falling back to GET')
			v2.Method.get
		}
	}
}

// build_headers_map builds a string-keyed headers map from the request,
// injecting user-agent and content-length when absent.
// Used by do_http2.
fn (req &Request) build_headers_map() map[string]string {
	keys := req.header.keys()
	mut headers_map := map[string]string{}
	for key in keys {
		values := req.header.custom_values(key)
		if values.len == 1 {
			headers_map[key] = values[0]
		} else if values.len > 1 {
			headers_map[key] = values.join('; ')
		}
	}
	// Add user-agent if not present
	if 'user-agent' !in headers_map {
		headers_map['user-agent'] = req.user_agent
	}
	// Add content-length if there's a body
	if req.data.len > 0 && 'content-length' !in headers_map {
		headers_map['content-length'] = req.data.len.str()
	}
	return headers_map
}

// build_request_path returns the full path (with optional query string) for
// the request URL.
fn build_request_path(url urllib.URL) string {
	p := url.escaped_path().trim_left('/')
	q := url.query()
	return if q.len > 0 { '/${p}?${q.encode()}' } else { '/${p}' }
}

// do_http2 performs an HTTP/2 request
fn (req &Request) do_http2(url urllib.URL) !Response {
	host_name := url.hostname()
	mut port := url.port().int()
	if port == 0 {
		port = 443 // HTTPS default
	}

	address := '${host_name}:${port}'

	// Create HTTP/2 client
	mut client := v2.new_client(address) or { return error('HTTP/2 connection failed: ${err}') }

	defer {
		client.close()
	}

	v2_req := v2.Request{
		method:  to_v2_method(req.method)
		url:     build_request_path(url)
		host:    host_name
		data:    req.data
		headers: req.build_headers_map()
	}

	// Send request
	v2_resp := client.request(v2_req) or { return error('HTTP/2 request failed: ${err}') }

	// Convert v2.Response to http.Response
	mut resp_header := new_header()
	for key, value in v2_resp.headers {
		resp_header.add_custom(key, value) or {}
	}

	return Response{
		body:        v2_resp.body
		status_code: v2_resp.status_code
		header:      resp_header
	}
}
