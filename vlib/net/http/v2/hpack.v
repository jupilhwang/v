// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module v2

// HPACK - Header Compression for HTTP/2 (RFC 7541)

// Static table entries (RFC 7541 Appendix A)
const static_table = [
	HeaderField{'', ''},
	HeaderField{':authority', ''},
	HeaderField{':method', 'GET'},
	HeaderField{':method', 'POST'},
	HeaderField{':path', '/'},
	HeaderField{':path', '/index.html'},
	HeaderField{':scheme', 'http'},
	HeaderField{':scheme', 'https'},
	HeaderField{':status', '200'},
	HeaderField{':status', '204'},
	HeaderField{':status', '206'},
	HeaderField{':status', '304'},
	HeaderField{':status', '400'},
	HeaderField{':status', '404'},
	HeaderField{':status', '500'},
	HeaderField{'accept-charset', ''},
	HeaderField{'accept-encoding', 'gzip, deflate'},
	HeaderField{'accept-language', ''},
	HeaderField{'accept-ranges', ''},
	HeaderField{'accept', ''},
	HeaderField{'access-control-allow-origin', ''},
	HeaderField{'age', ''},
	HeaderField{'allow', ''},
	HeaderField{'authorization', ''},
	HeaderField{'cache-control', ''},
	HeaderField{'content-disposition', ''},
	HeaderField{'content-encoding', ''},
	HeaderField{'content-language', ''},
	HeaderField{'content-length', ''},
	HeaderField{'content-location', ''},
	HeaderField{'content-range', ''},
	HeaderField{'content-type', ''},
	HeaderField{'cookie', ''},
	HeaderField{'date', ''},
	HeaderField{'etag', ''},
	HeaderField{'expect', ''},
	HeaderField{'expires', ''},
	HeaderField{'from', ''},
	HeaderField{'host', ''},
	HeaderField{'if-match', ''},
	HeaderField{'if-modified-since', ''},
	HeaderField{'if-none-match', ''},
	HeaderField{'if-range', ''},
	HeaderField{'if-unmodified-since', ''},
	HeaderField{'last-modified', ''},
	HeaderField{'link', ''},
	HeaderField{'location', ''},
	HeaderField{'max-forwards', ''},
	HeaderField{'proxy-authenticate', ''},
	HeaderField{'proxy-authorization', ''},
	HeaderField{'range', ''},
	HeaderField{'referer', ''},
	HeaderField{'refresh', ''},
	HeaderField{'retry-after', ''},
	HeaderField{'server', ''},
	HeaderField{'set-cookie', ''},
	HeaderField{'strict-transport-security', ''},
	HeaderField{'transfer-encoding', ''},
	HeaderField{'user-agent', ''},
	HeaderField{'vary', ''},
	HeaderField{'via', ''},
	HeaderField{'www-authenticate', ''},
]

// Static table lookup maps for O(1) access
// Map from "name:value" to index (for exact matches)
const static_table_exact_map = build_exact_map()

// Map from "name" to list of indices (for name-only matches)
const static_table_name_map = build_name_map()

// build_exact_map builds a map for exact header matches
fn build_exact_map() map[string]int {
	mut m := map[string]int{}
	for i, entry in static_table {
		if entry.name != '' {
			key := '${entry.name}:${entry.value}'
			if key !in m {
				m[key] = i // static_table[0] is a dummy; real entries start at index 1
			}
		}
	}
	return m
}

// build_name_map builds a map for name-only matches
fn build_name_map() map[string][]int {
	mut m := map[string][]int{}
	for i, entry in static_table {
		if entry.name != '' {
			if entry.name !in m {
				m[entry.name] = []int{}
			}
			m[entry.name] << i // static_table[0] is a dummy; real entries start at index 1
		}
	}
	return m
}

// HeaderField represents a name-value pair
pub struct HeaderField {
pub mut:
	name  string
	value string
}

// size returns the size of the header field in bytes (RFC 7541 Section 4.1)
pub fn (h HeaderField) size() int {
	return 32 + h.name.len + h.value.len
}

// DynamicTable represents the HPACK dynamic table.
// HPACK uses LIFO ordering per RFC 7541 §2.3.3: the newest entry is always at
// index 0 (front of array). Older entries are pushed toward higher indices and
// evicted from the back. This is the opposite of QPACK (HTTP/3), which uses
// absolute/relative indexing with entries appended to the back.
pub struct DynamicTable {
mut:
	entries  []HeaderField
	size     int
	max_size int = 4096 // Default from RFC 7541
}

// add adds an entry to the dynamic table, evicting oldest entries as needed (RFC 7541 §4.4).
// If the new entry alone exceeds max_size, the table is emptied and the entry is not added.
pub fn (mut dt DynamicTable) add(field HeaderField) {
	entry_size := field.size()

	// Per RFC 7541 §4.4: if the new entry is larger than max_size, empty the table
	if entry_size > dt.max_size {
		dt.entries = []HeaderField{}
		dt.size = 0
		return
	}

	// Evict oldest entries (from end of array) until there is room
	for dt.size + entry_size > dt.max_size && dt.entries.len > 0 {
		removed := dt.entries.pop()
		dt.size -= removed.size()
	}

	// Add new entry at the beginning (newest = index 1).
	// insert(0) is O(n), but max_size enforcement keeps the array small
	// (default 4096 bytes → at most ~128 entries), so this is acceptable.
	dt.entries.insert(0, field)
	dt.size += entry_size
}

// get retrieves an entry from the dynamic table (1-indexed)
pub fn (dt DynamicTable) get(index int) ?HeaderField {
	if index < 1 || index > dt.entries.len {
		return none
	}
	return dt.entries[index - 1]
}

// set_max_size updates the maximum size of the dynamic table
pub fn (mut dt DynamicTable) set_max_size(size int) {
	dt.max_size = size

	// Evict entries if necessary
	for dt.size > dt.max_size && dt.entries.len > 0 {
		removed := dt.entries.pop()
		dt.size -= removed.size()
	}
}

// sensitive_headers is the set of header names that must never be indexed per
// RFC 7541 §7.1.  Intermediaries are prohibited from re-encoding these fields
// with indexing, preventing their values from being stored in dynamic tables.
const sensitive_headers = ['authorization', 'cookie', 'set-cookie', 'proxy-authorization']

// get_indexed retrieves a header field from static or dynamic table
fn get_indexed(dynamic_table &DynamicTable, index int) ?HeaderField {
	if index == 0 {
		return none
	}

	// Static table (index directly corresponds to array position since static_table[0] is dummy)
	if index < static_table.len {
		return static_table[index]
	}

	// Dynamic table
	dynamic_index := index - static_table.len + 1
	return dynamic_table.get(dynamic_index)
}
