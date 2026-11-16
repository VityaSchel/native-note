use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

use native_note_vectors::content;
use native_note_vectors::envelope;
use native_note_vectors::frame::{self, Reason, Request, Response};
use native_note_vectors::vectors::{self, CONTENT_KEY, seq_bytes};
use native_note_vectors::{hex, kdf, mnemonic, note};
use serde_json::Value;
use sha2::{Digest, Sha256};

fn vectors_dir() -> PathBuf {
	PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../vectors")
}

#[test]
fn committed_vectors_match_the_generator() {
	let dir = vectors_dir();
	for (name, value) in vectors::all() {
		let path = dir.join(name);
		let committed = fs::read_to_string(&path)
			.unwrap_or_else(|_| panic!("{name} is missing; run `cargo run --bin gen-vectors`"));
		assert_eq!(
			committed,
			vectors::render(&value),
			"{name} is stale; regenerate it in the same commit as the spec change"
		);
	}
}

#[test]
fn no_stray_vector_files() {
	let known: Vec<&str> = vectors::all().iter().map(|(n, _)| *n).collect();
	for entry in fs::read_dir(vectors_dir()).expect("vectors directory exists") {
		let entry = entry.expect("readable directory entry");
		let name = entry.file_name().to_string_lossy().into_owned();
		if name.ends_with(".json") {
			assert!(
				known.contains(&name.as_str()),
				"{name} is not produced by the generator"
			);
		}
	}
}

#[test]
fn every_case_satisfies_its_own_assertions() {
	for (file, doc) in vectors::all() {
		for case in doc["cases"].as_array().unwrap() {
			let name = case["name"].as_str().unwrap_or_default();
			let negative = name.starts_with("reject");
			for field in ["roundTrips", "matches"] {
				if let Some(value) = case.get(field) {
					assert_eq!(value, true, "{file} {name}: {field}");
				}
			}
			for field in ["decodes", "opens", "pads", "unpads"] {
				if let Some(value) = case.get(field) {
					assert_eq!(value, !negative, "{file} {name}: {field}");
				}
			}
			if let Some(value) = case.get("opensUnderWrongVersion") {
				assert_eq!(value, false, "{file} {name}: opensUnderWrongVersion");
			}
		}
	}
}

#[test]
fn case_names_are_present_and_unique() {
	for (file, doc) in vectors::all() {
		let mut seen = HashSet::new();
		for case in doc["cases"].as_array().unwrap() {
			let name = case["name"]
				.as_str()
				.unwrap_or_else(|| panic!("{file} has an unnamed case"));
			assert!(seen.insert(name), "{file} repeats {name}");
		}
	}
}

#[test]
fn wordlist_matches_pinned_hash() {
	let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../wordlists/english.txt");
	let bytes = fs::read(path).expect("wordlist is present");
	let digest = hex::encode(&Sha256::digest(&bytes));

	assert_eq!(
		digest,
		mnemonic::WORDLIST_SHA256,
		"wordlist was substituted"
	);
	assert_eq!(mnemonic::words().len(), 2048);
}

