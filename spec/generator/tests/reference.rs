use std::fmt::Debug;

use native_note_vectors::codec::DecodeError;
use native_note_vectors::content::{self, Content};
use native_note_vectors::envelope::{self, MAX_BUCKET};
use native_note_vectors::export::{self, ArgonParams};
use native_note_vectors::frame::{self, Request, Response, Status, Write, WriteResult};
use native_note_vectors::mnemonic::{self, MnemonicError};
use native_note_vectors::server::{NOTE_MAX, Server};
use native_note_vectors::vectors::{seq_array, seq_bytes};
use native_note_vectors::{aead, hex, kdf, markdown, zip};

fn write(v: u32, size: usize) -> Write {
	Write {
		blinded_id: [7; 16],
		v,
		write_id: [1; 16],
		payload: vec![0; size],
	}
}

fn sync_request(writes: Vec<Write>) -> Vec<u8> {
	frame::encode_request(&Request::Sync { since: 0, writes })
}

fn decodes_exactly<T: Debug + PartialEq>(
	value: T,
	encode: fn(&T) -> Vec<u8>,
	decode: fn(&[u8]) -> Result<T, DecodeError>,
) {
	let encoded = encode(&value);
	assert_eq!(decode(&encoded), Ok(value));
	for cut in 0..encoded.len() {
		assert_eq!(
			decode(&encoded[..cut]),
			Err(DecodeError::Truncated),
			"cut at {cut}"
		);
	}
	assert_eq!(
		decode(&[encoded, vec![0]].concat()),
		Err(DecodeError::TrailingBytes)
	);
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
	let mut server = Server::new();

	assert_eq!(server.apply(&write(2, 1)).status, Status::Conflict);
	assert_eq!(server.apply(&write(1, 1)).status, Status::Accepted);
	assert_eq!(server.apply(&write(1, 1)).status, Status::Conflict);
	assert_eq!(server.apply(&write(3, 1)).status, Status::Conflict);

	let accepted = server.apply(&write(2, 1));
	assert_eq!(accepted.status, Status::Accepted);
	assert_eq!(accepted.seq, 2);

	let rejected = server.apply(&write(3, NOTE_MAX + 1));
	assert_eq!(rejected.status, Status::TooLarge);
	assert_eq!(rejected.seq, 0, "a rejected write never carries a seq");

	assert_eq!(server.changes_since(1).len(), 1);
	assert_eq!(server.changes_since(2).len(), 0);
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
		decodes_exactly(sample, content::encode, content::decode);
	}
	assert_eq!(
		content::decode(&[0x02, 0x01]),
		Err(DecodeError::UnknownDiscriminant)
	);
}

#[test]
fn frames_round_trip_and_reject_every_truncation() {
	let result = |status, seq| WriteResult { status, v: 7, seq };
	let requests = [
		Request::Sync {
			since: 9,
			writes: vec![write(2, 5), write(2, 5)],
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
			],
			changes: vec![write(2, 5)],
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
		Response::Error,
	];

	for request in requests {
		decodes_exactly(request, frame::encode_request, frame::decode_request);
	}
	for response in responses {
		decodes_exactly(response, frame::encode_response, frame::decode_response);
	}

	for status in [0x00, 0x03, 0x04, 0x05, 0xff] {
		assert_eq!(
			frame::decode_response(&[0x03, status, 0, 0, 0, 1]),
			Err(DecodeError::UnknownDiscriminant)
		);
	}
}

#[test]
fn sealed_inputs_shorter_than_nonce_and_tag_are_rejected() {
	for len in 0..aead::NONCE_LEN + aead::TAG_LEN {
		let short = vec![0; len];
		assert!(
			envelope::open_response(&[0; 32], &[0; 12], &short).is_err(),
			"length {len}"
		);
		assert!(
			envelope::open_request(&[0; 32], &short).is_err(),
			"length {len}"
		);
	}
}

