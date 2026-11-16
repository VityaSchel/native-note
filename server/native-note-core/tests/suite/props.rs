use crate::support::client::{self, Reason, Response, Status, WriteResult};
use crate::support::harness::{Failure, Harness};
use crate::support::memory::{Injected, MemoryStorage};
use crate::support::{NOTE_MAX, open, server_key};
use native_note_core::{
	BlindedNoteId, DecodeError, Fault, Record, Rejection, Request, Seq, Version,
};
use native_note_testkit::model::Model;
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::sample::Index;

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
		let key = server_key(API_KEY);
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

enum Expected {
	Sync {
		since: Seq,
		results: Vec<WriteResult>,
	},
	Whole(Response),
}

struct Step {
	request: Request,
	expected: Expected,
	calls: usize,
	model: Model,
}

fn kept<T: ?Sized>(value: Box<T>) -> &'static T {
	Box::leak(value)
}

fn step(model: &Model, op: Op) -> Step {
	let mut next = model.clone();
	match op {
		Op::Sync { since, writes } => {
			let since = Seq(match since {
				Since::Zero => 0,
				Since::Latest => model.latest().0,
				Since::Behind(by) => model.latest().0.saturating_sub(by),
				Since::Any(since) => since,
			});
			let mut sent = Vec::new();
			let mut results = Vec::new();
			for write in writes {
				let id = BlindedNoteId([write.id; 16]);
				let record = Record {
					id,
					v: write.v.resolve(next.version(&id)),
					write_id: write.write_id,
					payload: match write.payload {
						Payload::Small(payload) => payload,
						Payload::OverNoteMax => vec![0x5a; NOTE_MAX + 1],
					},
				};
				let result = next.judge(&record);
				if result.status == Status::Accepted {
					next.apply(kept(Box::new(record.clone())));
				}
				sent.push(record);
				results.push(result);
			}
			let accepted = results
				.iter()
				.filter(|result| result.status == Status::Accepted)
				.count();
			Step {
				calls: 1 + sent.len() + accepted + next.changes_after(since) + 1,
				expected: Expected::Sync { since, results },
				request: Request::Sync {
					since,
					writes: sent,
				},
				model: next,
			}
		}
		Op::Get => Step {
			request: Request::Get,
			expected: Expected::Whole(model.get()),
			calls: 1,
			model: next,
		},
		Op::Put { v, blob } => {
			let v = v.resolve(model.blob_version());
			let response = next.put(v, kept(blob.clone().into_boxed_slice()));
			Step {
				request: Request::Put { v, blob },
				calls: 1 + usize::from(matches!(
					response,
					Response::Put {
						status: Status::Accepted,
						..
					}
				)),
				expected: Expected::Whole(response),
				model: next,
			}
		}
	}
}

fn check(model: &Model, expected: Expected, inner: &[u8]) -> Result<(), TestCaseError> {
	let response = client::decode_response(inner);
	match expected {
		Expected::Whole(expected) => prop_assert_eq!(response, expected),
		Expected::Sync {
			since,
			results: expected,
		} => {
			let Response::Sync {
				results,
				changes,
				next_seq,
				more,
			} = response
			else {
				return Err(TestCaseError::fail(format!("not a sync: {response:?}")));
			};
			prop_assert_eq!(results, expected);
			model.check_changes(since, &changes, next_seq, more, inner.len());
		}
	}
	Ok(())
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
			let record = kept(Box::new(Record {
				id: BlindedNoteId([index; 16]),
				v: Version(v),
				write_id: [index ^ 0xff; 16],
				payload: vec![index; usize::from(index)],
			}));
			storage.seed_note(model.seed_note(record), record.clone());
		}
		if let Some(v) = blob_seed {
			storage.seed_content_key(Version(v), vec![0x6b; 60]);
			model.seed_blob(Version(v), &[0x6b; 60]);
		}

		let mut harness = Harness::new(API_KEY, storage);
		for (index, (op, fault)) in steps.into_iter().enumerate() {
			let step = step(&model, op);
			let before = harness.storage.state().clone();
			let fault = fault.map(|at| at.index(step.calls + 2));
			if let Some(at) = fault {
				harness.storage.fail_next_at(at);
			}
			let inner = harness.send(&client::encode_request(&step.request));
			match fault.filter(|&at| at < step.calls) {
				Some(at) => {
					prop_assert_eq!(
						client::decode_response(&inner),
						Response::Error(Reason::Fault),
						"step {}",
						index
					);
					prop_assert_eq!(
						harness.failures.pop(),
						Some(Failure::Fault(Fault::Storage(Injected(at)))),
						"step {}",
						index
					);
					prop_assert_eq!(harness.storage.calls(), at + 1, "step {}", index);
					prop_assert!(harness.storage.state() == &before, "step {}", index);
				}
				None => {
					model = step.model;
					check(&model, step.expected, &inner)?;
					prop_assert_eq!(harness.storage.calls(), step.calls, "step {}", index);
				}
			}
			prop_assert!(harness.failures.is_empty(), "step {}", index);
		}

		let everything = client::encode_request(&client::sync(0, &[]));
		let expected = Expected::Sync {
			since: Seq(0),
			results: Vec::new(),
		};
		check(&model, expected, &harness.send(&everything))?;
		prop_assert_eq!(harness.call(&Request::Get), model.get());
	}
}
