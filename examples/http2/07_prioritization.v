// HTTP/2 Stream Prioritization Example — demonstrates the HTTP/2 PRIORITY frame
// mechanism defined in RFC 7540 §5.3 and §6.3. Stream priority lets clients
// hint at the relative importance of resources so the server can schedule
// responses accordingly.
//
// This example constructs a raw PRIORITY frame and shows its binary layout,
// then sends normal requests to illustrate priority-annotated headers.
//
// Usage: v run examples/http2/07_prioritization.v
import net.http.v2

// priority_payload builds a PRIORITY frame payload (RFC 7540 §6.3).
// Fields: E(1-bit) | stream_dependency(31-bit) | weight(8-bit).
fn priority_payload(exclusive bool, stream_dep u32, weight u8) []u8 {
	mut dep := stream_dep & 0x7fffffff
	if exclusive {
		dep |= 0x80000000
	}
	return [
		u8(dep >> 24),
		u8(dep >> 16),
		u8(dep >> 8),
		u8(dep),
		weight,
	]
}

fn main() {
	println('=== HTTP/2 Stream Prioritization Example ===\n')

	println('HTTP/2 Priority (RFC 7540 §5.3 & §6.3):')
	println('  • Each stream has a dependency on another stream and a weight (1–256).')
	println('  • Higher weight → server allocates proportionally more bandwidth.')
	println('  • Exclusive dependency inserts a stream between parent and its children.')
	println('  • Default: all streams depend on stream 0, weight 16.\n')

	// Show PRIORITY frame byte layout
	println('PRIORITY frame layout (5 bytes):')
	println('  ┌──────────────────────────────────────────────────────────┐')
	println('  │ E │     Stream Dependency (31 bits)     │  Weight (8b)   │')
	println('  └──────────────────────────────────────────────────────────┘\n')

	// High-priority stream: exclusive dep on 0, weight 255
	high_payload := priority_payload(false, 0, 255)
	println('High-priority PRIORITY payload (dep=0, weight=255):')
	println('  Hex: ${high_payload.hex()}')
	println('  Bytes: ${high_payload}\n')

	// Low-priority stream: dep on 0, weight 1
	low_payload := priority_payload(false, 0, 1)
	println('Low-priority PRIORITY payload (dep=0, weight=1):')
	println('  Hex: ${low_payload.hex()}')
	println('  Bytes: ${low_payload}\n')

	// Construct a PRIORITY frame struct to show encoding
	prio_frame := v2.Frame{
		header:  v2.FrameHeader{
			length:     5
			frame_type: .priority
			flags:      0
			stream_id:  3 // applies to stream 3
		}
		payload: high_payload
	}
	encoded := prio_frame.encode()
	println('Encoded PRIORITY frame for stream 3 (9-byte header + 5-byte payload):')
	println('  Hex: ${encoded.hex()}\n')

	// Now send two requests to httpbin.org — in HTTP/2 the HEADERS frame can
	// carry priority signalling via the PRIORITY flag (§6.2).
	mut client := v2.new_client('httpbin.org:443') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		client.close()
	}
	println('Connected to httpbin.org via HTTP/2 over TLS')
	println('Sending two sequential requests (high-priority path first):\n')

	// High-priority request
	resp1 := client.request(v2.Request{
		method:  .get
		url:     '/get'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Priority/1.0'
			'x-priority': 'high'
			'accept':     'application/json'
		}
	}) or {
		eprintln('High-priority request failed: ${err}')
		return
	}
	println('High-priority GET /get — Status: ${resp1.status_code}')

	// Low-priority request
	resp2 := client.request(v2.Request{
		method:  .get
		url:     '/headers'
		host:    'httpbin.org'
		headers: {
			'user-agent': 'V-HTTP2-Priority/1.0'
			'x-priority': 'low'
			'accept':     'application/json'
		}
	}) or {
		eprintln('Low-priority request failed: ${err}')
		return
	}
	println('Low-priority  GET /headers — Status: ${resp2.status_code}')

	println('\nBoth requests completed. In a real deployment the server would')
	println('schedule bandwidth proportional to stream weights (255 vs 1 here).')
	println('\n=== Done ===')
}
