use native_note_vectors::codec::DecodeError;
use native_note_vectors::content::{self, Content};
use native_note_vectors::envelope::{self, PadError};
use native_note_vectors::frame::{self, Request, Response, Status, Write, WriteResult};
use native_note_vectors::mnemonic::{self, MnemonicError};
use native_note_vectors::server::Server;
use native_note_vectors::vectors::{seq_array, seq_bytes};
use native_note_vectors::{aead, hex, kdf};

#[test]
fn aead_and_envelope_round_trip() {
	let key = kdf::envelope_key(&seq_bytes(0x00, 32));
	let nonce: [u8; 12] = seq_array(0x70);
	let resp_nonce: [u8; 12] = seq_array(0x90);

	let sealed = aead::seal(&key, &nonce, b"probe", b"aad");
	assert_eq!(
		aead::open(&key, &sealed, b"aad").as_deref(),
		Ok(b"probe".as_slice())
	);
	assert!(aead::open(&key, &sealed, b"other").is_err());

	let request = envelope::seal_request(&key, &nonce, b"{}").unwrap();
	assert_eq!(
		envelope::open_request(&key, &request).as_deref(),
		Ok(b"{}".as_slice())
	);

	let response = envelope::seal_response(&key, &resp_nonce, &nonce, b"{}").unwrap();
	assert_eq!(
		envelope::open_response(&key, &nonce, &response).as_deref(),
		Ok(b"{}".as_slice())
	);

	let mut wrong = nonce;
	wrong[0] ^= 1;
	assert!(envelope::open_response(&key, &wrong, &response).is_err());
}

#[test]
fn mnemonic_round_trips_and_rejects() {
	for seed in [0x00u8, 0x40, 0xff] {
		let entropy: [u8; 32] = seq_array(seed);
		let phrase = mnemonic::encode(&entropy);
		assert_eq!(phrase.len(), 24);
		assert_eq!(mnemonic::decode(&phrase), Ok(entropy));
	}

	let entropy: [u8; 32] = seq_array(0x40);
	let phrase = mnemonic::encode(&entropy);

	let mut swapped = phrase.clone();
	swapped.swap(0, 1);
	assert_eq!(mnemonic::decode(&swapped), Err(MnemonicError::Checksum));

	let mut unknown = phrase.clone();
	unknown[3] = "notaword";
	assert_eq!(
		mnemonic::decode(&unknown),
		Err(MnemonicError::UnknownWord(3))
	);

	assert_eq!(
		mnemonic::decode(&phrase[..23]),
		Err(MnemonicError::WordCount)
	);
}

#[test]
fn version_rule_rejects_replays_and_gaps() {
	let mut server = Server::new(1024);
	let write = |v: u32, size: usize| Write {
		blinded_id: [7u8; 16],
		v,
		write_id: [1u8; 16],
		deleted: false,
		payload: vec![0; size],
	};

	assert_eq!(server.apply(&write(2, 1)).status, Status::Conflict);
	assert_eq!(server.apply(&write(1, 1)).status, Status::Accepted);
	assert_eq!(server.apply(&write(1, 1)).status, Status::Conflict);
	assert_eq!(server.apply(&write(3, 1)).status, Status::Conflict);

	let accepted = server.apply(&write(2, 1));
	assert_eq!(accepted.status, Status::Accepted);
	assert_eq!(accepted.seq, 2);

	let rejected = server.apply(&write(3, 2048));
	assert_eq!(rejected.status, Status::TooLarge);
	assert_eq!(rejected.seq, 0, "a rejected write never carries a seq");

	assert_eq!(server.changes_since(1).len(), 1);
	assert_eq!(server.changes_since(2).len(), 0);
}

#[test]
fn decoders_reject_malformed_input() {
	let mut count = frame::encode_request(&Request::Sync {
		since: 1,
		writes: vec![Write {
			blinded_id: [1u8; 16],
			v: 1,
			write_id: [2u8; 16],
			deleted: false,
			payload: vec![9; 8],
		}],
	});
	count[9..13].copy_from_slice(&u32::MAX.to_be_bytes());
	assert_eq!(frame::decode_request(&count), Err(DecodeError::Truncated));

	assert_eq!(
		content::decode(&[0x02, 0x01]),
		Err(DecodeError::UnknownDiscriminant)
	);
}

#[test]
fn content_round_trips_and_rejects_every_truncation() {
	let samples = [
		Content::Note {
			uuid: [1; 16],
			created_at: -1,
			updated_at: i64::MAX,
			body: "é".into(),
		},
		Content::Note {
			uuid: [2; 16],
			created_at: 0,
			updated_at: 0,
			body: String::new(),
		},
		Content::Tombstone {
			uuid: [3; 16],
			deleted_at: 1,
		},
	];
	for sample in samples {
		let encoded = content::encode(&sample);
		assert_eq!(content::decode(&encoded), Ok(sample));
		for cut in 0..encoded.len() {
			assert_eq!(
				content::decode(&encoded[..cut]),
				Err(DecodeError::Truncated),
				"cut at {cut}"
			);
		}
		assert_eq!(
			content::decode(&[encoded, vec![0]].concat()),
			Err(DecodeError::TrailingBytes)
		);
	}
}

