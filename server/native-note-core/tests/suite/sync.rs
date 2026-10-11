use crate::replay::replay_captured;
use crate::support::NOTE_MAX;
use crate::support::client::{self, Response, Status, WriteResult};
use crate::support::corpus::{SplitMix64, corpus, payload};
use crate::support::harness::Harness;
use crate::support::memory::MemoryStorage;
use crate::support::session::{Device, Session};
use crate::support::vectors::{hex, replayed};
use native_note_core::{BlindedNoteId, Record, Request, Seq, Version};
use std::collections::BTreeMap;

const API_KEY: [u8; 32] = [
	0x5e, 0x0b, 0xc4, 0x71, 0x2a, 0x96, 0xd3, 0x48, 0xef, 0x15, 0x7c, 0xa0, 0x39, 0x62, 0xbd, 0x04,
	0x8f, 0xd6, 0x23, 0x5a, 0xc1, 0x97, 0x4e, 0x0d, 0xb8, 0x6f, 0x31, 0xe5, 0x1c, 0xa9, 0x50, 0x7b,
];
const X: u8 = 0x58;

fn write(id: u8, v: u32, len: usize) -> Record {
	let mut write_id = [id; 16];
	write_id[12..].copy_from_slice(&v.to_be_bytes());
	Record {
		id: BlindedNoteId([id; 16]),
		v: Version(v),
		write_id,
		payload: payload(len, u64::from(id) << 32 | u64::from(v)),
	}
}

fn seeded(notes: &[(u64, Record)]) -> Harness {
	let mut storage = MemoryStorage::default();
	for (seq, note) in notes {
		storage.seed_note(Seq(*seq), note.clone());
	}
	Harness::new(API_KEY, storage)
}

fn sync(since: u64, writes: &[Record]) -> Request {
	Request::Sync {
		since: Seq(since),
		writes: writes.to_vec(),
	}
}

fn result(status: Status, v: u32, seq: u64) -> WriteResult {
	WriteResult {
		status,
		v: Version(v),
		seq: Seq(seq),
	}
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

fn leak_blob(rng: &mut SplitMix64) -> &'static [u8] {
	Vec::leak(payload(60, rng.next_u64()))
}

fn edits(device: &Device, originals: &[&Record], rng: &mut SplitMix64) -> &'static [Record] {
	let edits = originals
		.iter()
		.map(|original| Record {
			id: original.id,
			v: device.next_version(&original.id),
			write_id: rng.array(),
			payload: payload(original.payload.len(), rng.next_u64()),
		})
		.collect();
	Vec::leak(edits)
}

fn push(session: &mut Session, device: &mut Device, writes: &'static [Record]) -> Vec<Status> {
	client::batch(writes)
		.into_iter()
		.flat_map(|batch| session.sync(device, batch))
		.map(|result| result.status)
		.collect()
}

fn get(v: u32, blob: &[u8]) -> Response {
	Response::Get {
		v: Version(v),
		blob: blob.to_vec(),
	}
}

fn put(status: Status, v: u32) -> Response {
	Response::Put {
		status,
		v: Version(v),
	}
}

