use serde_json::{Value, json};

use super::{CONTENT_KEY, NONCE, WRITE_ID, file, seq_array, seq_bytes, uuid_bytes};
use crate::codec::DecodeError;
use crate::content::{self, Content};
use crate::hex::encode as hx;
use crate::{kdf, note};

pub(super) const CREATED_AT: i64 = 1_786_183_200_000;
pub(super) const UPDATED_AT: i64 = 1_786_183_500_000;
const DELETED_AT: i64 = 1_786_186_800_000;

pub fn sample_note(body: &str) -> Content {
	sample_note_as(uuid_bytes(), body)
}

pub fn sample_note_as(uuid: [u8; 16], body: &str) -> Content {
	Content::Note {
		uuid,
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

pub(super) fn describe(value: &Content) -> Value {
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

fn note_with_body_bytes(body: &[u8]) -> Vec<u8> {
	let mut encoded = content::encode(&sample_note(""));
	encoded.truncate(encoded.len() - 4);
	encoded.extend_from_slice(&(body.len() as u32).to_be_bytes());
	encoded.extend_from_slice(body);
	encoded
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

	let body_len_at = 1 + 1 + 16 + 8 + 8;
	let mut huge_length = content::encode(&sample_note("x"));
	huge_length[body_len_at..body_len_at + 4].copy_from_slice(&u32::MAX.to_be_bytes());

	file(
		"Note content: version ‖ kind ‖ fields. Timestamps are signed epoch milliseconds; the body is length-prefixed UTF-8 per RFC 3629. Nothing else is validated, so any uuid and timestamp order decodes.",
		vec![
			case("note", sample_note("Groceries\nmilk\nbread")),
			case("tombstone", sample_tombstone()),
			case("nonAscii", sample_note("Ünïcode — 日本語 🔐")),
			case("emptyBody", sample_note("")),
			case(
				"beforeEpoch",
				Content::Note {
					uuid: uuid_bytes(),
					created_at: -86_400_000,
					updated_at: -1,
					body: "1969".to_string(),
				},
			),
			case(
				"nonV4UuidAndReversedTimes",
				Content::Note {
					uuid: [0; 16],
					created_at: UPDATED_AT,
					updated_at: CREATED_AT,
					body: "decodes".to_string(),
				},
			),
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
			reject(
				"rejectImpossibleLength",
				huge_length,
				DecodeError::Truncated,
			),
			reject(
				"rejectInvalidUtf8",
				note_with_body_bytes(&[0xff]),
				DecodeError::NotCanonical,
			),
			reject(
				"rejectOverlongUtf8",
				note_with_body_bytes(&[0xc0, 0x80]),
				DecodeError::NotCanonical,
			),
			reject(
				"rejectEncodedSurrogate",
				note_with_body_bytes(&[0xed, 0xa0, 0x80]),
				DecodeError::NotCanonical,
			),
			reject(
				"rejectCodePointAboveMax",
				note_with_body_bytes(&[0xf4, 0x90, 0x80, 0x80]),
				DecodeError::NotCanonical,
			),
		],
	)
}

fn note_case(name: &str, v: u32, value: Content) -> Value {
	let content_key = seq_bytes(CONTENT_KEY, 32);
	let blinded = note::blinded_id(&kdf::blinding_key(&content_key), value.uuid());
	let write_id: [u8; 16] = seq_array(WRITE_ID);
	let nonce: [u8; 12] = seq_array(NONCE);
	let plaintext = content::encode(&value);
	let payload = note::seal(&content_key, &write_id, &nonce, &blinded, v, &plaintext);

	json!({
		"name": name,
		"contentKey": hx(&content_key),
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
