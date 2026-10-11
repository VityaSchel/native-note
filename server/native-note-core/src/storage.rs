use crate::types::{BlindedNoteId, Record, Seq, Version};

/// Every call runs inside the caller's transaction.
pub trait Storage {
	type Error;

	/// 0 when nothing was ever stored.
	fn latest_seq(&mut self) -> Result<Seq, Self::Error>;

	fn note_version(&mut self, id: &BlindedNoteId) -> Result<Option<Version>, Self::Error>;

	/// Upserts the note at `seq`, which is above every stored seq, and makes `seq` the latest.
	fn store_note(&mut self, seq: Seq, record: &Record) -> Result<(), Self::Error>;

	/// The current write with the smallest seq greater than `after`.
	fn next_change(&mut self, after: Seq) -> Result<Option<(Seq, Record)>, Self::Error>;

	/// The singleton recovery blob.
	fn content_key(&mut self) -> Result<Option<(Version, Vec<u8>)>, Self::Error>;

	fn store_content_key(&mut self, v: Version, blob: &[u8]) -> Result<(), Self::Error>;
}
