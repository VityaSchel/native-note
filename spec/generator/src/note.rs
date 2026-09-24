use crate::aead::{self, NONCE_LEN, OpenError};
use crate::kdf;

pub const BLINDED_ID_LEN: usize = 16;
pub const WRITE_ID_LEN: usize = 16;

pub type BlindedId = [u8; BLINDED_ID_LEN];

pub fn blinded_id(blinding_key: &[u8], uuid: &[u8; 16]) -> BlindedId {
	kdf::hmac_sha256(blinding_key, uuid)[..BLINDED_ID_LEN]
		.try_into()
		.unwrap()
}

pub fn aad(blinded_id: &BlindedId, v: u32, write_id: &[u8; WRITE_ID_LEN]) -> Vec<u8> {
	let mut out = Vec::with_capacity(BLINDED_ID_LEN + 4 + WRITE_ID_LEN);
	out.extend_from_slice(blinded_id);
	out.extend_from_slice(&v.to_be_bytes());
	out.extend_from_slice(write_id);
	out
}

pub fn seal(
	content_key: &[u8],
	write_id: &[u8; WRITE_ID_LEN],
	nonce: &[u8; NONCE_LEN],
	blinded_id: &BlindedId,
	v: u32,
	content: &[u8],
) -> Vec<u8> {
	let key = kdf::note_key(content_key, write_id);
	aead::seal(&key, nonce, content, &aad(blinded_id, v, write_id))
}

pub fn open(
	content_key: &[u8],
	write_id: &[u8; WRITE_ID_LEN],
	blinded_id: &BlindedId,
	v: u32,
	payload: &[u8],
) -> Result<Vec<u8>, OpenError> {
	let key = kdf::note_key(content_key, write_id);
	aead::open(&key, payload, &aad(blinded_id, v, write_id))
}
