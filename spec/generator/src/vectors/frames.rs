use serde_json::{Value, json};

use super::{API_KEY, NONCE, RESPONSE_NONCE, file};
use crate::codec::DecodeError;
use crate::frame::{self, Request, Response, Status, Write, WriteResult};
use crate::hex::encode as hx;
use crate::{envelope, fixed, kdf, seq_bytes};

pub fn sample_write(v: u32) -> Write {
	Write {
		blinded_id: fixed(0x10),
		v,
		write_id: fixed(0x60),
		deleted: false,
		payload: seq_bytes(0xd0, 24),
	}
}

fn request_case(name: &str, request: Request) -> Value {
	let encoded = frame::encode_request(&request);
	json!({
		"name": name,
		"direction": "request",
		"encoded": hx(&encoded),
		"length": encoded.len(),
		"roundTrips": frame::decode_request(&encoded).as_ref() == Ok(&request),
	})
}

fn response_case(name: &str, response: Response) -> Value {
	let encoded = frame::encode_response(&response);
	json!({
		"name": name,
		"direction": "response",
		"encoded": hx(&encoded),
		"length": encoded.len(),
		"roundTrips": frame::decode_response(&encoded).as_ref() == Ok(&response),
	})
}

fn reject_request(name: &str, bytes: Vec<u8>, expected: DecodeError) -> Value {
	json!({
		"name": name,
		"direction": "request",
		"encoded": hx(&bytes),
		"decodes": frame::decode_request(&bytes).is_ok(),
		"error": format!("{expected:?}"),
		"matches": frame::decode_request(&bytes) == Err(expected),
	})
}

fn reject_response(name: &str, bytes: Vec<u8>, expected: DecodeError) -> Value {
	json!({
		"name": name,
		"direction": "response",
		"encoded": hx(&bytes),
		"decodes": frame::decode_response(&bytes).is_ok(),
		"error": format!("{expected:?}"),
		"matches": frame::decode_response(&bytes) == Err(expected),
	})
}

pub fn frames() -> Value {
	let sync = Request::Sync {
		since: 7,
		writes: vec![sample_write(1)],
	};
	let encoded_sync = frame::encode_request(&sync);

	let mut unknown_action = encoded_sync.clone();
	unknown_action[0] = 0x7f;

	let mut bad_bool = encoded_sync.clone();
	let deleted_at = 1 + 8 + 4 + 16 + 4 + 16;
	bad_bool[deleted_at] = 0x02;

	let mut huge_count = encoded_sync.clone();
	huge_count[9..13].copy_from_slice(&u32::MAX.to_be_bytes());

	let trailing = [encoded_sync.clone(), vec![0]].concat();

	let conflict = Response::Sync {
		results: vec![WriteResult {
			blinded_id: fixed(0x10),
			status: Status::Conflict,
			v: 1,
			seq: 0,
		}],
		changes: vec![],
		next_seq: 1,
		more: false,
	};
	let status_at = 1 + 4 + 16;
	let mut unknown_status = frame::encode_response(&conflict);
	unknown_status[status_at] = 0x06;

	let mut seq_on_conflict = frame::encode_response(&conflict);
	let seq_at = status_at + 1 + 4;
	seq_on_conflict[seq_at..seq_at + 8].copy_from_slice(&9u64.to_be_bytes());

	file(
		"Request and response frames. Fixed-width big-endian fields, length-prefixed byte strings, exactly one valid encoding per message.",
		vec![
			request_case(
				"syncEmpty",
				Request::Sync {
					since: 0,
					writes: vec![],
				},
			),
			request_case("syncOneWrite", sync),
			request_case("getRecovery", Request::GetRecovery),
			request_case(
				"putRecovery",
				Request::PutRecovery {
					v: 2,
					blob: seq_bytes(0xe0, 60),
				},
			),
			response_case(
				"syncAccepted",
				Response::Sync {
					results: vec![WriteResult {
						blinded_id: fixed(0x10),
						status: Status::Accepted,
						v: 1,
						seq: 1,
					}],
					changes: vec![],
					next_seq: 1,
					more: false,
				},
			),
			response_case("syncConflict", conflict),
			response_case(
				"syncChanges",
				Response::Sync {
					results: vec![],
					changes: vec![sample_write(2)],
					next_seq: 4,
					more: true,
				},
			),
			response_case(
				"syncRefused",
				Response::Sync {
					results: [Status::TooLarge, Status::Exhausted, Status::Quota]
						.into_iter()
						.map(|status| WriteResult {
							blinded_id: fixed(0x10),
							status,
							v: 1,
							seq: 0,
						})
						.collect(),
					changes: vec![],
					next_seq: 1,
					more: false,
				},
			),
			response_case(
				"getRecoveryResult",
				Response::GetRecovery {
					v: 2,
					blob: seq_bytes(0xe0, 60),
				},
			),
			response_case(
				"putRecoveryResult",
				Response::PutRecovery {
					status: Status::Accepted,
					v: 3,
				},
			),
			reject_request(
				"rejectUnknownAction",
				unknown_action,
				DecodeError::UnknownDiscriminant,
			),
			reject_request(
				"rejectNonCanonicalBool",
				bad_bool,
				DecodeError::NotCanonical,
			),
			reject_request("rejectImpossibleCount", huge_count, DecodeError::Truncated),
			reject_request("rejectTrailingBytes", trailing, DecodeError::TrailingBytes),
			reject_response(
				"rejectSeqOnNonAcceptedResult",
				seq_on_conflict,
				DecodeError::NotCanonical,
			),
			reject_response(
				"rejectUnknownStatus",
				unknown_status,
				DecodeError::UnknownDiscriminant,
			),
		],
	)
}