#[test]
fn padding_stops_at_the_largest_bucket() {
	assert_eq!(envelope::bucket_for(0), Some(256));
	assert_eq!(envelope::bucket_for(257), Some(512));
	assert_eq!(envelope::bucket_for(MAX_BUCKET), Some(MAX_BUCKET));
	assert_eq!(envelope::bucket_for(MAX_BUCKET + 1), None);

	assert_eq!(
		envelope::seal_request(&[0; 32], &[0; 12], &vec![1; MAX_BUCKET - 3]),
		None
	);
	assert_eq!(
		envelope::seal_response(&[0; 32], &[0; 12], &[0; 12], &vec![1; MAX_BUCKET - 3]),
		None
	);

	assert_eq!(envelope::unpad(&[]), None);
	let mut past_end = vec![0; 256];
	past_end[..4].copy_from_slice(&u32::MAX.to_be_bytes());
	assert_eq!(envelope::unpad(&past_end), None);

	for inner in [0, 252, 253, 508, 509] {
		let mut oversized = envelope::pad(&vec![1; inner]).unwrap();
		oversized.resize(oversized.len() * 2, 0);
		assert_eq!(envelope::unpad(&oversized), None, "inner {inner}");
	}
}

#[test]
fn sealed_frames_are_28_bytes_longer_than_padded_in_both_directions() {
	for inner in [vec![], vec![1; MAX_BUCKET - 4]] {
		let padded = envelope::pad(&inner).unwrap().len();
		let request = envelope::seal_request(&[0; 32], &[0; 12], &inner).unwrap();
		let response = envelope::seal_response(&[0; 32], &[0; 12], &[0; 12], &inner).unwrap();
		assert_eq!(request.len(), padded + 28);
		assert_eq!(response.len(), padded + 28);
	}
}

#[test]
fn the_note_limit_is_one_mib() {
	assert_eq!(NOTE_MAX, 1024 * 1024);
}

#[test]
fn a_write_over_the_note_limit_fits_a_request_and_gets_too_large() {
	let over = write(1, NOTE_MAX + 1);
	assert!(envelope::pad(&sync_request(vec![over.clone()])).is_some());
	assert_eq!(Server::new().apply(&over).status, Status::TooLarge);
}

#[test]
fn the_most_results_a_request_can_ask_for_and_a_maximum_size_change_fit_one_response() {
	let request = |count| sync_request(vec![write(1, 0); count]);
	let empty = request(0).len();
	let most = (MAX_BUCKET - 4 - empty) / (request(1).len() - empty);
	assert!(envelope::pad(&request(most)).is_some());
	assert_eq!(envelope::pad(&request(most + 1)), None);

	let response = frame::encode_response(&Response::Sync {
		results: vec![
			WriteResult {
				status: Status::Accepted,
				v: 1,
				seq: 1,
			};
			most
		],
		changes: vec![write(1, NOTE_MAX)],
		next_seq: 1,
		more: false,
	});
	assert_eq!(
		envelope::pad(&response).map(|padded| padded.len()),
		Some(MAX_BUCKET)
	);
}

