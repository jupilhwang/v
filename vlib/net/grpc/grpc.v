module grpc

import encoding.proto

// invoke_unary performs a typed unary RPC call.
// T = request type, R = response type.
// Marshals request, sends, receives, and unmarshals response.
pub fn invoke_unary[T, R](mut conn ClientConn, method string, req T, opts InvokeOptions) !R {
	req_bytes := proto.marshal[T](req)!
	resp_bytes := conn.invoke(method, req_bytes, opts)!
	return proto.unmarshal[R](resp_bytes)
}

// ServerStreamReaderTyped wraps ServerStreamReader with typed deserialization
pub struct ServerStreamReaderTyped[R] {
mut:
	reader ServerStreamReader
}

// recv reads and unmarshals the next response message
pub fn (mut r ServerStreamReaderTyped[R]) recv() ?R {
	data := r.reader.recv() or { return none }
	result := proto.unmarshal[R](data) or { return none }
	return result
}

// trailer returns the gRPC status after stream ends
pub fn (mut r ServerStreamReaderTyped[R]) trailer() !Status {
	return r.reader.trailer()
}

// ClientStreamWriterTyped provides typed sending for client streaming RPCs
pub struct ClientStreamWriterTyped[T, R] {
mut:
	writer ClientStreamWriter
}

// send marshals and sends a single request message
pub fn (mut w ClientStreamWriterTyped[T, R]) send(msg T) ! {
	data := proto.marshal[T](msg)!
	w.writer.send(data)!
}

// close_and_recv closes the send side and receives the typed response
pub fn (mut w ClientStreamWriterTyped[T, R]) close_and_recv() !R {
	resp_data := w.writer.close_and_recv()!
	return proto.unmarshal[R](resp_data)
}

// invoke_client_streaming opens a typed client streaming call
pub fn invoke_client_streaming[T, R](mut conn ClientConn, method string) !ClientStreamWriterTyped[T, R] {
	writer := conn.invoke_client_streaming(method)!
	return ClientStreamWriterTyped[T, R]{writer: writer}
}
