use argon2::{Algorithm, Argon2, Params, Version};
use serde_json::{Value, json};

use super::{
	API_KEY, ARGON_OUT, CONTENT_KEY, LOCAL_SALT, MACHINE_ID, SHARED_SECRET, WRITE_ID, file,
	seq_bytes, uuid_bytes,
};
use crate::hex::encode as hx;
use crate::{kdf, markdown, note};

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
	let write_id = seq_bytes(WRITE_ID, 16);
	let local_salt = seq_bytes(LOCAL_SALT, 16);
	let argon_out = seq_bytes(ARGON_OUT, 32);
	let machine_id = seq_bytes(MACHINE_ID, 32);

	file(
		"HKDF-SHA256 derivations for every info label in the protocol.",
		vec![
			hkdf_case("envelopeKey", &api_key, None, kdf::label::ENVELOPE, 32),
			hkdf_case("blindingKey", &content_key, None, kdf::label::ID_BLIND, 32),
			hkdf_case(
				"noteKey",
				&content_key,
				Some(&write_id),
				kdf::label::NOTE,
				32,
			),
			hkdf_case(
				"machineId",
				&seq_bytes(SHARED_SECRET, 32),
				None,
				kdf::label::MACHINE_ID,
				32,
			),
			json!({
				"name": "localDbKey",
				"argonOut": hx(&argon_out),
				"machineId": hx(&machine_id),
				"salt": hx(&local_salt),
				"info": kdf::label::LOCAL_DB,
				"length": 32,
				"okm": hx(&kdf::local_db_key(&argon_out, &machine_id, &local_salt)),
			}),
			hkdf_case(
				"localDbKeyWithoutMachineId",
				&argon_out,
				Some(&local_salt),
				kdf::label::LOCAL_DB,
				32,
			),
		],
	)
}

pub fn blinding() -> Value {
	let content_key = seq_bytes(CONTENT_KEY, 32);
	let blinding_key = kdf::blinding_key(&content_key);
	let uuid = uuid_bytes();
	let mut neighbor = uuid;
	neighbor[15] ^= 0x01;

	let case = |name: &str, id: &[u8; 16]| {
		json!({
			"name": name,
			"blindingKey": hx(&blinding_key),
			"uuid": markdown::uuid_text(id),
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
			case("uuid", &uuid),
			case("uuidOneBitApart", &neighbor),
		],
	)
}

fn argon2_case(name: &str, password: &str) -> Value {
	let salt = seq_bytes(LOCAL_SALT, 16);
	let params = Params::new(1024, 1, 1, Some(32)).unwrap();
	let mut out = [0u8; 32];
	Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
		.hash_password_into(password.as_bytes(), &salt, &mut out)
		.unwrap();

	json!({
		"name": name,
		"password": password,
		"passwordUtf8": hx(password.as_bytes()),
		"salt": hx(&salt),
		"m": 1024,
		"t": 1,
		"p": 1,
		"length": 32,
		"output": hx(&out),
	})
}

pub fn argon2() -> Value {
	file(
		"Argon2id at fixed low-cost parameters. Production parameters are calibrated per device; these pin the algorithm only. The password enters as its UTF-8 bytes, unnormalized.",
		vec![
			argon2_case("argon2id", "correct horse battery staple"),
			argon2_case("unnormalizedPassword", "cafe\u{301} con le\u{301}che"),
		],
	)
}
