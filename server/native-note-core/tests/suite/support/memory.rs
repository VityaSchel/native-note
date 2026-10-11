use native_note_core::{BlindedNoteId, Record, Seq, Storage, Version};
use std::collections::BTreeMap;
use std::fmt;
use std::ops::Bound;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Injected(pub usize);

#[derive(Clone, PartialEq, Eq)]
pub struct State {
	notes: BTreeMap<BlindedNoteId, (Seq, Record)>,
	by_seq: BTreeMap<Seq, BlindedNoteId>,
	latest: Seq,
	content_key: Option<(Version, Vec<u8>)>,
}

impl State {
	pub fn latest(&self) -> Seq {
		self.latest
	}

	fn upsert(&mut self, seq: Seq, record: Record) -> Option<(Seq, Record)> {
		let id = record.id;
		let replaced = self.notes.insert(id, (seq, record));
		if let Some((old, _)) = &replaced {
			self.by_seq.remove(old);
		}
		self.by_seq.insert(seq, id);
		replaced
	}

	fn undo(&mut self, undo: Undo) {
		match undo {
			Undo::Note {
				id,
				seq,
				replaced,
				latest,
			} => {
				self.by_seq.remove(&seq);
				match replaced {
					Some((old, record)) => {
						self.by_seq.insert(old, id);
						self.notes.insert(id, (old, record));
					}
					None => {
						self.notes.remove(&id);
					}
				}
				self.latest = latest;
			}
			Undo::ContentKey(previous) => self.content_key = previous,
		}
	}
}

impl fmt::Debug for State {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.debug_struct("State")
			.field("notes", &self.notes.len())
			.field("latest", &self.latest)
			.field(
				"content_key",
				&self.content_key.as_ref().map(|(v, blob)| (v, blob.len())),
			)
			.finish()
	}
}

enum Undo {
	Note {
		id: BlindedNoteId,
		seq: Seq,
		replaced: Option<(Seq, Record)>,
		latest: Seq,
	},
	ContentKey(Option<(Version, Vec<u8>)>),
}

#[derive(Clone)]
pub struct MemoryStorage {
	state: State,
	fail_next_at: Option<usize>,
	calls: usize,
	transactions: usize,
}

impl Default for MemoryStorage {
	fn default() -> Self {
		Self {
			state: State {
				notes: BTreeMap::new(),
				by_seq: BTreeMap::new(),
				latest: Seq(0),
				content_key: None,
			},
			fail_next_at: None,
			calls: 0,
			transactions: 0,
		}
	}
}

impl MemoryStorage {
	pub fn seed_note(&mut self, seq: Seq, record: Record) {
		self.state.upsert(seq, record);
		self.state.latest = self.state.latest.max(seq);
	}

	pub fn seed_content_key(&mut self, v: Version, blob: Vec<u8>) {
		self.state.content_key = Some((v, blob));
	}

	pub fn state(&self) -> &State {
		&self.state
	}

	pub fn fail_next_at(&mut self, call: usize) {
		self.fail_next_at = Some(call);
	}

	pub fn calls(&self) -> usize {
		self.calls
	}

	pub fn transactions(&self) -> usize {
		self.transactions
	}

	pub fn begin(&mut self) -> Transaction<'_> {
		self.calls = 0;
		self.transactions += 1;
		Transaction {
			fail_at: self.fail_next_at.take(),
			storage: self,
			journal: Vec::new(),
		}
	}
}

pub struct Transaction<'a> {
	storage: &'a mut MemoryStorage,
	fail_at: Option<usize>,
	journal: Vec<Undo>,
}

impl Transaction<'_> {
	pub fn commit(mut self) {
		self.journal.clear();
	}

	fn call(&mut self) -> Result<&mut State, Injected> {
		let call = self.storage.calls;
		self.storage.calls += 1;
		if self.fail_at == Some(call) {
			Err(Injected(call))
		} else {
			Ok(&mut self.storage.state)
		}
	}
}

impl Drop for Transaction<'_> {
	fn drop(&mut self) {
		while let Some(undo) = self.journal.pop() {
			self.storage.state.undo(undo);
		}
	}
}

impl Storage for Transaction<'_> {
	type Error = Injected;

	fn latest_seq(&mut self) -> Result<Seq, Injected> {
		Ok(self.call()?.latest)
	}

	fn note_version(&mut self, id: &BlindedNoteId) -> Result<Option<Version>, Injected> {
		Ok(self.call()?.notes.get(id).map(|(_, record)| record.v))
	}

	fn store_note(&mut self, seq: Seq, record: &Record) -> Result<(), Injected> {
		let state = self.call()?;
		let latest = state.latest;
		assert!(seq > latest, "{seq:?} is not above the latest {latest:?}");
		let replaced = state.upsert(seq, record.clone());
		state.latest = seq;
		self.journal.push(Undo::Note {
			id: record.id,
			seq,
			replaced,
			latest,
		});
		Ok(())
	}

	fn next_change(&mut self, after: Seq) -> Result<Option<(Seq, Record)>, Injected> {
		let state = self.call()?;
		Ok(state
			.by_seq
			.range((Bound::Excluded(after), Bound::Unbounded))
			.next()
			.map(|(&seq, id)| (seq, state.notes[id].1.clone())))
	}

	fn content_key(&mut self) -> Result<Option<(Version, Vec<u8>)>, Injected> {
		Ok(self.call()?.content_key.clone())
	}

	fn store_content_key(&mut self, v: Version, blob: &[u8]) -> Result<(), Injected> {
		let previous = self.call()?.content_key.replace((v, blob.to_vec()));
		self.journal.push(Undo::ContentKey(previous));
		Ok(())
	}
}
