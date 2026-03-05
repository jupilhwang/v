// HTTP/2 Compression Example — demonstrates how HTTP/2 uses header compression
// (HPACK, RFC 7541) and how to negotiate body compression (gzip/deflate) via
// the Accept-Encoding request header. HPACK is always active for headers;
// body compression is an opt-in negotiated at the application layer.
//
// Usage: v run examples/http2/10_compression.v
import net.http.v2

fn main() {
	println('=== HTTP/2 Compression Example ===\n')

	println('HTTP/2 uses two kinds of compression:')
	println('  1. HPACK (RFC 7541) — mandatory header compression, always active.')
	println('     Reduces header overhead via static/dynamic table + Huffman coding.')
	println('  2. Content-Encoding — optional body compression (gzip, deflate, br).')
	println('     Negotiated with Accept-Encoding / Content-Encoding headers.\n')

	mut client := v2.new_client('httpbin.org:443') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		client.close()
	}
	println('Connected to httpbin.org via HTTP/2 over TLS\n')

	// --- 1. Request with gzip body compression ---
	println('--- Test 1: Accept-Encoding: gzip ---')
	resp_gzip := client.request(v2.Request{
		method:  .get
		url:     '/gzip' // httpbin returns a gzip-encoded body at this endpoint
		host:    'httpbin.org'
		headers: {
			'user-agent':      'V-HTTP2-Compression/1.0'
			'accept-encoding': 'gzip'
			'accept':          'application/json'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}
	println('  Status: ${resp_gzip.status_code}')
	content_enc := resp_gzip.headers['content-encoding'] or { '(not set)' }
	println('  Content-Encoding: ${content_enc}')
	println('  Body length: ${resp_gzip.body.len} bytes')
	body_preview := if resp_gzip.body.len > 150 {
		resp_gzip.body[..150] + '...'
	} else {
		resp_gzip.body
	}
	println('  Body: ${body_preview}\n')

	// --- 2. Request with deflate body compression ---
	println('--- Test 2: Accept-Encoding: deflate ---')
	resp_deflate := client.request(v2.Request{
		method:  .get
		url:     '/deflate' // httpbin returns a deflate-encoded body here
		host:    'httpbin.org'
		headers: {
			'user-agent':      'V-HTTP2-Compression/1.0'
			'accept-encoding': 'deflate'
			'accept':          'application/json'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}
	println('  Status: ${resp_deflate.status_code}')
	content_enc2 := resp_deflate.headers['content-encoding'] or { '(not set)' }
	println('  Content-Encoding: ${content_enc2}')
	println('  Body length: ${resp_deflate.body.len} bytes\n')

	// --- 3. Request without compression ---
	println('--- Test 3: No Accept-Encoding (uncompressed) ---')
	resp_plain := client.request(v2.Request{
		method:  .get
		url:     '/get'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Compression/1.0'
			'accept':     'application/json'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}
	println('  Status: ${resp_plain.status_code}')
	content_enc3 := resp_plain.headers['content-encoding'] or { '(not set)' }
	println('  Content-Encoding: ${content_enc3}')
	println('  Body length: ${resp_plain.body.len} bytes')

	println('\nHPACK header compression is always active — it is not shown in')
	println('response headers but saves significant bandwidth on repeated requests.')
	println('\n=== Done ===')
}
