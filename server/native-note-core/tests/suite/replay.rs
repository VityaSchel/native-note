use crate::support::client::{self, INNER_MAX, Response, Status};
use crate::support::corpus::{SplitMix64, corpus, payload};
use crate::support::harness::{Http, nonce_of};
use crate::support::open;
use crate::support::session::{Captured, Sent, Session};
use native_note_core::{EnvelopeKey, Record, Rejection, Reply, Request, Secret, Seq, Version};
use std::collections::BTreeSet;

const API_KEY: [u8; 32] = [
	0x2d, 0xb7, 0x48, 0x91, 0xe3, 0x0f, 0x6c, 0xa5, 0x13, 0xf8, 0x5a, 0x27, 0xc9, 0x84, 0x3e, 0x71,
	0xd0, 0x66, 0x1b, 0xae, 0x52, 0x09, 0xfd, 0x34, 0x8e, 0xc3, 0x75, 0x1a, 0xb6, 0x4f, 0xe2, 0x98,
];

fn server_key(api_key: [u8; 32]) -> EnvelopeKey {
	EnvelopeKey::derive(&Secret::new(api_key)).expect("a 32-byte key derives")
}

struct Script {
	syncs: Vec<(Seq, &'static [Record])>,
	recovery: [Request; 3],
}

impl Script {
	fn new() -> Self {
		let mut pushed = 0;
		let syncs = client::batch(corpus())
			.into_iter()
			.map(|writes| {
				let since = Seq(pushed);
				pushed += u64::try_from(writes.len()).expect("fits");
				(since, writes)
			})
			.collect();
		let recovery = [
			Request::Get,
			Request::Put {
				v: Version(1),
				blob: payload(60, 0x0049),
			},
			Request::Put {
				v: Version(2),
				blob: payload(INNER_MAX - 9, 0x0049),
			},
		];
		Self { syncs, recovery }
	}

	fn len(&self) -> usize {
		self.syncs.len() + self.recovery.len()
	}

	fn request(&self, index: usize) -> Request {
		match self.syncs.get(index) {
			Some(&(since, writes)) => Request::Sync {
				since,
				writes: writes.to_vec(),
			},
			None => self.recovery[index - self.syncs.len()].clone(),
		}
	}
}

fn shuffled(count: usize, rng: &mut SplitMix64) -> Vec<usize> {
	let mut order: Vec<usize> = (0..count).collect();
	for last in (1..count).rev() {
		order.swap(last, rng.between(0, last));
	}
	order
}

#[test]
fn a_captured_session_replayed_in_order_and_shuffled_opens_to_the_same_requests() {
	let key = server_key(API_KEY);
	let envelope_key = client::envelope_key(&API_KEY);
	let script = Script::new();
	let mut rng = SplitMix64::new(49);

	let captured: Vec<_> = (0..script.len())
		.map(|index| {
			let inner = client::encode_request(&script.request(index));
			client::seal_request(&envelope_key, rng.array(), &inner)
		})
		.collect();
	let nonces: BTreeSet<_> = captured.iter().map(|body| nonce_of(body)).collect();
	assert_eq!(nonces.len(), script.len());
	assert!(script.syncs.len() >= 25, "{} syncs", script.syncs.len());

	let order = shuffled(script.len(), &mut rng);
	assert!(order.windows(2).any(|pair| pair[0] > pair[1]));
	let mut replayed = vec![0; script.len()];
	for index in (0..script.len()).chain(order) {
		let body = captured[index].clone();
		let nonce = nonce_of(&body);
		let opened = open(&key, body).expect("a replay opens");
		assert_eq!(opened.nonce(), nonce, "replay of {index}");
		assert_eq!(
			opened.request(),
			Ok(script.request(index)),
			"replay of {index}"
		);
		replayed[index] += 1;
	}
	assert!(replayed.iter().all(|&count| count == 2), "{replayed:?}");
}

#[test]
fn a_sealed_reply_replayed_as_a_request_is_unopenable() {
	let key = server_key(API_KEY);
	let envelope_key = client::envelope_key(&API_KEY);
	let mut rng = SplitMix64::new(0x0049);
	for index in 0..256 {
		let request_nonce = rng.array();
		let body = key
			.seal(Reply::error(), &request_nonce, rng.array())
			.expect("seals");
		let inner = client::open_response(&envelope_key, &request_nonce, &body)
			.expect("the client opens it");
		assert_eq!(client::decode_response(&inner), Response::Error);
		assert_eq!(
			open(&key, body).err(),
			Some(Rejection::Unopenable),
			"reply {index}"
		);
	}
}

pub fn replay_captured(session: &mut Session) {
	let Session {
		harness,
		model,
		captured,
	} = session;
	let before = harness.storage.state().clone();
	let transactions = harness.storage.transactions();
	let mut rng = SplitMix64::new(0x0050_4c41_5953);
	let order = shuffled(captured.len(), &mut rng);
	assert!(order.windows(2).any(|pair| pair[0] > pair[1]));

	let (mut conflicts, mut too_large, mut gets, mut puts) = (0, 0, 0, 0);
	for index in (0..captured.len()).chain(order) {
		let Captured { body, sent } = &captured[index];
		let request_nonce = nonce_of(body);
		let Http::Ok(reply) = harness.exchange(body.clone(), rng.array()) else {
			panic!("replay {index} got no sealed reply");
		};
		let inner = harness
			.open(&request_nonce, &reply)
			.unwrap_or_else(|| panic!("replay {index} does not open under its own nonce"));
		let mut other = request_nonce;
		other[index % 12] ^= 0x01;
		assert_eq!(harness.open(&other, &reply), None, "replay {index}");

		match (*sent, client::decode_response(&inner)) {
			(
				Sent::Sync {
					since,
					writes: sent,
				},
				Response::Sync {
					results,
					changes,
					next_seq,
					more,
				},
			) => {
				let expected: Vec<_> = sent.iter().map(|write| model.judge(write)).collect();
				assert_eq!(results, expected, "replay {index}");
				for result in results {
					assert_eq!(result.seq, Seq(0), "replay {index}");
					match result.status {
						Status::Conflict => conflicts += 1,
						Status::TooLarge => too_large += 1,
						Status::Accepted => panic!("replay {index} stored a write"),
					}
				}
				model.check_changes(since, &changes, next_seq, more, inner.len());
			}
			(Sent::Get, response) => {
				assert_eq!(response, model.get(), "replay {index}");
				gets += 1;
			}
			(Sent::Put { v }, response) => {
				assert_eq!(response, model.judge_put(v), "replay {index}");
				assert!(
					matches!(
						response,
						Response::Put {
							status: Status::Conflict,
							..
						}
					),
					"replay {index}"
				);
				puts += 1;
			}
			(_, response) => panic!("replay {index} got the wrong action: {response:?}"),
		}
	}

	assert!(
		harness.storage.state() == &before,
		"a replay changed the store"
	);
	assert_eq!(harness.storage.state().latest(), model.latest());
	assert_eq!(
		harness.storage.transactions(),
		transactions + 2 * captured.len()
	);
	assert!(harness.failures.is_empty());
	assert_eq!((conflicts, too_large), (2 * 2_301, 2));
	assert_eq!((gets, puts), (2 * 4, 2 * 4));
}
