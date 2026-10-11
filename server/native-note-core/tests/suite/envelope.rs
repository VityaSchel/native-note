use crate::support::client::{self, INNER_MAX, Response};
use crate::support::corpus::{SplitMix64, corpus, payload};
use crate::support::{SEALED_MAX, open};
use native_note_core::{
	DecodeError, Envelope, EnvelopeKey, Rejection, Reply, Request, Secret, Seq, Version, admit,
};
use std::collections::BTreeSet;

const API_KEY: [u8; 32] = [
	0x9c, 0x4e, 0x21, 0xd7, 0x6a, 0x03, 0xb5, 0xf8, 0x1d, 0x92, 0x47, 0xe0, 0x3b, 0xa6, 0x58, 0xc4,
	0x7f, 0x10, 0xe9, 0x35, 0x8b, 0x62, 0xd1, 0x0a, 0xf4, 0x2c, 0x97, 0x5e, 0xb3, 0x06, 0x7d, 0xe8,
];

fn server_key(api_key: [u8; 32]) -> EnvelopeKey {
	EnvelopeKey::derive(&Secret::new(api_key)).expect("a 32-byte key derives")
}

#[test]
fn admit_takes_bodies_from_a_nonce_and_tag_up_to_the_sealed_limit() {
	assert_eq!(admit(0), Err(Rejection::Unopenable));
	assert_eq!(admit(27), Err(Rejection::Unopenable));
	assert_eq!(admit(28), Ok(()));
	assert_eq!(admit(SEALED_MAX), Ok(()));
	assert_eq!(admit(SEALED_MAX + 1), Err(Rejection::TooLarge));
	assert_eq!(admit(usize::MAX), Err(Rejection::TooLarge));
}

#[test]
fn parse_rejects_every_body_shorter_than_a_nonce_and_tag() {
	for len in 0..28 {
		assert_eq!(
			Envelope::parse(vec![0xa5; len]).err(),
			Some(Rejection::Unopenable),
			"{len}"
		);
	}
	assert!(Envelope::parse(vec![0xa5; 28]).is_ok());
}

#[test]
fn parse_takes_bodies_up_to_the_sealed_limit_and_no_more() {
	assert!(Envelope::parse(vec![0xa5; SEALED_MAX - 1]).is_ok());
	assert!(Envelope::parse(vec![0xa5; SEALED_MAX]).is_ok());
	assert_eq!(
		Envelope::parse(vec![0xa5; SEALED_MAX + 1]).err(),
		Some(Rejection::TooLarge)
	);
}

#[test]
fn a_frame_sealed_under_any_other_key_is_unopenable() {
	let key = server_key(API_KEY);
	let inner = client::encode_request(&Request::Get);
	let nonce = [0x45; 12];
	let mut other = API_KEY;
	other[0] ^= 0x80;
	for wrong in [client::envelope_key(&other), API_KEY, [0; 32]] {
		let body = client::seal_request(&wrong, nonce, &inner);
		assert_eq!(open(&key, body).err(), Some(Rejection::Unopenable));
	}

	let body = client::seal_request(&client::envelope_key(&API_KEY), nonce, &inner);
	assert_eq!(
		open(&server_key(other), body.clone()).err(),
		Some(Rejection::Unopenable)
	);
	let opened = open(&key, body).expect("opens under its own key");
	assert_eq!(opened.request(), Ok(Request::Get));
}

#[test]
fn flipping_any_bit_of_a_sealed_request_makes_it_unopenable() {
	let key = server_key(API_KEY);
	let request = Request::Put {
		v: Version(1),
		blob: payload(60, 0x0045),
	};
	let body = client::seal_request(
		&client::envelope_key(&API_KEY),
		[0x5a; 12],
		&client::encode_request(&request),
	);
	assert_eq!(body.len(), 256 + 28);
	let mut flipped = 0;
	for at in 0..body.len() {
		for bit in 0..8 {
			let mut tampered = body.clone();
			tampered[at] ^= 1 << bit;
			assert_eq!(
				open(&key, tampered).err(),
				Some(Rejection::Unopenable),
				"byte {at} bit {bit}"
			);
			flipped += 1;
		}
	}
	assert_eq!(flipped, 2_272);
	let opened = open(&key, body).expect("the untouched frame opens");
	assert_eq!(opened.request(), Ok(request));
}

