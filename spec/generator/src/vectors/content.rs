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
		ext: Vec::new(),
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
			ext,
		} => json!({
			"kind": "note",
			"uuid": hx(uuid),
			"createdAt": created_at,
			"updatedAt": updated_at,
			"body": body,
			"ext": hx(ext),
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

fn filled(mut fields: Vec<u8>) -> Vec<u8> {
	fields.resize(fields.len().div_ceil(content::BLOCK) * content::BLOCK, 0);
	fields
}

fn note_with_body_bytes(body: &[u8]) -> Vec<u8> {
	let mut fields = vec![content::VERSION, content::KIND_NOTE];
	fields.extend_from_slice(&uuid_bytes());
	fields.extend_from_slice(&CREATED_AT.to_be_bytes());
	fields.extend_from_slice(&UPDATED_AT.to_be_bytes());
	fields.extend_from_slice(&(body.len() as u32).to_be_bytes());
	fields.extend_from_slice(body);
	fields.extend_from_slice(&0u32.to_be_bytes());
	filled(fields)
}

fn tombstone_fields() -> Vec<u8> {
	let mut fields = vec![content::VERSION, content::KIND_TOMBSTONE];
	fields.extend_from_slice(&uuid_bytes());
	fields.extend_from_slice(&DELETED_AT.to_be_bytes());
	fields
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

fn reject_from_newer(name: &str, bytes: Vec<u8>) -> Value {
	let mut case = reject(name, bytes.clone(), DecodeError::UnknownDiscriminant);
	case["prefixUuid"] = json!(hx(&content::prefix_uuid(&bytes).unwrap()));
	case
}

pub(super) fn ext_bytes() -> Vec<u8> {
	[b"ext".as_slice(), &[0x00, 0xff, 0x00]].concat()
}

pub fn content() -> Value {
	let valid = content::encode(&sample_tombstone());

	let mut wrong_version = valid.clone();
	wrong_version[0] = 0x02;

	let mut wrong_kind = valid.clone();
	wrong_kind[1] = 0x7f;

	let prefix_only = wrong_version[..18].to_vec();

	let unpadded = tombstone_fields();
	let mut dirty_last = valid.clone();
	*dirty_last.last_mut().expect("content is never empty") = 0x01;
	let mut dirty_first = valid.clone();
	dirty_first[unpadded.len()] = 0x01;
	let dirty_off_boundary = [unpadded.clone(), vec![0x01]].concat();
	let dirty_past_a_block = [valid.clone(), vec![0; content::BLOCK - 1], vec![0x01]].concat();
	let off_boundary = [valid.clone(), vec![0]].concat();
	let aligned = content::encode(&sample_note(
		&"a".repeat(content::BLOCK - content::NOTE_FIELDS),
	));
	let whole_block = [aligned, vec![0; content::BLOCK]].concat();
	let truncated = unpadded[..unpadded.len() - 1].to_vec();

	let body_len_at = 1 + 1 + 16 + 8 + 8;
	let mut huge_length = content::encode(&sample_note("x"));
	huge_length[body_len_at..body_len_at + 4].copy_from_slice(&u32::MAX.to_be_bytes());

	let ext_len_at = body_len_at + 4 + 1;
	let mut ext_past_the_end = content::encode(&sample_note("x"));
	let past_the_end = (ext_past_the_end.len() - (ext_len_at + 4) + 1) as u32;
	ext_past_the_end[ext_len_at..ext_len_at + 4].copy_from_slice(&past_the_end.to_be_bytes());

	file(
		"Note content: version ‖ kind ‖ fields ‖ zero fill up to the next multiple of 4096 bytes, none when the fields end on one. Every version and kind begins with version ‖ kind ‖ uuid, so prefixUuid is the UUID a client reads from content it cannot decode. Timestamps are signed epoch milliseconds; the body is length-prefixed UTF-8 per RFC 3629, and ext is length-prefixed bytes kept as they are. Nothing else is validated, so any uuid, timestamp order and ext decodes.",
		vec![
			case("note", sample_note("Groceries\nmilk\nbread")),
			case("tombstone", sample_tombstone()),
			case(
				"fieldsFillOneBlockExactly",
				sample_note(&"a".repeat(content::BLOCK - content::NOTE_FIELDS)),
			),
			case(
				"oneByteSpillsIntoASecondBlock",
				sample_note(&"a".repeat(content::BLOCK - content::NOTE_FIELDS + 1)),
			),
			case("nonAscii", sample_note("Ünïcode — 日本語 🔐")),
			case("emptyBody", sample_note("")),
			case(
				"nonEmptyExt",
				Content::Note {
					uuid: uuid_bytes(),
					created_at: CREATED_AT,
					updated_at: UPDATED_AT,
					body: "kept with its ext".to_string(),
					ext: ext_bytes(),
				},
			),
			case(
				"beforeEpoch",
				Content::Note {
					uuid: uuid_bytes(),
					created_at: -86_400_000,
					updated_at: -1,
					body: "1969".to_string(),
					ext: Vec::new(),
				},
			),
			case(
				"nonV4UuidAndReversedTimes",
				Content::Note {
					uuid: [0; 16],
					created_at: UPDATED_AT,
					updated_at: CREATED_AT,
					body: "decodes".to_string(),
					ext: Vec::new(),
				},
			),
			reject_from_newer("rejectUnknownVersion", wrong_version),
			reject_from_newer("rejectUnknownKind", wrong_kind),
			reject_from_newer("rejectUnknownVersionUnpadded", prefix_only),
			reject(
				"rejectTrailingBytes",
				dirty_last,
				DecodeError::TrailingBytes,
			),
			reject(
				"rejectNonZeroFirstFillByte",
				dirty_first,
				DecodeError::TrailingBytes,
			),
			reject(
				"rejectDirtyFillOffABoundary",
				dirty_off_boundary,
				DecodeError::TrailingBytes,
			),
			reject(
				"rejectDirtyFillPastABlock",
				dirty_past_a_block,
				DecodeError::TrailingBytes,
			),
			reject("rejectUnpadded", unpadded, DecodeError::NotCanonical),
			reject(
				"rejectFillOffABoundary",
				off_boundary,
				DecodeError::NotCanonical,
			),
			reject(
				"rejectAWholeBlockOfFill",
				whole_block,
				DecodeError::NotCanonical,
			),
			reject("rejectTruncated", truncated, DecodeError::Truncated),
			reject(
				"rejectImpossibleLength",
				huge_length,
				DecodeError::Truncated,
			),
			reject(
				"rejectExtLengthPastTheEnd",
				ext_past_the_end,
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

fn sealed_case(name: &str, v: u32, plaintext: &[u8], uuid: &[u8; 16]) -> Value {
	let content_key = seq_bytes(CONTENT_KEY, 32);
	let blinded = note::blinded_id(&kdf::blinding_key(&content_key), uuid);
	let write_id: [u8; 16] = seq_array(WRITE_ID);
	let nonce: [u8; 12] = seq_array(NONCE);
	let payload = note::seal(&content_key, &write_id, &nonce, &blinded, v, plaintext);

	json!({
		"name": name,
		"contentKey": hx(&content_key),
		"plaintext": hx(plaintext),
		"blindedId": hx(&blinded),
		"v": v,
		"writeId": hx(&write_id),
		"nonce": hx(&nonce),
		"aad": hx(&note::aad(&blinded, v, &write_id)),
		"payload": hx(&payload),
		"roundTrips": note::open(&content_key, &write_id, &blinded, v, &payload).as_deref()
			== Ok(plaintext),
		"opensUnderWrongVersion": note::open(&content_key, &write_id, &blinded, v + 1, &payload)
			.is_ok(),
	})
}

fn note_case(name: &str, v: u32, value: Content) -> Value {
	let mut case = sealed_case(name, v, &content::encode(&value), value.uuid());
	case["content"] = describe(&value);
	case
}

fn note_from_newer(name: &str, v: u32) -> Value {
	let mut plaintext = content::encode(&sample_tombstone());
	plaintext[0] = 0x02;
	let uuid = content::prefix_uuid(&plaintext).unwrap();
	let mut case = sealed_case(name, v, &plaintext, &uuid);
	case["prefixUuid"] = json!(hx(&uuid));
	case["decodes"] = json!(content::decode(&plaintext).is_ok());
	case["error"] = json!(format!("{:?}", DecodeError::UnknownDiscriminant));
	case["matches"] = json!(content::decode(&plaintext) == Err(DecodeError::UnknownDiscriminant));
	case
}

pub fn note() -> Value {
	file(
		"Note payloads. The key is derived per write from writeId; the AAD binds blindedId, v and writeId, so a payload will not open at another version. Content a client cannot decode still carries the prefix whose prefixUuid re-derives blindedId.",
		vec![
			note_case("note", 1, sample_note("Groceries\nmilk\nbread")),
			note_case("tombstone", 2, sample_tombstone()),
			note_case("nonAscii", 3, sample_note("Ünïcode — 日本語 🔐")),
			note_from_newer("rejectUnknownVersion", 4),
		],
	)
}
