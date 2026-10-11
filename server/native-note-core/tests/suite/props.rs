use crate::support::client::{self, Response, Status, WriteResult};
use crate::support::harness::{Failure, Harness};
use crate::support::memory::{Injected, MemoryStorage};
use crate::support::{NOTE_MAX, open};
use native_note_core::{
	BlindedNoteId, DecodeError, EnvelopeKey, Fault, Record, Rejection, Request, Secret, Seq,
	Version,
};
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::sample::Index;
use std::collections::BTreeMap;
use std::ops::Bound;

const API_KEY: [u8; 32] = [
	0xf6, 0xfd, 0xe2, 0xa1, 0x54, 0x8a, 0xe1, 0xa7, 0xfd, 0x4b, 0xe6, 0x2f, 0x37, 0x9c, 0x19, 0x06,
	0x30, 0x58, 0x0b, 0x06, 0x2a, 0x6d, 0x67, 0xa5, 0xa5, 0xfb, 0xac, 0x7e, 0x91, 0xdb, 0x83, 0x74,
];
const IDS: u8 = 8;

fn record() -> impl Strategy<Value = Record> {
	(
		any::<[u8; 16]>(),
		any::<u32>(),
		any::<[u8; 16]>(),
		vec(any::<u8>(), 0..=64),
	)
		.prop_map(|(id, v, write_id, payload)| Record {
			id: BlindedNoteId(id),
			v: Version(v),
			write_id,
			payload,
		})
}

fn request() -> impl Strategy<Value = Request> {
	prop_oneof![
		(any::<u64>(), vec(record(), 0..=8)).prop_map(|(since, writes)| Request::Sync {
			since: Seq(since),
			writes,
		}),
		Just(Request::Get),
		(any::<u32>(), vec(any::<u8>(), 0..=128)).prop_map(|(v, blob)| Request::Put {
			v: Version(v),
			blob,
		}),
	]
}

fn decodable_or_not() -> impl Strategy<Value = Vec<u8>> {
	prop_oneof![
		vec(any::<u8>(), 0..=512),
		(
			request(),
			vec((any::<Index>(), any::<u8>()), 0..=3),
			vec(any::<u8>(), 0..=2),
		)
			.prop_map(|(request, edits, tail)| {
				let mut inner = client::encode_request(&request);
				for (at, byte) in edits {
					let at = at.index(inner.len());
					inner[at] = byte;
				}
				inner.extend(tail);
				inner
			}),
	]
}

fn server_key() -> EnvelopeKey {
	EnvelopeKey::derive(&Secret::new(API_KEY)).expect("a 32-byte key derives")
}

proptest! {
	#[test]
	fn a_request_decodes_back_from_its_encoding(request in request()) {
		prop_assert_eq!(Request::decode(&client::encode_request(&request)), Ok(request));
	}

	#[test]
	fn whatever_decodes_has_exactly_one_encoding(inner in decodable_or_not()) {
		if let Ok(request) = Request::decode(&inner) {
			prop_assert_eq!(client::encode_request(&request), inner);
		}
	}

	#[test]
	fn every_prefix_is_truncated_and_any_appended_byte_trails(
		request in request(),
		extra in any::<u8>(),
	) {
		let inner = client::encode_request(&request);
		for cut in 0..inner.len() {
			prop_assert_eq!(
				Request::decode(&inner[..cut]),
				Err(DecodeError::Truncated),
				"cut at {}",
				cut
			);
		}
		let longer = [&inner[..], &[extra]].concat();
		prop_assert_eq!(Request::decode(&longer), Err(DecodeError::TrailingBytes));
	}

	#[test]
	fn every_prefix_of_a_sealed_request_is_unopenable(
		request in request(),
		nonce in any::<[u8; 12]>(),
	) {
		let key = server_key();
		let inner = client::encode_request(&request);
		let body = client::seal_request(&client::envelope_key(&API_KEY), nonce, &inner);
		for cut in 0..body.len() {
			prop_assert_eq!(
				open(&key, body[..cut].to_vec()).err(),
				Some(Rejection::Unopenable),
				"cut at {}",
				cut
			);
		}
		let opened = open(&key, body).expect("the whole body opens");
		prop_assert_eq!(opened.nonce(), nonce);
		prop_assert_eq!(opened.request(), Ok(request));
	}
}

#[derive(Debug, Clone, Copy)]
enum Pick {
	Stored,
	Next,
	Skip,
	Zero,
	Last,
}

