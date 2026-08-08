use crate::codec::{DecodeError, Reader, Writer};

pub const VERSION: u8 = 0x01;

const KIND_NOTE: u8 = 0x01;
const KIND_TOMBSTONE: u8 = 0x02;

#[derive(Debug, PartialEq, Eq)]
pub enum Content {
	Note {
		uuid: [u8; 16],
		created_at: i64,
		updated_at: i64,
		body: String,
	},
	Tombstone {
		uuid: [u8; 16],
		deleted_at: i64,
	},
}

pub fn encode(content: &Content) -> Vec<u8> {
	let mut w = Writer::new();
	w.u8(VERSION);
	match content {
		Content::Note {
			uuid,
			created_at,
			updated_at,
			body,
		} => {
			w.u8(KIND_NOTE)
				.raw(uuid)
				.u64(*created_at as u64)
				.u64(*updated_at as u64)
				.bytes(body.as_bytes());
		}
		Content::Tombstone { uuid, deleted_at } => {
			w.u8(KIND_TOMBSTONE).raw(uuid).u64(*deleted_at as u64);
		}
	}
	w.into_bytes()
}

pub fn decode(input: &[u8]) -> Result<Content, DecodeError> {
	let mut r = Reader::new(input);
	if r.u8()? != VERSION {
		return Err(DecodeError::UnknownDiscriminant);
	}
	let content = match r.u8()? {
		KIND_NOTE => {
			let uuid = r.array()?;
			let created_at = r.u64()? as i64;
			let updated_at = r.u64()? as i64;
			let body =
				String::from_utf8(r.bytes()?.to_vec()).map_err(|_| DecodeError::NotCanonical)?;
			Content::Note {
				uuid,
				created_at,
				updated_at,
				body,
			}
		}
		KIND_TOMBSTONE => {
			let uuid = r.array()?;
			let deleted_at = r.u64()? as i64;
			Content::Tombstone { uuid, deleted_at }
		}
		_ => return Err(DecodeError::UnknownDiscriminant),
	};
	r.finish()?;
	Ok(content)
}

impl Content {
	pub fn uuid(&self) -> &[u8; 16] {
		match self {
			Content::Note { uuid, .. } | Content::Tombstone { uuid, .. } => uuid,
		}
	}

	pub fn is_tombstone(&self) -> bool {
		matches!(self, Content::Tombstone { .. })
	}
}
