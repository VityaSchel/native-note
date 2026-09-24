use serde_json::{Value, json};

use super::content::{sample_note, sample_tombstone};
use super::{CONTENT_KEY, DEVICE_A, DEVICE_B, file, seq_array, seq_bytes, uuid_bytes};
use crate::content::Content;
use crate::frame::{self, Request, Response, Write, WriteResult};
use crate::hex::encode as hx;
use crate::note::{self, BlindedId};
use crate::server::Server;
use crate::{content, kdf};

const NOTE_MAX: usize = 1024 * 1024;

struct Device {
	content_key: Vec<u8>,
	seed: u8,
}

impl Device {
	fn write(&self, blinded: BlindedId, v: u32, value: &Content) -> Write {
		let write_id: [u8; 16] = seq_array(self.seed.wrapping_add(v as u8));
		let nonce: [u8; 12] = seq_array(self.seed.wrapping_add(0x30).wrapping_add(v as u8));
		let plaintext = content::encode(value);
		Write {
			blinded_id: blinded,
			v,
			write_id,
			deleted: value.is_tombstone(),
			payload: note::seal(
				&self.content_key,
				&write_id,
				&nonce,
				&blinded,
				v,
				&plaintext,
			),
		}
	}
}

fn step(
	n: u32,
	device: &str,
	explains: &str,
	request: Request,
	results: Vec<WriteResult>,
	changes: Vec<Write>,
	server: &Server,
) -> Value {
	let outcome = json!({
		"results": results.iter().map(|r| json!({
			"status": r.status.name(), "v": r.v, "seq": r.seq,
		})).collect::<Vec<_>>(),
		"changes": changes.len(),
	});
	let response = Response::Sync {
		results,
		changes,
		next_seq: server.seq(),
		more: false,
	};

	json!({
		"name": format!("step{n}"),
		"step": n,
		"device": device,
		"explains": explains,
		"request": hx(&frame::encode_request(&request)),
		"response": hx(&frame::encode_response(&response)),
		"outcome": outcome,
	})
}

pub fn scenario() -> Value {
	let content_key = seq_bytes(CONTENT_KEY, 32);
	let blinded = note::blinded_id(&kdf::blinding_key(&content_key), &uuid_bytes());
	let a = Device {
		content_key: content_key.clone(),
		seed: DEVICE_A,
	};
	let b = Device {
		content_key,
		seed: DEVICE_B,
	};

	let mut server = Server::new(NOTE_MAX);
	let mut steps = Vec::new();

	let w = a.write(blinded, 1, &sample_note("written by A"));
	let result = server.apply(&w);
	steps.push(step(
		1,
		"A",
		"First write of a new note. storedV is 0, so v = 1 is accepted.",
		Request::Sync {
			since: 0,
			writes: vec![w],
		},
		vec![result],
		vec![],
		&server,
	));

	let w = b.write(blinded, 1, &sample_note("written by B"));
	let result = server.apply(&w);
	steps.push(step(
		2,
		"B",
		"B was offline and also produced v = 1. storedV is already 1, so the write is rejected and the server's current v is returned with seq 0.",
		Request::Sync { since: 0, writes: vec![w] },
		vec![result],
		vec![],
		&server,
	));

	steps.push(step(
		3,
		"B",
		"B pulls to see what it conflicted with. A's version arrives in memory; B's own version is still only on disk.",
		Request::Sync { since: 0, writes: vec![] },
		vec![],
		server.changes_since(0),
		&server,
	));

	let w = b.write(blinded, 2, &sample_note("written by B"));
	let result = server.apply(&w);
	steps.push(step(
		4,
		"B",
		"B resolves keep-mine: discard the in-memory server version and re-push at serverV + 1.",
		Request::Sync {
			since: 1,
			writes: vec![w],
		},
		vec![result],
		vec![],
		&server,
	));

	steps.push(step(
		5,
		"A",
		"A pulls from the seq it last saw and converges on B's version.",
		Request::Sync {
			since: 1,
			writes: vec![],
		},
		vec![],
		server.changes_since(1),
		&server,
	));

	let w = a.write(blinded, 3, &sample_tombstone());
	let result = server.apply(&w);
	steps.push(step(
		6,
		"A",
		"Deletion is an ordinary write at v + 1 carrying a sealed tombstone, so a forged delete fails to decrypt.",
		Request::Sync { since: 2, writes: vec![w] },
		vec![result],
		vec![],
		&server,
	));

	file(
		"End-to-end sync: concurrent v = 1 writes, conflict, keep-mine resolution, convergence, tombstone. Envelope framing is covered by envelope.json.",
		steps,
	)
}
