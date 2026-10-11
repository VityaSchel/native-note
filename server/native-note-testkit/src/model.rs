use crate::NOTE_MAX;
use crate::client::{INNER_MAX, Response, Status, WriteResult};
use native_note_core::{BlindedNoteId, Record, Seq, Version};
use std::collections::BTreeMap;
use std::ops::Bound;

const CHANGE_HEADER: usize = 16 + 4 + 16 + 4;

pub type View = BTreeMap<BlindedNoteId, (Version, [u8; 16])>;

pub struct Model {
	latest: Seq,
	notes: BTreeMap<BlindedNoteId, (Seq, &'static Record)>,
	by_seq: BTreeMap<Seq, &'static Record>,
	blob: Option<(Version, &'static [u8])>,
}

impl Default for Model {
	fn default() -> Self {
		Self {
			latest: Seq(0),
			notes: BTreeMap::new(),
			by_seq: BTreeMap::new(),
			blob: None,
		}
	}
}

fn follows(stored: Version, v: Version) -> bool {
	u64::from(v.0) == u64::from(stored.0) + 1
}

impl Model {
	pub fn latest(&self) -> Seq {
		self.latest
	}

	pub fn current(&self, id: &BlindedNoteId) -> (Seq, &'static Record) {
		self.notes[id]
	}

	pub fn view(&self) -> View {
		self.notes
			.iter()
			.map(|(&id, (_, write))| (id, (write.v, write.write_id)))
			.collect()
	}

	pub fn payload_bytes(&self) -> usize {
		self.by_seq.values().map(|write| write.payload.len()).sum()
	}

	pub fn judge(&self, write: &Record) -> WriteResult {
		let stored = self
			.notes
			.get(&write.id)
			.map_or(Version(0), |(_, current)| current.v);
		let status = if write.payload.len() > NOTE_MAX {
			Status::TooLarge
		} else if follows(stored, write.v) {
			Status::Accepted
		} else {
			Status::Conflict
		};
		match status {
			Status::Accepted => WriteResult {
				status,
				v: write.v,
				seq: Seq(self.latest.0 + 1),
			},
			_ => WriteResult {
				status,
				v: stored,
				seq: Seq(0),
			},
		}
	}

	pub fn apply(&mut self, write: &'static Record) -> WriteResult {
		let result = self.judge(write);
		if result.status == Status::Accepted {
			self.latest = result.seq;
			if let Some((old, _)) = self.notes.insert(write.id, (result.seq, write)) {
				self.by_seq.remove(&old);
			}
			self.by_seq.insert(result.seq, write);
		}
		result
	}

	pub fn check_changes(
		&self,
		since: Seq,
		changes: &[Record],
		next_seq: Seq,
		more: bool,
		inner_len: usize,
	) -> Vec<Seq> {
		let mut pending = self
			.by_seq
			.range((Bound::Excluded(since), Bound::Unbounded));
		let mut delivered = Vec::new();
		for change in changes {
			let (&seq, &current) = pending
				.next()
				.unwrap_or_else(|| panic!("a change past the latest after {since:?}"));
			assert!(change == current, "the change at {seq:?} is not current");
			delivered.push(seq);
		}
		match pending.next() {
			Some((_, next)) => {
				assert!(more, "changes left behind without more after {since:?}");
				assert_eq!(delivered.last(), Some(&next_seq), "since {since:?}");
				assert!(
					inner_len + CHANGE_HEADER + next.payload.len() > INNER_MAX,
					"a page of {inner_len} bytes stopped before a change that fits"
				);
			}
			None => {
				assert!(!more, "more with nothing left after {since:?}");
				assert_eq!(next_seq, self.latest, "since {since:?}");
			}
		}
		delivered
	}

	pub fn get(&self) -> Response {
		let (v, blob) = self.blob.unwrap_or((Version(0), &[]));
		Response::Get {
			v,
			blob: blob.to_vec(),
		}
	}

	pub fn judge_put(&self, v: Version) -> Response {
		let stored = self.blob.map_or(Version(0), |(stored, _)| stored);
		if follows(stored, v) {
			Response::Put {
				status: Status::Accepted,
				v,
			}
		} else {
			Response::Put {
				status: Status::Conflict,
				v: stored,
			}
		}
	}

	pub fn put(&mut self, v: Version, blob: &'static [u8]) -> Response {
		let response = self.judge_put(v);
		if matches!(
			response,
			Response::Put {
				status: Status::Accepted,
				..
			}
		) {
			self.blob = Some((v, blob));
		}
		response
	}
}
