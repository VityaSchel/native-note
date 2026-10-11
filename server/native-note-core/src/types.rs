#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct BlindedNoteId(pub [u8; 16]);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Version(pub u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Seq(pub u64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
	pub id: BlindedNoteId,
	pub v: Version,
	pub write_id: [u8; 16],
	pub payload: Vec<u8>,
}
