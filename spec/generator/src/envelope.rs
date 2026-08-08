use crate::aead::{self, NONCE_LEN, OpenError};

pub const VERSION: u8 = 0x01;
const MIN_BUCKET: usize = 256;
const MAX_BUCKET: usize = 2 * 1024 * 1024;
const LEN_PREFIX: usize = 4;

#[derive(Debug, PartialEq, Eq)]
pub enum PadError {
	TooLarge,
	Malformed,
}

pub fn bucket_for(len: usize) -> Option<usize> {
	let mut b = MIN_BUCKET;
	while b < len {
		b = b.checked_mul(2)?;
		if b > MAX_BUCKET {
			return None;
		}
	}
	(b <= MAX_BUCKET).then_some(b)
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
	if padded.len() < LEN_PREFIX || bucket_for(padded.len()) != Some(padded.len()) {
		return Err(PadError::Malformed);
	}
	let len = u32::from_be_bytes(padded[..LEN_PREFIX].try_into().unwrap()) as usize;
	let end = LEN_PREFIX.checked_add(len).ok_or(PadError::Malformed)?;
	if end > padded.len() || padded[end..].iter().any(|&b| b != 0) {
		return Err(PadError::Malformed);
	}
	Ok(padded[LEN_PREFIX..end].to_vec())
}

pub fn seal_request(
	key: &[u8],
	nonce: &[u8; NONCE_LEN],
	inner: &[u8],
) -> Result<Vec<u8>, PadError> {
	let padded = pad(inner)?;
	let mut out = vec![VERSION];
	out.extend_from_slice(&aead::seal(key, nonce, &padded, &[VERSION]));
	Ok(out)
}

pub fn open_request(key: &[u8], frame: &[u8]) -> Result<Vec<u8>, OpenError> {
	let (&version, sealed) = frame.split_first().ok_or(OpenError)?;
	if version != VERSION {
		return Err(OpenError);
	}
	let padded = aead::open(key, sealed, &[VERSION])?;
	unpad(&padded).map_err(|_| OpenError)
}

fn response_aad(request_nonce: &[u8; NONCE_LEN]) -> Vec<u8> {
	let mut aad = vec![VERSION];
	aad.extend_from_slice(request_nonce);
	aad
}

pub fn seal_response(
	key: &[u8],
	nonce: &[u8; NONCE_LEN],
	request_nonce: &[u8; NONCE_LEN],
	inner: &[u8],
) -> Result<Vec<u8>, PadError> {
	let padded = pad(inner)?;
	Ok(aead::seal(
		key,
		nonce,
		&padded,
		&response_aad(request_nonce),
	))
}

pub fn open_response(
	key: &[u8],
	request_nonce: &[u8; NONCE_LEN],
	frame: &[u8],
) -> Result<Vec<u8>, OpenError> {
	let padded = aead::open(key, frame, &response_aad(request_nonce))?;
	unpad(&padded).map_err(|_| OpenError)
}
