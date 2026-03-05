// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// Performance infrastructure: buffer pool, frame buffer, and statistics.

// Optimized buffer pool for reducing allocations.
// TODO: BufferPool is not yet integrated into the client/server pipeline.
// It is defined here for future use to reduce per-frame allocations.
struct BufferPool {
mut:
	buffers [][]u8
	size    int
}

// new_buffer_pool creates a new buffer pool for reducing memory allocations
pub fn new_buffer_pool(size int, count int) BufferPool {
	mut buffers := [][]u8{cap: count}
	for _ in 0 .. count {
		buffers << []u8{len: size, cap: size}
	}
	return BufferPool{
		buffers: buffers
		size:    size
	}
}

// get gets a buffer from the pool or creates a new one if empty
pub fn (mut p BufferPool) get() []u8 {
	if p.buffers.len > 0 {
		buf := p.buffers[p.buffers.len - 1]
		p.buffers = p.buffers[..p.buffers.len - 1]
		return buf
	}
	return []u8{len: p.size, cap: p.size}
}

// put returns a buffer to the pool for reuse after clearing it
pub fn (mut p BufferPool) put(buf []u8) {
	if buf.cap == p.size {
		// unsafe is required here because `buf` is an immutable parameter; we need a
		// mutable alias to call trim() on its backing memory without copying the slice.
		mut b := unsafe { buf }
		b.trim(0)
		p.buffers << b
	}
}

// Memory-efficient frame buffer.
// TODO: FrameBuffer is not yet integrated into the client/server pipeline.
// It is defined here for future use to enable zero-copy frame serialization.
pub struct FrameBuffer {
mut:
	data   []u8
	offset int
}

// new_frame_buffer creates a new frame buffer with the specified size.
pub fn new_frame_buffer(size int) FrameBuffer {
	return FrameBuffer{
		data:   []u8{len: size, cap: size}
		offset: 0
	}
}

// reset resets the frame buffer offset to zero, making it ready for new data.
@[inline]
pub fn (mut fb FrameBuffer) reset() {
	fb.offset = 0
}

// write writes data to the frame buffer using bulk copy. Returns false if there is not enough space.
@[inline]
pub fn (mut fb FrameBuffer) write(data []u8) bool {
	if fb.offset + data.len > fb.data.len {
		return false
	}

	if data.len > 0 {
		copy(mut fb.data[fb.offset..], data)
	}
	fb.offset += data.len
	return true
}

// bytes returns the written bytes from the frame buffer.
@[inline]
pub fn (fb FrameBuffer) bytes() []u8 {
	return fb.data[..fb.offset]
}

// Statistics for performance monitoring.
// TODO: Stats is not yet integrated into the client/server pipeline.
// It is defined here for future use to expose request throughput metrics.
pub struct Stats {
pub mut:
	total_requests       u64
	successful_requests  u64
	failed_requests      u64
	total_bytes_sent     u64
	total_bytes_received u64
	total_time_ms        u64
	min_time_ms          u64 = 999999
	max_time_ms          u64
}

// record_request records statistics for a single request.
pub fn (mut s Stats) record_request(success bool, bytes_sent int, bytes_received int, time_ms u64) {
	s.total_requests++
	if success {
		s.successful_requests++
	} else {
		s.failed_requests++
	}
	s.total_bytes_sent += u64(bytes_sent)
	s.total_bytes_received += u64(bytes_received)
	s.total_time_ms += time_ms

	if time_ms < s.min_time_ms {
		s.min_time_ms = time_ms
	}
	if time_ms > s.max_time_ms {
		s.max_time_ms = time_ms
	}
}

// avg_time_ms calculates and returns the average request time in milliseconds.
pub fn (s Stats) avg_time_ms() f64 {
	if s.total_requests == 0 {
		return 0.0
	}
	return f64(s.total_time_ms) / f64(s.total_requests)
}

// success_rate calculates and returns the request success rate as a percentage.
pub fn (s Stats) success_rate() f64 {
	if s.total_requests == 0 {
		return 0.0
	}
	return f64(s.successful_requests) / f64(s.total_requests) * 100.0
}

// print displays the performance statistics to stdout.
pub fn (s Stats) print() {
	println('Performance Statistics:')
	println('  Total requests: ${s.total_requests}')
	println('  Successful: ${s.successful_requests}')
	println('  Failed: ${s.failed_requests}')
	println('  Success rate: ${s.success_rate():.2f}%')
	println('  Total bytes sent: ${s.total_bytes_sent}')
	println('  Total bytes received: ${s.total_bytes_received}')
	println('  Average time: ${s.avg_time_ms():.2f}ms')
	println('  Min time: ${s.min_time_ms}ms')
	println('  Max time: ${s.max_time_ms}ms')
}
