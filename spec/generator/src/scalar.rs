use crate::kdf;

/// Order of the P-256 base point, from FIPS 186-5 D.1.2.3.
const P256_ORDER: [u8; 32] = [
	0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
];

pub fn is_valid(candidate: &[u8; 32]) -> bool {
	candidate.iter().any(|&b| b != 0) && *candidate < P256_ORDER
}

/// Candidate testing per FIPS 186-5 A.4.1: redraw on rejection rather than adjusting
/// a rejected value, which would bias the result.
pub fn derive(x: &[u8], index: u32) -> ([u8; 32], u32) {
	for attempt in 0.. {
		let info = kdf::chain_round(index, attempt);
		let candidate: [u8; 32] = kdf::hkdf(x, None, info.as_bytes(), 32).try_into().unwrap();
		if is_valid(&candidate) {
			return (candidate, attempt);
		}
	}
	unreachable!("rejection probability is about 2^-32 per draw")
}
