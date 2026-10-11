use crate::support::client::{self, INNER_MAX, Response, Status, WriteResult};
use crate::support::corpus::{SplitMix64, payload};
use crate::support::harness::{Failure, Harness, Http, nonce_of};
use crate::support::memory::{Injected, MemoryStorage};
use crate::support::{NOTE_MAX, SEALED_MAX};
use native_note_core::{
	BlindedNoteId, DecodeError, EnvelopeKey, Fault, Record, Request, Secret, Seq, Version, process,
};

const API_KEY: [u8; 32] = [
	0x71, 0xe4, 0x0a, 0x9f, 0x36, 0xcb, 0x58, 0x13, 0xd2, 0x87, 0x4d, 0xb0, 0x65, 0x1e, 0xf3, 0x2a,
	0x9c, 0x07, 0x5b, 0xe8, 0x41, 0xa6, 0x3d, 0xc9, 0x12, 0x7f, 0xb4, 0x68, 0x0e, 0xd5, 0x23, 0x96,
];
const MOST_RESULTS: usize = (INNER_MAX - 18) / 13;

fn note(rng: &mut SplitMix64, v: u32, len: usize) -> Record {
	Record {
		id: BlindedNoteId(rng.array()),
		v: Version(v),
		write_id: rng.array(),
		payload: payload(len, rng.next_u64()),
	}
}

fn edit(original: &Record, v: u32, rng: &mut SplitMix64) -> Record {
	Record {
		id: original.id,
		v: Version(v),
		write_id: rng.array(),
		payload: payload(original.payload.len(), rng.next_u64()),
	}
}

fn pull(since: u64) -> Request {
	Request::Sync {
		since: Seq(since),
		writes: Vec::new(),
	}
}

fn workload() -> (MemoryStorage, Request) {
	let mut rng = SplitMix64::new(0x0046_4155_4c54);
	let mut storage = MemoryStorage::default();
	let mut seeded = Vec::new();
	for seq in 1..=30 {
		let len = rng.between(0, 4 << 10);
		let record = note(&mut rng, 1 + seq % 3, len);
		storage.seed_note(Seq(u64::from(seq)), record.clone());
		seeded.push(record);
	}
	storage.seed_content_key(Version(1), payload(60, 0x0046));

	let mut writes = Vec::new();
	for _ in 0..25 {
		let len = rng.between(0, 2 << 10);
		writes.push(note(&mut rng, 1, len));
	}
	for original in &seeded[..12] {
		writes.push(edit(original, original.v.0 + 1, &mut rng));
	}
	for original in &seeded[12..24] {
		writes.push(edit(original, original.v.0, &mut rng));
	}
	writes.push(note(&mut rng, 1, NOTE_MAX + 1));
	assert_eq!(writes.len(), 50);
	let request = Request::Sync {
		since: Seq(10),
		writes,
	};
	(storage, request)
}

fn fault_every_call(storage: &MemoryStorage, request: &Request) -> usize {
	let inner = client::encode_request(request);
	let mut clean = Harness::new(API_KEY, storage.clone());
	let expected = clean.send(&inner);
	let calls = clean.storage.calls();
	assert!(clean.failures.is_empty());

	let mut harness = Harness::new(API_KEY, storage.clone());
	for call in 0..calls {
		harness.storage.fail_next_at(call);
		assert_eq!(
			client::decode_response(&harness.send(&inner)),
			Response::Error,
			"call {call}"
		);
		assert_eq!(
			harness.failures.pop(),
			Some(Failure::Fault(Fault::Storage(Injected(call))))
		);
		assert_eq!(harness.storage.calls(), call + 1);
		assert!(harness.storage.state() == storage.state(), "call {call}");
	}
	assert_eq!(harness.send(&inner), expected);
	assert!(harness.storage.state() == clean.storage.state());
	assert!(harness.failures.is_empty());
	calls
}

