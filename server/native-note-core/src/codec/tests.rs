use super::Reader;
use crate::frame::DecodeError;

const INPUT: [u8; 29] = [
	0xa1, 0x01, 0x02, 0x03, 0x04, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0xf0, 0xf1, 0xf2,
	0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
];

#[test]
fn each_fixed_width_read_at_its_exact_length_leaves_nothing() {
	let mut reader = Reader::new(&INPUT[..1]);
	assert_eq!(reader.u8(), Ok(0xa1));
	assert_eq!(reader.finish(), Ok(()));
	let mut reader = Reader::new(&INPUT[1..5]);
	assert_eq!(reader.u32(), Ok(0x0102_0304));
	assert_eq!(reader.finish(), Ok(()));
	let mut reader = Reader::new(&INPUT[5..13]);
	assert_eq!(reader.u64(), Ok(0x1020_3040_5060_7080));
	assert_eq!(reader.finish(), Ok(()));
	let mut reader = Reader::new(&INPUT[13..]);
	assert!(reader.array::<16>().is_ok());
	assert_eq!(reader.finish(), Ok(()));
}

#[test]
fn each_fixed_width_read_short_of_its_length_is_truncated() {
	assert_eq!(Reader::new(&[]).u8(), Err(DecodeError::Truncated));
	for len in 0..4 {
		assert_eq!(
			Reader::new(&INPUT[..len]).u32(),
			Err(DecodeError::Truncated)
		);
	}
	for len in 0..8 {
		assert_eq!(
			Reader::new(&INPUT[..len]).u64(),
			Err(DecodeError::Truncated)
		);
	}
	for len in 0..16 {
		assert_eq!(
			Reader::new(&INPUT[..len]).array::<16>(),
			Err(DecodeError::Truncated)
		);
	}
}

#[test]
fn bytes_reads_its_length_prefix_then_that_many_bytes() {
	let input = [0x00, 0x00, 0x00, 0x03, 0x61, 0x62, 0x63, 0x64];
	let mut reader = Reader::new(&input);
	assert_eq!(reader.bytes(), Ok(&input[4..7]));
	assert_eq!(reader.u8(), Ok(0x64));
	assert_eq!(reader.finish(), Ok(()));

	let mut reader = Reader::new(&input[..7]);
	assert_eq!(reader.bytes(), Ok(&input[4..7]));
	assert_eq!(reader.finish(), Ok(()));
}

#[test]
fn bytes_of_length_zero_is_empty() {
	let mut reader = Reader::new(&[0x00, 0x00, 0x00, 0x00]);
	assert_eq!(reader.bytes(), Ok(&[][..]));
	assert_eq!(reader.finish(), Ok(()));
}

#[test]
fn bytes_short_of_its_prefix_or_its_length_is_truncated() {
	let input = [0x00, 0x00, 0x00, 0x03, 0x61, 0x62, 0x63];
	for len in 0..input.len() {
		assert_eq!(
			Reader::new(&input[..len]).bytes(),
			Err(DecodeError::Truncated),
			"{len}"
		);
	}
}

#[test]
fn bytes_of_length_u32_max_is_truncated_without_allocating() {
	assert_eq!(
		Reader::new(&[0xff, 0xff, 0xff, 0xff]).bytes(),
		Err(DecodeError::Truncated)
	);
	let mut input = [0x41; 4096];
	input[..4].copy_from_slice(&u32::MAX.to_be_bytes());
	assert_eq!(Reader::new(&input).bytes(), Err(DecodeError::Truncated));
}

#[test]
fn finish_rejects_any_trailing_byte() {
	assert_eq!(Reader::new(&[]).finish(), Ok(()));
	assert_eq!(
		Reader::new(&[0x00]).finish(),
		Err(DecodeError::TrailingBytes)
	);
	let mut reader = Reader::new(&INPUT[..2]);
	assert_eq!(reader.u8(), Ok(0xa1));
	assert_eq!(reader.finish(), Err(DecodeError::TrailingBytes));
}