#[test]
fn frames_round_trip_and_reject_every_truncation() {
	let write = Write {
		blinded_id: [1; 16],
		v: 2,
		write_id: [3; 16],
		deleted: true,
		payload: vec![4; 5],
	};
	let result = |status, seq| WriteResult {
		blinded_id: [1; 16],
		status,
		v: 7,
		seq,
	};
	let requests = [
		Request::Sync {
			since: 9,
			writes: vec![write.clone(), write.clone()],
		},
		Request::GetRecovery,
		Request::PutRecovery {
			v: 1,
			blob: vec![5; 3],
		},
	];
	let responses = [
		Response::Sync {
			results: vec![
				result(Status::Accepted, 1),
				result(Status::Conflict, 0),
				result(Status::TooLarge, 0),
				result(Status::Exhausted, 0),
				result(Status::Quota, 0),
			],
			changes: vec![write],
			next_seq: 3,
			more: true,
		},
		Response::GetRecovery {
			v: 1,
			blob: vec![6; 4],
		},
		Response::PutRecovery {
			status: Status::Conflict,
			v: 2,
		},
	];

	for request in requests {
		let encoded = frame::encode_request(&request);
		assert_eq!(frame::decode_request(&encoded), Ok(request));
		for cut in 0..encoded.len() {
			assert_eq!(
				frame::decode_request(&encoded[..cut]),
				Err(DecodeError::Truncated),
				"cut at {cut}"
			);
		}
		assert_eq!(
			frame::decode_request(&[encoded, vec![0]].concat()),
			Err(DecodeError::TrailingBytes)
		);
	}
	for response in responses {
		let encoded = frame::encode_response(&response);
		assert_eq!(frame::decode_response(&encoded), Ok(response));
		for cut in 0..encoded.len() {
			assert_eq!(
				frame::decode_response(&encoded[..cut]),
				Err(DecodeError::Truncated),
				"cut at {cut}"
			);
		}
		assert_eq!(
			frame::decode_response(&[encoded, vec![0]].concat()),
			Err(DecodeError::TrailingBytes)
		);
	}

	assert_eq!(
		frame::decode_response(&[0x7f]),
		Err(DecodeError::UnknownDiscriminant)
	);
	for status in [0x00, 0x06, 0xff] {
		assert_eq!(
			frame::decode_response(&[0x03, status, 0, 0, 0, 1]),
			Err(DecodeError::UnknownDiscriminant)
		);
	}
}

#[test]
fn sealed_inputs_shorter_than_nonce_and_tag_are_rejected() {
	let key = kdf::envelope_key(&[0; 32]);
	for len in 0..aead::NONCE_LEN + aead::TAG_LEN {
		let short = vec![0; len];
		assert!(aead::open(&key, &short, &[]).is_err(), "length {len}");
		assert!(
			envelope::open_response(&key, &[0; 12], &short).is_err(),
			"length {len}"
		);
		assert!(
			envelope::open_request(&key, &[&[envelope::VERSION][..], &short].concat()).is_err(),
			"length {len}"
		);
	}
	assert!(envelope::open_request(&key, &[]).is_err());
}

#[test]
fn padding_stops_at_the_largest_bucket() {
	const MAX_BUCKET: usize = 2 * 1024 * 1024;
	assert_eq!(envelope::bucket_for(0), Some(256));
	assert_eq!(envelope::bucket_for(257), Some(512));
	assert_eq!(envelope::bucket_for(MAX_BUCKET), Some(MAX_BUCKET));
	assert_eq!(envelope::bucket_for(MAX_BUCKET + 1), None);

	let largest = vec![1; MAX_BUCKET - 4];
	let padded = envelope::pad(&largest).unwrap();
	assert_eq!(padded.len(), MAX_BUCKET);
	assert_eq!(envelope::unpad(&padded), Ok(largest));
	assert_eq!(
		envelope::pad(&vec![1; MAX_BUCKET - 3]),
		Err(PadError::TooLarge)
	);
	assert_eq!(
		envelope::seal_request(&[0; 32], &[0; 12], &vec![1; MAX_BUCKET - 3]),
		Err(PadError::TooLarge)
	);
	assert_eq!(
		envelope::seal_response(&[0; 32], &[0; 12], &[0; 12], &vec![1; MAX_BUCKET - 3]),
		Err(PadError::TooLarge)
	);

	assert_eq!(envelope::unpad(&[]), Err(PadError::Malformed));
	let mut past_end = vec![0; 256];
	past_end[..4].copy_from_slice(&253u32.to_be_bytes());
	assert_eq!(envelope::unpad(&past_end), Err(PadError::Malformed));
	past_end[..4].copy_from_slice(&u32::MAX.to_be_bytes());
	assert_eq!(envelope::unpad(&past_end), Err(PadError::Malformed));
}

#[test]
fn status_names_match_the_protocol() {
	let statuses = [
		Status::Accepted,
		Status::Conflict,
		Status::TooLarge,
		Status::Exhausted,
		Status::Quota,
	];
	assert_eq!(
		statuses.map(Status::name),
		["accepted", "conflict", "too_large", "exhausted", "quota"]
	);
}

#[test]
fn hex_is_lowercase_and_rejects_malformed_input() {
	let all: Vec<u8> = (0..=255).collect();
	assert_eq!(hex::decode(&hex::encode(&all)), Some(all));
	assert_eq!(hex::encode(&[0xab]), "ab");
	for malformed in ["0", "0g", "AB", " 0", "+1"] {
		assert_eq!(hex::decode(malformed), None, "{malformed:?}");
	}
}