#[test]
fn a_fault_at_any_storage_call_of_a_sync_rolls_it_back_and_answers_error() {
	let (storage, request) = workload();
	let mut clean = Harness::new(API_KEY, storage.clone());
	let Response::Sync {
		results, changes, ..
	} = clean.call(&request)
	else {
		panic!("a sync gets a sync response");
	};
	let count = |status| {
		results
			.iter()
			.filter(|result| result.status == status)
			.count()
	};
	assert_eq!(
		(
			count(Status::Accepted),
			count(Status::Conflict),
			count(Status::TooLarge)
		),
		(37, 12, 1)
	);
	assert_eq!(changes.len(), 18 + 37);
	assert!(clean.storage.state() != storage.state());

	let calls = fault_every_call(&storage, &request);
	assert_eq!(calls, 1 + 50 + 37 + changes.len() + 1);
}

#[test]
fn a_fault_at_any_storage_call_of_a_put_rolls_it_back_and_answers_error() {
	let put = |v, seed| Request::Put {
		v: Version(v),
		blob: payload(60, seed),
	};
	let mut storage = MemoryStorage::default();
	let first = fault_every_call(&storage, &put(1, 1));
	assert_eq!(first, 2);

	storage.seed_content_key(Version(1), payload(60, 1));
	let rotate = fault_every_call(&storage, &put(2, 2));
	let stale = fault_every_call(&storage, &put(1, 3));
	assert_eq!((rotate, stale), (2, 1));
}

#[test]
fn a_fault_at_the_storage_call_of_a_get_answers_error() {
	let mut storage = MemoryStorage::default();
	storage.seed_content_key(Version(4), payload(60, 4));
	let calls = fault_every_call(&storage, &Request::Get);
	assert_eq!(calls, 1);
}

#[test]
fn a_sync_that_would_pass_the_last_seq_rolls_back_and_answers_error() {
	let mut rng = SplitMix64::new(0x0053_4551);
	let mut storage = MemoryStorage::default();
	let held = note(&mut rng, 1, 16);
	storage.seed_note(Seq(u64::MAX - 1), held.clone());
	let mut harness = Harness::new(API_KEY, storage);
	let before = harness.storage.state().clone();
	let (first, second) = (note(&mut rng, 1, 32), note(&mut rng, 1, 48));
	let sync = |since, writes: &[Record]| Request::Sync {
		since: Seq(since),
		writes: writes.to_vec(),
	};

	let both = sync(u64::MAX - 1, &[first.clone(), second.clone()]);
	assert_eq!(harness.call(&both), Response::Error);
	assert_eq!(harness.failures, [Failure::Fault(Fault::SeqExhausted)]);
	assert!(harness.storage.state() == &before);

	let last_seq = |status, v, seq, changes| Response::Sync {
		results: vec![WriteResult {
			status,
			v: Version(v),
			seq: Seq(seq),
		}],
		changes,
		next_seq: Seq(u64::MAX),
		more: false,
	};
	assert_eq!(
		harness.call(&sync(u64::MAX - 1, std::slice::from_ref(&first))),
		last_seq(Status::Accepted, 1, u64::MAX, vec![first])
	);
	assert_eq!(
		harness.call(&sync(u64::MAX, std::slice::from_ref(&held))),
		last_seq(Status::Conflict, 1, 0, Vec::new())
	);

	let after = harness.storage.state().clone();
	assert_eq!(harness.call(&sync(u64::MAX, &[second])), Response::Error);
	assert_eq!(harness.failures.len(), 2);
	assert_eq!(
		harness.failures.pop(),
		Some(Failure::Fault(Fault::SeqExhausted))
	);
	assert!(harness.storage.state() == &after);
}

