use serde_json::{Value, json};

use super::{EXPORT_SALT, NONCE, file, seq_array};
use crate::aead::NONCE_LEN;
use crate::export::{self, ArgonParams, HEADER_LEN, MAGIC, SALT_LEN};
use crate::hex::encode as hx;

const PASSPHRASE: &str = "correct horse ünïcode staple";
const WRONG_PASSPHRASE: &str = "correct horse unicode staple";
const PARAMS: ArgonParams = ArgonParams {
	m: 1024,
	t: 2,
	p: 3,
};

fn empty_zip() -> Vec<u8> {
	[b"PK\x05\x06".as_slice(), &[0; 18]].concat()
}

fn reject(name: &str, passphrase: &str, file: &[u8]) -> Value {
	json!({
		"name": name,
		"passphrase": passphrase,
		"file": hx(file),
		"opens": export::open(passphrase, file).is_ok(),
	})
}

pub fn export() -> Value {
	let salt: [u8; SALT_LEN] = seq_array(EXPORT_SALT);
	let nonce: [u8; NONCE_LEN] = seq_array(NONCE);
	let zip = empty_zip();
	let sealed = export::seal(PASSPHRASE, PARAMS, &salt, &nonce, &zip).unwrap();

	let mut flipped_salt = sealed.clone();
	flipped_salt[MAGIC.len() + export::PARAMS_LEN] ^= 0x01;

	let mut flipped_ciphertext = sealed.clone();
	flipped_ciphertext[HEADER_LEN + NONCE_LEN] ^= 0x01;

	let truncated = &sealed[..sealed.len() - 1];

	let mut bad_magic = sealed.clone();
	bad_magic[MAGIC.len() - 1] = b'2';

	let out_of_bounds = ArgonParams {
		t: export::MAX_T + 1,
		..PARAMS
	};
	let too_costly = export::seal(PASSPHRASE, out_of_bounds, &salt, &nonce, &zip).unwrap();

	file(
		"Passphrase-encrypted exports. The header carries the Argon2id parameters and salt and is the AAD. Low-cost parameters; exports use the Argon2 floor. A reader refuses m above 2 GiB or below 8p, t above 10, and p above 16.",
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
				"file": hx(&sealed),
				"opens": export::open(PASSPHRASE, &sealed).as_deref() == Ok(zip.as_slice()),
			}),
			reject("rejectWrongPassphrase", WRONG_PASSPHRASE, &sealed),
			reject("rejectFlippedHeaderByte", PASSPHRASE, &flipped_salt),
			reject(
				"rejectFlippedCiphertextByte",
				PASSPHRASE,
				&flipped_ciphertext,
			),
			reject("rejectTruncated", PASSPHRASE, truncated),
			reject("rejectBadMagic", PASSPHRASE, &bad_magic),
			reject("rejectParametersOutOfBounds", PASSPHRASE, &too_costly),
		],
	)
}
