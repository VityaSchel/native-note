use serde_json::{Value, json};

use super::content::{CREATED_AT, UPDATED_AT};
use super::{EXPORT_SALT, NONCE, file, seq_array, uuid_bytes};
use crate::aead::NONCE_LEN;
use crate::export::{self, ArgonParams, HEADER_LEN, MAGIC, SALT_LEN};
use crate::hex::encode as hx;
use crate::{markdown, zip};

const PASSPHRASE: &str = "correct horse ünïcode staple";
const WRONG_PASSPHRASE: &str = "correct horse unicode staple";
const PARAMS: ArgonParams = ArgonParams {
	m: 1024,
	t: 2,
	p: 3,
};

const ENTRY_NAME: &str = "Groceries.md";

fn reject(name: &str, file: &[u8]) -> Value {
	json!({
		"name": name,
		"passphrase": PASSPHRASE,
		"file": hx(file),
		"opens": export::open(PASSPHRASE, file).is_ok(),
	})
}

pub fn export() -> Value {
	let salt: [u8; SALT_LEN] = seq_array(EXPORT_SALT);
	let nonce: [u8; NONCE_LEN] = seq_array(NONCE);
	let markdown = markdown::render(
		&uuid_bytes(),
		CREATED_AT,
		UPDATED_AT,
		"Groceries\nmilk\nbread",
	);
	let zip = zip::stored(&[(ENTRY_NAME, markdown.as_bytes())]);
	let sealed = export::seal(PASSPHRASE, PARAMS, &salt, &nonce, &zip).unwrap();

	let mut flipped_salt = sealed.clone();
	flipped_salt[HEADER_LEN - SALT_LEN] ^= 0x01;

	let mut flipped_ciphertext = sealed.clone();
	flipped_ciphertext[HEADER_LEN + NONCE_LEN] ^= 0x01;

	let truncated = &sealed[..sealed.len() - 1];

	let mut newer_version = sealed.clone();
	newer_version[MAGIC.len() - 1] = b'2';

	let sealed_under =
		|params: ArgonParams| export::seal(PASSPHRASE, params, &salt, &nonce, &zip).unwrap();
	let with_header_params = |params: ArgonParams| {
		[export::header(params, &salt), sealed[HEADER_LEN..].to_vec()].concat()
	};
	let too_many_passes = sealed_under(ArgonParams {
		t: export::MAX_T + 1,
		..PARAMS
	});
	let too_many_lanes = sealed_under(ArgonParams {
		p: export::MAX_P + 1,
		..PARAMS
	});
	let no_passes = with_header_params(ArgonParams { t: 0, ..PARAMS });
	let no_lanes = with_header_params(ArgonParams { p: 0, ..PARAMS });
	let too_much_memory = with_header_params(ArgonParams {
		m: export::MAX_M + 1,
		..PARAMS
	});
	let too_little_memory = with_header_params(ArgonParams {
		m: 8 * PARAMS.p - 1,
		..PARAMS
	});

	file(
		"Passphrase-encrypted exports. The header carries the Argon2id parameters and salt and is the AAD. Low-cost parameters; exports use the Argon2 floor. Before hashing, a reader refuses m (KiB) above 2 GiB or below 8p, t outside 1 to 10, and p outside 1 to 16. A file that starts with NNEXPORT and then any byte but 1 is refused as written by a newer version, never read as a zip. The sealed zip holds the listed entries.",
		vec![
			json!({
				"name": "export",
				"passphrase": PASSPHRASE,
				"salt": hx(&salt),
				"m": PARAMS.m,
				"t": PARAMS.t,
				"p": PARAMS.p,
				"header": hx(&export::header(PARAMS, &salt)),
				"exportKey": hx(&export::export_key(PASSPHRASE, &salt, PARAMS).unwrap()),
				"nonce": hx(&nonce),
				"zip": hx(&zip),
				"entries": [{ "name": ENTRY_NAME, "markdown": markdown }],
				"file": hx(&sealed),
				"opens": export::open(PASSPHRASE, &sealed).as_deref() == Ok(zip.as_slice()),
			}),
			json!({
				"name": "rejectWrongPassphrase",
				"passphrase": WRONG_PASSPHRASE,
				"file": hx(&sealed),
				"opens": export::open(WRONG_PASSPHRASE, &sealed).is_ok(),
			}),
			reject("rejectFlippedHeaderByte", &flipped_salt),
			reject("rejectFlippedCiphertextByte", &flipped_ciphertext),
			reject("rejectTruncated", truncated),
			json!({
				"name": "rejectNewerVersion",
				"passphrase": PASSPHRASE,
				"file": hx(&newer_version),
				"opens": export::read(PASSPHRASE, &newer_version).is_ok(),
				"outcome": export::read(PASSPHRASE, &newer_version).map_err(|e| e.name()).err(),
			}),
			reject("rejectParametersTooManyPasses", &too_many_passes),
			reject("rejectParametersZeroPasses", &no_passes),
			reject("rejectParametersTooManyLanes", &too_many_lanes),
			reject("rejectParametersZeroLanes", &no_lanes),
			reject("rejectParametersTooMuchMemory", &too_much_memory),
			reject("rejectParametersTooLittleMemory", &too_little_memory),
		],
	)
}