#[test]
fn a_sealed_plaintext_too_short_to_unpad_opens_then_fails_with_padding() {
	let key = server_key(API_KEY);
	let envelope_key = client::envelope_key(&API_KEY);
	for len in 0..=3 {
		let nonce = [u8::try_from(len).expect("small"); 12];
		let body = client::seal(&envelope_key, nonce, &vec![0; len]);
		assert_eq!(body.len(), 28 + len);
		let opened = open(&key, body).expect("opens");
		assert_eq!(opened.nonce(), nonce, "{len}");
		assert_eq!(opened.request(), Err(DecodeError::Padding), "{len}");
	}
}

#[test]
fn every_corpus_batch_sealed_by_a_client_opens_back_to_its_request() {
	let key = server_key(API_KEY);
	let envelope_key = client::envelope_key(&API_KEY);
	let batches = client::batch(corpus());
	let syncs = batches
		.iter()
		.zip(0..)
		.map(|(writes, index)| Request::Sync {
			since: Seq(index * 1_000),
			writes: writes.to_vec(),
		});
	let recovery = [
		Request::Get,
		Request::Put {
			v: Version(1),
			blob: payload(60, 0x0050_5554),
		},
		Request::Put {
			v: Version(2),
			blob: payload(INNER_MAX - 9, 0x0050_5554),
		},
	];

	let mut rng = SplitMix64::new(45);
	let mut nonces = BTreeSet::new();
	let mut at_limit = 0;
	let mut largest = Vec::new();
	for request in syncs.chain(recovery) {
		let nonce = rng.array();
		assert!(nonces.insert(nonce), "nonce reused");
		let body = client::seal_request(&envelope_key, nonce, &client::encode_request(&request));
		assert_eq!(admit(body.len()), Ok(()));
		if body.len() == SEALED_MAX {
			at_limit += 1;
			largest.clone_from(&body);
		}
		let opened = open(&key, body).expect("opens");
		assert_eq!(opened.nonce(), nonce);
		assert_eq!(opened.request(), Ok(request));
	}
	assert_eq!(nonces.len(), batches.len() + 3);
	assert!(batches.len() >= 25, "{} batches", batches.len());
	assert!(at_limit >= batches.len(), "{at_limit} bodies at the limit");

	let mut over = largest.clone();
	over.push(0x00);
	assert_eq!(over.len(), SEALED_MAX + 1);
	assert_eq!(admit(over.len()), Err(Rejection::TooLarge));
	assert_eq!(open(&key, over).err(), Some(Rejection::TooLarge));
	largest.pop();
	assert_eq!(open(&key, largest).err(), Some(Rejection::Unopenable));
}

#[test]
fn a_sealed_error_reply_is_284_bytes_and_opens_only_under_its_request_nonce() {
	let key = server_key(API_KEY);
	let envelope_key = client::envelope_key(&API_KEY);
	let (request_nonce, response_nonce) = ([0x52; 12], [0x91; 12]);
	let body = key
		.seal(Reply::error(), &request_nonce, response_nonce)
		.expect("seals");
	assert_eq!(body.len(), 284);
	assert_eq!(body[..12], response_nonce);
	let inner = client::open_response(&envelope_key, &request_nonce, &body).expect("opens");
	assert_eq!(client::decode_response(&inner), Response::Error);

	for bit in 0..96 {
		let mut other = request_nonce;
		other[bit / 8] ^= 1 << (bit % 8);
		assert_eq!(
			client::open_response(&envelope_key, &other, &body),
			None,
			"bit {bit}"
		);
	}
	assert_eq!(
		client::open_response(&envelope_key, &response_nonce, &body),
		None
	);
	assert_eq!(open(&key, body).err(), Some(Rejection::Unopenable));
}
