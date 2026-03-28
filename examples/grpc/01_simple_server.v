module main

import net.grpc
import encoding.proto

// Protobuf message definitions — fields map to proto field numbers by position

struct HelloRequest {
	name string // field 1
}

struct HelloReply {
	message string // field 1
}

// say_hello handles unary SayHello RPC.
// Receives serialized request bytes, returns serialized response bytes.
fn say_hello(req_bytes []u8) ![]u8 {
	request := proto.unmarshal[HelloRequest](req_bytes)!

	reply := HelloReply{
		message: 'Hello, ${request.name}!'
	}

	return proto.marshal[HelloReply](reply)!
}

fn main() {
	mut server := grpc.new_server(grpc.ServerConfig{ port: 50051 })

	server.register_unary_method('/helloworld.Greeter/SayHello', say_hello)

	println('gRPC server listening on :50051')
	println('Registered methods:')
	println('  - /helloworld.Greeter/SayHello (unary)')

	server.serve() or {
		eprintln('Server error: ${err}')
	}
}
