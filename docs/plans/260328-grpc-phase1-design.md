# net.grpc Phase 1 Design — gRPC over HTTP/2

## Date
2026-03-28

## Scope
- **Unary RPC only** (1 request → 1 response)
- **HTTP/2 transport only** (h2c plaintext first, TLS deferred)
- **Pure V protobuf** (compile-time reflection `$for field in T.fields`)
- **Codec interface** for extensibility (OCP — JSON etc. can be added later)

## Import Strategy
- `transport/h2/*.v` → `import net.http.v2` (v2 Frame, HPACK, Stream direct reuse)
- `net.grpc` core module has NO dependency on `net.http.v2` (decoupled via Transport interface)
- V module system requires explicit `import net.http.v2` — parent `import net.http` does NOT expose v2 types

## Module Structure

```
vlib/net/grpc/
├── grpc.v              # Public API: dial(), invoke[Req,Resp]()
├── status.v            # 17 gRPC status codes + Status struct
├── frame.v             # 5-byte Length-Prefixed Message framing
├── metadata.v          # gRPC metadata (ASCII + -bin binary headers)
├── codec.v             # Codec interface definition
├── client.v            # ClientConn struct, unary RPC execution
├── server.v            # Server struct, service registration, dispatch loop
├── service.v           # ServiceDesc, MethodDesc, UnaryHandler type
├── transport/
│   ├── transport.v     # ClientTransport, ServerTransport, Stream interfaces
│   └── h2/
│       ├── h2_client.v # HTTP/2 ClientTransport (uses net.http.v2)
│       ├── h2_server.v # HTTP/2 ServerTransport (uses net.http.v2)
│       └── h2_stream.v # HTTP/2 Stream impl (HEADERS+DATA+trailing HEADERS)
├── encoding/
│   └── proto/
│       ├── codec.v     # ProtoCodec implementing Codec interface
│       ├── wire.v      # proto3 wire format: varint, zigzag, field tags
│       └── marshal.v   # $for-based auto marshal/unmarshal
└── *_test.v            # Unit tests per module
```

## Key Interfaces

### Codec (codec.v)
```v
pub interface Codec {
    name() string             // "proto", "json", etc.
    marshal(voidptr) ![]u8    // serialize any struct
    unmarshal([]u8, voidptr) ! // deserialize into struct
}
```

### Transport (transport/transport.v)
```v
pub interface ClientTransport {
    new_stream(method string, md Metadata) !&Stream
    close() !
}

pub interface ServerTransport {
    accept_stream() !&Stream
    close() !
}

pub interface Stream {
    send_header(md Metadata) !
    send_msg(data []u8) !
    recv_msg() ![]u8
    send_trailer(status Status, md Metadata) !
    recv_trailer() !(Status, Metadata)
    close_send() !
}
```

## Client API (Phase 1)
```v
import net.grpc

conn := grpc.dial('localhost:50051')!
defer { conn.close()! }

resp := grpc.invoke[HelloRequest, HelloResponse](
    conn, '/helloworld.Greeter/SayHello',
    HelloRequest{ name: 'World' }
)!
println(resp.message)
```

## Server API (Phase 1)
```v
import net.grpc

s := grpc.new_server(port: 50051)
s.register_unary_method('/helloworld.Greeter/SayHello',
    fn (req HelloRequest) !HelloResponse {
        return HelloResponse{ message: 'Hello ${req.name}' }
    })
s.serve()!
```

## Wire Protocol — Unary RPC Flow

```
Client → Server:
  HEADERS frame:
    :method = POST
    :scheme = http
    :path = /package.Service/Method
    :authority = host:port
    te = trailers
    content-type = application/grpc+proto

  DATA frame (END_STREAM):
    [0x00][4-byte big-endian length][protobuf bytes]

Server → Client:
  HEADERS frame:
    :status = 200
    content-type = application/grpc+proto

  DATA frame:
    [0x00][4-byte big-endian length][protobuf bytes]

  HEADERS frame (END_STREAM) — Trailers:
    grpc-status = 0
    [grpc-message = ...]
```

## gRPC Status Codes (status.v)

| Code | Name | Number |
|------|------|--------|
| OK | Success | 0 |
| CANCELLED | Caller cancelled | 1 |
| UNKNOWN | Unknown error | 2 |
| INVALID_ARGUMENT | Bad argument | 3 |
| DEADLINE_EXCEEDED | Timeout | 4 |
| NOT_FOUND | Not found | 5 |
| ALREADY_EXISTS | Already exists | 6 |
| PERMISSION_DENIED | No permission | 7 |
| RESOURCE_EXHAUSTED | Exhausted | 8 |
| FAILED_PRECONDITION | Bad state | 9 |
| ABORTED | Aborted | 10 |
| OUT_OF_RANGE | Out of range | 11 |
| UNIMPLEMENTED | Not implemented | 12 |
| INTERNAL | Internal error | 13 |
| UNAVAILABLE | Unavailable | 14 |
| DATA_LOSS | Data loss | 15 |
| UNAUTHENTICATED | Not authenticated | 16 |

## Length-Prefixed Message Framing (frame.v)

```
[1 byte: compressed flag (0 or 1)]
[4 bytes: message length (big-endian unsigned)]
[N bytes: message payload]
```

- Compressed flag = 0 in Phase 1 (no compression)
- Max message size: configurable, default 4MB (4,194,304 bytes)

## Protobuf Encoding (encoding/proto/)

Phase 1 supports proto3 wire format with these types:

| Wire Type | ID | V Types |
|-----------|----|---------|
| Varint | 0 | int, i8, i16, i32, i64, u8, u16, u32, u64, bool, enum |
| 64-bit | 1 | f64 (double) |
| Length-delimited | 2 | string, []u8, nested structs, repeated fields |
| 32-bit | 5 | f32 (float) |

Field numbers derived from struct field order (1-indexed) using V's `$for field in T.fields`.

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| v2 Connection coupled to ssl.SSLConn | h2_client.v uses TCP directly + HTTP/2 preface (h2c mode) |
| v2 client has no trailer API | h2_stream.v parses trailing HEADERS at frame level |
| V `$for` reflection limitations | Phase 1: basic types only; complex types in Phase 2 |
| common.Header 50-entry limit | gRPC uses own Metadata struct (not common.Header) |
| No concurrent stream reading in v2 | Phase 1 is unary only; streaming in Phase 2 |

## Deferred to Phase 2+

- Server/client/bidi streaming
- Compression (gzip, deflate, snappy)
- TLS (ALPN h2)
- Deadline/timeout propagation (grpc-timeout header)
- Interceptors/middleware
- Keepalive (PING frames)
- GOAWAY handling
- Name resolution + load balancing
- HTTP/3 transport
- protoc-gen-v code generator

## Decision Log

| Decision | Alternatives | Rationale |
|----------|-------------|-----------|
| Pure V protobuf | C binding, community lib | No external deps, V compile-time reflection makes it feasible |
| Transport abstraction | Direct v2 coupling | OCP for HTTP/3 in Phase 2+; clean layer separation |
| `import net.http.v2` in transport/h2/ | `import net.http` | V module system requires explicit submodule import |
| h2c (plaintext) first | TLS first | Simpler development/testing; TLS in Phase 2 |
| Unary only | All streaming modes | Smallest viable scope; streaming in Phase 2 |
