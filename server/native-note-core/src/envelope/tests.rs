use super::{Envelope, EnvelopeKey, Rejection};
use crate::frame::{Changes, WriteResult, sync_response};
use crate::padding::pad;
use crate::reply::Reply;
use crate::secret::Secret;
use crate::types::{BlindedNoteId, Record, Seq, Version};
use crate::version::Status;
use ring::aead::{Aad, Nonce};

const API_KEY: [u8; 32] = [
	0x3f, 0x91, 0x0c, 0xe7, 0x52, 0xb8, 0x14, 0x6d, 0xa9, 0x27, 0xf0, 0x83, 0x5e, 0xc1, 0x38, 0x9b,
	0x07, 0x64, 0xdd, 0x1a, 0x8f, 0x46, 0xb3, 0x29, 0x70, 0xce, 0x95, 0x02, 0x6b, 0xe4, 0x11, 0xfa,
];

#[test]
fn debug_of_an_envelope_key_prints_no_key_material() {
	let key = EnvelopeKey::derive(&Secret::new(API_KEY)).expect("a 32-byte key derives");
	assert_eq!(format!("{key:?}"), "EnvelopeKey([redacted])");
	assert_eq!(format!("{key:x?}"), "EnvelopeKey([redacted])");
	assert_eq!(format!("{key:#?}"), "EnvelopeKey(\n    [redacted],\n)");
	assert_eq!(format!("{key:#X?}"), "EnvelopeKey(\n    [redacted],\n)");
	assert_eq!(format!("{:?}", Some(&key)), "Some(EnvelopeKey([redacted]))");
}

fn open_reply(key: &EnvelopeKey, request_nonce: &[u8], body: &[u8]) -> Option<Vec<u8>> {
	let (nonce, sealed) = body.split_first_chunk::<12>()?;
	let mut padded = sealed.to_vec();
	key.0
		.expose()
		.open_in_place(
			Nonce::assume_unique_for_key(*nonce),
			Aad::from(request_nonce),
			&mut padded,
		)
		.ok()
		.map(|plaintext| plaintext.to_vec())
}

#[test]
fn a_sealed_reply_is_its_response_nonce_then_the_padded_reply_sealed_to_the_request_nonce() {
	let key = EnvelopeKey::derive(&Secret::new(API_KEY)).expect("a 32-byte key derives");
	let results = [
		WriteResult {
			status: Status::Accepted,
			v: Version(4),
			seq: Seq(17),
		},
		WriteResult {
			status: Status::Conflict,
			v: Version(9),
			seq: Seq(0),
		},
		WriteResult {
			status: Status::TooLarge,
			v: Version(1),
			seq: Seq(0),
		},
	];
	let changes = Changes {
		records: vec![Record {
			id: BlindedNoteId([0x31; 16]),
			v: Version(4),
			write_id: [0x32; 16],
			payload: vec![0x33; 3_000],
		}],
		next_seq: Seq(17),
		more: false,
	};
	let reply = pad(&sync_response(&results, &changes))
		.map(Reply)
		.expect("pads");
	let padded = reply.0.clone();
	assert_eq!(padded.len(), 4_096);

	let (request_nonce, response_nonce) = ([0x21; 12], [0x9a; 12]);
	let body = key
		.seal(reply, &request_nonce, response_nonce)
		.expect("seals");
	assert_eq!(body.len(), padded.len() + 28);
	assert_eq!(body[..12], response_nonce);
	assert_eq!(open_reply(&key, &request_nonce, &body), Some(padded));

	for bit in 0..96 {
		let mut other = request_nonce;
		other[bit / 8] ^= 1 << (bit % 8);
		assert_eq!(open_reply(&key, &other, &body), None, "bit {bit}");
	}
	assert_eq!(open_reply(&key, &[], &body), None);
	assert_eq!(open_reply(&key, &response_nonce, &body), None);
	assert_eq!(
		key.open(Envelope::parse(body).expect("parses")).err(),
		Some(Rejection::Unopenable)
	);
}

#[test]
fn a_reply_is_never_sealed_under_its_request_nonce() {
	let key = EnvelopeKey::derive(&Secret::new(API_KEY)).expect("a 32-byte key derives");
	let nonce = [0x44; 12];
	assert_eq!(key.seal(Reply::error(), &nonce, nonce), None);
}
