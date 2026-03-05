// HTTP/2 POST Request Example — sends a POST request with a JSON body
// to a real HTTPS endpoint using TLS with ALPN 'h2'.
//
// Usage: v run examples/http2/03_post_request.v
import net.http.v2

fn main() {
	println('=== HTTP/2 POST Request Example ===\n')

	// Connect to httpbin.org, a public HTTP testing service
	mut client := v2.new_client('httpbin.org:443') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		client.close()
	}
	println('Connected to httpbin.org via HTTP/2 over TLS')

	// Prepare a JSON body
	json_body := '{"name":"V Language","version":"0.4","protocol":"HTTP/2"}'

	// Send a POST request with a JSON body
	response := client.request(v2.Request{
		method:  .post
		url:     '/post'
		host:    'httpbin.org'
		data:    json_body
		headers: {
			'content-type':   'application/json'
			'content-length': json_body.len.str()
			'user-agent':     'V-HTTP2-Client/1.0'
			'accept':         'application/json'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}

	println('Status: ${response.status_code}')
	println('Headers:')
	for key, value in response.headers {
		println('  ${key}: ${value}')
	}
	body_preview := if response.body.len > 300 {
		response.body[..300] + '...'
	} else {
		response.body
	}
	println('Body (${response.body.len} bytes):\n${body_preview}')
	println('\n=== Done ===')
}
