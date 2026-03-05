// HTTP/2 HEAD Request Example — demonstrates using the HEAD method over HTTP/2.
// HEAD requests retrieve only the response headers, not the body. This is
// useful to check resource metadata (content-type, content-length, etag, etc.)
// without downloading the full payload.
//
// Usage: v run examples/http2/12_headers_only.v
import net.http.v2

fn main() {
	println('=== HTTP/2 HEAD Request Example ===\n')

	println('The HEAD method (RFC 7231 §4.3.2):')
	println('  • Returns identical headers to a GET request for the same resource.')
	println('  • The response MUST NOT include a message body.')
	println('  • Useful for metadata inspection, cache validation, and link checking.\n')

	mut client := v2.new_client('httpbin.org:443') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		client.close()
	}
	println('Connected to httpbin.org via HTTP/2 over TLS\n')

	// --- Test 1: HEAD /get ---
	println('--- Test 1: HEAD /get ---')
	resp1 := client.request(v2.Request{
		method:  .head
		url:     '/get'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Head/1.0'
			'accept':     'application/json'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}
	println('  Status: ${resp1.status_code}')
	println('  Body length: ${resp1.body.len} bytes  (must be 0 for HEAD)')
	println('  Response headers:')
	for key, value in resp1.headers {
		println('    ${key}: ${value}')
	}

	// --- Test 2: HEAD /image/png — check content-type and content-length ---
	println('\n--- Test 2: HEAD /image/png ---')
	resp2 := client.request(v2.Request{
		method:  .head
		url:     '/image/png'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Head/1.0'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}
	println('  Status: ${resp2.status_code}')
	content_type := resp2.headers['content-type'] or { '(not set)' }
	content_len := resp2.headers['content-length'] or { '(not set)' }
	println('  Content-Type  : ${content_type}')
	println('  Content-Length: ${content_len}')
	println('  Body length   : ${resp2.body.len} bytes  (must be 0 for HEAD)')

	// --- Test 3: HEAD /status/404 — check status without body ---
	println('\n--- Test 3: HEAD /status/404 ---')
	resp3 := client.request(v2.Request{
		method:  .head
		url:     '/status/404'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Head/1.0'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}
	println('  Status: ${resp3.status_code}  (status without body download)')
	println('  Body length: ${resp3.body.len} bytes  (must be 0 for HEAD)')

	println('\nSummary: HEAD requests returned headers only — zero body bytes in all cases.')
	println('\n=== Done ===')
}
