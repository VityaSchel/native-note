use crate::aead::{self, NONCE_LEN, OpenError};

const MIN_BUCKET: usize = 256;
pub const MAX_BUCKET: usize = 2 * 1024 * 1024;
const LEN_PREFIX: usize = 4;

pub fn bucket_for(len: usize) -> Option<usize> {
	let bucket = len.max(MIN_BUCKET).checked_next_power_of_two()?;
	(bucket <= MAX_BUCKET).then_some(bucket)
}

pub fn pad(inner: &[u8]) -> Option<Vec<u8>> {
	let total = bucket_for(LEN_PREFIX + inner.len())?;
	let mut out = Vec::with_capacity(total);
	out.extend_from_slice(&(inner.len() as u32).to_be_bytes());
	out.extend_from_slice(inner);
	out.resize(total, 0);
	Some(out)
}

pub fn unpad(padded: &[u8]) -> Option<Vec<u8>> {
	let (len, rest) = padded.split_first_chunk::<LEN_PREFIX>()?;
	let len = u32::from_be_bytes(*len) as usize;
	if LEN_PREFIX.checked_add(len).and_then(bucket_for) != Some(padded.len()) {
		return None;
	}
	let (inner, fill) = rest.split_at(len);
	fill.iter().all(|&b| b == 0).then(|| inner.to_vec())
}

pub fn seal_request(key: &[u8], nonce: &[u8; NONCE_LEN], inner: &[u8]) -> Option<Vec<u8>> {
	Some(aead::seal(key, nonce, &pad(inner)?, &[]))
}

pub fn open_request(key: &[u8], frame: &[u8]) -> Result<Option<Vec<u8>>, OpenError> {
	let padded = aead::open(key, frame, &[])?;
	Ok(unpad(&padded))
}

pub fn seal_response(
	key: &[u8],
	nonce: &[u8; NONCE_LEN],
	request_nonce: &[u8; NONCE_LEN],
	inner: &[u8],
) -> Option<Vec<u8>> {
	Some(aead::seal(key, nonce, &pad(inner)?, request_nonce))
}

pub fn open_response(
	key: &[u8],
	request_nonce: &[u8; NONCE_LEN],
	frame: &[u8],
) -> Result<Vec<u8>, OpenError> {
	let padded = aead::open(key, frame, request_nonce)?;
	unpad(&padded).ok_or(OpenError)
}
