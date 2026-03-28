module proto

// ProtoCodec implements the gRPC Codec interface for protobuf.
// Phase 1: delegates to the generic marshal[T]/unmarshal[T] functions.
// Full voidptr-based integration happens in T6 (gRPC transport).
pub struct ProtoCodec {}

// Codec name identifier used by gRPC content-type negotiation.
pub fn (c ProtoCodec) name() string {
	return 'proto'
}

// Marshal serializes a message to protobuf bytes.
// Phase 1 limitation: use marshal[T]() directly for type-safe encoding.
pub fn (c ProtoCodec) marshal_msg(msg voidptr, size int) ![]u8 {
	return error('use marshal[T]() directly for Phase 1')
}

// Unmarshal deserializes protobuf bytes into a message.
// Phase 1 limitation: use unmarshal[T]() directly for type-safe decoding.
pub fn (c ProtoCodec) unmarshal_msg(data []u8, msg voidptr) ! {
	return error('use unmarshal[T]() directly for Phase 1')
}