#[test]
fn three_devices_sync_two_thousand_notes_converge_and_ignore_a_replay_of_everything() {
	let (a_notes, b_notes) = corpus().split_at(1_500);
	let mut session = Session::new(API_KEY);
	let mut rng = SplitMix64::new(50);
	let (mut a, mut b, mut c) = (Device::default(), Device::default(), Device::default());

	let blob_a = leak_blob(&mut rng);
	assert_eq!(session.get(), get(0, &[]));
	assert_eq!(session.put(Version(1), blob_a), put(Status::Accepted, 1));
	assert_eq!(session.put(Version(1), blob_a), put(Status::Conflict, 1));
	assert_eq!(session.get(), get(1, blob_a));

	let statuses = push(&mut session, &mut a, a_notes);
	assert!(statuses.iter().all(|&status| status == Status::Accepted));
	assert_eq!(session.get(), get(1, blob_a));
	let statuses = push(&mut session, &mut b, b_notes);
	let too_large: Vec<_> = (0..b_notes.len())
		.filter(|&index| statuses[index] == Status::TooLarge)
		.collect();
	assert_eq!(too_large, [489]);
	assert_eq!(b_notes[489].payload.len(), NOTE_MAX + 1);
	assert_eq!(session.model.latest(), Seq(1_999));
	assert_eq!(b.view(), &session.model.view());

	let chosen: Vec<&Record> = (0..200).map(|k| &a_notes[k * 7 + 6]).collect();
	let first: Vec<&Record> = chosen.iter().step_by(4).copied().collect();
	assert!(chosen.iter().any(|note| note.payload.len() == NOTE_MAX));
	let a_edits = edits(&a, &first, &mut rng);
	let statuses = push(&mut session, &mut a, a_edits);
	assert!(statuses.iter().all(|&status| status == Status::Accepted));
	let b_edits = edits(&b, &chosen, &mut rng);
	let statuses = push(&mut session, &mut b, b_edits);
	let conflicted: Vec<&Record> = chosen
		.iter()
		.zip(&statuses)
		.filter(|&(_, &status)| status == Status::Conflict)
		.map(|(&note, _)| note)
		.collect();
	assert!(
		conflicted
			.iter()
			.map(|note| note.id)
			.eq(first.iter().map(|note| note.id))
	);
	assert_eq!(statuses.len() - conflicted.len(), 150);
	let rewrites = edits(&b, &conflicted, &mut rng);
	assert!(rewrites.iter().all(|edit| edit.v == Version(3)));
	let statuses = push(&mut session, &mut b, rewrites);
	assert!(statuses.iter().all(|&status| status == Status::Accepted));

	let blob_b = leak_blob(&mut rng);
	assert_eq!(session.put(Version(2), blob_b), put(Status::Accepted, 2));
	let stale = leak_blob(&mut rng);
	assert_eq!(session.put(Version(2), stale), put(Status::Conflict, 2));
	assert_eq!(session.get(), get(2, blob_b));

	let mut pages = 0;
	while pages < 15 {
		assert!(session.sync_once(&mut c, &[]).1, "page {pages}");
		pages += 1;
	}
	let had = c.received()[0].1;
	let lacking = b_notes[b_notes.len() - 1].id;
	assert!(session.model.current(&had).0 <= c.since());
	assert!(session.model.current(&lacking).0 > c.since());
	assert!(!c.view().contains_key(&lacking));
	session.sync(&mut a, &[]);
	let originals = [
		session.model.current(&had).1,
		session.model.current(&lacking).1,
	];
	let a_rewrites = edits(&a, &originals, &mut rng);
	assert_eq!(
		session.sync(&mut a, a_rewrites),
		[
			result(Status::Accepted, 2, 2_250),
			result(Status::Accepted, 2, 2_251)
		]
	);
	while session.sync_once(&mut c, &[]).1 {
		pages += 1;
	}
	pages += 1;
	let bytes = session.model.payload_bytes();
	assert!((50 << 20..80 << 20).contains(&bytes), "{bytes} bytes");
	assert!(
		pages >= 30 && pages > bytes / client::INNER_MAX,
		"{pages} pages"
	);

	let seqs: Vec<Seq> = c.received().iter().map(|&(seq, _)| seq).collect();
	assert!(seqs.windows(2).all(|pair| pair[0] < pair[1]));
	let mut receipts = BTreeMap::new();
	for (_, id) in c.received() {
		*receipts.entry(*id).or_insert(0) += 1;
	}
	assert_eq!(receipts.len(), 1_999);
	assert_eq!((receipts[&had], receipts[&lacking]), (2, 1));
	assert_eq!(receipts.values().sum::<usize>(), 2_000);
	assert_eq!(c.received().last(), Some(&(Seq(2_251), lacking)));

	session.sync(&mut a, &[]);
	session.sync(&mut b, &[]);
	let view = session.model.view();
	assert_eq!(view.len(), 1_999);
	assert_eq!((a.view(), b.view(), c.view()), (&view, &view, &view));
	assert_eq!(session.model.latest(), Seq(2_251));
	assert!(session.harness.failures.is_empty());

	replay_captured(&mut session);
}
