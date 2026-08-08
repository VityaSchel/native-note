use serde_json::{Value, json};

use super::{API_KEY, RECOVERY_KEY, file};
use crate::hex::encode as hx;
use crate::{fixed, mnemonic, seq_bytes};

pub const PAIRING_LEN: usize = 64;

pub fn pairing_blob(api_key: &[u8], recovery_key: &[u8]) -> Vec<u8> {
	[api_key, recovery_key].concat()
}

pub fn split_pairing(blob: &[u8]) -> Option<(&[u8], &[u8])> {
	(blob.len() == PAIRING_LEN).then(|| blob.split_at(PAIRING_LEN / 2))
}

pub fn mnemonic() -> Value {
	let entropy: [u8; 32] = fixed(RECOVERY_KEY);
	let phrase = mnemonic::encode(&entropy);
	let list = mnemonic::words();

	let mut bad_checksum = phrase.clone();
	bad_checksum.swap(0, 1);

	let mut unknown = phrase.clone();
	unknown[0] = "notaword";

	let short = &phrase[..mnemonic::WORD_COUNT - 1];

	file(
		"BIP39 encoding of 256-bit entropy: 24 words, 8-bit checksum. Encoding only, never BIP39 seed derivation.",
		vec![
			json!({
				"name": "wordlist",
				"sha256": mnemonic::WORDLIST_SHA256,
				"count": list.len(),
				"first": list[0],
				"last": list[list.len() - 1],
			}),
			json!({
				"name": "roundTrip",
				"entropy": hx(&entropy),
				"mnemonic": phrase.join(" "),
				"decodes": mnemonic::decode(&phrase).as_ref() == Ok(&entropy),
			}),
			json!({
				"name": "rejectBadChecksum",
				"mnemonic": bad_checksum.join(" "),
				"decodes": mnemonic::decode(&bad_checksum).is_ok(),
			}),
			json!({
				"name": "rejectWrongWordCount",
				"mnemonic": short.join(" "),
				"decodes": mnemonic::decode(short).is_ok(),
			}),
			json!({
				"name": "rejectUnknownWord",
				"mnemonic": unknown.join(" "),
				"decodes": mnemonic::decode(&unknown).is_ok(),
			}),
		],
	)
}

pub fn pairing() -> Value {
	let api_key = seq_bytes(API_KEY, 32);
	let recovery_key = seq_bytes(RECOVERY_KEY, 32);
	let blob = pairing_blob(&api_key, &recovery_key);
	let long = [blob.clone(), vec![0]].concat();

	file(
		"Pairing credential: apiKey ‖ recoveryKey, exactly 64 raw bytes. No version field — the length discriminates. No server URL: it is public, and migrating servers must not invalidate the credential.",
		vec![
			json!({
				"name": "blob",
				"apiKey": hx(&api_key),
				"recoveryKey": hx(&recovery_key),
				"blob": hx(&blob),
				"length": blob.len(),
				"splits": split_pairing(&blob) == Some((&api_key[..], &recovery_key[..])),
			}),
			json!({
				"name": "rejectShort",
				"length": PAIRING_LEN - 1,
				"splits": split_pairing(&blob[..PAIRING_LEN - 1]).is_some(),
			}),
			json!({
				"name": "rejectLong",
				"length": PAIRING_LEN + 1,
				"splits": split_pairing(&long).is_some(),
			}),
		],
	)
}
