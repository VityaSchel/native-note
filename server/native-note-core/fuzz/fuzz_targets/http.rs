#![no_main]

use libfuzzer_sys::fuzz_target;
use native_note_core::http::{Status, admitted_body_len, head_len};

const SEALED_MIN: usize = 12 + 16;
const SEALED_MAX: usize = (2 << 20) + SEALED_MIN;

fn values_of<'a>(head: &'a [u8], name: &'a [u8]) -> impl Iterator<Item = &'a [u8]> {
	head.split(|&byte| byte == b'\n').filter_map(move |line| {
		let (start, value) = line.split_at_checked(name.len())?;
		start.eq_ignore_ascii_case(name).then_some(value)
	})
}

fn decimal(value: &[u8]) -> Option<usize> {
	let digits = str::from_utf8(value).ok()?.trim_matches([' ', '\t', '\r']);
	let unsigned = digits.bytes().all(|byte| byte.is_ascii_digit());
	digits.parse().ok().filter(|_| unsigned)
}

fn first_blank_line_end(input: &[u8]) -> Option<usize> {
	(4..=input.len()).find(|&end| input[..end].ends_with(b"\r\n\r\n"))
}

fn check_declared(len: usize) {
	let head = format!("POST / HTTP/1.1\r\nContent-Length: {len}\r\n\r\n");
	let expected = match len {
		..SEALED_MIN => Err(Status::BadRequest),
		SEALED_MIN..=SEALED_MAX => Ok(len),
		_ => Err(Status::TooLarge),
	};
	assert_eq!(admitted_body_len(head.as_bytes()), expected);
}

fn check(input: &[u8]) {
	assert_eq!(head_len(input), first_blank_line_end(input));
	let Some(len) = head_len(input) else {
		return;
	};
	let head = &input[..len];
	assert_eq!(head_len(head), Some(len));
	if let Ok(body) = admitted_body_len(head) {
		assert!(head.starts_with(b"POST / HTTP/1.1\r\n"));
		assert!((SEALED_MIN..=SEALED_MAX).contains(&body));
		let declared: Vec<_> = values_of(head, b"content-length:").map(decimal).collect();
		assert_eq!(declared, [Some(body)]);
		assert_eq!(values_of(head, b"transfer-encoding:").count(), 0);
	}
}

fuzz_target!(|input: &[u8]| {
	check(input);
	check(&[b"POST / HTTP/1.1\r\n", input, b"\r\n\r\n"].concat());
	if let Some(len) = input.first_chunk().copied().map(u32::from_le_bytes) {
		check_declared(usize::try_from(len).expect("a u32 fits usize"));
	}
});