#[test]
fn a_stored_note_or_blob_that_fits_no_response_answers_error() {
	let alone = INNER_MAX - 18 - 40;
	let largest = INNER_MAX - 9;
	let mut rng = SplitMix64::new(0x0055_4e41);
	for (extra, fits) in [(0, true), (1, false)] {
		let mut storage = MemoryStorage::default();
		let stored = note(&mut rng, 1, alone + extra);
		storage.seed_note(Seq(1), stored.clone());
		storage.seed_content_key(Version(1), payload(largest + extra, 1));
		let mut harness = Harness::new(API_KEY, storage);

		let pulled = harness.call(&pull(0));
		let got = harness.call(&Request::Get);
		if fits {
			assert!(matches!(pulled, Response::Sync { changes, .. } if changes == [stored]));
			assert!(matches!(got, Response::Get { blob, .. } if blob.len() == largest));
			assert!(harness.failures.is_empty());
		} else {
			assert_eq!((pulled, got), (Response::Error, Response::Error));
			assert_eq!(
				harness.failures,
				[
					Failure::Fault(Fault::Unanswerable),
					Failure::Fault(Fault::Unanswerable)
				]
			);
		}

		let rotate = Request::Put {
			v: Version(2),
			blob: payload(60, 2),
		};
		assert_eq!(
			harness.call(&rotate),
			Response::Put {
				status: Status::Accepted,
				v: Version(2)
			}
		);
	}
}

#[test]
fn results_that_fit_no_response_are_unanswerable() {
	let key = EnvelopeKey::derive(&Secret::new(API_KEY)).expect("a 32-byte key derives");
	let conflicting = Record {
		id: BlindedNoteId([0x55; 16]),
		v: Version(0),
		write_id: [0x56; 16],
		payload: Vec::new(),
	};
	for (count, answerable) in [(MOST_RESULTS, true), (MOST_RESULTS + 1, false)] {
		let mut storage = MemoryStorage::default();
		let request = Request::Sync {
			since: Seq(0),
			writes: vec![conflicting.clone(); count],
		};
		let processed = process(&mut storage.begin(), &request);
		assert_eq!(storage.calls(), 1 + count + 1);
		match processed {
			Ok(reply) => {
				assert!(answerable, "{count}");
				let sealed = key.seal(reply, &[0x01; 12], [0x02; 12]).expect("seals");
				assert_eq!(sealed.len(), SEALED_MAX, "{count}");
			}
			Err(fault) => {
				assert!(!answerable, "{count}");
				assert_eq!(fault, Fault::Unanswerable);
			}
		}
	}
}

#[test]
fn a_body_that_does_not_unseal_gets_a_bare_status_and_one_that_does_not_decode_opens_no_transaction()
 {
	let mut harness = Harness::new(API_KEY, MemoryStorage::default());
	let nonce = [0x40; 12];
	for len in [0, 27, 28, 284] {
		assert_eq!(
			harness.exchange(vec![0; len], nonce),
			Http::BadRequest,
			"{len}"
		);
	}
	assert_eq!(
		harness.exchange(vec![0; SEALED_MAX + 1], nonce),
		Http::TooLarge
	);
	let mut other_key = API_KEY;
	other_key[31] ^= 0x01;
	let foreign = Harness::new(other_key, MemoryStorage::default()).seal(&[0x02]);
	assert_eq!(harness.exchange(foreign, nonce), Http::BadRequest);
	assert!(harness.failures.is_empty());

	for inner in [&[0x04][..], &[0x02, 0x00], &[0x03, 0x00]] {
		assert_eq!(
			client::decode_response(&harness.send(inner)),
			Response::Error
		);
	}
	assert_eq!(
		harness.failures,
		[
			Failure::Decode(DecodeError::UnknownDiscriminant),
			Failure::Decode(DecodeError::TrailingBytes),
			Failure::Decode(DecodeError::Truncated),
		]
	);
	assert_eq!(harness.storage.transactions(), 0);

	assert_eq!(
		harness.call(&pull(0)),
		Response::Sync {
			results: Vec::new(),
			changes: Vec::new(),
			next_seq: Seq(0),
			more: false
		}
	);
	assert_eq!(harness.storage.transactions(), 1);

	let body = harness.seal(&[0x02]);
	assert_eq!(
		harness.exchange(body.clone(), nonce_of(&body)),
		Http::ServerError
	);
	assert_eq!(harness.storage.transactions(), 2);
}
