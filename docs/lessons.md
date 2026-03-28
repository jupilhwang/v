# Lessons Learned

## L12: V generic parameters must be single-character
- V rejected `[Req, Resp]` for generics; must use `[T, R]`
- Impact: Less readable but V compiler requirement

## L13: V interface covariant returns not supported
- V rejected `!&H2Stream` as implementation of `!transport.Stream`
- Fix: Return `!transport.Stream` explicitly from interface methods

## L14: gRPC DATA frame ≠ message boundary
- HTTP/2 DATA frame boundaries are independent of gRPC Length-Prefixed Message boundaries
- Always accumulate DATA frames and parse gRPC frame header to determine message length

## L15: gRPC Trailers-Only requires initial headers
- Error responses before data must include :status 200 and content-type in the trailing HEADERS
- This is the "Trailers-Only" format per PROTOCOL-HTTP2.md

## L16: Concurrent HTTP/2 stream writes need mutex
- Multiple gRPC handlers writing to same TCP connection need serialization
- V's sync.Mutex works for this; wrap write_frame() at transport level

## L17: Frame demuxer required for HTTP/2 streaming
- gRPC client streaming requires per-stream frame demultiplexing
- Initial "buffer all DATA" approach works for unary but fails fundamentally for streaming
- Correct architecture: central read goroutine → per-stream channels (`chan Frame{cap: N}`)

## L18: V channel-based concurrency patterns
- V channels (`chan T{cap: N}`) work well for frame demuxing
- Key patterns: `<-ch or { return error('closed') }` for blocking reads, `spawn fn() {}` for goroutines
- Limitation: V channels do NOT support timed reads (no select with timeout) — document as known constraint

## L19: RawConn abstraction enables TLS without rewrite
- Creating a `RawConn` interface early (before TLS needed) made TLS support trivial — just wrap ssl.SSLConn
- DIP principle validated: depend on abstractions, not concretes
- Two-file change to add TLS: rawconn.v + ssl_conn.v

## L20: Wire protocol features separately from API features
- Building compression/timeout/rich-errors as standalone modules (G1) then wiring them (T10) was effective
- But CHECK found the wiring was incomplete — always verify end-to-end protocol paths, not just unit tests
- Standalone module tests can pass while integration fails silently

## L21: Response HEADERS must be consumed before DATA
- gRPC over HTTP/2 sends: initial HEADERS → DATA frames → trailing HEADERS
- Client recv_msg must handle the initial HEADERS frame before processing DATA
- Common oversight when building on top of HTTP/2 directly — first frame from server is HEADERS, not DATA
