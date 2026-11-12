use crate::types::{BlindedNoteId, Record, Seq, Version};

pub trait Storage {
	type Error;

	fn latest_seq(&mut self) -> Result<Seq, Self::Error>;

	fn note_version(&mut self, id: &BlindedNoteId) -> Result<Option<Version>, Self::Error>;

	fn store_note(&mut self, seq: Seq, record: &Record) -> Result<(), Self::Error>;

	fn next_change(&mut self, after: Seq) -> Result<Option<(Seq, Record)>, Self::Error>;

	fn content_key(&mut self) -> Result<Option<(Version, Vec<u8>)>, Self::Error>;

	fn store_content_key(&mut self, v: Version, blob: &[u8]) -> Result<(), Self::Error>;
}
