module grpc

// TimeUnit represents gRPC timeout units per the gRPC wire format spec.
// Header format: {1-8 digit positive integer}{unit char}
pub enum TimeUnit {
	hours // H
	minutes // M
	seconds // S
	milliseconds // m
	microseconds // u
	nanoseconds // n
}

// Timeout represents a parsed gRPC timeout value
pub struct Timeout {
pub:
	value i64
	unit  TimeUnit
}

// encode_timeout converts a duration in nanoseconds to a gRPC timeout header value.
// Picks the largest unit that fits without losing precision and within 8 digits.
pub fn encode_timeout(duration_ns i64) string {
	if duration_ns == 0 {
		return '0n'
	}
	units := [TimeUnit.hours, .minutes, .seconds, .milliseconds, .microseconds, .nanoseconds]
	for u in units {
		divisor := ns_per_unit(u)
		if duration_ns % divisor == 0 {
			val := duration_ns / divisor
			if val > 0 && val <= 99999999 {
				return '${val}${rune(unit_char(u))}'
			}
		}
	}
	// Fallback to nanoseconds
	return '${duration_ns}${rune(unit_char(.nanoseconds))}'
}

// decode_timeout parses a gRPC timeout header value like "1S" or "500m".
// Returns the duration in nanoseconds.
pub fn decode_timeout(s string) !i64 {
	if s.len == 0 {
		return error('empty timeout string')
	}
	if s.len < 2 {
		return error('timeout too short: need at least 1 digit and 1 unit char')
	}
	digit_part := s[..s.len - 1]
	unit_byte := s[s.len - 1]
	if digit_part.len > 8 {
		return error('too many digits: max 8, got ${digit_part.len}')
	}
	for c in digit_part {
		if c < `0` || c > `9` {
			return error('invalid character in digits: ${rune(c)}')
		}
	}
	value := digit_part.i64()
	u := char_to_unit(unit_byte)!
	return value * ns_per_unit(u)
}

// str converts a Timeout struct to its gRPC header string representation
pub fn (t &Timeout) str() string {
	return '${t.value}${rune(unit_char(t.unit))}'
}

// unit_char returns the gRPC wire format character for a TimeUnit
fn unit_char(u TimeUnit) u8 {
	return match u {
		.hours { `H` }
		.minutes { `M` }
		.seconds { `S` }
		.milliseconds { `m` }
		.microseconds { `u` }
		.nanoseconds { `n` }
	}
}

// char_to_unit converts a gRPC wire format character to a TimeUnit
fn char_to_unit(c u8) !TimeUnit {
	return match c {
		`H` { TimeUnit.hours }
		`M` { TimeUnit.minutes }
		`S` { TimeUnit.seconds }
		`m` { TimeUnit.milliseconds }
		`u` { TimeUnit.microseconds }
		`n` { TimeUnit.nanoseconds }
		else { error('invalid timeout unit: ${rune(c)}') }
	}
}

// ns_per_unit returns the number of nanoseconds in one unit
fn ns_per_unit(u TimeUnit) i64 {
	return match u {
		.hours { i64(3_600_000_000_000) }
		.minutes { i64(60_000_000_000) }
		.seconds { i64(1_000_000_000) }
		.milliseconds { i64(1_000_000) }
		.microseconds { i64(1_000) }
		.nanoseconds { i64(1) }
	}
}
