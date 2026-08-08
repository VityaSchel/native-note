use std::collections::BTreeMap;

use crate::frame::{Status, Write, WriteResult};

pub type BlindedId = [u8; 16];

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
