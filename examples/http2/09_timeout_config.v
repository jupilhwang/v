// HTTP/2 Timeout Configuration Example — shows how to configure per-request
// response timeouts using ClientConfig. The default is 30 seconds; this
// example creates clients with short, default, and long timeouts and
// demonstrates that the short one triggers a timeout error on a slow endpoint.
//
// Usage: v run examples/http2/09_timeout_config.v
import net.http.v2
import time

fn main() {
	println('=== HTTP/2 Timeout Configuration Example ===\n')

	println('ClientConfig.response_timeout controls how long the client waits')
	println('for a complete response. Default is 30 s when set to 0.\n')

	// --- 1. Default timeout (30 s) ---
	println('--- Test 1: Default timeout (30 s) ---')
	mut default_client := v2.new_client_with_config('httpbin.org:443', v2.ClientConfig{}) or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		default_client.close()
	}
	resp1 := default_client.request(v2.Request{
		method:  .get
		url:     '/get'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Timeout/1.0'
			'accept':     'application/json'
		}
	}) or {
		eprintln('  Request failed: ${err}')
		return
	}
	println('  Status: ${resp1.status_code}  (completed within default 30 s timeout)')

	// --- 2. Explicit 10-second timeout ---
	println('\n--- Test 2: Explicit 10 s timeout ---')
	mut ten_s_client := v2.new_client_with_config('httpbin.org:443', v2.ClientConfig{
		response_timeout: 10 * time.second
	}) or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		ten_s_client.close()
	}
	start := time.now()
	resp2 := ten_s_client.request(v2.Request{
		method:  .get
		url:     '/delay/2' // server waits 2 s — well within 10 s
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Timeout/1.0'
			'accept':     'application/json'
		}
	}) or {
		eprintln('  Request failed (timeout or error): ${err}')
		return
	}
	elapsed := time.now() - start
	println('  Status: ${resp2.status_code}  (elapsed: ${elapsed.milliseconds()} ms, timeout was 10 s)')

	// --- 3. Very short timeout — should trigger timeout on a slow endpoint ---
	println('\n--- Test 3: Very short timeout (1 ms) — expects timeout error ---')
	mut short_client := v2.new_client_with_config('httpbin.org:443', v2.ClientConfig{
		response_timeout: 1 * time.millisecond
	}) or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		short_client.close()
	}
	_ := short_client.request(v2.Request{
		method:  .get
		url:     '/delay/3' // server waits 3 s, but our timeout is 1 ms
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Timeout/1.0'
		}
	}) or {
		println('  Timeout triggered as expected: ${err}')
		println('\nTimeout Configuration Summary:')
		println('  response_timeout: 0             → 30 s (default)')
		println('  response_timeout: 10*time.second → 10 s')
		println('  response_timeout: 1*time.millisecond → 1 ms  ← too short!')
		println('\n=== Done ===')
		return
	}
	println('  Request unexpectedly succeeded (timeout may not have fired)')
	println('\n=== Done ===')
}
