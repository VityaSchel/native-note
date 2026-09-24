use argon2::{Algorithm, Argon2, Params, Version};

use crate::aead::{self, NONCE_LEN, OpenError};

pub const MAGIC: &[u8; 9] = b"NNEXPORT1";
pub const PARAMS_LEN: usize = 12;
pub const SALT_LEN: usize = 16;
pub const HEADER_LEN: usize = MAGIC.len() + PARAMS_LEN + SALT_LEN;
pub const MAX_M: u32 = 2 * 1024 * 1024;
pub const MAX_T: u32 = 10;
pub const MAX_P: u32 = 16;
const KEY_LEN: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArgonParams {
	pub m: u32,
	pub t: u32,
	pub p: u32,
}

impl ArgonParams {
	pub fn encode(&self) -> [u8; PARAMS_LEN] {
		let mut out = [0; PARAMS_LEN];
		out[..4].copy_from_slice(&self.m.to_be_bytes());
		out[4..8].copy_from_slice(&self.t.to_be_bytes());
		out[8..].copy_from_slice(&self.p.to_be_bytes());
		out
	}

	pub fn within_bounds(&self) -> bool {
		(1..=MAX_P).contains(&self.p)
			&& (1..=MAX_T).contains(&self.t)
			&& (8 * self.p..=MAX_M).contains(&self.m)
	}

	pub fn decode(bytes: &[u8; PARAMS_LEN]) -> Self {
		let word = |at: usize| {
			u32::from_be_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
		};
		Self {
			m: word(0),
			t: word(4),
			p: word(8),
		}
	}
}

pub fn header(params: ArgonParams, salt: &[u8; SALT_LEN]) -> Vec<u8> {
	[MAGIC.as_slice(), &params.encode(), salt].concat()
}

pub fn export_key(
	passphrase: &str,
	salt: &[u8],
	params: ArgonParams,
) -> Result<[u8; KEY_LEN], argon2::Error> {
	let params = Params::new(params.m, params.t, params.p, Some(KEY_LEN))?;
	let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
	let mut key = [0; KEY_LEN];
	argon2.hash_password_into(passphrase.as_bytes(), salt, &mut key)?;
	Ok(key)
}

pub fn seal(
	passphrase: &str,
	params: ArgonParams,
	salt: &[u8; SALT_LEN],
	nonce: &[u8; NONCE_LEN],
	zip: &[u8],
) -> Result<Vec<u8>, argon2::Error> {
	let key = export_key(passphrase, salt, params)?;
	let header = header(params, salt);
	let sealed = aead::seal(&key, nonce, zip, &header);
	Ok([header, sealed].concat())
}

pub fn open(passphrase: &str, file: &[u8]) -> Result<Vec<u8>, OpenError> {
	let (header, sealed) = file.split_at_checked(HEADER_LEN).ok_or(OpenError)?;
	let fields = header.strip_prefix(MAGIC.as_slice()).ok_or(OpenError)?;
	let (params, salt) = fields.split_first_chunk::<PARAMS_LEN>().ok_or(OpenError)?;
	let params = ArgonParams::decode(params);
	if !params.within_bounds() {
		return Err(OpenError);
	}
	let key = export_key(passphrase, salt, params).map_err(|_| OpenError)?;
	aead::open(&key, sealed, header)
}
