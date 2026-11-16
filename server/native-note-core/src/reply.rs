use crate::frame::{ACTION_ERROR, Changes};
use crate::padding::{BODY_MAX, LEN_PREFIX, pad};
use crate::types::{Record, Seq};

const INNER_MAX: usize = BODY_MAX - LEN_PREFIX;
const EMPTY_SYNC_LEN: usize = 1 + 4 + 4 + 8 + 1;
const RESULT_LEN: usize = 1 + 4;
const CHANGE_HEADER_LEN: usize = 16 + 4 + 16 + 4;

pub struct Reply(pub(crate) Vec<u8>);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reason {
	Malformed,
	Unsupported,
	Fault,
}

impl Reason {
	fn code(self) -> u8 {
		match self {
			Reason::Malformed => 0x01,
			Reason::Unsupported => 0x02,
			Reason::Fault => 0x03,
		}
	}
}

impl Reply {
	pub fn error(reason: Reason) -> Reply {
		Reply(pad(&[ACTION_ERROR, reason.code()]).unwrap_or_default())
	}
}

#[derive(Debug, PartialEq, Eq)]
pub enum Fault<E> {
	Storage(E),
	SeqExhausted,
	Unanswerable,
}

impl<E> Fault<E> {
	pub fn reason(&self) -> Reason {
		match self {
			Fault::Storage(_) | Fault::SeqExhausted | Fault::Unanswerable => Reason::Fault,
		}
	}
}

pub(crate) fn collect_changes<E>(
	results: usize,
	since: Seq,
	latest: Seq,
	mut next_change: impl FnMut(Seq) -> Result<Option<(Seq, Record)>, E>,
) -> Result<Changes, Fault<E>> {
	let mut used = RESULT_LEN
		.saturating_mul(results)
		.saturating_add(EMPTY_SYNC_LEN);
	let mut after = since;
	let mut records = Vec::new();
	while let Some((seq, record)) = next_change(after).map_err(Fault::Storage)? {
		used = used
			.saturating_add(CHANGE_HEADER_LEN)
			.saturating_add(record.payload.len());
		if used > INNER_MAX {
			return if records.is_empty() {
				Err(Fault::Unanswerable)
			} else {
				Ok(Changes {
					records,
					next_seq: after,
					more: true,
				})
			};
		}
		after = seq;
		records.push(record);
	}
	Ok(Changes {
		records,
		next_seq: latest,
		more: false,
	})
}

#[cfg(test)]
mod tests;
