use crate::support::client::{Response, Status, WriteResult};
use crate::support::harness::{Failure, Harness, Http};
use crate::support::memory::MemoryStorage;
use crate::support::vectors::{
	Listing, REGISTRY, case, cases, hex, hex_array, replayed, vectors_dir,
};
use crate::support::{BODY_MAX, NOTE_MAX, client, open};
use native_note_core::{
	BlindedNoteId, DecodeError, EnvelopeKey, Record, Rejection, Request, Secret, Seq, Version,
};
use serde_json::Value;
use std::panic;

const PUT_RECOVERY_BLOB: &str = "707172737475767778797a7bf3c4993bba7dc22d837691769329350ef83953a22430f40dceb4acbe193feb9ec3713126e6440746f49bffc271e6731e";

#[test]
fn every_vector_file_and_case_is_replayed_or_listed_as_client_only() {
	let mut files: Vec<String> = std::fs::read_dir(vectors_dir())
		.expect("spec/vectors")
		.map(|entry| {
			entry
				.expect("an entry")
				.file_name()
				.into_string()
				.expect("UTF-8")
		})
		.filter(|name| name.ends_with(".json"))
		.collect();
	files.sort();
	let mut listed: Vec<&str> = REGISTRY.iter().map(|(file, _)| *file).collect();
	listed.sort();
	assert_eq!(
		files, listed,
		"spec/vectors (left) against the registry (right)"
	);

	for (file, listing) in REGISTRY {
		let Listing::Replayed {
			replayed,
			client_only,
		} = listing
		else {
			continue;
		};
		let mut names: Vec<String> = cases(file)
			.iter()
			.map(|case| case["name"].as_str().expect("a name").to_owned())
			.collect();
		names.sort();
		let mut listed: Vec<&str> = replayed.iter().chain(client_only).copied().collect();
		listed.sort();
		assert_eq!(names, listed, "{file} (left) against the registry (right)");
	}
}

fn sequential<const N: usize>(first: u8) -> [u8; N] {
	std::array::from_fn(|index| first + u8::try_from(index).expect("small"))
}

fn change(v: u32) -> Record {
	Record {
		id: BlindedNoteId(sequential(0x10)),
		v: Version(v),
		write_id: sequential(0x60),
		payload: sequential::<24>(0xd0).to_vec(),
	}
}

fn sync_request(since: u64, writes: Vec<Record>) -> Request {
	Request::Sync {
		since: Seq(since),
		writes,
	}
}

fn expected_request(name: &str) -> Request {
	match name {
		"syncEmpty" => sync_request(0, Vec::new()),
		"syncOneWrite" => sync_request(7, vec![change(1)]),
		"getRecovery" => Request::Get,
		"putRecovery" => Request::Put {
			v: Version(2),
			blob: hex(&Value::from(PUT_RECOVERY_BLOB)),
		},
		_ => panic!("frames.json request case {name} is not replayed"),
	}
}

fn request_cases() -> Vec<Value> {
	replayed("frames.json")
		.into_iter()
		.filter(|case| case["direction"] == "request")
		.collect()
}

fn positives() -> Vec<(String, Vec<u8>)> {
	request_cases()
		.into_iter()
		.filter(|case| case["decodes"] != false)
		.map(|case| {
			(
				case["name"].as_str().expect("a name").to_owned(),
				hex(&case["encoded"]),
			)
		})
		.collect()
}

#[test]
fn every_request_vector_decodes_to_its_value_or_fails_with_its_error() {
	let (mut decoded, mut rejected) = (0, 0);
	for case in request_cases() {
		let name = case["name"].as_str().expect("a name");
		let encoded = hex(&case["encoded"]);
		if case["decodes"] == false {
			assert!(name.starts_with("reject"), "{name}");
			assert_eq!(case["matches"], true, "{name}");
			let error = Request::decode(&encoded).expect_err(name);
			assert_eq!(Value::from(format!("{error:?}")), case["error"], "{name}");
			rejected += 1;
		} else {
			assert_eq!(case["roundTrips"], true, "{name}");
			assert_eq!(Value::from(encoded.len()), case["length"], "{name}");
			let expected = expected_request(name);
			assert_eq!(Request::decode(&encoded).as_ref(), Ok(&expected), "{name}");
			assert_eq!(client::encode_request(&expected), encoded, "{name}");
			decoded += 1;
		}
	}
	assert_eq!((decoded, rejected), (4, 5));
}

#[test]
fn every_prefix_of_a_request_vector_is_truncated() {
	for (name, encoded) in positives() {
		for cut in 0..encoded.len() {
			assert_eq!(
				Request::decode(&encoded[..cut]),
				Err(DecodeError::Truncated),
				"{name} cut at {cut}"
			);
		}
	}
}

