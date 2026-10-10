use serde_json::{Value, json};

use super::recovery::sample_blob;
use super::{
	API_KEY, BLINDED_ID, NONCE, PAYLOAD, RESPONSE_NONCE, WRITE_ID, file, seq_array, seq_bytes,
};
use crate::codec::DecodeError;
use crate::frame::{self, Request, Response, Status, Write, WriteResult};
use crate::hex::encode as hx;
use crate::server::Server;
use crate::{aead, envelope, kdf};

fn sample_write(v: u32) -> Write {
	Write {
		blinded_id: seq_array(BLINDED_ID),
		v,
		write_id: seq_array(WRITE_ID),
		payload: seq_bytes(PAYLOAD, 24),
	}
}

fn one_result(status: Status, v: u32, seq: u64) -> Response {
	Response::Sync {
		results: vec![WriteResult { status, v, seq }],
		changes: vec![],
		next_seq: 1,
		more: false,
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

	let mut huge_count = encoded_sync.clone();
	huge_count[9..13].copy_from_slice(&u32::MAX.to_be_bytes());

	let payload_len_at = 1 + 8 + 4 + 16 + 4 + 16;
	let mut huge_length = encoded_sync.clone();
	huge_length[payload_len_at..payload_len_at + 4].copy_from_slice(&u32::MAX.to_be_bytes());

	let trailing = [encoded_sync, vec![0]].concat();

	let conflict = one_result(Status::Conflict, 1, 0);
	let status_at = 1 + 4;
	let mut unknown_status = frame::encode_response(&conflict);
	unknown_status[status_at] = 0x04;

	let mut seq_on_conflict = frame::encode_response(&conflict);
	let seq_at = status_at + 1 + 4;
	seq_on_conflict[seq_at..seq_at + 8].copy_from_slice(&9u64.to_be_bytes());

	let mut short_count_bad_item = frame::encode_response(&conflict);
	short_count_bad_item[1..5].copy_from_slice(&2u32.to_be_bytes());
	short_count_bad_item[status_at] = 0x04;
	short_count_bad_item.truncate(seq_at + 8);

	let mut bad_bool = frame::encode_response(&conflict);
	*bad_bool.last_mut().unwrap() = 0x02;

	let too_large_on_put = frame::encode_response(&Response::PutRecovery {
		status: Status::TooLarge,
		v: 1,
	});

	let encoded_error = frame::encode_response(&Response::Error);
	let trailing_error = [encoded_error.clone(), vec![0]].concat();
	let mut unknown_response_action = encoded_error.clone();
	unknown_response_action[0] = 0xfe;

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
					blob: sample_blob(),
				},
			),
			response_case("syncAccepted", one_result(Status::Accepted, 1, 1)),
			response_case("syncConflict", conflict),
			response_case(
				"syncConflictAtLastVersion",
				one_result(Status::Conflict, u32::MAX, 0),
			),
			response_case("syncTooLarge", one_result(Status::TooLarge, 1, 0)),
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
				"getRecoveryResult",
				Response::GetRecovery {
					v: 2,
					blob: sample_blob(),
				},
			),
			response_case(
				"getRecoveryEmpty",
				Response::GetRecovery { v: 0, blob: vec![] },
			),
			response_case(
				"putRecoveryResult",
				Response::PutRecovery {
					status: Status::Accepted,
					v: 3,
				},
			),
			response_case("error", Response::Error),
			reject_request(
				"rejectUnknownAction",
				unknown_action,
				DecodeError::UnknownDiscriminant,
			),
			reject_request("rejectImpossibleCount", huge_count, DecodeError::Truncated),
			reject_request(
				"rejectImpossibleLength",
				huge_length,
				DecodeError::Truncated,
			),
			reject_request("rejectTrailingBytes", trailing, DecodeError::TrailingBytes),
			reject_request(
				"rejectErrorAsRequest",
				encoded_error,
				DecodeError::UnknownDiscriminant,
			),
			reject_response(
				"rejectNonCanonicalBool",
				bad_bool,
				DecodeError::NotCanonical,
			),
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
			reject_response(
				"rejectBadItemBeforeShortCount",
				short_count_bad_item,
				DecodeError::UnknownDiscriminant,
			),
			reject_response(
				"rejectTooLargeOnPut",
				too_large_on_put,
				DecodeError::UnknownDiscriminant,
			),
			reject_response(
				"rejectUnknownResponseAction",
				unknown_response_action,
				DecodeError::UnknownDiscriminant,
			),
			reject_response(
				"rejectTrailingBytesAfterError",
				trailing_error,
				DecodeError::TrailingBytes,
			),
		],
	)
}

