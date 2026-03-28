module h2

import net.http.v2

// H2Stream implements the gRPC Stream interface over an HTTP/2 stream.
// Delegates frame I/O to the H2ClientTransport via the transport field.
pub struct H2Stream {
pub:
	sid    u32
	method string
pub mut:
	transport    &H2ClientTransport = unsafe { nil }
	state        v2.StreamState     = .idle
	resp_headers map[string]string // response metadata from initial HEADERS
}

// stream_id returns the HTTP/2 stream identifier.
pub fn (s &H2Stream) stream_id() u32 {
	return s.sid
}

// send_header HPACK-encodes gRPC pseudo-headers and sends a HEADERS frame.
pub fn (mut s H2Stream) send_header(headers map[string]string) ! {
	mut t := s.transport
	encoded := encode_grpc_request_headers(mut t.encoder, s.method, headers, t.tls)
	hf := v2.HeadersFrame{
		stream_id:   s.sid
		headers:     encoded
		end_headers: true
	}
	t.write_frame(hf.to_frame())!
	s.state = .open
}

// send_msg sends a DATA frame with the message bytes.
pub fn (mut s H2Stream) send_msg(data []u8) ! {
	frame := build_data_frame(s.sid, data, false)
	s.transport.write_frame(frame)!
}

// recv_msg reads DATA frames, accumulating until a complete gRPC Length-Prefixed
// Message is received. Handles interleaved control frames via handle_control_frame.
pub fn (mut s H2Stream) recv_msg() ![]u8 {
	mut t := s.transport
	mut buf := []u8{}
	mut msg_len := -1

	for {
		frame := t.read_frame()!
		match frame.header.frame_type {
			.data {
				df := v2.DataFrame.from_frame(frame)!
				buf << df.data
				if msg_len == -1 && buf.len >= 5 {
					msg_len = parse_grpc_msg_length(buf)
				}
				if msg_len >= 0 && buf.len >= 5 + msg_len {
					if df.end_stream {
						s.state = .half_closed_remote
					}
					return buf[..5 + msg_len].clone()
				}
				if df.end_stream {
					s.state = .half_closed_remote
					return error('end of stream before complete gRPC message: got ${buf.len} bytes, need ${5 + msg_len}')
				}
			}
			.headers {
				s.consume_response_headers(frame)!
				continue
			}
			else {
				if s.handle_control_frame(frame)! {
					continue
				}
				return error('unexpected frame type: ${frame.header.frame_type}')
			}
		}
	}
	return error('unreachable')
}

// consume_response_headers decodes a HEADERS frame and stores the response metadata.
fn (mut s H2Stream) consume_response_headers(frame v2.Frame) ! {
	mut t := s.transport
	hf := v2.HeadersFrame.from_frame(frame)!
	decoded := t.decoder.decode(hf.headers)!
	for h in decoded {
		s.resp_headers[h.name] = h.value
	}
}

// handle_control_frame responds to HTTP/2 control frames during frame reception.
// Sends SETTINGS ACK for non-ACK SETTINGS, PONG for non-ACK PING, and skips
// WINDOW_UPDATE. Returns true if the frame was handled, false otherwise.
fn (mut s H2Stream) handle_control_frame(frame v2.Frame) !bool {
	mut t := s.transport
	match frame.header.frame_type {
		.settings {
			if !frame.header.has_flag(.ack) {
				t.write_frame(v2.new_settings_ack_frame())!
			}
			return true
		}
		.ping {
			if !frame.header.has_flag(.ack) {
				pf := v2.PingFrame.from_frame(frame)!
				ack_pf := v2.PingFrame{
					ack:  true
					data: pf.data
				}
				t.write_frame(ack_pf.to_frame())!
			}
			return true
		}
		.window_update {
			return true
		}
		else {
			return false
		}
	}
}

// parse_grpc_msg_length reads the 4-byte big-endian message length from bytes 1-4
// of a gRPC Length-Prefixed Message header (after the compression flag byte).
fn parse_grpc_msg_length(buf []u8) int {
	return (int(buf[1]) << 24) | (int(buf[2]) << 16) | (int(buf[3]) << 8) | int(buf[4])
}

