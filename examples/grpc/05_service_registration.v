module main

import net.grpc
import encoding.proto

struct EchoRequest {
	message string // field 1
}

struct EchoReply {
	message string // field 1
}

struct UpperRequest {
	text string // field 1
}

struct UpperReply {
	text string // field 1
}

// echo_handler returns the request message unchanged
fn echo_handler(req_bytes []u8) ![]u8 {
	request := proto.unmarshal[EchoRequest](req_bytes)!
	reply := EchoReply{message: request.message}
	return proto.marshal[EchoReply](reply)!
}

// upper_handler converts the request text to uppercase
fn upper_handler(req_bytes []u8) ![]u8 {
	request := proto.unmarshal[UpperRequest](req_bytes)!
	reply := UpperReply{text: request.text.to_upper()}
	return proto.marshal[UpperReply](reply)!
}

fn main() {
	mut server := grpc.new_server(grpc.ServerConfig{ port: 50054 })

	// Register via service descriptor — groups related methods under one service name
	service := grpc.ServiceDesc{
		name:    'text.TextService'
		methods: [
			grpc.MethodDesc{name: 'Echo', handler: echo_handler},
			grpc.MethodDesc{name: 'ToUpper', handler: upper_handler},
		]
	}
	server.register_service(service)

	println('gRPC multi-method service example on :50054')
	println('Registered service: text.TextService')
	println('  - /text.TextService/Echo (unary)')
	println('  - /text.TextService/ToUpper (unary)')

	server.serve() or {
		eprintln('Server error: ${err}')
	}
}
