use serde_json::{Value, json};

use super::content::{
	CREATED_AT, UPDATED_AT, describe, sample_note, sample_note_as, sample_tombstone,
};
use super::{CONTENT_KEY, DEVICE_A, DEVICE_B, file, parse_uuid, seq_array, seq_bytes};
use crate::content::Content;
use crate::frame::{self, Request, Response, Write};
use crate::hex::encode as hx;
use crate::server::Server;
use crate::{content, kdf, note};

const COPY_UUID: &str = "5d2c8a71-4e6b-4f30-9c1d-a2b3c4d5e6f7";
const NEW_UUID: &str = "e4a1c7d2-9b3f-4a58-8c6e-1f2a3b4c5d6e";
const MINUTE: i64 = 60_000;

struct Device {
	seed: u8,
	writes: u8,
}

impl Device {
	fn new(seed: u8) -> Self {
		Self { seed, writes: 0 }
	}

	fn write(&mut self, v: u32, value: &Content) -> Sealed {
		self.writes += 1;
		let content_key = seq_bytes(CONTENT_KEY, 32);
		let blinded = note::blinded_id(&kdf::blinding_key(&content_key), value.uuid());
		let write_id: [u8; 16] = seq_array(self.seed.wrapping_add(self.writes));
		let nonce: [u8; 12] = seq_array(self.seed.wrapping_add(0x30).wrapping_add(self.writes));
		Sealed {
			write: Write {
				blinded_id: blinded,
				v,
				write_id,
				payload: note::seal(
					&content_key,
					&write_id,
					&nonce,
					&blinded,
					v,
					&content::encode(value),
				),
			},
			input: json!({
				"content": describe(value),
				"writeId": hx(&write_id),
				"nonce": hx(&nonce),
			}),
		}
	}
}

#[derive(Clone)]
struct Sealed {
	write: Write,
	input: Value,
}

fn step(
	server: &mut Server,
	n: u32,
	device: Option<&str>,
	explains: &str,
	since: u64,
	sealed: Vec<Sealed>,
) -> Value {
	let inputs: Vec<Value> = sealed.iter().map(|s| s.input.clone()).collect();
	let writes: Vec<Write> = sealed.into_iter().map(|s| s.write).collect();
	let (results, changes) = server.sync(since, &writes);
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
		"contentKey": hx(&seq_bytes(CONTENT_KEY, 32)),
		"writes": inputs,
		"request": hx(&frame::encode_request(&request)),
		"response": hx(&frame::encode_response(&response)),
		"outcome": outcome,
	})
}

pub fn scenario() -> Value {
	let mut a = Device::new(DEVICE_A);
	let mut b = Device::new(DEVICE_B);
	let mut server = Server::new();
	let first = a.write(1, &sample_note("written by A"));

	let mut steps = vec![
		step(
			&mut server,
			1,
			Some("A"),
			"First write of a new note. storedV is 0, so v = 1 is accepted. Changes are read after the writes, so the accepted write comes back.",
			0,
			vec![first.clone()],
		),
		step(
			&mut server,
			2,
			Some("B"),
			"B holds the same note unsynced at v = 0, as after importing the same export, and produced v = 1 offline. storedV is already 1, so the write is rejected with the server's current v and seq 0. The same response carries A's version, newer than B's unpushed edit, so B saves its own text as a new note under copyUuid, keeping its createdAt and updatedAt, and applies A's version.",
			0,
			vec![b.write(1, &sample_note("written by B"))],
		),
		step(
			&mut server,
			3,
			Some("B"),
			"B pushes the copy, a new note under a new UUID, at v = 1.",
			1,
			vec![b.write(1, &sample_note_as(parse_uuid(COPY_UUID), "written by B"))],
		),
		step(
			&mut server,
			4,
			Some("A"),
			"A pulls from the seq it last saw and gets B's copy. Both devices now hold both versions.",
			1,
			vec![],
		),
		step(
			&mut server,
			5,
			Some("A"),
			"Deletion is an ordinary write at v + 1 carrying a sealed tombstone, so a forged delete fails to decrypt.",
			2,
			vec![a.write(2, &sample_tombstone())],
		),
		step(
			&mut server,
			6,
			None,
			"Step 1's request arrives again, as a network replay, so no device builds it. storedV is 2, so the write is rejected, and the pull returns every current write, sealed to a key a replaying attacker lacks.",
			0,
			vec![first],
		),
		step(
			&mut server,
			7,
			Some("B"),
			"B pushes two notes in one request from the seq it last saw: a new note at v = 1, then an edit of the copy at v = 2. Writes apply in the order submitted, so their seqs follow that order, not blindedId order. The pull also brings A's tombstone, which removes the original on B.",
			2,
			vec![
				b.write(
					1,
					&Content::Note {
						uuid: parse_uuid(NEW_UUID),
						created_at: UPDATED_AT + MINUTE,
						updated_at: UPDATED_AT + MINUTE,
						body: "new on B".to_string(),
					},
				),
				b.write(
					2,
					&Content::Note {
						uuid: parse_uuid(COPY_UUID),
						created_at: CREATED_AT,
						updated_at: UPDATED_AT + 2 * MINUTE,
						body: "written by B, edited".to_string(),
					},
				),
			],
		),
	];
	steps[1]["copyUuid"] = json!(COPY_UUID);
	steps[5]["replays"] = json!("step1");

	file(
		"End-to-end sync: concurrent v = 1 writes, conflict, the losing edit kept as a new note, convergence, tombstone, replay, and two writes in one request. Steps run in order against one server; the content key is the same in every step. Envelope framing is covered by envelope.json.",
		steps,
	)
}
