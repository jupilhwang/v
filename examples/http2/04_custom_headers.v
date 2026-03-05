// HTTP/2 Custom Headers Example — demonstrates sending custom request headers
// over an HTTP/2 connection using TLS with ALPN 'h2'.
//
// Usage: v run examples/http2/04_custom_headers.v
import net.http.v2

fn main() {
	println('=== HTTP/2 Custom Headers Example ===\n')

	// Connect to httpbin.org, a public HTTP testing service
	mut client := v2.new_client('httpbin.org:443') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		client.close()
	}
	println('Connected to httpbin.org via HTTP/2 over TLS')

	// Build a request with several custom headers.
	// httpbin.org/headers echoes back all request headers as JSON.
	response := client.request(v2.Request{
		method:  .get
		url:     '/headers'
		host:    'httpbin.org'
		headers: {
			'user-agent':      'V-HTTP2-Client/1.0'
			'accept':          'application/json'
			'x-request-id':    'abc-123'
			'x-custom-header': 'hello-from-v'
			'accept-language': 'en-US,en;q=0.9'
			'cache-control':   'no-cache'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}

	println('Status: ${response.status_code}')
	println('\nResponse headers sent back by server:')
	for key, value in response.headers {
		println('  ${key}: ${value}')
	}
	println('\nEchoed request headers (JSON body):')
	println(response.body)
	println('\n=== Done ===')
}
