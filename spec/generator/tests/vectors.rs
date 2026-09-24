use std::collections::HashSet;
use std::fs;
use std::path::PathBuf;

use native_note_vectors::vectors;

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
			for field in ["decodes", "opens", "unpads", "splits"] {
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
fn aead_and_envelope_round_trip() {
	use native_note_vectors::{aead, envelope, fixed, kdf, seq_bytes};

	let key = kdf::envelope_key(&seq_bytes(0x00, 32));
	let nonce: [u8; 12] = fixed(0x70);
	let resp_nonce: [u8; 12] = fixed(0x90);

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
fn wordlist_matches_pinned_hash() {
	use native_note_vectors::mnemonic;
	use sha2::{Digest, Sha256};

	let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../wordlists/english.txt");
	let bytes = fs::read(path).expect("wordlist is present");
	let digest = native_note_vectors::hex::encode(&Sha256::digest(&bytes));

	assert_eq!(
		digest,
		mnemonic::WORDLIST_SHA256,
		"wordlist was substituted"
	);
	assert_eq!(mnemonic::words().len(), 2048);
}

#[test]
fn mnemonic_round_trips_and_rejects() {
	use native_note_vectors::mnemonic::{self, MnemonicError};

	for seed in [0x00u8, 0x40, 0xff] {
		let entropy: [u8; 32] = native_note_vectors::fixed(seed);
		let phrase = mnemonic::encode(&entropy);
		assert_eq!(phrase.len(), 24);
		assert_eq!(mnemonic::decode(&phrase), Ok(entropy));
	}

	let entropy: [u8; 32] = native_note_vectors::fixed(0x40);
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
	use native_note_vectors::frame::{Status, Write};
	use native_note_vectors::server::Server;

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
fn sync_scenario_payloads_decrypt_to_their_declared_shape() {
	use native_note_vectors::content::{self, Content};
	use native_note_vectors::frame::{self, Request};
	use native_note_vectors::{hex, kdf, note, seq_bytes};
	use serde_json::Value;

	let content_key = seq_bytes(0x20, 32);
	let blinding_key = kdf::blinding_key(&content_key);
	let doc: Value =
		serde_json::from_str(&fs::read_to_string(vectors_dir().join("sync.json")).unwrap())
			.unwrap();

	let mut checked = 0;
	for case in doc["cases"].as_array().unwrap() {
		let encoded = hex::decode(case["request"].as_str().unwrap()).unwrap();
		let Request::Sync { writes, .. } = frame::decode_request(&encoded).unwrap() else {
			panic!("scenario requests are all sync");
		};

		for write in &writes {
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
			assert_eq!(
				decoded.is_tombstone(),
				write.deleted,
				"deleted flag must match content kind"
			);
			assert!(matches!(
				decoded,
				Content::Note { .. } | Content::Tombstone { .. }
			));

			assert!(
				note::open(
					&content_key,
					&write.write_id,
					&write.blinded_id,
					write.v + 1,
					&write.payload
				)
				.is_err(),
				"payload must not open at another version"
			);
			checked += 1;
		}
	}
	assert_eq!(checked, 4, "scenario should carry four writes");
}

#[test]
fn decoders_reject_malformed_input() {
	use native_note_vectors::codec::DecodeError;
	use native_note_vectors::content;
	use native_note_vectors::frame::{self, Request, Write};

	let valid = frame::encode_request(&Request::Sync {
		since: 1,
		writes: vec![Write {
			blinded_id: [1u8; 16],
			v: 1,
			write_id: [2u8; 16],
			deleted: false,
			payload: vec![9; 8],
		}],
	});
	assert!(frame::decode_request(&valid).is_ok());

	for cut in 0..valid.len() {
		assert!(
			frame::decode_request(&valid[..cut]).is_err(),
			"every truncation must be rejected, failed at {cut}"
		);
	}
	assert_eq!(
		frame::decode_request(&[valid.clone(), vec![0]].concat()),
		Err(DecodeError::TrailingBytes)
	);

	let mut count = valid.clone();
	count[9..13].copy_from_slice(&u32::MAX.to_be_bytes());
	assert_eq!(frame::decode_request(&count), Err(DecodeError::Truncated));

	assert_eq!(frame::decode_request(&[]), Err(DecodeError::Truncated));
	assert_eq!(
		frame::decode_request(&[0x7f]),
		Err(DecodeError::UnknownDiscriminant)
	);
	assert_eq!(content::decode(&[]), Err(DecodeError::Truncated));
	assert_eq!(
		content::decode(&[0x02, 0x01]),
		Err(DecodeError::UnknownDiscriminant)
	);
}
