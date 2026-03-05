// HTTP/2 Connection Reuse Example — demonstrates reusing a single HTTP/2
// connection for multiple sequential requests. HTTP/2 multiplexes streams over
// one TLS connection, so establishing the connection once and reusing it for
// many requests avoids repeated TLS handshake overhead (versus HTTP/1.1 where
// each new connection requires a separate handshake).
//
// Usage: v run examples/http2/14_connection_reuse.v
import net.http.v2
import time

fn main() {
	println('=== HTTP/2 Connection Reuse Example ===\n')

	println('HTTP/2 connection reuse benefits:')
	println('  • One TLS handshake per host regardless of request count.')
	println('  • Connection settings (window sizes, HPACK tables) are preserved.')
	println('  • HPACK dynamic table grows, making later requests cheaper to encode.')
	println('  • Avoids TCP slow-start on every request.\n')

	// Establish connection once
	connect_start := time.now()
	mut client := v2.new_client('httpbin.org:443') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		client.close()
	}
	connect_time := time.now() - connect_start
	println('Connection established in ${connect_time.milliseconds()} ms')
	println('(Includes TCP connect + TLS handshake + SETTINGS exchange)\n')

	// Send multiple requests over the same connection
	requests := [
		v2.Request{
			method:  .get
			url:     '/get'
			host:    'httpbin.org'
			headers: {
				'user-agent': 'V-HTTP2-Reuse/1.0'
				'accept':     'application/json'
				'x-request':  '1'
			}
		},
		v2.Request{
			method:  .get
			url:     '/headers'
			host:    'httpbin.org'
			headers: {
				'user-agent': 'V-HTTP2-Reuse/1.0'
				'accept':     'application/json'
				'x-request':  '2'
			}
		},
		v2.Request{
			method:  .get
			url:     '/user-agent'
			host:    'httpbin.org'
			headers: {
				'user-agent': 'V-HTTP2-Reuse/1.0'
				'accept':     'application/json'
				'x-request':  '3'
			}
		},
		v2.Request{
			method:  .get
			url:     '/ip'
			host:    'httpbin.org'
			headers: {
				'user-agent': 'V-HTTP2-Reuse/1.0'
				'accept':     'application/json'
				'x-request':  '4'
			}
		},
	]

	println('Sending ${requests.len} requests over the same connection:\n')

	mut total_elapsed := i64(0)
	for i, req in requests {
		stream_id := i * 2 + 1
		req_start := time.now()
		resp := client.request(req) or {
			eprintln('  Request ${i + 1} failed: ${err}')
			continue
		}
		elapsed := (time.now() - req_start).milliseconds()
		total_elapsed += elapsed
		println('  Request ${i + 1} (stream ${stream_id}): GET ${req.url}')
		println('    Status: ${resp.status_code}  |  Time: ${elapsed} ms  |  Body: ${resp.body.len} bytes')
	}

	println('\nSummary:')
	println('  Requests   : ${requests.len}')
	println('  Connect    : ${connect_time.milliseconds()} ms  (one-time cost)')
	println('  Total req  : ${total_elapsed} ms  (amortised across all requests)')
	avg := if requests.len > 0 { total_elapsed / requests.len } else { 0 }
	println('  Avg/request: ${avg} ms')
	println('\n  All requests reused the same HTTP/2 connection — no extra TLS handshake.')
	println('\n=== Done ===')
}
