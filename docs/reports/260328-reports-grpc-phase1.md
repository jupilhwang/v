# PDCA Report: net.grpc Phase 1 — Unary RPC over HTTP/2

## Date: 2026-03-28
## Branch: grpc
## Commit: 18d21d09f

## PLAN
- Scope: Unary RPC only, HTTP/2 h2c transport, pure V protobuf
- Architecture: Transport abstraction (DIP) with codec interface (OCP)
- 8 tasks across 4 execution groups

## DO
- G1 (parallel): T1 Proto wire format + T2 Core types + T3 Transport interfaces
- G2 (sequential): T4 H2 client transport + T5 H2 server transport
- G3 (parallel): T6 gRPC client + T7 gRPC server
- G3.5: Moved encoding/proto to vlib/encoding/proto/ (user-requested refactor)

## CHECK (Iteration 1)
- 15/15 test suites pass
- 6 bugs found by QA:
  - B1 HIGH: Non-compliant trailers-only (missing :status 200)
  - B2 HIGH: Fragmented DATA frame handling
  - B3 HIGH: Concurrent write race condition
  - B4 MEDIUM: Duplicate content-type/te headers
  - B5 MEDIUM: Missing request validation
  - B6 MEDIUM: Metadata key validation bypass

## ACT: ITERATE → STANDARDIZE
- All 6 bugs fixed in 3 parallel tasks
- Re-CHECK: 15/15 pass
- Decision: STANDARDIZE

## Metrics
- Files: 25 new files
- Lines: ~2943 lines of code
- Tests: 15 test files, ~70+ test functions
- TDD: All features RED→GREEN→REFACTOR verified
- Iterations: 1 (6 bugs fixed on first iteration)

## Key Decisions
1. Pure V protobuf via $for reflection (no external deps)
2. Transport abstraction for future HTTP/3 support
3. encoding/proto as standalone vlib module (user request)
4. h2c (plaintext) for Phase 1 (no TLS)
5. Codec interface for OCP extensibility
