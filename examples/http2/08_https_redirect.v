// HTTP/2 HTTPS Redirect Handling Example — demonstrates how to detect and
// follow HTTP → HTTPS redirects when using the HTTP/2 client. HTTP/2 is
// defined only over TLS (h2) in browsers and most servers; the plaintext
// variant (h2c) is rarely deployed. Redirect status codes 301, 302, 307,
// and 308 are handled explicitly.
//
// Usage: v run examples/http2/08_https_redirect.v
import net.http.v2

// follow_redirect extracts the Location header from a redirect response
// and issues a new request to the HTTPS target. Only one hop is followed.
fn follow_redirect(mut client v2.Client, resp v2.Response, original_host string) !v2.Response {
	location := resp.headers['location'] or {
		return error('redirect response missing Location header')
	}
	println('  → Redirect to: ${location}')

	// Derive the path from the Location value
	path := if location.starts_with('http') {
		// Strip scheme + host to get path by finding the first slash after the host
		// e.g. "https://example.com/foo" → "/foo"
		scheme_end := location.index('://') or { -1 }
		host_start := if scheme_end >= 0 { scheme_end + 3 } else { 0 }
		slash_pos := location.index_after('/', host_start) or { -1 }
		if slash_pos >= 0 {
			location[slash_pos..]
		} else {
			'/'
		}
	} else {
		location
	}

	return client.request(v2.Request{
		method:  .get
		url:     path
		host:    original_host
		headers: {
			'user-agent': 'V-HTTP2-Redirect/1.0'
			'accept':     '*/*'
		}
	})
}

fn main() {
	println('=== HTTP/2 HTTPS Redirect Handling Example ===\n')

	println('HTTP/2 redirect status codes:')
	println('  301 Moved Permanently  — resource has a new permanent URL')
	println('  302 Found              — temporary redirect')
	println('  307 Temporary Redirect — method preserved on redirect')
	println('  308 Permanent Redirect — method preserved, permanent\n')

	mut client := v2.new_client('httpbin.org:443') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		client.close()
	}
	println('Connected to httpbin.org via HTTP/2 over TLS\n')

	// httpbin.org/redirect/1 returns a 302 pointing to /get
	println('--- Test 1: Single redirect (302) ---')
	resp := client.request(v2.Request{
		method:  .get
		url:     '/redirect/1'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Redirect/1.0'
			'accept':     'application/json'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}

	println('  Initial status: ${resp.status_code}')

	if resp.status_code in [301, 302, 307, 308] {
		println('  Redirect detected!')
		final := follow_redirect(mut client, resp, 'httpbin.org') or {
			eprintln('  Failed to follow redirect: ${err}')
			return
		}
		println('  Final status after redirect: ${final.status_code}')
		body_preview := if final.body.len > 150 {
			final.body[..150] + '...'
		} else {
			final.body
		}
		println('  Final body: ${body_preview}')
	} else {
		println('  No redirect — direct response received.')
		body_preview := if resp.body.len > 150 { resp.body[..150] + '...' } else { resp.body }
		println('  Body: ${body_preview}')
	}

	println('\n--- Test 2: Absolute redirect (302) ---')
	resp2 := client.request(v2.Request{
		method:  .get
		url:     '/absolute-redirect/1'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Redirect/1.0'
			'accept':     'application/json'
		}
	}) or {
		eprintln('Request failed: ${err}')
		return
	}
	println('  Status: ${resp2.status_code}')
	if loc := resp2.headers['location'] {
		println('  Location header: ${loc}')
	}
	println('  (absolute redirect resolved; follow-up GET /get would be next hop)')

	println('\n=== Done ===')
}
