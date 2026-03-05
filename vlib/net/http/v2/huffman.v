// Copyright (c) 2019-2024 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
@[has_globals]
module v2

// Huffman coding for HPACK (RFC 7541 Appendix B)
// This implements the static Huffman table from RFC 7541

// sentinel value indicating no trie child or no symbol
const huffman_trie_null = -1

// huffman_eos_symbol is the EOS pseudo-symbol index (RFC 7541 §5.2)
const huffman_eos_symbol = 256

// DecodeTrieNode is one node in the binary decode trie.
// Internal nodes have symbol == huffman_trie_null.
// Leaf nodes store the decoded symbol (0–255) or huffman_eos_symbol.
struct DecodeTrieNode {
mut:
	left   int // child index for bit value 0; huffman_trie_null if absent
	right  int // child index for bit value 1; huffman_trie_null if absent
	symbol int // decoded symbol, or huffman_trie_null for internal nodes
}

// Module-level trie storage; populated once by build_huffman_decode_trie.
__global huffman_decode_trie = []DecodeTrieNode{}

// huffman_encoded_length calculates the encoded length in bits for the given data
pub fn huffman_encoded_length(data []u8) int {
	mut bits := 0
	for b in data {
		bits += int(huffman_table[b].bit_length)
	}
	return bits
}

// encode_huffman encodes data using Huffman coding
pub fn encode_huffman(data []u8) []u8 {
	if data.len == 0 {
		return []u8{}
	}

	total_bits := huffman_encoded_length(data)
	total_bytes := (total_bits + 7) / 8

	mut result := []u8{len: total_bytes}
	mut current_byte := u8(0)
	mut bits_in_byte := 0
	mut byte_index := 0

	for b in data {
		entry := huffman_table[b]
		mut code := entry.code
		mut bits_left := int(entry.bit_length)

		for bits_left > 0 {
			bits_to_write := if bits_left < (8 - bits_in_byte) {
				bits_left
			} else {
				8 - bits_in_byte
			}

			shift := bits_left - bits_to_write
			mask := (u32(1) << bits_to_write) - 1
			bits := u8((code >> shift) & mask)

			current_byte |= bits << (8 - bits_in_byte - bits_to_write)
			bits_in_byte += bits_to_write
			bits_left -= bits_to_write

			if bits_in_byte == 8 {
				result[byte_index] = current_byte
				byte_index++
				current_byte = 0
				bits_in_byte = 0
			}
		}
	}

	if bits_in_byte > 0 {
		current_byte |= u8((1 << (8 - bits_in_byte)) - 1)
		result[byte_index] = current_byte
	}

	return result
}

// build_huffman_decode_trie constructs the binary decode trie from the static
// Huffman table (RFC 7541 Appendix B). It is called once before first use.
// Symbols 0–255 are leaves; symbol 256 (EOS) is included so decoding can
// detect and reject it per RFC 7541 §5.2.
fn build_huffman_decode_trie() {
	// Pre-size to avoid repeated reallocations; 2*257-1 = 513 nodes maximum.
	huffman_decode_trie = []DecodeTrieNode{cap: 513}
	huffman_decode_trie << DecodeTrieNode{
		left:   huffman_trie_null
		right:  huffman_trie_null
		symbol: huffman_trie_null
	}

	// Insert all 257 symbols (0–255 plus EOS at index 256).
	for sym in 0 .. 257 {
		entry := huffman_table[sym]
		code := entry.code
		nbits := int(entry.bit_length)

		mut node_idx := 0
		for bit_i := nbits - 1; bit_i >= 0; bit_i-- {
			bit := int((code >> u32(bit_i)) & 1)
			if bit == 0 {
				if huffman_decode_trie[node_idx].left == huffman_trie_null {
					huffman_decode_trie << DecodeTrieNode{
						left:   huffman_trie_null
						right:  huffman_trie_null
						symbol: huffman_trie_null
					}
					huffman_decode_trie[node_idx].left = huffman_decode_trie.len - 1
				}
				node_idx = huffman_decode_trie[node_idx].left
			} else {
				if huffman_decode_trie[node_idx].right == huffman_trie_null {
					huffman_decode_trie << DecodeTrieNode{
						left:   huffman_trie_null
						right:  huffman_trie_null
						symbol: huffman_trie_null
					}
					huffman_decode_trie[node_idx].right = huffman_decode_trie.len - 1
				}
				node_idx = huffman_decode_trie[node_idx].right
			}
		}
		huffman_decode_trie[node_idx].symbol = sym
	}
}

// init builds the Huffman decode trie once at module load time, before main()
// and before any goroutines start, ensuring thread-safe access without locks.
fn init() {
	build_huffman_decode_trie()
}

// decode_huffman decodes Huffman encoded data by walking the pre-built binary
// trie (RFC 7541 §5.2). This is O(n) in input bytes, replacing the former
// O(n × 256) linear table scan.
pub fn decode_huffman(data []u8) ![]u8 {
	if data.len == 0 {
		return []u8{}
	}

	mut result := []u8{cap: data.len * 2}
	mut node_idx := 0
	mut bits_since_root := 0 // how many bits into the current code we are

	for b in data {
		for bit_pos := 7; bit_pos >= 0; bit_pos-- {
			bit := int((b >> u8(bit_pos)) & 1)
			bits_since_root++

			next := if bit == 0 {
				huffman_decode_trie[node_idx].left
			} else {
				huffman_decode_trie[node_idx].right
			}

			if next == huffman_trie_null {
				return error('invalid Huffman code after ${bits_since_root} bits')
			}
			node_idx = next

			sym := huffman_decode_trie[node_idx].symbol
			if sym == huffman_trie_null {
				// Internal node — keep accumulating bits.
				continue
			}
			if sym == huffman_eos_symbol {
				// EOS must not appear in encoded data per RFC 7541 §5.2.
				return error('invalid Huffman sequence: EOS symbol in data')
			}
			result << u8(sym)
			node_idx = 0
			bits_since_root = 0
		}
	}

	// Any remaining bits must be all-1 padding of at most 7 bits (RFC 7541 §5.2).
	if bits_since_root > 7 {
		return error('invalid Huffman padding: ${bits_since_root} bits remaining')
	}
	if bits_since_root > 0 {
		check_huffman_padding(bits_since_root, node_idx)!
	}

	return result
}

// check_huffman_padding verifies that the remaining partial code is all-1 padding bits.
// It walks right-only children from the root, ensuring the path matches node_idx.
fn check_huffman_padding(bits_since_root int, node_idx int) ! {
	mut check_idx := 0
	for _ in 0 .. bits_since_root {
		right_child := huffman_decode_trie[check_idx].right
		if right_child == huffman_trie_null {
			return error('invalid Huffman padding')
		}
		// A valid padding path must not pass through a symbol leaf.
		if huffman_decode_trie[right_child].symbol != huffman_trie_null {
			return error('invalid Huffman padding')
		}
		check_idx = right_child
	}
	if check_idx != node_idx {
		return error('invalid Huffman padding')
	}
}
