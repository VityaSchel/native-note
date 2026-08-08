use serde_json::{json, Value};

use super::{file, uuid_bytes, CONTENT_KEY, NONCE, WRITE_ID};
use crate::content::{self, Content};
use crate::hex::encode as hx;
use crate::{codec::DecodeError, fixed, kdf, note, seq_bytes};

pub const CREATED_AT: i64 = 1_786_183_200_000;
pub const UPDATED_AT: i64 = 1_786_183_500_000;
pub const DELETED_AT: i64 = 1_786_186_800_000;

pub fn sample_note(body: &str) -> Content {
	Content::Note {
		uuid: uuid_bytes(),
		created_at: CREATED_AT,
		updated_at: UPDATED_AT,
		body: body.to_string(),
	}
}

pub fn sample_tombstone() -> Content {
	Content::Tombstone {
		uuid: uuid_bytes(),
		deleted_at: DELETED_AT,
	}
}

fn describe(value: &Content) -> Value {
	match value {
		Content::Note {
			uuid,
			created_at,
			updated_at,
			body,
		} => json!({
			"kind": "note",
			"uuid": hx(uuid),
			"createdAt": created_at,
			"updatedAt": updated_at,
			"body": body,
		}),
		Content::Tombstone { uuid, deleted_at } => json!({
			"kind": "tombstone",
			"uuid": hx(uuid),
			"deletedAt": deleted_at,
		}),
	}
}

fn case(name: &str, value: Content) -> Value {
	let encoded = content::encode(&value);
	json!({
		"name": name,
		"content": describe(&value),
		"encoded": hx(&encoded),
		"length": encoded.len(),
		"roundTrips": content::decode(&encoded).as_ref() == Ok(&value),
	})
}

fn reject(name: &str, bytes: Vec<u8>, expected: DecodeError) -> Value {
	json!({
		"name": name,
		"encoded": hx(&bytes),
		"decodes": content::decode(&bytes).is_ok(),
		"error": format!("{expected:?}"),
		"matches": content::decode(&bytes) == Err(expected),
	})
}

pub fn content() -> Value {
	let valid = content::encode(&sample_tombstone());

	let mut wrong_version = valid.clone();
	wrong_version[0] = 0x02;

	let mut wrong_kind = valid.clone();
	wrong_kind[1] = 0x7f;

	let trailing = [valid.clone(), vec![0]].concat();
	let truncated = valid[..valid.len() - 1].to_vec();

	let mut bad_utf8 = content::encode(&sample_note("x"));
	*bad_utf8.last_mut().unwrap() = 0xff;

	file(
		"Note content: version ‖ kind ‖ fields. Timestamps are epoch milliseconds; the body is length-prefixed UTF-8.",
		vec![
			case("note", sample_note("Groceries\nmilk\nbread")),
			case("tombstone", sample_tombstone()),
			case("nonAscii", sample_note("Ünïcode — 日本語 🔐")),
			case("emptyBody", sample_note("")),
			reject(
				"rejectUnknownVersion",
				wrong_version,
				DecodeError::UnknownDiscriminant,
			),
			reject(
				"rejectUnknownKind",
				wrong_kind,
				DecodeError::UnknownDiscriminant,
			),
			reject("rejectTrailingBytes", trailing, DecodeError::TrailingBytes),
			reject("rejectTruncated", truncated, DecodeError::Truncated),
			reject("rejectInvalidUtf8", bad_utf8, DecodeError::NotCanonical),
		],
	)
}

fn note_case(name: &str, v: u32, value: Content) -> Value {
	let content_key = seq_bytes(CONTENT_KEY, 32);
	let blinded = note::blinded_id(&kdf::blinding_key(&content_key), &uuid_bytes());
	let write_id: [u8; 16] = fixed(WRITE_ID);
	let nonce: [u8; 12] = fixed(NONCE);
	let plaintext = content::encode(&value);
	let payload = note::seal(&content_key, &write_id, &nonce, &blinded, v, &plaintext);

	json!({
		"name": name,
		"content": describe(&value),
		"plaintext": hx(&plaintext),
		"blindedId": hx(&blinded),
		"v": v,
		"writeId": hx(&write_id),
		"nonce": hx(&nonce),
		"aad": hx(&note::aad(&blinded, v, &write_id)),
		"payload": hx(&payload),
		"roundTrips": note::open(&content_key, &write_id, &blinded, v, &payload).as_deref()
			== Ok(plaintext.as_slice()),
		"opensUnderWrongVersion": note::open(&content_key, &write_id, &blinded, v + 1, &payload)
			.is_ok(),
	})
}

pub fn note() -> Value {
	file(
		"Note payloads. The key is derived per write from writeId; the AAD binds blindedId, v and writeId, so a payload will not open at another version.",
		vec![
			note_case("note", 1, sample_note("Groceries\nmilk\nbread")),
			note_case("tombstone", 2, sample_tombstone()),
			note_case("nonAscii", 3, sample_note("Ünïcode — 日本語 🔐")),
		],
	)
}
