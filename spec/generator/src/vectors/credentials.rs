use serde_json::{Value, json};

use super::{RECOVERY_KEY, file, seq_array};
use crate::hex::encode as hx;
use crate::mnemonic;

pub fn mnemonic() -> Value {
	let entropy: [u8; 32] = seq_array(RECOVERY_KEY);
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
