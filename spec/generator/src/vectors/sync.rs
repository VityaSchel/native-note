use serde_json::{Value, json};

use super::content::{sample_note, sample_note_as, sample_tombstone};
use super::{CONTENT_KEY, DEVICE_A, DEVICE_B, file, parse_uuid, seq_array, seq_bytes};
use crate::content::Content;
use crate::frame::{self, Request, Response, Write, WriteResult};
use crate::hex::encode as hx;
use crate::server::Server;
use crate::{content, kdf, note};

const COPY_UUID: &str = "5d2c8a71-4e6b-4f30-9c1d-a2b3c4d5e6f7";

struct Device {
	content_key: Vec<u8>,
	seed: u8,
	writes: u8,
}

impl Device {
	fn new(content_key: &[u8], seed: u8) -> Self {
		Self {
			content_key: content_key.to_vec(),
			seed,
			writes: 0,
		}
	}

	fn write(&mut self, v: u32, value: &Content) -> Write {
		self.writes += 1;
		let blinded = note::blinded_id(&kdf::blinding_key(&self.content_key), value.uuid());
		let write_id: [u8; 16] = seq_array(self.seed.wrapping_add(self.writes));
		let nonce: [u8; 12] = seq_array(self.seed.wrapping_add(0x30).wrapping_add(self.writes));
		Write {
			blinded_id: blinded,
			v,
			write_id,
			payload: note::seal(
				&self.content_key,
				&write_id,
				&nonce,
				&blinded,
				v,
				&content::encode(value),
			),
		}
	}
}

fn step(
	server: &mut Server,
	n: u32,
	device: &str,
	explains: &str,
	since: u64,
	writes: Vec<Write>,
) -> Value {
	let results: Vec<WriteResult> = writes.iter().map(|w| server.apply(w)).collect();
	let changes = server.changes_since(since);
	let outcome = json!({
		"results": results.iter().map(|r| json!({
			"status": r.status.name(), "v": r.v, "seq": r.seq,
		})).collect::<Vec<_>>(),
		"changes": changes.len(),
	});
	let request = Request::Sync { since, writes };
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
	let mut a = Device::new(&content_key, DEVICE_A);
	let mut b = Device::new(&content_key, DEVICE_B);
	let mut server = Server::new();

	let steps = vec![
		step(
			&mut server,
			1,
			"A",
			"First write of a new note. storedV is 0, so v = 1 is accepted. Changes are read after the writes, so the accepted write comes back.",
			0,
			vec![a.write(1, &sample_note("written by A"))],
		),
		step(
			&mut server,
			2,
			"B",
			"B was offline and also produced v = 1. storedV is already 1, so the write is rejected with the server's current v and seq 0. The same response carries A's version, newer than B's unpushed edit, so B saves its own text as a new note and applies A's version.",
			0,
			vec![b.write(1, &sample_note("written by B"))],
		),
		step(
			&mut server,
			3,
			"B",
			"B pushes the copy, a new note under a new UUID, at v = 1.",
			1,
			vec![b.write(1, &sample_note_as(parse_uuid(COPY_UUID), "written by B"))],
		),
		step(
			&mut server,
			4,
			"A",
			"A pulls from the seq it last saw and gets B's copy. Both devices now hold both versions.",
			1,
			vec![],
		),
		step(
			&mut server,
			5,
			"A",
			"Deletion is an ordinary write at v + 1 carrying a sealed tombstone, so a forged delete fails to decrypt.",
			2,
			vec![a.write(2, &sample_tombstone())],
		),
	];

	file(
		"End-to-end sync: concurrent v = 1 writes, conflict, the losing edit kept as a new note, convergence, tombstone. Envelope framing is covered by envelope.json.",
		steps,
	)
}