impl Pick {
	fn resolve(self, stored: Version) -> Version {
		Version(match self {
			Pick::Stored => stored.0,
			Pick::Next => stored.0.wrapping_add(1),
			Pick::Skip => stored.0.wrapping_add(2),
			Pick::Zero => 0,
			Pick::Last => u32::MAX,
		})
	}
}

#[derive(Debug, Clone, Copy)]
enum Since {
	Zero,
	Latest,
	Behind(u64),
	Any(u64),
}

#[derive(Debug, Clone)]
enum Payload {
	Small(Vec<u8>),
	OverNoteMax,
}

#[derive(Debug, Clone)]
struct Write {
	id: u8,
	v: Pick,
	write_id: [u8; 16],
	payload: Payload,
}

#[derive(Debug, Clone)]
enum Op {
	Sync { since: Since, writes: Vec<Write> },
	Get,
	Put { v: Pick, blob: Vec<u8> },
}

fn pick() -> impl Strategy<Value = Pick> {
	prop_oneof![
		1 => Just(Pick::Stored),
		4 => Just(Pick::Next),
		1 => Just(Pick::Skip),
		1 => Just(Pick::Zero),
		1 => Just(Pick::Last),
	]
}

fn since() -> impl Strategy<Value = Since> {
	prop_oneof![
		Just(Since::Zero),
		Just(Since::Latest),
		(1..=4u64).prop_map(Since::Behind),
		any::<u64>().prop_map(Since::Any),
	]
}

fn write() -> impl Strategy<Value = Write> {
	let payload = prop_oneof![
		40 => vec(any::<u8>(), 0..=64).prop_map(Payload::Small),
		1 => Just(Payload::OverNoteMax),
	];
	(0..IDS, pick(), any::<[u8; 16]>(), payload).prop_map(|(id, v, write_id, payload)| Write {
		id,
		v,
		write_id,
		payload,
	})
}

fn op() -> impl Strategy<Value = Op> {
	let writes =
		vec(write(), 0..=8).prop_filter("two oversized writes exceed a request", |writes| {
			writes
				.iter()
				.filter(|write| matches!(write.payload, Payload::OverNoteMax))
				.count() <= 1
		});
	prop_oneof![
		3 => (since(), writes).prop_map(|(since, writes)| Op::Sync { since, writes }),
		1 => Just(Op::Get),
		1 => (pick(), vec(any::<u8>(), 0..=128)).prop_map(|(v, blob)| Op::Put { v, blob }),
	]
}

fn seed_version() -> impl Strategy<Value = Option<u32>> {
	prop::option::of(prop_oneof![
		Just(1),
		Just(u32::MAX - 1),
		Just(u32::MAX),
		any::<u32>()
	])
}

#[derive(Clone, Default)]
struct Model {
	latest: u64,
	notes: BTreeMap<u64, Record>,
	blob: Option<(Version, Vec<u8>)>,
}

fn follows(stored: Version, v: Version) -> bool {
	u64::from(v.0) == u64::from(stored.0) + 1
}

impl Model {
	fn stored(&self, id: &BlindedNoteId) -> Version {
		self.notes
			.values()
			.find(|note| note.id == *id)
			.map_or(Version(0), |note| note.v)
	}

	fn blob_version(&self) -> Version {
		self.blob.as_ref().map_or(Version(0), |(v, _)| *v)
	}

	fn write(&mut self, write: Record) -> WriteResult {
		let stored = self.stored(&write.id);
		let status = if write.payload.len() > NOTE_MAX {
			Status::TooLarge
		} else if follows(stored, write.v) {
			Status::Accepted
		} else {
			Status::Conflict
		};
		if status != Status::Accepted {
			return WriteResult {
				status,
				v: stored,
				seq: Seq(0),
			};
		}
		self.latest += 1;
		let v = write.v;
		self.notes.retain(|_, note| note.id != write.id);
		self.notes.insert(self.latest, write);
		WriteResult {
			status,
			v,
			seq: Seq(self.latest),
		}
	}

	fn changes(&self, since: u64) -> Vec<Record> {
		self.notes
			.range((Bound::Excluded(since), Bound::Unbounded))
			.map(|(_, note)| note.clone())
			.collect()
	}

	fn sync(&self, results: Vec<WriteResult>, changes: Vec<Record>) -> Response {
		Response::Sync {
			results,
			changes,
			next_seq: Seq(self.latest),
			more: false,
		}
	}

	fn get(&self) -> Response {
		let (v, blob) = self.blob.clone().unwrap_or((Version(0), Vec::new()));
		Response::Get { v, blob }
	}