pub fn envelope() -> Value {
	let api_key = seq_bytes(API_KEY, 32);
	let key = kdf::envelope_key(&api_key);
	let req_nonce: [u8; 12] = seq_array(NONCE);
	let resp_nonce: [u8; 12] = seq_array(RESPONSE_NONCE);

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

	let mut wrong_nonce = req_nonce;
	wrong_nonce[0] ^= 0x01;

	let truncated = &request[..request.len() - 1];

	let mut dirty_fill = envelope::pad(&request_inner).unwrap();
	*dirty_fill.last_mut().unwrap() = 0x01;
	let unpaddable = aead::seal(&key, &req_nonce, &dirty_fill, &[]);
	let undecodable = envelope::seal_request(&key, &req_nonce, &[0x7f]).unwrap();
	let answered = |name: &str, sealed: &[u8]| {
		json!({
			"name": name,
			"envelopeKey": hx(&key),
			"frame": hx(sealed),
			"responseNonce": hx(&resp_nonce),
			"response": hx(&Server::new().handle(&key, sealed, &resp_nonce).unwrap()),
			"responseInner": hx(&frame::encode_response(&Response::Error)),
		})
	};

	file(
		"Sealed envelopes. Requests are sealed with an empty AAD; responses bind the request nonce as AAD. A request that opens but fails to unpad or decode is answered with a sealed error.",
		vec![
			json!({
				"name": "request",
				"apiKey": hx(&api_key),
				"envelopeKey": hx(&key),
				"inner": hx(&request_inner),
				"nonce": hx(&req_nonce),
				"frame": hx(&request),
				"opens": envelope::open_request(&key, &request).is_ok(),
			}),
			json!({
				"name": "response",
				"envelopeKey": hx(&key),
				"inner": hx(&response_inner),
				"nonce": hx(&resp_nonce),
				"requestNonce": hx(&req_nonce),
				"frame": hx(&response),
				"opens": envelope::open_response(&key, &req_nonce, &response).is_ok(),
			}),
			json!({
				"name": "rejectResponseUnderWrongRequestNonce",
				"envelopeKey": hx(&key),
				"frame": hx(&response),
				"requestNonce": hx(&wrong_nonce),
				"opens": envelope::open_response(&key, &wrong_nonce, &response).is_ok(),
			}),
			json!({
				"name": "rejectTruncated",
				"envelopeKey": hx(&key),
				"frame": hx(truncated),
				"opens": envelope::open_request(&key, truncated).is_ok(),
			}),
			json!({
				"name": "rejectRequestOpenedAsResponse",
				"envelopeKey": hx(&key),
				"frame": hx(&request),
				"requestNonce": hx(&req_nonce),
				"opens": envelope::open_response(&key, &req_nonce, &request).is_ok(),
			}),
			json!({
				"name": "rejectResponseOpenedAsRequest",
				"envelopeKey": hx(&key),
				"frame": hx(&response),
				"opens": envelope::open_request(&key, &response).is_ok(),
			}),
			answered("errorForUnpaddableRequest", &unpaddable),
			answered("errorForUndecodableRequest", &undecodable),
		],
	)
}
