use super::{HEAD_MAX, Status, body_len, head_len, sealed_response_head};
use crate::envelope::{Rejection, SEALED_MAX};

fn head(headers: &[&str]) -> Vec<u8> {
	let mut head = String::from("POST / HTTP/1.1\r\n");
	for header in headers {
		head.push_str(header);
		head.push_str("\r\n");
	}
	head.push_str("\r\n");
	head.into_bytes()
}

#[test]
fn the_head_ends_after_the_first_blank_line_and_not_before_it_arrives() {
	let request = [head(&["Content-Length: 300"]), b"body\r\n\r\nmore".to_vec()].concat();
	let len = head(&["Content-Length: 300"]).len();
	assert_eq!(head_len(&request), Some(len));
	for cut in 0..len {
		assert_eq!(head_len(&request[..cut]), None, "{cut}");
	}
	assert_eq!(head_len(b"POST / HTTP/1.1\n\nContent-Length: 9\n\n"), None);
	assert_eq!(head_len(b"\r\n\r\n"), Some(4));
	assert_eq!(HEAD_MAX, 8 << 10);
}

#[test]
fn a_head_declares_its_body_with_one_content_length_and_other_headers_are_ignored() {
	assert_eq!(body_len(&head(&["Content-Length: 300"])), Ok(300));
	assert_eq!(
		body_len(&head(&[
			"Host: notes.example",
			"content-LENGTH:\t 4124 \t",
			"Expect: 100-continue",
			"X-Odd: \u{1}\u{7f} :: value",
			"Empty:",
		])),
		Ok(4124)
	);
	assert_eq!(body_len(&head(&["Content-Length: 028"])), Ok(28));
	assert_eq!(
		body_len(&head(&["Content-Length: 0"])),
		Err(Status::BadRequest)
	);
	assert_eq!(
		body_len(&head(&["Content-Length: 27"])),
		Err(Status::BadRequest)
	);
	assert_eq!(
		body_len(&head(&[&format!("Content-Length: {SEALED_MAX}")])),
		Ok(SEALED_MAX)
	);
	for too_large in [
		format!("Content-Length: {}", SEALED_MAX + 1),
		format!("Content-Length: {}", u64::MAX),
		format!("Content-Length: {}0", u64::MAX),
		"Content-Length: 99999999999999999999999999999999999999999".to_owned(),
	] {
		assert_eq!(
			body_len(&head(&[&too_large])),
			Err(Status::TooLarge),
			"{too_large}"
		);
	}
}

#[test]
fn at_most_one_hundred_headers_are_accepted() {
	let others: Vec<String> = (0..99)
		.map(|index| format!("X-Header-{index}: {index}"))
		.collect();
	let mut headers: Vec<&str> = others.iter().map(String::as_str).collect();
	headers.push("Content-Length: 300");
	assert_eq!(body_len(&head(&headers)), Ok(300));
	headers.insert(0, "X-One-Too-Many: 1");
	assert_eq!(body_len(&head(&headers)), Err(Status::BadRequest));
}

#[test]
fn any_other_request_line_is_a_bad_request() {
	for line in [
		"GET / HTTP/1.1",
		"post / HTTP/1.1",
		"POST /notes HTTP/1.1",
		"POST //  HTTP/1.1",
		"POST http://host/ HTTP/1.1",
		"POST / HTTP/1.0",
		"POST / HTTP/2",
		"POST /  HTTP/1.1",
		" POST / HTTP/1.1",
		"POST / HTTP/1.1 ",
		"",
	] {
		let request = format!("{line}\r\nContent-Length: 300\r\n\r\n");
		assert_eq!(
			body_len(request.as_bytes()),
			Err(Status::BadRequest),
			"{line:?}"
		);
	}
}

#[test]
fn bad_framing_is_a_bad_request() {
	for headers in [
		&[][..],
		&["Content-Length: 300", "Content-Length: 300"],
		&["Content-Length: 300", "content-length: 301"],
		&["Content-Length: 300", "Transfer-Encoding: chunked"],
		&["transfer-encoding: identity", "Content-Length: 300"],
		&["Content-Length:"],
		&["Content-Length: +300"],
		&["Content-Length: -300"],
		&["Content-Length: 3 00"],
		&["Content-Length: 0x12c"],
		&["Content-Length: 300,300"],
		&["Content-Length: ３００"],
		&["Content-Length : 300"],
		&["Content-Length\t: 300"],
		&[" Content-Length: 300"],
		&["Content-Length: 300", " folded"],
		&["Content-Length: 300", "\tfolded: value"],
		&["Content-Length: 300", "No colon"],
		&["Content-Length: 300", ": no name"],
		&["Content-Length: 300", "Bad(name): value"],
		&["Content-Length: 300", "Bad name: value"],
		&["Content-Length: 300", "Carriage: re\rturn"],
		&["Content-Length: 300\r"],
	] {
		assert_eq!(
			body_len(&head(headers)),
			Err(Status::BadRequest),
			"{headers:?}"
		);
	}
	for request in [
		&b"POST / HTTP/1.1\nContent-Length: 300\r\n\r\n"[..],
		b"POST / HTTP/1.1\r\nContent-Length: 300\n\r\n",
		b"POST / HTTP/1.1\r\nContent-Length: 300\r\n",
		b"POST / HTTP/1.1\r\nContent-Length: 300",
		b"",
	] {
		assert_eq!(body_len(request), Err(Status::BadRequest), "{request:?}");
	}
}

#[test]
fn every_response_closes_the_connection_and_only_a_sealed_one_has_a_body() {
	assert_eq!(
		sealed_response_head(300),
		b"HTTP/1.1 200 OK\r\nContent-Length: 300\r\nConnection: close\r\n\r\n"
	);
	for (status, line) in [
		(Status::BadRequest, "400 Bad Request"),
		(Status::TooLarge, "413 Content Too Large"),
		(Status::ServerError, "500 Internal Server Error"),
	] {
		let expected = format!("HTTP/1.1 {line}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
		assert_eq!(status.response(), expected.as_bytes());
	}
	assert_eq!(Status::from(Rejection::TooLarge), Status::TooLarge);
	assert_eq!(Status::from(Rejection::Unopenable), Status::BadRequest);
}
