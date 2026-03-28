module h2

import net.http.v2

// H2ServerStream represents a server-side gRPC stream.
// Implements transport.Stream via structural typing.
pub struct H2ServerStream {
pub:
	sid u32
pub mut:
	transport  &H2ServerTransport = unsafe { nil }
	headers    map[string]string
	recv_buf   []u8
	end_stream bool
	frame_ch   chan v2.Frame
}

// stream_id returns the HTTP/2 stream identifier.
pub fn (s &H2ServerStream) stream_id() u32 {
	return s.sid
}

// send_header sends gRPC response HEADERS (:status 200, content-type).
pub fn (mut s H2ServerStream) send_header(headers map[string]string) ! {
	mut t := s.transport
	encoded := encode_grpc_response_headers(mut t.encoder, headers)
	hf := v2.HeadersFrame{
		stream_id:   s.sid
		headers:     encoded
		end_headers: true
	}
	t.write_frame(hf.to_frame())!
}

// recv_header returns request headers already parsed during stream creation.
pub fn (mut s H2ServerStream) recv_header() !map[string]string {
	return s.headers.clone()
}

// send_msg sends a DATA frame with response message bytes.
pub fn (mut s H2ServerStream) send_msg(data []u8) ! {
	frame := build_data_frame(s.sid, data, false)
	s.transport.write_frame(frame)!
}

// recv_msg reads DATA frames from the per-stream channel and returns
// a complete gRPC Length-Prefixed Message when available.
// WARNING: blocks on channel read until data arrives or channel closes.
// V channels do not support timeout-based reads natively.
// TODO(G2-08): Add deadline/cancellation support when V channels support timed reads.
pub fn (mut s H2ServerStream) recv_msg() ![]u8 {
	for {
		if s.recv_buf.len >= 5 {
			msg_len := parse_grpc_msg_len(s.recv_buf)
			total := 5 + msg_len
			if s.recv_buf.len >= total {
				result := s.recv_buf[..total].clone()
				s.recv_buf = s.recv_buf[total..].clone()
				return result
			}
		}
		if s.end_stream {
			return error('end of stream')
		}
		frame := <-s.frame_ch or { return error('stream closed') }
		df := v2.DataFrame.from_frame(frame)!
		s.recv_buf << df.data
		if frame.header.has_flag(.end_stream) {
			s.end_stream = true
		}
	}
	return error('unreachable')
}

// send_trailer sends trailing HEADERS with END_STREAM (grpc-status, grpc-message).
// Also cleans up the stream channel to prevent memory leaks (G2-06).
pub fn (mut s H2ServerStream) send_trailer(trailers map[string]string) ! {
	mut t := s.transport
	frame := encode_trailing_headers(mut t.encoder, s.sid, trailers)
	t.write_frame(frame)!
	t.cleanup_stream(s.sid)
}

// recv_trailer is not used on server side (client doesn't send trailers in unary).
pub fn (mut s H2ServerStream) recv_trailer() !map[string]string {
	return error('recv_trailer not supported on server stream')
}

// close_send sends an empty DATA frame with END_STREAM.
pub fn (mut s H2ServerStream) close_send() ! {
	frame := build_data_frame(s.sid, []u8{}, true)
	s.transport.write_frame(frame)!
}

// parse_grpc_msg_len extracts the 4-byte big-endian message length
// from a gRPC Length-Prefixed Message header (bytes 1-4).
fn parse_grpc_msg_len(buf []u8) int {
	return (int(buf[1]) << 24) | (int(buf[2]) << 16) | (int(buf[3]) << 8) | int(buf[4])
}
