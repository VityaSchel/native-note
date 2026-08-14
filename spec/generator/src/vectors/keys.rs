use argon2::{Algorithm, Argon2, Params, Version};
use serde_json::{Value, json};

use super::{API_KEY, CONTENT_KEY, LOCAL_SALT, UUID, file, uuid_bytes};
use crate::hex::encode as hx;
use crate::{kdf, note, seq_bytes};

const ARGON_OUT: u8 = 0xa0;
const MACHINE_ID: u8 = 0xc0;
const SHARED_SECRET: u8 = 0xd0;

fn hkdf_case(name: &str, ikm: &[u8], salt: Option<&[u8]>, info: &str, len: usize) -> Value {
	json!({
		"name": name,
		"ikm": hx(ikm),
		"salt": salt.map(hx),
		"info": info,
		"length": len,
		"okm": hx(&kdf::hkdf(ikm, salt, info.as_bytes(), len)),
	})
}

pub fn hkdf() -> Value {
	let api_key = seq_bytes(API_KEY, 32);
	let content_key = seq_bytes(CONTENT_KEY, 32);
	let write_id = seq_bytes(0x60, 16);
	let local_salt = seq_bytes(LOCAL_SALT, 16);
	let argon_out = seq_bytes(ARGON_OUT, 32);
	let machine_id = seq_bytes(MACHINE_ID, 32);

	file(
		"HKDF-SHA256 derivations for every info label in the protocol.",
		vec![
			hkdf_case("envelopeKey", &api_key, None, kdf::ENVELOPE, 32),
			hkdf_case("blindingKey", &content_key, None, kdf::ID_BLIND, 32),
			hkdf_case("noteKey", &content_key, Some(&write_id), kdf::NOTE, 32),
			hkdf_case(
				"machineId",
				&seq_bytes(SHARED_SECRET, 32),
				None,
				kdf::MACHINE_ID,
				32,
			),
			json!({
				"name": "localDbKey",
				"argonOut": hx(&argon_out),
				"machineId": hx(&machine_id),
				"salt": hx(&local_salt),
				"info": kdf::LOCALDB,
				"length": 32,
				"okm": hx(&kdf::local_db_key(&argon_out, &machine_id, &local_salt)),
			}),
		],
	)
}

pub fn blinding() -> Value {
	let content_key = seq_bytes(CONTENT_KEY, 32);
	let blinding_key = kdf::blinding_key(&content_key);
	let uuid = uuid_bytes();
	let mut neighbour = uuid;
	neighbour[15] ^= 0x01;

	let case = |name: &str, id: &[u8; 16], text: &str| {
		json!({
			"name": name,
			"uuid": text,
			"uuidBytes": hx(id),
			"blindedId": hx(&note::blinded_id(&blinding_key, id)),
		})
	};

	file(
		"blindedId = HMAC-SHA256(blindingKey, uuid) truncated to 16 bytes.",
		vec![
			json!({
				"name": "blindingKey",
				"contentKey": hx(&content_key),
				"blindingKey": hx(&blinding_key),
			}),
			case("uuid", &uuid, UUID),
			case(
				"uuidOneBitApart",
				&neighbour,
				"0b8f1d2e-3a4b-4c5d-8e9f-001122334454",
			),
		],
	)
}

pub fn argon2() -> Value {
	let salt = seq_bytes(LOCAL_SALT, 16);
	let params = Params::new(1024, 1, 1, Some(32)).unwrap();
	let mut out = [0u8; 32];
	Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
		.hash_password_into(b"correct horse battery staple", &salt, &mut out)
		.unwrap();

	file(
		"Argon2id at fixed low-cost parameters. Production parameters are calibrated per device; these pin the algorithm only.",
		vec![json!({
			"name": "argon2id",
			"password": "correct horse battery staple",
			"salt": hx(&salt),
			"m": 1024,
			"t": 1,
			"p": 1,
			"length": 32,
			"output": hx(&out),
		})],
	)
}