#[test]
fn a_request_vector_with_any_byte_appended_has_trailing_bytes() {
	for (name, encoded) in positives() {
		for extra in [0x00, 0x01, 0xff] {
			let mut longer = encoded.clone();
			longer.push(extra);
			assert_eq!(
				Request::decode(&longer),
				Err(DecodeError::TrailingBytes),
				"{name} with {extra:02x}"
			);
		}
	}
}

fn envelope_vector_key() -> EnvelopeKey {
	EnvelopeKey::derive(&Secret::new(vector_api_key())).expect("a 32-byte key derives")
}

fn envelope_case(name: &str) -> Value {
	let request = case("envelope.json", "request");
	let named = case("envelope.json", name);
	assert_eq!(named["envelopeKey"], request["envelopeKey"], "{name}");
	named
}

#[test]
fn the_envelope_key_vector_derives_the_key_its_okm_seals_under() {
	let case = case("hkdf.json", "envelopeKey");
	assert_eq!(case["info"], "native-note/envelope/v1");
	assert_eq!(case["salt"], Value::Null);
	assert_eq!(case["length"], 32);
	let ikm: [u8; 32] = hex_array(&case["ikm"]);
	let okm: [u8; 32] = hex_array(&case["okm"]);
	assert_eq!(client::envelope_key(&ikm), okm);

	let nonce = [0x45; 12];
	let padded = client::pad(&client::encode_request(&Request::Get)).expect("pads");
	let sealed = client::seal(&okm, nonce, &padded);
	let key = EnvelopeKey::derive(&Secret::new(ikm)).expect("a 32-byte key derives");
	let opened = open(&key, sealed).expect("opens under the derived key");
	assert_eq!(opened.nonce(), nonce);
	assert_eq!(opened.request(), Ok(Request::Get));
}

#[test]
fn the_request_vector_opens_to_its_inner_frame_under_its_nonce() {
	let case = envelope_case("request");
	assert_eq!(case["opens"], true);
	let nonce = hex_array(&case["nonce"]);
	let inner = hex(&case["inner"]);
	assert_eq!(
		client::seal_request(&hex_array(&case["envelopeKey"]), nonce, &inner),
		hex(&case["frame"])
	);

	let opened = open(&envelope_vector_key(), hex(&case["frame"])).expect("opens");
	assert_eq!(opened.nonce(), nonce);
	assert_eq!(opened.request(), Ok(sync_request(0, Vec::new())));
}

#[test]
fn the_envelope_vectors_a_server_must_reject_do_not_open() {
	let key = envelope_vector_key();
	for name in ["rejectTruncated", "rejectResponseOpenedAsRequest"] {
		let case = envelope_case(name);
		assert_eq!(case["opens"], false, "{name}");
		assert_eq!(
			open(&key, hex(&case["frame"])).err(),
			Some(Rejection::Unopenable),
			"{name}"
		);
	}
}

#[test]
fn an_envelope_vector_that_fails_to_unpad_or_decode_is_answered_with_the_reference_error() {
	for (name, error) in [
		("errorForUnpaddableRequest", DecodeError::Padding),
		(
			"errorForUndecodableRequest",
			DecodeError::UnknownDiscriminant,
		),
	] {
		let case = envelope_case(name);
		let mut harness = Harness::new(vector_api_key(), MemoryStorage::default());
		assert_eq!(
			harness.exchange(hex(&case["frame"]), hex_array(&case["responseNonce"])),
			Http::Ok(hex(&case["response"])),
			"{name}"
		);
		assert_eq!(harness.failures, [Failure::Decode(error)], "{name}");
		assert_eq!(harness.storage.transactions(), 0, "{name}");
	}
}

fn one_result(status: Status, v: u32, seq: u64) -> Response {
	Response::Sync {
		results: vec![WriteResult {
			status,
			v: Version(v),
			seq: Seq(seq),
		}],
		changes: Vec::new(),
		next_seq: Seq(1),
		more: false,
	}
}

fn expected_response(name: &str) -> Response {
	match name {
		"syncAccepted" => one_result(Status::Accepted, 1, 1),
		"syncConflict" => one_result(Status::Conflict, 1, 0),
		"syncConflictAtLastVersion" => one_result(Status::Conflict, u32::MAX, 0),
		"syncTooLarge" => one_result(Status::TooLarge, 1, 0),
		"syncChanges" => Response::Sync {
			results: Vec::new(),
			changes: vec![change(2)],
			next_seq: Seq(4),
			more: true,
		},
		"getRecoveryResult" => Response::Get {
			v: Version(2),
			blob: hex(&Value::from(PUT_RECOVERY_BLOB)),
		},
		"getRecoveryEmpty" => Response::Get {
			v: Version(0),
			blob: Vec::new(),
		},
		"putRecoveryResult" => Response::Put {
			status: Status::Accepted,
			v: Version(3),
		},
		"error" => Response::Error,
		_ => panic!("frames.json response case {name} is not replayed"),
	}
}

