// HTTP/2 Error Handling Example — demonstrates how to handle HTTP/2 protocol
// errors, RST_STREAM frames, GOAWAY frames, and application-level HTTP error
// status codes (4xx, 5xx). Shows graceful degradation and error classification.
//
// Usage: v run examples/http2/13_error_handling.v
import net.http.v2

// classify_status returns a human-readable category for an HTTP status code.
fn classify_status(code int) string {
	return match code {
		100...199 { '1xx Informational' }
		200...299 { '2xx Success' }
		300...399 { '3xx Redirection' }
		400...499 { '4xx Client Error' }
		500...599 { '5xx Server Error' }
		else { 'Unknown' }
	}
}

// error_code_name maps HTTP/2 error codes to names per RFC 7540 §7.
fn error_code_name(code u32) string {
	return match code {
		0x0 { 'NO_ERROR' }
		0x1 { 'PROTOCOL_ERROR' }
		0x2 { 'INTERNAL_ERROR' }
		0x3 { 'FLOW_CONTROL_ERROR' }
		0x4 { 'SETTINGS_TIMEOUT' }
		0x5 { 'STREAM_CLOSED' }
		0x6 { 'FRAME_SIZE_ERROR' }
		0x7 { 'REFUSED_STREAM' }
		0x8 { 'CANCEL' }
		0x9 { 'COMPRESSION_ERROR' }
		0xa { 'CONNECT_ERROR' }
		0xb { 'ENHANCE_YOUR_CALM' }
		0xc { 'INADEQUATE_SECURITY' }
		0xd { 'HTTP_1_1_REQUIRED' }
		else { 'UNKNOWN (0x${code:04x})' }
	}
}

fn main() {
	println('=== HTTP/2 Error Handling Example ===\n')

	println('HTTP/2 error taxonomy (RFC 7540 §7):')
	println('  • Connection errors → GOAWAY frame, connection closed')
	println('  • Stream errors     → RST_STREAM frame, stream closed, connection alive')
	println('  • Application errors → HTTP status 4xx/5xx, no protocol-level error\n')

	mut client := v2.new_client('httpbin.org:443') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		client.close()
	}
	println('Connected to httpbin.org via HTTP/2 over TLS\n')

	// --- Test 1: 404 Not Found (application-level error) ---
	println('--- Test 1: 404 Not Found ---')
	resp404 := client.request(v2.Request{
		method:  .get
		url:     '/status/404'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Error/1.0'
			'accept':     '*/*'
		}
	}) or {
		eprintln('  Protocol error: ${err}')
		return
	}
	println('  Status: ${resp404.status_code} — ${classify_status(resp404.status_code)}')
	println('  (No protocol error — this is an application-level error code)\n')

	// --- Test 2: 500 Internal Server Error ---
	println('--- Test 2: 500 Internal Server Error ---')
	resp500 := client.request(v2.Request{
		method:  .get
		url:     '/status/500'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Error/1.0'
		}
	}) or {
		eprintln('  Protocol error: ${err}')
		return
	}
	println('  Status: ${resp500.status_code} — ${classify_status(resp500.status_code)}\n')

	// --- Test 3: 400 Bad Request ---
	println('--- Test 3: 400 Bad Request ---')
	resp400 := client.request(v2.Request{
		method:  .get
		url:     '/status/400'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Error/1.0'
		}
	}) or {
		eprintln('  Protocol error: ${err}')
		return
	}
	println('  Status: ${resp400.status_code} — ${classify_status(resp400.status_code)}\n')

	// --- Test 4: 429 Too Many Requests ---
	println('--- Test 4: 429 Too Many Requests ---')
	resp429 := client.request(v2.Request{
		method:  .get
		url:     '/status/429'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Error/1.0'
		}
	}) or {
		eprintln('  Protocol error: ${err}')
		return
	}
	println('  Status: ${resp429.status_code} — ${classify_status(resp429.status_code)}')
	retry_after := resp429.headers['retry-after'] or { '(not set)' }
	println('  Retry-After: ${retry_after}\n')

	// Show error code table for reference
	println('HTTP/2 Error Code Reference (RFC 7540 §7):')
	for code in u32(0) .. u32(0xe) {
		println('  0x${code:02x}  ${error_code_name(code)}')
	}

	println('\n=== Done ===')
}
