module main

import net.grpc

struct HelloRequest {
	name string
}

struct HelloReply {
	message string
}

fn main() {
	// Connect to gRPC server (h2c — plaintext HTTP/2)
	mut conn := grpc.dial('127.0.0.1:50051') or {
		eprintln('Failed to connect: ${err}')
		return
	}
	defer {
		conn.close() or {}
	}

	// Create request
	request := HelloRequest{name: 'V Language'}

	// Make unary RPC call
	response := grpc.invoke_unary[HelloRequest, HelloReply](mut conn,
		'/helloworld.Greeter/SayHello', request, grpc.InvokeOptions{}) or {
		eprintln('RPC failed: ${err}')
		return
	}
	println('Server replied: ${response.message}')

	// Example with gzip compression
	compressed_response := grpc.invoke_unary[HelloRequest, HelloReply](mut conn,
		'/helloworld.Greeter/SayHello',
		HelloRequest{name: 'Compressed World'},
		grpc.InvokeOptions{encoding: 'gzip'}) or {
		eprintln('Compressed RPC failed: ${err}')
		return
	}
	println('Compressed reply: ${compressed_response.message}')

	// Example with 5-second timeout
	timeout_response := grpc.invoke_unary[HelloRequest, HelloReply](mut conn,
		'/helloworld.Greeter/SayHello',
		HelloRequest{name: 'Timeout World'},
		grpc.InvokeOptions{timeout_ns: 5_000_000_000}) or {
		eprintln('Timeout RPC failed: ${err}')
		return
	}
	println('Timeout reply: ${timeout_response.message}')
}
