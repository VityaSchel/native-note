use crate::envelope::{Rejection, admit};

pub const HEAD_MAX: usize = 8192;
const HEADERS_MAX: usize = 100;
const REQUEST_LINE: &[u8] = b"POST / HTTP/1.1";
const BLANK_LINE: &[u8] = b"\r\n\r\n";
const TOKEN_SYMBOLS: &[u8] = b"!#$%&'*+-.^_`|~";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
	BadRequest,
	TooLarge,
	ServerError,
}

impl Status {
	pub fn response(self) -> &'static [u8] {
		match self {
			Status::BadRequest => {
				b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			}
			Status::TooLarge => {
				b"HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			}
			Status::ServerError => {
				b"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
			}
		}
	}
}

impl From<Rejection> for Status {
	fn from(rejection: Rejection) -> Status {
		match rejection {
			Rejection::TooLarge => Status::TooLarge,
			Rejection::Unopenable => Status::BadRequest,
		}
	}
}

pub fn sealed_response_head(body_len: usize) -> Vec<u8> {
	format!("HTTP/1.1 200 OK\r\nContent-Length: {body_len}\r\nConnection: close\r\n\r\n")
		.into_bytes()
}

/// The length of the head through the blank line that ends it, once `received` holds that line.
pub fn head_len(received: &[u8]) -> Option<usize> {
	received
		.windows(BLANK_LINE.len())
		.position(|window| window == BLANK_LINE)
		.and_then(|at| at.checked_add(BLANK_LINE.len()))
}

/// The admitted body length declared by a head that `head_len` delimited.
pub fn body_len(head: &[u8]) -> Result<usize, Status> {
	let mut lines = head
		.strip_suffix(b"\r\n")
		.unwrap_or_default()
		.split_inclusive(|&byte| byte == b'\n')
		.map(|line| {
			line.strip_suffix(b"\r\n")
				.filter(|line| !line.contains(&b'\r'))
				.ok_or(Status::BadRequest)
		});
	if lines.next() != Some(Ok(REQUEST_LINE)) {
		return Err(Status::BadRequest);
	}
	let mut declared = None;
	for (index, line) in lines.enumerate() {
		if index >= HEADERS_MAX {
			return Err(Status::BadRequest);
		}
		let (name, value) = header(line?).ok_or(Status::BadRequest)?;
		if name.eq_ignore_ascii_case(b"content-length") {
			let len = digits(value).ok_or(Status::BadRequest)?;
			if declared.replace(len).is_some() {
				return Err(Status::BadRequest);
			}
		} else if name.eq_ignore_ascii_case(b"transfer-encoding") {
			return Err(Status::BadRequest);
		}
	}
	let len = declared.ok_or(Status::BadRequest)?;
	admit(len)?;
	Ok(len)
}

fn header(line: &[u8]) -> Option<(&[u8], &[u8])> {
	let mut parts = line.splitn(2, |&byte| byte == b':');
	let (Some(name), Some(value)) = (parts.next(), parts.next()) else {
		return None;
	};
	let token = !name.is_empty()
		&& name
			.iter()
			.all(|byte| byte.is_ascii_alphanumeric() || TOKEN_SYMBOLS.contains(byte));
	token.then_some((name, trim_whitespace(value)))
}

fn trim_whitespace(mut value: &[u8]) -> &[u8] {
	while let [b' ' | b'\t', rest @ ..] = value {
		value = rest;
	}
	while let [rest @ .., b' ' | b'\t'] = value {
		value = rest;
	}
	value
}

fn digits(value: &[u8]) -> Option<usize> {
	if value.is_empty() || !value.iter().all(u8::is_ascii_digit) {
		return None;
	}
	Some(value.iter().fold(0_usize, |len, &digit| {
		len.saturating_mul(10)
			.saturating_add(usize::from(digit.wrapping_sub(b'0')))
	}))
}

#[cfg(test)]
mod tests;
