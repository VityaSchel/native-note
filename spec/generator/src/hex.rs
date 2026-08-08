pub fn encode(bytes: &[u8]) -> String {
	let mut out = String::with_capacity(bytes.len() * 2);
	for b in bytes {
		out.push(char::from_digit((b >> 4) as u32, 16).unwrap());
		out.push(char::from_digit((b & 0x0f) as u32, 16).unwrap());
	}
	out
}

pub fn decode(s: &str) -> Option<Vec<u8>> {
	if !s.len().is_multiple_of(2) {
		return None;
	}
	let nibble = |c: u8| match c {
		b'0'..=b'9' => Some(c - b'0'),
		b'a'..=b'f' => Some(c - b'a' + 10),
		_ => None,
	};
	s.as_bytes()
		.chunks(2)
		.map(|pair| Some(nibble(pair[0])? << 4 | nibble(pair[1])?))
		.collect()
}
