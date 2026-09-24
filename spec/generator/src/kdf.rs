use hkdf::Hkdf;
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;

pub mod label {
	pub const ENVELOPE: &str = "native-note/envelope/v1";
	pub const ID_BLIND: &str = "native-note/id-blind/v1";
	pub const NOTE: &str = "native-note/note/v1";
	pub const LOCAL_DB: &str = "native-note/localdb/v1";
	pub const MACHINE_ID: &str = "native-note/machine-id/v1";
}

pub fn hkdf(ikm: &[u8], salt: Option<&[u8]>, info: &[u8], len: usize) -> Vec<u8> {
	let hk = Hkdf::<Sha256>::new(salt, ikm);
	let mut okm = vec![0u8; len];
	hk.expand(info, &mut okm)
		.expect("length within HKDF-SHA256 limit");
	okm
}

pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
	let mut mac =
		<Hmac<Sha256> as KeyInit>::new_from_slice(key).expect("HMAC accepts any key length");
	mac.update(data);
	mac.finalize().into_bytes().into()
}

pub fn envelope_key(api_key: &[u8]) -> Vec<u8> {
	hkdf(api_key, None, label::ENVELOPE.as_bytes(), 32)
}

pub fn blinding_key(content_key: &[u8]) -> Vec<u8> {
	hkdf(content_key, None, label::ID_BLIND.as_bytes(), 32)
}

pub fn note_key(content_key: &[u8], write_id: &[u8]) -> Vec<u8> {
	hkdf(content_key, Some(write_id), label::NOTE.as_bytes(), 32)
}

pub fn local_db_key(argon_out: &[u8], machine_id: &[u8], local_salt: &[u8]) -> Vec<u8> {
	let mut ikm = Vec::with_capacity(argon_out.len() + machine_id.len());
	ikm.extend_from_slice(argon_out);
	ikm.extend_from_slice(machine_id);
	hkdf(&ikm, Some(local_salt), label::LOCAL_DB.as_bytes(), 32)
}
