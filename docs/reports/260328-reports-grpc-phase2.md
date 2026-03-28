# PDCA Report: net.grpc Phase 2 — Streaming, Compression, TLS

## Date: 2026-03-28
## Branch: grpc
## Parent: 06e007c21 (Phase 1)

## PLAN

### Scope: 10 Features
1. Client streaming RPC
2. Server streaming RPC
3. Bidirectional streaming RPC (client + server combined)
4. gRPC compression (gzip registry, per-message)
5. gRPC timeout/deadline propagation (grpc-timeout header)
6. Rich error model (google.rpc.Status with details)
7. Metadata API (custom headers/trailers)
8. TLS transport (RawConn abstraction + ssl.SSLConn)
9. Frame demuxer (per-stream HTTP/2 frame routing)
10. End-to-end wiring (compression, timeout, metadata in RPC paths)

### Architecture Decisions
- **Frame demuxer**: Central read goroutine dispatches frames to per-stream channels
- **RawConn interface**: Abstraction over net.TcpConn/ssl.SSLConn for DIP compliance
- **Compression registry**: OCP-compliant — new compressors via registration, no code modification

## DO

### Execution: 12 Tasks, 4 Groups

- **G1 (parallel)**: T1 Compression module + T2 Timeout module + T3 Rich error status
- **G2 (parallel)**: T4 Metadata API + T5 RawConn abstraction + T6 TLS transport
- **G3 (sequential)**: T7 Frame demuxer + T8 Client streaming + T9 Server streaming
- **G4 (sequential)**: T10 End-to-end wiring + T11 Integration tests + T12 Bidirectional streaming

### TDD Compliance
All 12 tasks followed RED → GREEN → REFACTOR cycle. No violations.

## CHECK

### Iteration 1: 10 Issues Found
QA identified 10 issues across two categories:

**gRPC Protocol Issues (G2-01 through G2-08):**
- **G2-01 HIGH**: Frame demuxer missing — client streaming recv blocked on non-DATA frames
- **G2-02 HIGH**: Response HEADERS not consumed before DATA in client recv_msg
- **G2-03 HIGH**: Server send_status_trailer not called on error paths
- **G2-04 MEDIUM**: Compression flag not set in gRPC frame header when compressed
- **G2-05 MEDIUM**: Timeout header not propagated from client options to wire
- **G2-06 MEDIUM**: Metadata not included in request HEADERS frame
- **G2-07 MEDIUM**: TLS handshake not triggered on connect (lazy vs eager)
- **G2-08 LOW**: Status detail Any type_url missing package prefix

**Naming/Convention Issues (N1, N2):**
- **N1**: Inconsistent method naming (`recv_msg` vs `receive_message`)
- **N2**: Missing public API documentation on exported types

### Iteration 2: PASS
All 10 issues resolved. Re-CHECK passed with 0 violations.

## ACT: ITERATE → STANDARDIZE

- Iteration 1: 10 issues fixed in 3 parallel fix groups
- Iteration 2: Re-CHECK passed — decision: STANDARDIZE
- Total iterations: 2

## Metrics

### Code Volume (cumulative, Phase 1 + Phase 2)
| Metric | Count |
|--------|-------|
| Source files (non-test) | 17 |
| Test files | 19 |
| Total files | 36 |
| Source lines | 2,126 |
| Test lines | 3,098 |
| Total lines | 5,224 |
| Test functions | 176 |

### Phase 2 Delta
| Metric | Count |
|--------|-------|
| New files added | 16 |
| Files modified | 14 |
| Features delivered | 10 |
| Tasks executed | 12 |
| CHECK iterations | 2 |
| Issues found & fixed | 10 |

### Test Coverage Ratio
- Test:Source line ratio = 1.46:1 (3,098 test / 2,126 source)
- Test function density = 176 tests / 17 source files ≈ 10.4 tests/file

## Key Decisions

1. **Frame demuxer over buffer-all**: Per-stream channels (`chan Frame{cap: 8}`) for concurrent stream handling. Buffer-all approach from Phase 1 insufficient for streaming.
2. **RawConn abstraction before TLS**: Created interface first (DIP), then wrapped ssl.SSLConn. Made TLS addition a 2-file change.
3. **Compression registry (OCP)**: `register_compressor(name, Compressor)` pattern. New algorithms added without modifying existing code.
4. **V channel patterns**: Used `<-ch or { return error('closed') }` for blocking reads. Documented limitation: V channels do not support timed/select reads.
5. **Separate wire protocol from API**: Built compression/timeout/rich-errors as standalone modules, then wired into RPC paths. Effective but CHECK caught incomplete wiring.

## Lessons Applied from Phase 1
- L14 (DATA frame ≠ message boundary): Applied in streaming recv_msg accumulator
- L15 (Trailers-Only): Applied in server error responses
- L16 (Concurrent writes need mutex): Applied in frame demuxer write path
