use crate::support::client::{self, INNER_MAX, Response, Status};
use crate::support::corpus::payload;
use crate::support::harness::{Harness, Http, nonce_of};
use crate::support::memory::MemoryStorage;
use crate::support::vectors::{hex, replayed};
use crate::support::{BODY_MAX, SEALED_MAX};
use native_note_core::{Request, Version};
use std::collections::BTreeMap;

const API_KEY: [u8; 32] = [
	0xc8, 0x13, 0x7a, 0xe5, 0x40, 0x9d, 0x26, 0xbf, 0x01, 0x6c, 0xd7, 0x52, 0xa3, 0x3e, 0xf9, 0x84,
	0x2b, 0x70, 0xce, 0x19, 0x65, 0xb2, 0x0f, 0xda, 0x47, 0x88, 0x3c, 0xe1, 0x9a, 0x56, 0x0d, 0xf3,
];
const RESENT: [(&str, &str); 1] = [("putAgain", "put")];

#[test]
fn the_recovery_vector_exchanges_run_in_order_against_one_server_and_a_resent_put_conflicts() {
	let mut harness = Harness::new(API_KEY, MemoryStorage::default());
	let mut bodies = BTreeMap::new();
	for case in replayed("recovery.json") {
		let name = case["name"].as_str().expect("a name").to_owned();
		let inner = hex(&case["request"]);
		let body = match RESENT.iter().find(|(resent, _)| *resent == name) {
			Some((_, original)) => {
				let (original_inner, body): &(Vec<u8>, Vec<u8>) = &bodies[*original];
				assert_eq!(*original_inner, inner, "{name}");
				body.clone()
			}
			None => harness.seal(&inner),
		};
		let response = harness.post(&body);
		assert_eq!(response, hex(&case["response"]), "{name}");
		if name == "putAgain" {
			assert_eq!(
				client::decode_response(&response),
				Response::Put {
					status: Status::Conflict,
					v: Version(1)
				}
			);
		}
		bodies.insert(name, (inner, body));
	}
	assert_eq!(bodies.len(), 8);
	assert!(harness.failures.is_empty());
}

#[test]
fn the_largest_put_is_accepted_and_a_get_answers_it_padded_to_the_body_limit() {
	let blob = payload(INNER_MAX - 9, 0x0050_5554);
	assert_eq!(blob.len(), 2_097_139);
	let mut harness = Harness::new(API_KEY, MemoryStorage::default());
	let put = Request::Put {
		v: Version(1),
		blob: blob.clone(),
	};
	assert_eq!(
		client::pad(&client::encode_request(&put)).map(|padded| padded.len()),
		Some(BODY_MAX)
	);
	assert_eq!(
		harness.call(&put),
		Response::Put {
			status: Status::Accepted,
			v: Version(1)
		}
	);

	let body = harness.seal(&client::encode_request(&Request::Get));
	let Http::Ok(reply) = harness.exchange(body.clone(), [0x67; 12]) else {
		panic!("a get gets a sealed reply");
	};
	assert_eq!(reply.len(), SEALED_MAX);
	let inner = harness.open(&nonce_of(&body), &reply).expect("opens");
	assert!(
		client::decode_response(&inner)
			== Response::Get {
				v: Version(1),
				blob: blob.clone(),
			}
	);

	let skipping = Request::Put {
		v: Version(3),
		blob: payload(60, 1),
	};
	assert_eq!(
		harness.call(&skipping),
		Response::Put {
			status: Status::Conflict,
			v: Version(1)
		}
	);
	assert!(
		harness.call(&Request::Get)
			== Response::Get {
				v: Version(1),
				blob
			}
	);
}
