// HTTP/2 Server Push Example — explains the HTTP/2 server push mechanism and
// shows how the V HTTP/2 client handles PUSH_PROMISE frames. RFC 7540 §8.2
// allows a server to proactively send resources the client has not yet requested.
//
// Note: httpbin.org does not send PUSH_PROMISE frames, so this example
// demonstrates the client-side settings and behaviour rather than live push.
// The client advertises SETTINGS_ENABLE_PUSH=0 (disabled) which is the safe
// default per RFC 7540 §8.2; a server that ignores this and sends a
// PUSH_PROMISE would trigger a connection error.
//
// Usage: v run examples/http2/06_server_push.v
import net.http.v2

fn main() {
	println('=== HTTP/2 Server Push Example ===\n')

	println('HTTP/2 Server Push (RFC 7540 §8.2):')
	println('  • The server can proactively push resources along with a response.')
	println('  • A PUSH_PROMISE frame reserves a stream for the pushed resource.')
	println('  • Clients can disable push by sending SETTINGS_ENABLE_PUSH=0.\n')

	// The V HTTP/2 client sets SETTINGS_ENABLE_PUSH=0 during the connection
	// preface, instructing the server not to push resources.
	mut client := v2.new_client('httpbin.org:443') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		client.close()
	}
	println('Connected to httpbin.org via HTTP/2 over TLS')
	println('Client advertised SETTINGS_ENABLE_PUSH=0 (push disabled)\n')

	// Send a normal GET request; the server will NOT send PUSH_PROMISE because
	// we disabled it in settings. Receiving one would be a connection error.
	resp := client.request(v2.Request{
		method:  .get
		url:     '/get'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Push/1.0'
			'accept':     'application/json'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}

	println('GET /get — Status: ${resp.status_code}')
	println('No PUSH_PROMISE received (server respected ENABLE_PUSH=0)\n')

	println('Server Push Settings summary:')
	println('  SETTINGS_ENABLE_PUSH = 0  (client disabled push)')
	println('  Per RFC 7540 §8.2: server MUST NOT send PUSH_PROMISE when push disabled')
	println('  If received anyway: client returns a connection error (PROTOCOL_ERROR)\n')

	body_preview := if resp.body.len > 200 { resp.body[..200] + '...' } else { resp.body }
	println('Response body preview:\n${body_preview}')
	println('\n=== Done ===')
}
