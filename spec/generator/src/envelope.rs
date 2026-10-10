use crate::aead::{self, NONCE_LEN, OpenError, TAG_LEN};

const MIN_BUCKET: usize = 256;
pub const MAX_BUCKET: usize = 2 * 1024 * 1024;
const LEN_PREFIX: usize = 4;
const SEAL_OVERHEAD: usize = NONCE_LEN + TAG_LEN;

#[derive(Debug, PartialEq, Eq)]
pub enum PadError {
	TooLarge,
	Malformed,
}

pub fn bucket_for(len: usize) -> Option<usize> {
	let bucket = len.max(MIN_BUCKET).checked_next_power_of_two()?;
	(bucket <= MAX_BUCKET).then_some(bucket)
}

pub fn pad(inner: &[u8]) -> Result<Vec<u8>, PadError> {
	let total = bucket_for(LEN_PREFIX + inner.len()).ok_or(PadError::TooLarge)?;
	let mut out = Vec::with_capacity(total);
	out.extend_from_slice(&(inner.len() as u32).to_be_bytes());
	out.extend_from_slice(inner);
	out.resize(total, 0);
	Ok(out)
}

pub fn unpad(padded: &[u8]) -> Result<Vec<u8>, PadError> {
	if bucket_for(padded.len()) != Some(padded.len()) {
		return Err(PadError::Malformed);
	}
	let (len, rest) = padded
		.split_first_chunk::<LEN_PREFIX>()
		.ok_or(PadError::Malformed)?;
	let (inner, fill) = rest
		.split_at_checked(u32::from_be_bytes(*len) as usize)
		.ok_or(PadError::Malformed)?;
	if fill.iter().any(|&b| b != 0) {
		return Err(PadError::Malformed);
	}
	Ok(inner.to_vec())
}

pub fn admits_request(frame_len: usize) -> bool {
	frame_len.saturating_sub(SEAL_OVERHEAD) <= MAX_BUCKET
}

pub fn seal_request(
	key: &[u8],
	nonce: &[u8; NONCE_LEN],
	inner: &[u8],
) -> Result<Vec<u8>, PadError> {
	Ok(aead::seal(key, nonce, &pad(inner)?, &[]))
}

pub fn open_request(key: &[u8], frame: &[u8]) -> Result<Result<Vec<u8>, PadError>, OpenError> {
	let padded = aead::open(key, frame, &[])?;
	Ok(unpad(&padded))
}

pub fn seal_response(
	key: &[u8],
	nonce: &[u8; NONCE_LEN],
	request_nonce: &[u8; NONCE_LEN],
	inner: &[u8],
) -> Result<Vec<u8>, PadError> {
	Ok(aead::seal(key, nonce, &pad(inner)?, request_nonce))
}

pub fn open_response(
	key: &[u8],
	request_nonce: &[u8; NONCE_LEN],
	frame: &[u8],
) -> Result<Vec<u8>, OpenError> {
	let padded = aead::open(key, frame, request_nonce)?;
	unpad(&padded).map_err(|_| OpenError)
}