#[test]
fn status_names_match_the_protocol() {
	let statuses = [Status::Accepted, Status::Conflict, Status::TooLarge];
	assert_eq!(
		statuses.map(Status::name),
		["accepted", "conflict", "too_large"]
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

#[test]
fn export_round_trips_under_its_own_header() {
	let params = ArgonParams { m: 64, t: 1, p: 2 };
	let salt: [u8; 16] = seq_array(0x30);
	let nonce: [u8; 12] = seq_array(0x70);
	let file = export::seal("passphrase", params, &salt, &nonce, b"zip").unwrap();

	assert_eq!(ArgonParams::decode(&params.encode()), params);
	assert_eq!(
		&file[..export::HEADER_LEN],
		export::header(params, &salt).as_slice()
	);
	assert_eq!(
		export::open("passphrase", &file).as_deref(),
		Ok(b"zip".as_slice())
	);
	assert!(export::open("Passphrase", &file).is_err());

	for at in (0..export::MAGIC.len()).chain(export::HEADER_LEN - export::SALT_LEN..file.len()) {
		let mut flipped = file.clone();
		flipped[at] ^= 0x01;
		assert!(export::open("passphrase", &flipped).is_err(), "byte {at}");
	}
}

#[test]
fn export_rejects_short_files_and_invalid_parameters() {
	let params = ArgonParams { m: 64, t: 1, p: 2 };
	let salt: [u8; 16] = seq_array(0x30);
	let nonce: [u8; 12] = seq_array(0x70);
	let file = export::seal("passphrase", params, &salt, &nonce, b"").unwrap();
	assert_eq!(
		file.len(),
		export::HEADER_LEN + aead::NONCE_LEN + aead::TAG_LEN
	);

	for len in 0..file.len() {
		assert!(
			export::open("passphrase", &file[..len]).is_err(),
			"length {len}"
		);
	}

	assert!(export::export_key("passphrase", &salt[..7], params).is_err());

	let no_passes = ArgonParams { t: 0, ..params };
	assert!(export::seal("passphrase", no_passes, &salt, &nonce, b"zip").is_err());
}

#[test]
fn the_server_seals_an_answer_to_everything_that_unseals() {
	let key = kdf::envelope_key(&seq_bytes(0x00, 32));
	let nonce: [u8; 12] = seq_array(0x70);
	let resp_nonce: [u8; 12] = seq_array(0x90);
	let mut server = Server::new();
	let mut answer_to = |sealed: &[u8]| {
		let answer = server.handle(&key, sealed, &resp_nonce).unwrap();
		frame::decode_response(&envelope::open_response(&key, &nonce, &answer).unwrap()).unwrap()
	};
	let mut ask = |inner: &[u8]| answer_to(&envelope::seal_request(&key, &nonce, inner).unwrap());

	let put = frame::encode_request(&Request::PutRecovery {
		v: 1,
		blob: b"blob".to_vec(),
	});
	assert_eq!(
		ask(&put),
		Response::PutRecovery {
			status: Status::Accepted,
			v: 1
		}
	);
	assert_eq!(
		ask(&frame::encode_request(&Request::GetRecovery)),
		Response::GetRecovery {
			v: 1,
			blob: b"blob".to_vec()
		}
	);
	let Response::Sync {
		results, changes, ..
	} = ask(&sync_request(vec![write(1, 1)]))
	else {
		panic!("a sync gets a sync response");
	};
	assert_eq!(results[0].status, Status::Accepted);
	assert_eq!(changes, vec![write(1, 1)]);
	assert_eq!(ask(&[0x7f]), Response::Error);

	let mut dirty = envelope::pad(&put).unwrap();
	dirty[200] = 0x01;
	let unpaddable = aead::seal(&key, &nonce, &dirty, &[]);
	assert_eq!(answer_to(&unpaddable), Response::Error);

	let other_key = kdf::envelope_key(&seq_bytes(0x01, 32));
	let foreign = envelope::seal_request(&other_key, &nonce, &put).unwrap();
	assert_eq!(server.handle(&key, &foreign, &resp_nonce), None);
	assert_eq!(server.handle(&key, &[], &resp_nonce), None);
}

#[test]
fn stored_archives_match_the_zip_check_values() {
	assert_eq!(zip::crc32(b""), 0);
	assert_eq!(zip::crc32(b"123456789"), 0xcbf4_3926);
	assert_eq!(
		zip::stored(&[]),
		[b"PK\x05\x06".as_slice(), &[0; 18]].concat()
	);

	let archive = zip::stored(&[("a.md", b"x")]);
	assert_eq!(&archive[..4], b"PK\x03\x04");
	assert_eq!(archive.len(), 30 + 4 + 1 + 46 + 4 + 22);
}

#[test]
fn timestamps_widen_past_six_digit_years_at_the_limits_of_i64() {
	assert_eq!(
		markdown::timestamp(i64::MIN),
		"-292275055-05-16T16:47:04.192Z"
	);
	assert_eq!(
		markdown::timestamp(i64::MAX),
		"+292278994-08-17T07:12:55.807Z"
	);
	assert_eq!(markdown::timestamp(-1), "1969-12-31T23:59:59.999Z");
	assert_eq!(
		markdown::timestamp(-62_167_219_200_000),
		"0000-01-01T00:00:00.000Z"
	);
}