#[test]
fn the_test_client_decodes_every_response_vector_and_rejects_every_malformed_one() {
	let (mut decoded, mut rejected) = (0, 0);
	for case in cases("frames.json") {
		if case["direction"] != "response" {
			continue;
		}
		let name = case["name"].as_str().expect("a name");
		let encoded = hex(&case["encoded"]);
		if case["decodes"] == false {
			let error = case["error"].as_str().expect("an error name");
			let payload =
				panic::catch_unwind(|| client::decode_response(&encoded)).expect_err(name);
			let message = payload
				.downcast_ref::<String>()
				.map(String::as_str)
				.or_else(|| payload.downcast_ref::<&str>().copied())
				.expect("a panic message");
			assert!(
				message.starts_with(&format!("{error}: ")),
				"{name}: {message}"
			);
			rejected += 1;
		} else {
			assert_eq!(
				client::decode_response(&encoded),
				expected_response(name),
				"{name}"
			);
			decoded += 1;
		}
	}
	assert_eq!((decoded, rejected), (9, 7));
}

#[test]
fn the_envelope_response_vector_is_the_sealed_answer_to_the_request_vector_on_an_empty_store() {
	let request = envelope_case("request");
	let response = envelope_case("response");
	assert_eq!(response["requestNonce"], request["nonce"]);
	let mut harness = Harness::new(hex_array(&request["apiKey"]), MemoryStorage::default());
	assert_eq!(
		harness.exchange(hex(&request["frame"]), hex_array(&response["nonce"])),
		Http::Ok(hex(&response["frame"]))
	);
	assert!(harness.failures.is_empty());
	assert_eq!(harness.storage.transactions(), 1);
}

fn reproduce(name: &str) -> (MemoryStorage, Vec<u8>) {
	let mut storage = MemoryStorage::default();
	let request = match name {
		"syncAccepted" => sync_request(1, vec![change(1)]),
		"syncConflict" => {
			storage.seed_note(Seq(1), change(1));
			sync_request(1, vec![change(1)])
		}
		"syncConflictAtLastVersion" => {
			storage.seed_note(Seq(1), change(u32::MAX));
			sync_request(1, vec![change(u32::MAX)])
		}
		"syncTooLarge" => {
			storage.seed_note(Seq(1), change(1));
			let mut over = change(2);
			over.payload.resize(NOTE_MAX + 1, 0xd0);
			sync_request(1, vec![over])
		}
		"syncChanges" => {
			storage.seed_note(Seq(4), change(2));
			let unfittable = Record {
				id: BlindedNoteId([0x55; 16]),
				v: Version(1),
				write_id: [0x56; 16],
				payload: vec![0x57; BODY_MAX],
			};
			storage.seed_note(Seq(5), unfittable);
			sync_request(3, Vec::new())
		}
		"getRecoveryResult" => {
			storage.seed_content_key(Version(2), hex(&Value::from(PUT_RECOVERY_BLOB)));
			Request::Get
		}
		"getRecoveryEmpty" => Request::Get,
		"putRecoveryResult" => {
			storage.seed_content_key(Version(2), hex(&Value::from(PUT_RECOVERY_BLOB)));
			Request::Put {
				v: Version(3),
				blob: vec![0x58; 60],
			}
		}
		"error" => return (storage, vec![0x04]),
		_ => panic!("frames.json response case {name} is not reproduced"),
	};
	(storage, client::encode_request(&request))
}

#[test]
fn every_response_vector_is_answered_by_the_core_from_a_seeded_store() {
	let mut reproduced = 0;
	for case in replayed("frames.json") {
		if case["direction"] != "response" {
			continue;
		}
		let name = case["name"].as_str().expect("a name");
		let (storage, inner) = reproduce(name);
		let mut harness = Harness::new(vector_api_key(), storage);
		assert_eq!(harness.send(&inner), hex(&case["encoded"]), "{name}");
		let failures = match name {
			"error" => vec![Failure::Decode(DecodeError::UnknownDiscriminant)],
			_ => Vec::new(),
		};
		assert_eq!(harness.failures, failures, "{name}");
		reproduced += 1;
	}
	assert_eq!(reproduced, 9);
}

fn vector_api_key() -> [u8; 32] {
	hex_array(&case("envelope.json", "request")["apiKey"])
}
