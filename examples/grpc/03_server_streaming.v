module main

import net.grpc
import encoding.proto

struct NumberRequest {
	count int // field 1
}

struct NumberReply {
	value   int    // field 1
	message string // field 2
}

// generate_numbers streams 'count' numbered responses back to the client.
// ServerStream handles framing internally — just pass marshaled bytes to send().
fn generate_numbers(req_bytes []u8, mut stream grpc.ServerStream) ! {
	request := proto.unmarshal[NumberRequest](req_bytes)!

	for i := 1; i <= request.count; i++ {
		reply := NumberReply{
			value:   i
			message: 'Number ${i} of ${request.count}'
		}
		reply_bytes := proto.marshal[NumberReply](reply)!
		stream.send(reply_bytes)!
	}
	// Stream closes with OK status automatically after handler returns
}

fn main() {
	mut server := grpc.new_server(grpc.ServerConfig{ port: 50052 })

	server.register_server_streaming_method(
		'/numbers.NumberService/GenerateNumbers',
		generate_numbers
	)

	println('gRPC server streaming example on :50052')
	println('Registered methods:')
	println('  - /numbers.NumberService/GenerateNumbers (server streaming)')

	server.serve() or {
		eprintln('Server error: ${err}')
	}
}
