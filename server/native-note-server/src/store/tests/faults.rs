use super::{call, opened, state, sync, write};
use crate::log::{Cause, Failure};
use crate::store::{Rows, Store};
use native_note_core::{BlindedNoteId, Fault, Record, Request, Seq, Storage, Version, process};
use native_note_testkit::NOTE_MAX;
use native_note_testkit::client::{Response, Status};
use native_note_testkit::scratch::Scratch;
use rusqlite::ErrorCode;
use rusqlite::ffi::{self, SQLITE_IOERR};

struct Failing<'r, 'c> {
	rows: &'r mut Rows<'c>,
	fail_at: Option<usize>,
	calls: usize,
}

impl Failing<'_, '_> {
	fn call(&mut self) -> rusqlite::Result<()> {
		let call = self.calls;
		self.calls += 1;
		if self.fail_at == Some(call) {
			Err(rusqlite::Error::SqliteFailure(
				ffi::Error::new(SQLITE_IOERR),
				None,
			))
		} else {
			Ok(())
		}
	}
}

impl Storage for Failing<'_, '_> {
	type Error = rusqlite::Error;

	fn latest_seq(&mut self) -> rusqlite::Result<Seq> {
		self.call()?;
		self.rows.latest_seq()
	}

	fn note_version(&mut self, id: &BlindedNoteId) -> rusqlite::Result<Option<Version>> {
		self.call()?;
		self.rows.note_version(id)
	}

	fn store_note(&mut self, seq: Seq, record: &Record) -> rusqlite::Result<()> {
		self.call()?;
		self.rows.store_note(seq, record)
	}

	fn next_change(&mut self, after: Seq) -> rusqlite::Result<Option<(Seq, Record)>> {
		self.call()?;
		self.rows.next_change(after)
	}

	fn content_key(&mut self) -> rusqlite::Result<Option<(Version, Vec<u8>)>> {
		self.call()?;
		self.rows.content_key()
	}

	fn store_content_key(&mut self, v: Version, blob: &[u8]) -> rusqlite::Result<()> {
		self.call()?;
		self.rows.store_content_key(v, blob)
	}
}

fn storage_calls(store: &mut Store, request: &Request) -> usize {
	let mut calls = 0;
	let rolled_back = store.transact(|rows| {
		let mut failing = Failing {
			rows,
			fail_at: None,
			calls: 0,
		};
		process(&mut failing, request)?;
		calls = failing.calls;
		Err(Fault::Unanswerable)
	});
	assert_eq!(rolled_back.err(), Some(Failure::Unanswerable));
	calls
}

#[test]
fn a_storage_failure_at_any_call_of_any_action_rolls_the_whole_request_back() {
	let scratch = Scratch::new("faults");
	let (mut store, _) = opened(&scratch);
	let replica_scratch = Scratch::new("faults-replica");
	let (mut replica, _) = opened(&replica_scratch);
	let requests = [
		Request::Put {
			v: Version(1),
			blob: vec![1; 60],
		},
		sync(0, &[write(1, 1, 300), write(2, 1, 40), write(3, 1, 0)]),
		sync(
			3,
			&[
				write(1, 2, 500),
				write(2, 1, 41),
				write(4, 1, NOTE_MAX + 1),
				write(3, 2, 9),
			],
		),
		sync(5, &[write(5, 1, NOTE_MAX), write(6, 1, NOTE_MAX)]),
		sync(0, &[]),
		Request::Get,
		Request::Put {
			v: Version(2),
			blob: vec![2; 60],
		},
		Request::Put {
			v: Version(2),
			blob: vec![3; 60],
		},
	];
	let mut injected = 0;
	for (index, request) in requests.iter().enumerate() {
		let before = state(&store.0);
		let calls = storage_calls(&mut store, request);
		assert!(calls > 0, "request {index}");
		for fail_at in 0..calls {
			let failed = store.transact(|rows| {
				process(
					&mut Failing {
						rows,
						fail_at: Some(fail_at),
						calls: 0,
					},
					request,
				)
			});
			assert_eq!(
				failed.err(),
				Some(Failure::Storage(Cause::Sqlite(ErrorCode::SystemIoFailure))),
				"request {index}, call {fail_at}"
			);
			assert_eq!(state(&store.0), before, "request {index}, call {fail_at}");
			assert!(store.0.is_autocommit());
			injected += 1;
		}
		assert_eq!(
			call(&mut store, request),
			call(&mut replica, request),
			"request {index}"
		);
		assert_eq!(state(&store.0), state(&replica.0), "request {index}");
	}
	assert!(injected >= 40, "{injected} failures injected");
}

#[test]
fn a_full_disk_mid_request_rolls_it_back_and_a_retry_with_room_succeeds() {
	let scratch = Scratch::new("full");
	let (mut store, _) = opened(&scratch);
	call(
		&mut store,
		&sync(0, &[write(1, 1, 4000), write(2, 1, 4000)]),
	);
	let pages: i64 = store
		.0
		.pragma_query_value(None, "page_count", |row| row.get(0))
		.expect("counts pages");
	store
		.0
		.pragma_update(None, "max_page_count", pages)
		.expect("caps the database");
	let before = state(&store.0);
	let request = sync(2, &[write(3, 1, 50), write(4, 1, NOTE_MAX)]);
	assert_eq!(
		store.answer(&request).err(),
		Some(Failure::Storage(Cause::Sqlite(ErrorCode::DiskFull)))
	);
	assert_eq!(state(&store.0), before);
	assert!(store.0.is_autocommit());
	assert_eq!(
		call(&mut store, &Request::Get),
		Response::Get {
			v: Version(0),
			blob: Vec::new()
		}
	);

	store
		.0
		.pragma_update(None, "max_page_count", pages + 1024)
		.expect("makes room");
	let Response::Sync { results, .. } = call(&mut store, &request) else {
		panic!("a sync response");
	};
	assert!(
		results
			.iter()
			.all(|result| result.status == Status::Accepted)
	);
}
