use aes_gcm::Aes256Gcm;
use aes_gcm::aead::{Aead, KeyInit, Payload};

pub const NONCE_LEN: usize = 12;
pub const TAG_LEN: usize = 16;

#[derive(Debug, PartialEq, Eq)]
pub struct OpenError;

fn cipher(key: &[u8]) -> Aes256Gcm {
	Aes256Gcm::new_from_slice(key).expect("32-byte key")
}

pub fn seal(key: &[u8], nonce: &[u8; NONCE_LEN], plaintext: &[u8], aad: &[u8]) -> Vec<u8> {
	let sealed = cipher(key)
		.encrypt(
			nonce.into(),
			Payload {
				msg: plaintext,
				aad,
			},
		)
		.expect("AES-256-GCM never fails on valid key and nonce sizes");
	let mut out = Vec::with_capacity(NONCE_LEN + sealed.len());
	out.extend_from_slice(nonce);
	out.extend_from_slice(&sealed);
	out
}

pub fn open(key: &[u8], sealed: &[u8], aad: &[u8]) -> Result<Vec<u8>, OpenError> {
	let (nonce, body) = sealed.split_first_chunk::<NONCE_LEN>().ok_or(OpenError)?;
	if body.len() < TAG_LEN {
		return Err(OpenError);
	}
	cipher(key)
		.decrypt(nonce.into(), Payload { msg: body, aad })
		.map_err(|_| OpenError)
}
