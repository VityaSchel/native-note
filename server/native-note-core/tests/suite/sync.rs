use crate::replay::replay_captured;
use crate::support::NOTE_MAX;
use crate::support::client::{self, Response, Status, sync};
use crate::support::corpus::write;
use crate::support::harness::Harness;
use crate::support::memory::MemoryStorage;
use crate::support::session::Session;
use crate::support::vectors::{hex, replayed};
use native_note_core::{Record, Seq};
use native_note_testkit::scenario::{result, three_devices};
use std::collections::BTreeMap;

const API_KEY: [u8; 32] = [
	0x5e, 0x0b, 0xc4, 0x71, 0x2a, 0x96, 0xd3, 0x48, 0xef, 0x15, 0x7c, 0xa0, 0x39, 0x62, 0xbd, 0x04,
	0x8f, 0xd6, 0x23, 0x5a, 0xc1, 0x97, 0x4e, 0x0d, 0xb8, 0x6f, 0x31, 0xe5, 0x1c, 0xa9, 0x50, 0x7b,
];
const X: u8 = 0x58;

fn seeded(notes: &[(u64, Record)]) -> Harness {
	let mut storage = MemoryStorage::default();
	for (seq, note) in notes {
		storage.seed_note(Seq(*seq), note.clone());
	}
	Harness::new(API_KEY, storage)
}

#[test]
fn the_sync_vector_steps_run_in_order_against_one_server_and_the_replayed_step_conflicts() {
	let mut harness = Harness::new(API_KEY, MemoryStorage::default());
	let steps = replayed("sync.json");
	let mut bodies = BTreeMap::new();
	let mut replays = 0;
	for (index, step) in steps.iter().enumerate() {
		let name = step["name"].as_str().expect("a name");
		assert_eq!(step["step"], index + 1, "{name}");
		let body = match step["replays"].as_str() {
			Some(original) => {
				let original_step = steps.iter().find(|step| step["name"] == original);
				assert_eq!(
					step["request"],
					original_step.expect("the replayed step")["request"]
				);
				replays += 1;
				bodies.get(original).cloned().expect("an earlier step")
			}
			None => harness.seal(&hex(&step["request"])),
		};
		let inner = harness.post(&body);
		assert_eq!(inner, hex(&step["response"]), "{name}");
		if step["replays"].is_string() {
			let Response::Sync { results, .. } = client::decode_response(&inner) else {
				panic!("{name} gets a sync response");
			};
			assert_eq!(results, [result(Status::Conflict, 2, 0)], "{name}");
		}
		bodies.insert(name.to_owned(), body);
	}
	assert_eq!((steps.len(), replays), (7, 1));
	assert!(harness.failures.is_empty());
}

#[test]
fn writes_within_one_sync_see_each_other_and_take_consecutive_seqs() {
	let others = [
		(1, write(0xa1, 1, 100)),
		(2, write(0xa2, 3, 0)),
		(3, write(0xa3, 1, 9)),
	];
	let mut harness = seeded(&others);
	let writes = [
		write(X, 1, 300),
		write(X, 2, 400),
		write(X, 2, 500),
		write(X, 4, NOTE_MAX + 1),
		write(X, 3, 600),
	];
	let response = harness.call(&sync(3, &writes));
	assert_eq!(
		response,
		Response::Sync {
			results: vec![
				result(Status::Accepted, 1, 4),
				result(Status::Accepted, 2, 5),
				result(Status::Conflict, 2, 0),
				result(Status::TooLarge, 2, 0),
				result(Status::Accepted, 3, 6),
			],
			changes: vec![writes[4].clone()],
			next_seq: Seq(6),
			more: false,
		}
	);

	let mut everything: Vec<_> = others.into_iter().map(|(_, note)| note).collect();
	everything.push(writes[4].clone());
	assert_eq!(
		harness.call(&sync(0, &[])),
		Response::Sync {
			results: Vec::new(),
			changes: everything,
			next_seq: Seq(6),
			more: false,
		}
	);
}

#[test]
fn a_note_at_the_last_version_takes_no_write_after_it() {
	let mut harness = seeded(&[(1, write(X, u32::MAX - 1, 64))]);
	let last = write(X, u32::MAX, 32);
	let response = harness.call(&sync(
		1,
		&[last.clone(), write(X, u32::MAX, 16), write(X, 0, 8)],
	));
	assert_eq!(
		response,
		Response::Sync {
			results: vec![
				result(Status::Accepted, u32::MAX, 2),
				result(Status::Conflict, u32::MAX, 0),
				result(Status::Conflict, u32::MAX, 0),
			],
			changes: vec![last],
			next_seq: Seq(2),
			more: false,
		}
	);
}

#[test]
fn a_pull_since_the_latest_seq_or_beyond_answers_no_changes_and_the_latest_seq() {
	let caught_up = |next_seq| Response::Sync {
		results: Vec::new(),
		changes: Vec::new(),
		next_seq: Seq(next_seq),
		more: false,
	};
	let mut empty = seeded(&[]);
	for since in [0, 5, u64::MAX] {
		assert_eq!(empty.call(&sync(since, &[])), caught_up(0), "{since}");
	}
	let mut harness = seeded(&[(1, write(0xa1, 1, 1)), (3, write(0xa3, 1, 3))]);
	for since in [3, 4, u64::MAX] {
		assert_eq!(harness.call(&sync(since, &[])), caught_up(3), "{since}");
	}
	assert!(harness.failures.is_empty());
}

#[test]
fn three_devices_sync_two_thousand_notes_converge_and_ignore_a_replay_of_everything() {
	let mut session = Session::new(Harness::new(API_KEY, MemoryStorage::default()));
	three_devices(&mut session);
	assert!(session.server.failures.is_empty());
	replay_captured(&mut session);
}