#[test]
fn sync_scenario_payloads_decrypt_to_their_declared_shape() {
	let content_key = seq_bytes(CONTENT_KEY, 32);
	let blinding_key = kdf::blinding_key(&content_key);
	let doc: Value =
		serde_json::from_str(&fs::read_to_string(vectors_dir().join("sync.json")).unwrap())
			.unwrap();

	let mut checked = 0;
	for case in doc["cases"].as_array().unwrap() {
		let request = hex::decode(case["request"].as_str().unwrap()).unwrap();
		let Request::Sync { writes, .. } = frame::decode_request(&request).unwrap() else {
			panic!("scenario requests are all sync");
		};
		let response = hex::decode(case["response"].as_str().unwrap()).unwrap();
		let Response::Sync {
			results, changes, ..
		} = frame::decode_response(&response).unwrap()
		else {
			panic!("scenario responses are all sync");
		};
		assert_eq!(results.len(), writes.len(), "{}", case["name"]);
		if case["name"] == "step7" {
			assert_eq!(writes.len(), 2);
			assert!(
				writes[0].blinded_id > writes[1].blinded_id,
				"step7 submits out of blindedId order"
			);
		}

		for write in writes.iter().chain(&changes) {
			let plaintext = note::open(
				&content_key,
				&write.write_id,
				&write.blinded_id,
				write.v,
				&write.payload,
			)
			.expect("payload opens under its own blindedId, v and writeId");
			let decoded = content::decode(&plaintext).expect("content decodes");

			assert_eq!(
				note::blinded_id(&blinding_key, decoded.uuid()),
				write.blinded_id
			);
			checked += 1;
		}
	}
	assert_eq!(
		checked, 17,
		"scenario should carry seven writes and ten changes"
	);
}

fn vector_file(name: &str) -> Value {
	serde_json::from_str(&fs::read_to_string(vectors_dir().join(name)).unwrap()).unwrap()
}

fn hex_field(case: &Value, field: &str) -> Vec<u8> {
	hex::decode(case[field].as_str().unwrap()).unwrap()
}

#[test]
fn each_error_vector_names_the_reason_its_frame_carries() {
	let mut errors = 0;
	for case in vector_file("frames.json")["cases"].as_array().unwrap() {
		let Some(name) = case["reason"].as_str() else {
			continue;
		};
		let Ok(Response::Error(reason)) = frame::decode_response(&hex_field(case, "encoded"))
		else {
			panic!("{} is an error response", case["name"]);
		};
		assert_eq!(reason.name(), name, "{}", case["name"]);
		errors += 1;
	}
	assert_eq!(errors, 4);

	let mut answered = 0;
	for case in vector_file("envelope.json")["cases"].as_array().unwrap() {
		let Some(name) = case["reason"].as_str() else {
			continue;
		};
		let frame = hex_field(case, "frame");
		let request_nonce: [u8; 12] = frame[..12].try_into().unwrap();
		let inner = envelope::open_response(
			&hex_field(case, "envelopeKey"),
			&request_nonce,
			&hex_field(case, "response"),
		)
		.unwrap();
		assert_eq!(inner, hex_field(case, "responseInner"), "{}", case["name"]);
		assert_eq!(
			frame::decode_response(&inner).map(|response| match response {
				Response::Error(reason) => reason.name(),
				_ => "not an error",
			}),
			Ok(name),
			"{}",
			case["name"]
		);
		answered += 1;
	}
	assert_eq!(answered, 3);
	assert_eq!(Reason::from_code(0x02), Reason::Unsupported);
}

#[test]
fn content_from_a_newer_version_still_names_the_uuid_its_blinded_id_derives_from() {
	let blinding_key = kdf::blinding_key(&seq_bytes(CONTENT_KEY, 32));
	let mut prefixed = 0;
	for file in ["content.json", "note.json"] {
		for case in vector_file(file)["cases"].as_array().unwrap() {
			let Some(uuid) = case["prefixUuid"].as_str() else {
				continue;
			};
			let field = if file == "note.json" {
				"plaintext"
			} else {
				"encoded"
			};
			let bytes = hex_field(case, field);
			assert_eq!(
				content::prefix_uuid(&bytes)
					.map(|uuid| hex::encode(&uuid))
					.as_deref(),
				Ok(uuid)
			);
			assert!(content::decode(&bytes).is_err(), "{}", case["name"]);
			if file == "note.json" {
				let uuid: [u8; 16] = hex::decode(uuid).unwrap().try_into().unwrap();
				assert_eq!(
					note::blinded_id(&blinding_key, &uuid).to_vec(),
					hex_field(case, "blindedId")
				);
			}
			prefixed += 1;
		}
	}
	assert_eq!(prefixed, 4);
}
