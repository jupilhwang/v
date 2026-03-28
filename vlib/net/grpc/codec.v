module grpc

// Codec defines a serialization format for gRPC messages
pub interface Codec {
	// name returns the codec identifier (e.g., "proto", "json")
	name() string
}

// Note: For Phase 1, actual marshal/unmarshal happens via generics
// in encoding/proto/marshal.v. The Codec interface exists for
// content-type negotiation and future extensibility.
