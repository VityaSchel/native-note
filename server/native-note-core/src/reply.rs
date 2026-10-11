use crate::frame::{ACTION_ERROR, Changes};
use crate::padding::{BODY_MAX, LEN_PREFIX, pad};
use crate::types::{Record, Seq};

const INNER_MAX: usize = BODY_MAX - LEN_PREFIX;
const EMPTY_SYNC_LEN: usize = 1 + 4 + 4 + 8 + 1;
const RESULT_LEN: usize = 1 + 4 + 8;
const CHANGE_HEADER_LEN: usize = 16 + 4 + 16 + 4;

pub struct Reply(pub(crate) Vec<u8>);

impl Reply {
	pub fn error() -> Reply {
		Reply(pad(&[ACTION_ERROR]).unwrap_or_default())
	}
}

#[derive(Debug, PartialEq, Eq)]
pub enum Fault<E> {
	Storage(E),
	SeqExhausted,
	Unanswerable,
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
