module grpc

fn test_status_code_values() {
	assert int(StatusCode.ok) == 0
	assert int(StatusCode.cancelled) == 1
	assert int(StatusCode.unknown) == 2
	assert int(StatusCode.invalid_argument) == 3
	assert int(StatusCode.deadline_exceeded) == 4
	assert int(StatusCode.not_found) == 5
	assert int(StatusCode.already_exists) == 6
	assert int(StatusCode.permission_denied) == 7
	assert int(StatusCode.resource_exhausted) == 8
	assert int(StatusCode.failed_precondition) == 9
	assert int(StatusCode.aborted) == 10
	assert int(StatusCode.out_of_range) == 11
	assert int(StatusCode.unimplemented) == 12
	assert int(StatusCode.internal) == 13
	assert int(StatusCode.unavailable) == 14
	assert int(StatusCode.data_loss) == 15
	assert int(StatusCode.unauthenticated) == 16
}

fn test_new_status() {
	s := new_status(.not_found, 'resource not found')
	assert s.code == .not_found
	assert s.message == 'resource not found'
}

fn test_status_ok() {
	s := status_ok()
	assert s.code == .ok
	assert s.is_ok()
}

fn test_status_is_ok() {
	ok := new_status(.ok, '')
	assert ok.is_ok()

	err := new_status(.internal, 'server error')
	assert !err.is_ok()
}

fn test_status_str() {
	s := new_status(.not_found, 'missing')
	result := s.str()
	assert result.contains('not_found')
	assert result.contains('missing')
}
