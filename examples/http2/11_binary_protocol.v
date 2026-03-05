// HTTP/2 Binary Protocol Example — demonstrates the binary framing layer that
// is the foundation of HTTP/2 (RFC 7540 §4). Unlike HTTP/1.1 which is text-
// based, HTTP/2 encodes all communication as binary frames. This example
// constructs, encodes, and parses several frame types by hand to show the
// exact byte layout.
//
// Usage: v run examples/http2/11_binary_protocol.v
import net.http.v2

fn print_frame_hex(label string, frame v2.Frame) {
	encoded := frame.encode()
	println('  ${label}')
	println('    Raw hex : ${encoded.hex()}')
	println('    Length  : ${frame.header.length} bytes payload')
	println('    Type    : ${frame.header.frame_type} (0x${u8(frame.header.frame_type):02x})')
	println('    Flags   : 0x${frame.header.flags:02x}')
	println('    Stream  : ${frame.header.stream_id}')
}

fn main() {
	println('=== HTTP/2 Binary Protocol Example ===\n')

	println('HTTP/2 binary frame structure (RFC 7540 §4.1):')
	println('  ┌────────────────────────────────────────────┐')
	println('  │         Length (24 bits)                   │')
	println('  ├────────────┬───────────────────────────────┤')
	println('  │ Type (8b)  │ Flags (8b)                    │')
	println('  ├────────────┴───────────────────────────────┤')
	println('  │ R │        Stream Identifier (31 bits)     │')
	println('  ├────────────────────────────────────────────┤')
	println('  │         Frame Payload (0..Length bytes)    │')
	println('  └────────────────────────────────────────────┘\n')

	// Connection preface (client magic bytes, RFC 7540 §3.5)
	println('Connection preface (PRI * HTTP/2.0\\r\\n\\r\\nSM\\r\\n\\r\\n):')
	println('  Hex: ${v2.preface.bytes().hex()}\n')

	// SETTINGS frame (type=0x04)
	settings_frame := v2.Frame{
		header:  v2.FrameHeader{
			length:     0
			frame_type: .settings
			flags:      u8(v2.FrameFlags.ack)
			stream_id:  0
		}
		payload: []u8{}
	}
	println('Frame encodings:')
	print_frame_hex('SETTINGS ACK (empty, stream 0)', settings_frame)
	println('')

	// PING frame (type=0x06, 8-byte opaque payload)
	ping_payload := [u8(0xDE), 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0x00, 0x01]
	ping_frame := v2.Frame{
		header:  v2.FrameHeader{
			length:     8
			frame_type: .ping
			flags:      0
			stream_id:  0
		}
		payload: ping_payload
	}
	print_frame_hex('PING (8-byte payload, stream 0)', ping_frame)
	println('')

	// WINDOW_UPDATE frame (type=0x08, 4-byte increment)
	window_increment := u32(32768)
	window_payload := [
		u8(window_increment >> 24) & 0x7f,
		u8(window_increment >> 16),
		u8(window_increment >> 8),
		u8(window_increment),
	]
	window_frame := v2.Frame{
		header:  v2.FrameHeader{
			length:     4
			frame_type: .window_update
			flags:      0
			stream_id:  0
		}
		payload: window_payload
	}
	print_frame_hex('WINDOW_UPDATE (increment=32768, connection level)', window_frame)
	println('')

	// RST_STREAM frame (type=0x03, 4-byte error code)
	rst_payload := [u8(0), 0, 0, u8(v2.ErrorCode.cancel)]
	rst_frame := v2.Frame{
		header:  v2.FrameHeader{
			length:     4
			frame_type: .rst_stream
			flags:      0
			stream_id:  3
		}
		payload: rst_payload
	}
	print_frame_hex('RST_STREAM (CANCEL, stream 3)', rst_frame)
	println('')

	// GOAWAY frame (type=0x07)
	last_id := u32(5)
	goaway_payload := [
		u8((last_id >> 24) & 0x7f),
		u8(last_id >> 16),
		u8(last_id >> 8),
		u8(last_id),
		u8(0),
		u8(0),
		u8(0),
		u8(0), // error code NO_ERROR
	]
	goaway_frame := v2.Frame{
		header:  v2.FrameHeader{
			length:     8
			frame_type: .goaway
			flags:      0
			stream_id:  0
		}
		payload: goaway_payload
	}
	print_frame_hex('GOAWAY (last_stream=5, NO_ERROR, stream 0)', goaway_frame)
	println('')

	// Round-trip: encode then parse back
	println('Round-trip verification (encode → parse):')
	encoded_ping := ping_frame.encode()
	if parsed := v2.parse_frame(encoded_ping) {
		println('  Parsed PING: type=${parsed.header.frame_type} payload=${parsed.payload.hex()}')
		println('  ✓ Encode/parse round-trip successful')
	} else {
		println('  ✗ Parse failed')
	}

	println('\n=== Done ===')
}
