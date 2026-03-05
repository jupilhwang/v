// HTTP/2 Stream Multiplexing Example — demonstrates sending multiple independent
// requests over a single HTTP/2 connection. Each request uses a distinct odd
// stream ID (1, 3, 5, …) assigned automatically by the client. The server can
// interleave response frames across those streams, which is the core multiplexing
// advantage of HTTP/2 over HTTP/1.1.
//
// Usage: v run examples/http2/05_stream_multiplexing.v
import net.http.v2
import time

fn main() {
	println('=== HTTP/2 Stream Multiplexing Example ===\n')
	println('HTTP/2 multiplexes multiple requests over one TCP/TLS connection.')
	println('Each request gets its own stream ID; frames from different streams')
	println('may arrive interleaved without head-of-line blocking.\n')

	mut client := v2.new_client('httpbin.org:443') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		client.close()
	}
	println('Connected to httpbin.org via HTTP/2 over TLS\n')

	// Send three GET requests sequentially over the same connection.
	// Each call internally allocates a new stream (IDs 1, 3, 5).
	endpoints := ['/get', '/headers', '/user-agent']

	for i, path in endpoints {
		stream_num := i * 2 + 1 // stream IDs are odd: 1, 3, 5
		println('--- Request on stream ${stream_num}: GET ${path} ---')

		start := time.now()
		resp := client.request(v2.Request{
			method:  .get
			url:     path
			host:    'httpbin.org'
			headers: {
				'user-agent': 'V-HTTP2-Multiplex/1.0'
				'accept':     'application/json'
			}
		}) or {
			eprintln('  Request failed: ${err}')
			continue
		}
		elapsed := time.now() - start

		println('  Status: ${resp.status_code}')
		println('  Response time: ${elapsed.milliseconds()} ms')
		body_preview := if resp.body.len > 120 {
			resp.body[..120] + '...'
		} else {
			resp.body
		}
		println('  Body: ${body_preview}\n')
	}

	println('All 3 requests completed over a single HTTP/2 connection.')
	println('\n=== Done ===')
}
