use std::collections::BTreeMap;

use crate::frame::{Status, Write, WriteResult};
use crate::note::BlindedId;

struct Record {
	seq: u64,
	write: Write,
}

pub struct Server {
	notes: BTreeMap<BlindedId, Record>,
	seq: u64,
	note_max: usize,
}

impl Server {
	pub fn new(note_max: usize) -> Self {
		Self {
			notes: BTreeMap::new(),
			seq: 0,
			note_max,
		}
	}

	pub fn seq(&self) -> u64 {
		self.seq
	}

	pub fn apply(&mut self, write: &Write) -> WriteResult {
		let stored = self.notes.get(&write.blinded_id).map_or(0, |r| r.write.v);
		let reject = |status| WriteResult {
			blinded_id: write.blinded_id,
			status,
			v: stored,
			seq: 0,
		};

		if write.payload.len() > self.note_max {
			return reject(Status::TooLarge);
		}
		if stored == u32::MAX {
			return reject(Status::Exhausted);
		}
		if write.v != stored + 1 {
			return reject(Status::Conflict);
		}

		self.seq += 1;
		self.notes.insert(
			write.blinded_id,
			Record {
				seq: self.seq,
				write: write.clone(),
			},
		);
		WriteResult {
			blinded_id: write.blinded_id,
			status: Status::Accepted,
			v: write.v,
			seq: self.seq,
		}
	}

	pub fn changes_since(&self, since: u64) -> Vec<Write> {
		let mut pending: Vec<&Record> = self.notes.values().filter(|r| r.seq > since).collect();
		pending.sort_by_key(|r| r.seq);
		pending.into_iter().map(|r| r.write.clone()).collect()
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn a_note_at_the_last_version_accepts_no_further_writes() {
		let write = |v| Write {
			blinded_id: [7; 16],
			v,
			write_id: [1; 16],
			deleted: false,
			payload: vec![],
		};
		let mut server = Server::new(1024);
		server.seq = 1;
		server.notes.insert(
			[7; 16],
			Record {
				seq: 1,
				write: write(u32::MAX),
			},
		);

		for v in [0, 1, u32::MAX] {
			let result = server.apply(&write(v));
			assert_eq!(result.status, Status::Exhausted, "v {v}");
			assert_eq!(result.v, u32::MAX, "v {v}");
			assert_eq!(result.seq, 0, "v {v}");
		}
		assert_eq!(server.seq(), 1);
	}
}
