use crate::codec::{Reader, Writer};
use crate::types::{BlindedNoteId, Record, Seq, Version};
use crate::version::Status;

const ACTION_SYNC: u8 = 0x01;
const ACTION_GET: u8 = 0x02;
const ACTION_PUT: u8 = 0x03;
pub(crate) const ACTION_ERROR: u8 = 0xff;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
	Sync { since: Seq, writes: Vec<Record> },
	Get,
	Put { v: Version, blob: Vec<u8> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodeError {
	Padding,
	Truncated,
	TrailingBytes,
	UnknownDiscriminant,
}

impl Request {
	pub fn decode(inner: &[u8]) -> Result<Request, DecodeError> {
		let mut reader = Reader::new(inner);
		let request = match reader.u8()? {
			ACTION_SYNC => Request::Sync {
				since: Seq(reader.u64()?),
				writes: records(&mut reader)?,
			},
			ACTION_GET => Request::Get,
			ACTION_PUT => Request::Put {
				v: Version(reader.u32()?),
				blob: reader.bytes()?.to_vec(),
			},
			_ => return Err(DecodeError::UnknownDiscriminant),
		};
		reader.finish()?;
		Ok(request)
	}
}

fn records(reader: &mut Reader) -> Result<Vec<Record>, DecodeError> {
	let count = reader.u32()?;
	let mut records = Vec::new();
	for _ in 0..count {
		records.push(Record {
			id: BlindedNoteId(reader.array()?),
			v: Version(reader.u32()?),
			write_id: reader.array()?,
			payload: reader.bytes()?.to_vec(),
		});
	}
	Ok(records)
}

impl Status {
	fn code(self) -> u8 {
		match self {
			Status::Accepted => 0x01,
			Status::Conflict => 0x02,
			Status::TooLarge => 0x03,
		}
	}
}

pub(crate) struct WriteResult {
	pub(crate) status: Status,
	pub(crate) v: Version,
	pub(crate) seq: Seq,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Changes {
	pub(crate) records: Vec<Record>,
	pub(crate) next_seq: Seq,
	pub(crate) more: bool,
}

pub(crate) fn sync_response(results: &[WriteResult], changes: &Changes) -> Vec<u8> {
	let mut writer = Writer::new();
	writer.u8(ACTION_SYNC).count(results.len());
	for result in results {
		writer
			.u8(result.status.code())
			.u32(result.v.0)
			.u64(result.seq.0);
	}
	writer.count(changes.records.len());
	for record in &changes.records {
		writer
			.raw(&record.id.0)
			.u32(record.v.0)
			.raw(&record.write_id)
			.bytes(&record.payload);
	}
	writer.u64(changes.next_seq.0).u8(u8::from(changes.more));
	writer.into_bytes()
}

pub(crate) fn get_response(v: Version, blob: &[u8]) -> Vec<u8> {
	let mut writer = Writer::new();
	writer.u8(ACTION_GET).u32(v.0).bytes(blob);
	writer.into_bytes()
}

pub(crate) fn put_response(status: Status, v: Version) -> Vec<u8> {
	let mut writer = Writer::new();
	writer.u8(ACTION_PUT).u8(status.code()).u32(v.0);
	writer.into_bytes()
}

#[cfg(test)]
mod tests;
