use crate::frame::{self, Request, WriteResult};
use crate::padding::pad;
use crate::reply::{Fault, Reply, collect_changes};
use crate::storage::Storage;
use crate::types::{Record, Seq, Version};
use crate::version::{Status, put_status, write_status};

/// Runs inside one caller-held transaction: commit on `Ok`, then seal; on `Err`, roll back and
/// seal `Reply::error()`.
pub fn process<S: Storage>(storage: &mut S, request: &Request) -> Result<Reply, Fault<S::Error>> {
	let inner = match request {
		Request::Sync { since, writes } => sync(storage, *since, writes)?,
		Request::Get => {
			let (v, blob) = storage
				.content_key()
				.map_err(Fault::Storage)?
				.unwrap_or((Version(0), Vec::new()));
			frame::get_response(v, &blob)
		}
		Request::Put { v, blob } => put(storage, *v, blob)?,
	};
	pad(&inner).map(Reply).ok_or(Fault::Unanswerable)
}

fn sync<S: Storage>(
	storage: &mut S,
	since: Seq,
	writes: &[Record],
) -> Result<Vec<u8>, Fault<S::Error>> {
	let mut latest = storage.latest_seq().map_err(Fault::Storage)?;
	let mut results = Vec::new();
	for write in writes {
		results.push(apply(storage, &mut latest, write)?);
	}
	let changes = collect_changes(results.len(), since, latest, |after| {
		storage.next_change(after)
	})?;
	Ok(frame::sync_response(&results, &changes))
}

fn apply<S: Storage>(
	storage: &mut S,
	latest: &mut Seq,
	write: &Record,
) -> Result<WriteResult, Fault<S::Error>> {
	let stored = storage
		.note_version(&write.id)
		.map_err(Fault::Storage)?
		.unwrap_or(Version(0));
	match write_status(stored, write) {
		Status::Accepted => {
			let seq = latest
				.0
				.checked_add(1)
				.map(Seq)
				.ok_or(Fault::SeqExhausted)?;
			storage.store_note(seq, write).map_err(Fault::Storage)?;
			*latest = seq;
			Ok(WriteResult {
				status: Status::Accepted,
				v: write.v,
				seq,
			})
		}
		status => Ok(WriteResult {
			status,
			v: stored,
			seq: Seq(0),
		}),
	}
}

fn put<S: Storage>(storage: &mut S, v: Version, blob: &[u8]) -> Result<Vec<u8>, Fault<S::Error>> {
	let stored = storage
		.content_key()
		.map_err(Fault::Storage)?
		.map_or(Version(0), |(stored, _)| stored);
	match put_status(stored, v) {
		Status::Accepted => {
			storage.store_content_key(v, blob).map_err(Fault::Storage)?;
			Ok(frame::put_response(Status::Accepted, v))
		}
		status => Ok(frame::put_response(status, stored)),
	}
}