pub fn envelope() -> Value {
	let api_key = seq_bytes(API_KEY, 32);
	let key = kdf::envelope_key(&api_key);
	let req_nonce: [u8; 12] = fixed(NONCE);
	let resp_nonce: [u8; 12] = fixed(RESPONSE_NONCE);

	let request_inner = frame::encode_request(&Request::Sync {
		since: 0,
		writes: vec![],
	});
	let response_inner = frame::encode_response(&Response::Sync {
		results: vec![],
		changes: vec![],
		next_seq: 0,
		more: false,
	});

	let request = envelope::seal_request(&key, &req_nonce, &request_inner).unwrap();
	let response = envelope::seal_response(&key, &resp_nonce, &req_nonce, &response_inner).unwrap();

	let mut flipped = request.clone();
	flipped[0] = 0x02;

	let mut wrong_nonce = req_nonce;
	wrong_nonce[0] ^= 0x01;

	let truncated = &request[..request.len() - 1];
	let unwrapped = &request[1..];

	file(
		"Sealed envelopes. Version is authenticated as AAD; responses additionally bind the request nonce.",
		vec![
			json!({
				"name": "request",
				"apiKey": hx(&api_key),
				"envelopeKey": hx(&key),
				"inner": hx(&request_inner),
				"nonce": hx(&req_nonce),
				"aad": hx(&[envelope::VERSION]),
				"frame": hx(&request),
				"opens": envelope::open_request(&key, &request).is_ok(),
			}),
			json!({
				"name": "response",
				"inner": hx(&response_inner),
				"nonce": hx(&resp_nonce),
				"requestNonce": hx(&req_nonce),
				"frame": hx(&response),
				"opens": envelope::open_response(&key, &req_nonce, &response).is_ok(),
			}),
			json!({
				"name": "rejectFlippedVersion",
				"frame": hx(&flipped),
				"opens": envelope::open_request(&key, &flipped).is_ok(),
			}),
			json!({
				"name": "rejectResponseUnderWrongRequestNonce",
				"frame": hx(&response),
				"requestNonce": hx(&wrong_nonce),
				"opens": envelope::open_response(&key, &wrong_nonce, &response).is_ok(),
			}),
			json!({
				"name": "rejectTruncated",
				"frame": hx(truncated),
				"opens": envelope::open_request(&key, truncated).is_ok(),
			}),
			json!({
				"name": "rejectRequestOpenedAsResponse",
				"frame": hx(unwrapped),
				"requestNonce": hx(&req_nonce),
				"opens": envelope::open_response(&key, &req_nonce, unwrapped).is_ok(),
			}),
		],
	)
}
