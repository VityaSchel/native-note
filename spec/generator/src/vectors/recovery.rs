use serde_json::{Value, json};

use super::{CONTENT_KEY, NONCE, RECOVERY_KEY, file, seq_array};
use crate::frame::{self, Request, Response};
use crate::hex::encode as hx;
use crate::server::Server;
use crate::{aead, mnemonic, recovery};

pub fn sample_blob() -> Vec<u8> {
	Rotation::new(0).blob
}

struct Rotation {
	recovery_key: [u8; 32],
	nonce: [u8; 12],
	blob: Vec<u8>,
}

impl Rotation {
	fn new(seed: u8) -> Self {
		let recovery_key = seq_array(RECOVERY_KEY.wrapping_add(seed));
		let nonce = seq_array(NONCE.wrapping_add(seed));
		let blob = recovery::seal(&recovery_key, &nonce, &seq_array(CONTENT_KEY));
		Self {
			recovery_key,
			nonce,
			blob,
		}
	}

	fn inputs(&self) -> Value {
		json!({
			"recoveryKey": hx(&self.recovery_key),
			"contentKey": hx(&seq_array::<32>(CONTENT_KEY)),
			"nonce": hx(&self.nonce),
		})
	}

	fn put(&self, v: u32) -> Request {
		Request::PutRecovery {
			v,
			blob: self.blob.clone(),
		}
	}
}

fn exchange(
	name: &str,
	device: &str,
	explains: &str,
	request: Request,
	response: Response,
	mut case: Value,
) -> Value {
	case["name"] = json!(name);
	case["device"] = json!(device);
	case["explains"] = json!(explains);
	case["request"] = json!(hx(&frame::encode_request(&request)));
	case["response"] = json!(hx(&frame::encode_response(&response)));
	case
}

fn opening(recovery_key: &[u8; 32], blob: &[u8]) -> Value {
	json!({
		"recoveryKey": hx(recovery_key),
		"opens": recovery::open(recovery_key, blob) == Ok(seq_array(CONTENT_KEY)),
	})
}

pub fn recovery() -> Value {
	let content_key: [u8; 32] = seq_array(CONTENT_KEY);
	let setup = Rotation::new(0);
	let elsewhere = Rotation::new(0x20);
	let stale = Rotation::new(0x40);

	let mut wrong_key = setup.recovery_key;
	wrong_key[0] ^= 0x01;
	let short = aead::seal(&setup.recovery_key, &setup.nonce, &content_key[..31], &[]);

	let mut server = Server::new();
	let get_empty = server.get_recovery();
	let put = server.put_recovery(1, &setup.blob);
	let put_again = server.put_recovery(1, &setup.blob);
	let get_after_conflict = server.get_recovery();
	let landed = opening(&setup.recovery_key, server.recovery_blob());
	let get_on_join = server.get_recovery();
	let joined = opening(&setup.recovery_key, server.recovery_blob());
	let rotate_elsewhere = server.put_recovery(2, &elsewhere.blob);
	let rotate_stale = server.put_recovery(2, &stale.blob);
	let get_after_stale = server.get_recovery();
	let rotated_elsewhere = opening(&stale.recovery_key, server.recovery_blob());

	file(
		"contentKeyEncrypted: the Content key sealed under the Recovery key with an empty AAD, then get and put exchanges over the reference server semantics. A client puts at its pin + 1 and, after a conflict, checks whether the fetched blob opens under the Recovery key it just put.",
		vec![
			json!({
				"name": "blob",
				"mnemonic": mnemonic::encode(&setup.recovery_key).join(" "),
				"recoveryKey": hx(&setup.recovery_key),
				"contentKey": hx(&content_key),
				"nonce": hx(&setup.nonce),
				"blob": hx(&setup.blob),
				"opens": recovery::open(&setup.recovery_key, &setup.blob) == Ok(content_key),
			}),
			json!({
				"name": "rejectWrongRecoveryKey",
				"recoveryKey": hx(&wrong_key),
				"blob": hx(&setup.blob),
				"opens": recovery::open(&wrong_key, &setup.blob).is_ok(),
			}),
			json!({
				"name": "rejectWrongLength",
				"recoveryKey": hx(&setup.recovery_key),
				"blob": hx(&short),
				"opens": recovery::open(&setup.recovery_key, &short).is_ok(),
			}),
			exchange(
				"getEmpty",
				"A",
				"Setup gets the blob first. v = 0 means none is stored, so setup goes on with pin 0.",
				Request::GetRecovery,
				get_empty,
				json!({}),
			),
			exchange(
				"put",
				"A",
				"Setup puts the blob at its pin + 1, so v = 1 is accepted.",
				setup.put(1),
				put,
				setup.inputs(),
			),
			exchange(
				"putAgain",
				"A",
				"The same put after a lost response. storedV is already 1, so it conflicts with the server's current v.",
				setup.put(1),
				put_again,
				setup.inputs(),
			),
			exchange(
				"getAfterConflict",
				"A",
				"A gets the blob; it opens under the Recovery key A just put, so that put landed and the pin is 1.",
				Request::GetRecovery,
				get_after_conflict,
				landed,
			),
			exchange(
				"getOnJoin",
				"B",
				"B joins with the same words. The blob opens, so B stores the Content key and takes v = 1 as its pin.",
				Request::GetRecovery,
				get_on_join,
				joined,
			),
			exchange(
				"rotateOnB",
				"B",
				"B rotates to a new Recovery key and puts at its pin + 1, so v = 2 is accepted.",
				elsewhere.put(2),
				rotate_elsewhere,
				elsewhere.inputs(),
			),
			exchange(
				"rotateOnAWithStalePin",
				"A",
				"A rotates too and puts at its pin + 1 without a get. storedV is already 2, so it conflicts.",
				stale.put(2),
				rotate_stale,
				stale.inputs(),
			),
			exchange(
				"rejectBlobRotatedElsewhere",
				"A",
				"A gets the blob; it does not open under the Recovery key A just put, so A reports that another device rotated and keeps pin 1.",
				Request::GetRecovery,
				get_after_stale,
				rotated_elsewhere,
			),
		],
	)
}
