use crate::codec::{DecodeError, Reader, Writer};
use crate::note::BlindedId;

const ACTION_SYNC: u8 = 0x01;
const ACTION_GET_RECOVERY: u8 = 0x02;
const ACTION_PUT_RECOVERY: u8 = 0x03;

const STATUS_ACCEPTED: u8 = 0x01;
const STATUS_CONFLICT: u8 = 0x02;
const STATUS_TOO_LARGE: u8 = 0x03;
const STATUS_EXHAUSTED: u8 = 0x04;
const STATUS_QUOTA: u8 = 0x05;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
	Accepted,
	Conflict,
	TooLarge,
	Exhausted,
	Quota,
}

impl Status {
	pub fn name(self) -> &'static str {
		match self {
			Status::Accepted => "accepted",
			Status::Conflict => "conflict",
			Status::TooLarge => "too_large",
			Status::Exhausted => "exhausted",
			Status::Quota => "quota",
		}
	}

	fn code(self) -> u8 {
		match self {
			Status::Accepted => STATUS_ACCEPTED,
			Status::Conflict => STATUS_CONFLICT,
			Status::TooLarge => STATUS_TOO_LARGE,
			Status::Exhausted => STATUS_EXHAUSTED,
			Status::Quota => STATUS_QUOTA,
		}
	}

	fn from_code(code: u8) -> Result<Self, DecodeError> {
		match code {
			STATUS_ACCEPTED => Ok(Status::Accepted),
			STATUS_CONFLICT => Ok(Status::Conflict),
			STATUS_TOO_LARGE => Ok(Status::TooLarge),
			STATUS_EXHAUSTED => Ok(Status::Exhausted),
			STATUS_QUOTA => Ok(Status::Quota),
			_ => Err(DecodeError::UnknownDiscriminant),
		}
	}
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Write {
	pub blinded_id: BlindedId,
	pub v: u32,
	pub write_id: [u8; 16],
	pub deleted: bool,
	pub payload: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WriteResult {
	pub blinded_id: BlindedId,
	pub status: Status,
	pub v: u32,
	pub seq: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
	Sync { since: u64, writes: Vec<Write> },
	GetRecovery,
	PutRecovery { v: u32, blob: Vec<u8> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Response {
	Sync {
		results: Vec<WriteResult>,
		changes: Vec<Write>,
		next_seq: u64,
		more: bool,
	},
	GetRecovery {
		v: u32,
		blob: Vec<u8>,
	},
	PutRecovery {
		status: Status,
		v: u32,
	},
}

fn put_write(w: &mut Writer, write: &Write) {
	w.raw(&write.blinded_id)
		.u32(write.v)
		.raw(&write.write_id)
		.bool(write.deleted)
		.bytes(&write.payload);
}

fn get_write(r: &mut Reader) -> Result<Write, DecodeError> {
	let blinded_id = r.array()?;
	let v = r.u32()?;
	let write_id = r.array()?;
	let deleted = r.bool()?;
	let payload = r.bytes()?.to_vec();
	Ok(Write {
		blinded_id,
		v,
		write_id,
		deleted,
		payload,
	})
}

fn get_all<T>(
	r: &mut Reader,
	item: fn(&mut Reader) -> Result<T, DecodeError>,
) -> Result<Vec<T>, DecodeError> {
	let count = r.u32()?;
	let mut out = Vec::new();
	for _ in 0..count {
		out.push(item(r)?);
	}
	Ok(out)
}

pub fn encode_request(request: &Request) -> Vec<u8> {
	let mut w = Writer::new();
	match request {
		Request::Sync { since, writes } => {
			w.u8(ACTION_SYNC).u64(*since).count(writes.len());
			for write in writes {
				put_write(&mut w, write);
			}
		}
		Request::GetRecovery => {
			w.u8(ACTION_GET_RECOVERY);
		}
		Request::PutRecovery { v, blob } => {
			w.u8(ACTION_PUT_RECOVERY).u32(*v).bytes(blob);
		}
	}
	w.into_bytes()
}

pub fn decode_request(input: &[u8]) -> Result<Request, DecodeError> {
	let mut r = Reader::new(input);
	let request = match r.u8()? {
		ACTION_SYNC => {
			let since = r.u64()?;
			let writes = get_all(&mut r, get_write)?;
			Request::Sync { since, writes }
		}
		ACTION_GET_RECOVERY => Request::GetRecovery,
		ACTION_PUT_RECOVERY => {
			let v = r.u32()?;
			let blob = r.bytes()?.to_vec();
			Request::PutRecovery { v, blob }
		}
		_ => return Err(DecodeError::UnknownDiscriminant),
	};
	r.finish()?;
	Ok(request)
}

pub fn encode_response(response: &Response) -> Vec<u8> {
	let mut w = Writer::new();
	match response {
		Response::Sync {
			results,
			changes,
			next_seq,
			more,
		} => {
			w.u8(ACTION_SYNC).count(results.len());
			for result in results {
				w.raw(&result.blinded_id)
					.u8(result.status.code())
					.u32(result.v)
					.u64(result.seq);
			}
			w.count(changes.len());
			for change in changes {
				put_write(&mut w, change);
			}
			w.u64(*next_seq).bool(*more);
		}
		Response::GetRecovery { v, blob } => {
			w.u8(ACTION_GET_RECOVERY).u32(*v).bytes(blob);
		}
		Response::PutRecovery { status, v } => {
			w.u8(ACTION_PUT_RECOVERY).u8(status.code()).u32(*v);
		}
	}
	w.into_bytes()
}

fn get_result(r: &mut Reader) -> Result<WriteResult, DecodeError> {
	let blinded_id = r.array()?;
	let status = Status::from_code(r.u8()?)?;
	let v = r.u32()?;
	let seq = r.u64()?;
	if status != Status::Accepted && seq != 0 {
		return Err(DecodeError::NotCanonical);
	}
	Ok(WriteResult {
		blinded_id,
		status,
		v,
		seq,
	})
}

pub fn decode_response(input: &[u8]) -> Result<Response, DecodeError> {
	let mut r = Reader::new(input);
	let response = match r.u8()? {
		ACTION_SYNC => {
			let results = get_all(&mut r, get_result)?;
			let changes = get_all(&mut r, get_write)?;
			let next_seq = r.u64()?;
			let more = r.bool()?;
			Response::Sync {
				results,
				changes,
				next_seq,
				more,
			}
		}
		ACTION_GET_RECOVERY => {
			let v = r.u32()?;
			let blob = r.bytes()?.to_vec();
			Response::GetRecovery { v, blob }
		}
		ACTION_PUT_RECOVERY => {
			let status = Status::from_code(r.u8()?)?;
			let v = r.u32()?;
			Response::PutRecovery { status, v }
		}
		_ => return Err(DecodeError::UnknownDiscriminant),
	};
	r.finish()?;
	Ok(response)
}
