use std::collections::BTreeMap;

use crate::aead::NONCE_LEN;
use crate::envelope;
use crate::frame::{self, Request, Response, Status, Write, WriteResult};
use crate::note::BlindedId;

pub const NOTE_MAX: usize = 1024 * 1024;

struct Record {
	seq: u64,
	write: Write,
}

#[derive(Default)]
pub struct Server {
	notes: BTreeMap<BlindedId, Record>,
	seq: u64,
	recovery_v: u32,
	recovery_blob: Vec<u8>,
}

fn follows(stored: u32, v: u32) -> bool {
	stored.checked_add(1) == Some(v)
}

impl Server {
	pub fn new() -> Self {
		Self::default()
	}

	pub fn seq(&self) -> u64 {
		self.seq
	}

	pub fn apply(&mut self, write: &Write) -> WriteResult {
		let stored = self.notes.get(&write.blinded_id).map_or(0, |r| r.write.v);
		let reject = |status| WriteResult {
			status,
			v: stored,
			seq: 0,
		};

		if write.payload.len() > NOTE_MAX {
			return reject(Status::TooLarge);
		}
		if !follows(stored, write.v) {
			return reject(Status::Conflict);
		}

		WriteResult {
			status: Status::Accepted,
			v: write.v,
			seq: self.record(write.clone()),
		}
	}

	fn record(&mut self, write: Write) -> u64 {
		self.seq += 1;
		self.notes.insert(
			write.blinded_id,
			Record {
				seq: self.seq,
				write,
			},
		);
		self.seq
	}

	pub fn changes_since(&self, since: u64) -> Vec<Write> {
		let mut pending: Vec<&Record> = self.notes.values().filter(|r| r.seq > since).collect();
		pending.sort_by_key(|r| r.seq);
		pending.into_iter().map(|r| r.write.clone()).collect()
	}

	pub fn sync(&mut self, since: u64, writes: &[Write]) -> (Vec<WriteResult>, Vec<Write>) {
		let results = writes.iter().map(|write| self.apply(write)).collect();
		(results, self.changes_since(since))
	}

	pub fn handle(
		&mut self,
		envelope_key: &[u8],
		sealed: &[u8],
		response_nonce: &[u8; NONCE_LEN],
	) -> Option<Vec<u8>> {
		let request_nonce = sealed.first_chunk()?;
		let unpadded = envelope::open_request(envelope_key, sealed).ok()?;
		let response = match unpadded.and_then(|inner| frame::decode_request(&inner).ok()) {
			Some(Request::Sync { since, writes }) => {
				let (results, changes) = self.sync(since, &writes);
				Response::Sync {
					results,
					changes,
					next_seq: self.seq,
					more: false,
				}
			}
			Some(Request::GetRecovery) => self.get_recovery(),
			Some(Request::PutRecovery { v, blob }) => self.put_recovery(v, &blob),
			None => Response::Error,
		};
		let inner = frame::encode_response(&response);
		Some(
			envelope::seal_response(envelope_key, response_nonce, request_nonce, &inner)
				.expect("the reference never answers past the body limit"),
		)
	}

	pub fn recovery_blob(&self) -> &[u8] {
		&self.recovery_blob
	}

	pub fn get_recovery(&self) -> Response {
		Response::GetRecovery {
			v: self.recovery_v,
			blob: self.recovery_blob.clone(),
		}
	}

	pub fn put_recovery(&mut self, v: u32, blob: &[u8]) -> Response {
		if !follows(self.recovery_v, v) {
			return Response::PutRecovery {
				status: Status::Conflict,
				v: self.recovery_v,
			};
		}
		self.recovery_v = v;
		self.recovery_blob = blob.to_vec();
		Response::PutRecovery {
			status: Status::Accepted,
			v,
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn write(v: u32, size: usize) -> Write {
		Write {
			blinded_id: [7; 16],
			v,
			write_id: [1; 16],
			payload: vec![0; size],
		}
	}

	#[test]
	fn a_write_failing_both_checks_gets_too_large() {
		for (too_large, conflicts, expected) in [
			(false, false, Status::Accepted),
			(false, true, Status::Conflict),
			(true, false, Status::TooLarge),
			(true, true, Status::TooLarge),
		] {
			let mut server = Server::new();
			server.record(write(1, 0));
			let v = if conflicts { 1 } else { 2 };
			let size = if too_large { NOTE_MAX + 1 } else { NOTE_MAX };

			let result = server.apply(&write(v, size));
			assert_eq!(result.status, expected, "{too_large} {conflicts}");
			let seq = if expected == Status::Accepted { 2 } else { 1 };
			assert_eq!(server.seq(), seq, "{too_large} {conflicts}");
		}
	}

	#[test]
	fn a_note_at_the_last_version_accepts_no_further_writes() {
		let mut server = Server::new();
		server.record(write(u32::MAX, 0));

		for v in [0, 1, u32::MAX] {
			let result = server.apply(&write(v, 0));
			assert_eq!(result.status, Status::Conflict, "v {v}");
			assert_eq!(result.v, u32::MAX, "v {v}");
			assert_eq!(result.seq, 0, "v {v}");
		}
		assert_eq!(server.seq(), 1);
	}

	#[test]
	fn the_recovery_blob_follows_the_version_rule() {
		let mut server = Server::new();
		let held = |v: u32, blob: &[u8]| Response::GetRecovery {
			v,
			blob: blob.to_vec(),
		};
		let put = |status, v| Response::PutRecovery { status, v };

		assert_eq!(server.get_recovery(), held(0, &[]));
		assert_eq!(server.put_recovery(2, b"a"), put(Status::Conflict, 0));
		assert_eq!(server.put_recovery(1, b"a"), put(Status::Accepted, 1));
		assert_eq!(server.put_recovery(1, b"b"), put(Status::Conflict, 1));
		assert_eq!(server.get_recovery(), held(1, b"a"));

		server.recovery_v = u32::MAX;
		for v in [0, 1, u32::MAX] {
			assert_eq!(
				server.put_recovery(v, b"c"),
				put(Status::Conflict, u32::MAX),
				"v {v}"
			);
		}
		assert_eq!(server.get_recovery(), held(u32::MAX, b"a"));
	}
}