	fn put(&mut self, v: Version, blob: Vec<u8>) -> Response {
		let stored = self.blob_version();
		if follows(stored, v) {
			self.blob = Some((v, blob));
			Response::Put {
				status: Status::Accepted,
				v,
			}
		} else {
			Response::Put {
				status: Status::Conflict,
				v: stored,
			}
		}
	}
}

struct Expected {
	request: Request,
	response: Response,
	calls: usize,
	model: Model,
}

fn expect(model: &Model, op: Op) -> Expected {
	let mut next = model.clone();
	match op {
		Op::Sync { since, writes } => {
			let since = match since {
				Since::Zero => 0,
				Since::Latest => model.latest,
				Since::Behind(by) => model.latest.saturating_sub(by),
				Since::Any(since) => since,
			};
			let mut sent = Vec::new();
			let mut results = Vec::new();
			for write in writes {
				let id = BlindedNoteId([write.id; 16]);
				let record = Record {
					id,
					v: write.v.resolve(next.stored(&id)),
					write_id: write.write_id,
					payload: match write.payload {
						Payload::Small(payload) => payload,
						Payload::OverNoteMax => vec![0x5a; NOTE_MAX + 1],
					},
				};
				sent.push(record.clone());
				results.push(next.write(record));
			}
			let accepted = results
				.iter()
				.filter(|result| result.status == Status::Accepted)
				.count();
			let changes = next.changes(since);
			Expected {
				calls: 1 + sent.len() + accepted + changes.len() + 1,
				response: next.sync(results, changes),
				request: Request::Sync {
					since: Seq(since),
					writes: sent,
				},
				model: next,
			}
		}
		Op::Get => Expected {
			request: Request::Get,
			response: model.get(),
			calls: 1,
			model: next,
		},
		Op::Put { v, blob } => {
			let v = v.resolve(model.blob_version());
			let response = next.put(v, blob.clone());
			Expected {
				request: Request::Put { v, blob },
				calls: 1 + usize::from(matches!(
					response,
					Response::Put {
						status: Status::Accepted,
						..
					}
				)),
				response,
				model: next,
			}
		}
	}
}

proptest! {
	#![proptest_config(ProptestConfig::with_cases(64))]

	#[test]
	fn process_agrees_with_a_model_and_a_fault_leaves_the_state_untouched(
		seeds in vec(seed_version(), usize::from(IDS)),
		blob_seed in seed_version(),
		steps in vec((op(), prop::option::weighted(0.3, any::<Index>())), 1..=40),
	) {
		let mut storage = MemoryStorage::default();
		let mut model = Model::default();
		for (index, v) in (0..IDS).zip(seeds) {
			let Some(v) = v else { continue };
			let record = Record {
				id: BlindedNoteId([index; 16]),
				v: Version(v),
				write_id: [index ^ 0xff; 16],
				payload: vec![index; usize::from(index)],
			};
			model.latest += 1;
			storage.seed_note(Seq(model.latest), record.clone());
			model.notes.insert(model.latest, record);
		}
		if let Some(v) = blob_seed {
			storage.seed_content_key(Version(v), vec![0x6b; 60]);
			model.blob = Some((Version(v), vec![0x6b; 60]));
		}

		let mut harness = Harness::new(API_KEY, storage);
		for (step, (op, fault)) in steps.into_iter().enumerate() {
			let expected = expect(&model, op);
			let before = harness.storage.state().clone();
			let fault = fault.map(|at| at.index(expected.calls + 2));
			if let Some(at) = fault {
				harness.storage.fail_next_at(at);
			}
			let response = harness.call(&expected.request);
			match fault.filter(|&at| at < expected.calls) {
				Some(at) => {
					prop_assert_eq!(response, Response::Error, "step {}", step);
					prop_assert_eq!(
						harness.failures.pop(),
						Some(Failure::Fault(Fault::Storage(Injected(at)))),
						"step {}",
						step
					);
					prop_assert_eq!(harness.storage.calls(), at + 1, "step {}", step);
					prop_assert!(harness.storage.state() == &before, "step {}", step);
				}
				None => {
					prop_assert_eq!(response, expected.response, "step {}", step);
					prop_assert_eq!(harness.storage.calls(), expected.calls, "step {}", step);
					model = expected.model;
				}
			}
			prop_assert!(harness.failures.is_empty(), "step {}", step);
		}

		let everything = Request::Sync {
			since: Seq(0),
			writes: Vec::new(),
		};
		prop_assert_eq!(
			harness.call(&everything),
			model.sync(Vec::new(), model.changes(0))
		);
		prop_assert_eq!(harness.call(&Request::Get), model.get());
	}
}
