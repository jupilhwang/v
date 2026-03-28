module main

import net.grpc
import encoding.proto

struct DataPoint {
	value int // field 1
}

struct Summary {
	count   int // field 1
	sum     int // field 2
	average int // field 3
}

// summarize accumulates data points from the client stream,
// then returns a single summary response.
// ClientStream.recv() already decodes gRPC frames internally.
fn summarize(mut stream grpc.ClientStream) ![]u8 {
	mut count := 0
	mut sum := 0

	for {
		data := stream.recv() or { break }
		point := proto.unmarshal[DataPoint](data) or { break }
		count++
		sum += point.value
	}

	average := if count > 0 { sum / count } else { 0 }
	result := Summary{
		count:   count
		sum:     sum
		average: average
	}
	return proto.marshal[Summary](result)!
}

fn main() {
	mut server := grpc.new_server(grpc.ServerConfig{ port: 50053 })

	server.register_client_streaming_method(
		'/stats.StatsService/Summarize',
		summarize
	)

	println('gRPC client streaming example on :50053')
	println('Registered methods:')
	println('  - /stats.StatsService/Summarize (client streaming)')

	server.serve() or {
		eprintln('Server error: ${err}')
	}
}
