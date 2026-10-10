use crate::aead::{self, NONCE_LEN, OpenError};

const CONTENT_KEY_LEN: usize = 32;

pub fn seal(
	recovery_key: &[u8],
	nonce: &[u8; NONCE_LEN],
	content_key: &[u8; CONTENT_KEY_LEN],
) -> Vec<u8> {
	aead::seal(recovery_key, nonce, content_key, &[])
}

pub fn open(recovery_key: &[u8], blob: &[u8]) -> Result<[u8; CONTENT_KEY_LEN], OpenError> {
	aead::open(recovery_key, blob, &[])?
		.try_into()
		.map_err(|_| OpenError)
}