// recv_header reads initial response HEADERS, skipping control frames.
// Stores the headers in resp_headers for later access.
pub fn (mut s H2Stream) recv_header() !map[string]string {
	if s.resp_headers.len > 0 {
		return s.resp_headers.clone()
	}
	mut t := s.transport
	for {
		frame := t.read_frame()!
		match frame.header.frame_type {
			.headers {
				s.consume_response_headers(frame)!
				return s.resp_headers.clone()
			}
			else {
				if s.handle_control_frame(frame)! {
					continue
				}
				return error('expected HEADERS, got ${frame.header.frame_type}')
			}
		}
	}
	return error('unreachable')
}

// send_trailer sends trailing HEADERS with END_STREAM.
pub fn (mut s H2Stream) send_trailer(trailers map[string]string) ! {
	mut t := s.transport
	frame := encode_trailing_headers(mut t.encoder, s.sid, trailers)
	t.write_frame(frame)!
	s.state = .half_closed_local
}

// recv_trailer reads the trailing HEADERS frame, skipping control frames.
pub fn (mut s H2Stream) recv_trailer() !map[string]string {
	mut t := s.transport
	for {
		frame := t.read_frame()!
		if frame.header.frame_type == .headers {
			hf := v2.HeadersFrame.from_frame(frame)!
			decoded := t.decoder.decode(hf.headers)!
			mut result := map[string]string{}
			for h in decoded {
				result[h.name] = h.value
			}
			if hf.end_stream {
				s.state = .closed
			}
			return result
		}
		if frame.header.frame_type in [.settings, .ping, .window_update] {
			continue
		}
	}
	return error('unreachable')
}

// close_send sends an empty DATA frame with END_STREAM.
pub fn (mut s H2Stream) close_send() ! {
	frame := build_data_frame(s.sid, []u8{}, true)
	s.transport.write_frame(frame)!
	s.state = .half_closed_local
}

// encode_grpc_request_headers HPACK-encodes the standard gRPC request headers:
// :method POST, :scheme http/https, :path, content-type, te: trailers, plus extras.
// When tls is true, uses :scheme https; otherwise :scheme http.
pub fn encode_grpc_request_headers(mut encoder v2.Encoder, path string, extra map[string]string, tls bool) []u8 {
	scheme := if tls { 'https' } else { 'http' }
	mut headers := []v2.HeaderField{cap: 5 + extra.len}
	headers << v2.HeaderField{name: ':method', value: 'POST'}
	headers << v2.HeaderField{name: ':scheme', value: scheme}
	headers << v2.HeaderField{name: ':path', value: path}
	headers << v2.HeaderField{name: 'content-type', value: 'application/grpc+proto'}
	headers << v2.HeaderField{name: 'te', value: 'trailers'}
	for k, val in extra {
		if k.starts_with(':') || k == 'content-type' || k == 'te' {
			continue
		}
		headers << v2.HeaderField{name: k, value: val}
	}
	return encoder.encode(headers)
}

// build_data_frame creates an HTTP/2 DATA frame from message bytes.
pub fn build_data_frame(stream_id u32, data []u8, end_stream bool) v2.Frame {
	df := v2.DataFrame{
		stream_id:  stream_id
		data:       data
		end_stream: end_stream
	}
	return df.to_frame()
}

// encode_trailing_headers builds a HEADERS frame for gRPC trailers with END_STREAM.
pub fn encode_trailing_headers(mut encoder v2.Encoder, stream_id u32, trailers map[string]string) v2.Frame {
	mut fields := []v2.HeaderField{cap: trailers.len}
	for k, val in trailers {
		fields << v2.HeaderField{name: k, value: val}
	}
	encoded := encoder.encode(fields)
	hf := v2.HeadersFrame{
		stream_id:   stream_id
		headers:     encoded
		end_stream:  true
		end_headers: true
	}
	return hf.to_frame()
}
