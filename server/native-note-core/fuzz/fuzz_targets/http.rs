#![no_main]

use libfuzzer_sys::fuzz_target;
use native_note_core::http::{body_len, head_len};

const SEALED_MIN: usize = 12 + 16;
const SEALED_MAX: usize = (2 << 20) + SEALED_MIN;

fn headers_named(head: &[u8], name: &[u8]) -> usize {
	head.split(|&byte| byte == b'\n')
		.filter(|line| {
			line.get(..name.len())
				.is_some_and(|start| start.eq_ignore_ascii_case(name))
		})
		.count()
}

fn check(input: &[u8]) {
	let Some(len) = head_len(input) else {
		return;
	};
	let head = &input[..len];
	assert!(head.ends_with(b"\r\n\r\n"));
	assert_eq!(head_len(head), Some(len));
	if let Ok(body) = body_len(head) {
		assert!(head.starts_with(b"POST / HTTP/1.1\r\n"));
		assert!((SEALED_MIN..=SEALED_MAX).contains(&body));
		assert_eq!(headers_named(head, b"content-length:"), 1);
		assert_eq!(headers_named(head, b"transfer-encoding:"), 0);
	}
}

fuzz_target!(|input: &[u8]| {
	check(input);
	check(&[b"POST / HTTP/1.1\r\n", input, b"\r\n\r\n"].concat());
});
