use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

use native_note_vectors::content;
use native_note_vectors::frame::{self, Request, Response};
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
fn generation_is_deterministic() {
	for ((name, a), (_, b)) in vectors::all().iter().zip(vectors::all().iter()) {
		assert_eq!(
			vectors::render(a),
			vectors::render(b),
			"{name} is not deterministic"
		);
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
