use super::{MIGRATIONS, Store};
use crate::log::{Cause, Failure};
use native_note_core::{BlindedNoteId, EnvelopeKey, Record, Reply, Request, Secret, Seq, Version};
use native_note_testkit::NOTE_MAX;
use native_note_testkit::client::{self, Response, Status, sync};
use native_note_testkit::corpus::{payload, write};
use native_note_testkit::scenario::result;
use native_note_testkit::scratch::{Scratch, mode};
use ring::digest::{SHA256, digest};
use rusqlite::{Connection, ErrorCode, OpenFlags};
use std::fs;
use std::thread;
use std::time::{Duration, Instant};

mod crash;
mod faults;

const API_KEY: [u8; 32] = [
	0x61, 0x0e, 0xd4, 0x2b, 0x97, 0x3c, 0xf5, 0x48, 0x1a, 0xc6, 0x7d, 0x02, 0xe9, 0x54, 0xb0, 0x8f,
	0x36, 0xa1, 0x5d, 0xf8, 0x0c, 0x73, 0xbe, 0x29, 0x84, 0xd7, 0x1f, 0x6a, 0xc2, 0x45, 0x9b, 0xe0,
];

type Row = (i64, Vec<u8>, i64, Vec<u8>, Vec<u8>);

#[derive(Debug, Clone, PartialEq, Eq)]
struct State {
	notes: Vec<Row>,
	content_key: Option<(i64, Vec<u8>)>,
}

fn state(connection: &Connection) -> State {
	let notes = connection
		.prepare("SELECT seq, blindedId, v, writeId, payload FROM note ORDER BY seq")
		.expect("prepares")
		.query_map([], |row| {
			let payload: Vec<u8> = row.get(4)?;
			Ok((
				row.get(0)?,
				row.get(1)?,
				row.get(2)?,
				row.get(3)?,
				digest(&SHA256, &payload).as_ref().to_vec(),
			))
		})
		.expect("queries")
		.collect::<Result<_, _>>()
		.expect("reads every note");
	let content_key = connection
		.prepare("SELECT v, blob FROM content_key")
		.expect("prepares")
		.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
		.expect("queries")
		.next()
		.transpose()
		.expect("reads the content key");
	State { notes, content_key }
}

fn decode(reply: Reply) -> Response {
	let key = EnvelopeKey::derive(&Secret::new(API_KEY)).expect("derives");
	let sealed = key.seal(reply, &[1; 12], [2; 12]).expect("seals");
	let inner =
		client::open_response(&client::envelope_key(&API_KEY), &[1; 12], &sealed).expect("opens");
	client::decode_response(&inner)
}

fn call(store: &mut Store, request: &Request) -> Response {
	decode(store.answer(request).expect("answers"))
}

fn pulled(changes: Vec<Record>, next_seq: u64) -> Response {
	Response::Sync {
		results: Vec::new(),
		changes,
		next_seq: Seq(next_seq),
		more: false,
	}
}

fn opened(scratch: &Scratch) -> (Store, std::path::PathBuf) {
	let path = scratch.join("native-note.sqlite");
	(Store::open(&path).expect("opens"), path)
}

#[test]
fn a_new_database_is_owner_only_strict_wal_with_full_sync_at_the_latest_schema() {
	let scratch = Scratch::new("schema");
	let (mut store, path) = opened(&scratch);
	call(&mut store, &sync(0, &[write(1, 1, 64)]));
	for file in [
		"native-note.sqlite",
		"native-note.sqlite-wal",
		"native-note.sqlite-shm",
	] {
		assert_eq!(mode(&scratch.join(file)), 0o600, "{file}");
	}
	let connection = &store.0;
	let pragma = |name: &str| -> String {
		connection
			.pragma_query_value(None, name, |row| row.get::<_, rusqlite::types::Value>(0))
			.map(|value| format!("{value:?}"))
			.expect("reads the pragma")
	};
	assert_eq!(pragma("journal_mode"), "Text(\"wal\")");
	assert_eq!(pragma("synchronous"), "Integer(2)");
	assert_eq!(pragma("busy_timeout"), "Integer(5000)");
	assert_eq!(
		pragma("user_version"),
		format!("Integer({})", MIGRATIONS.len())
	);
	let tables: Vec<(String, bool)> = connection
		.prepare("SELECT name, strict FROM pragma_table_list WHERE schema = 'main' AND name NOT LIKE 'sqlite_%' ORDER BY name")
		.expect("prepares")
		.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
		.expect("queries")
		.collect::<Result<_, _>>()
		.expect("lists tables");
	assert_eq!(
		tables,
		[("content_key".to_owned(), true), ("note".to_owned(), true)]
	);
	drop(store);
	assert_eq!(
		state(&Connection::open(&path).expect("opens")).notes.len(),
		1
	);
}

#[test]
fn reopening_keeps_every_note_and_the_blob_and_runs_no_migration_twice() {
	let scratch = Scratch::new("reopen");
	let (mut store, path) = opened(&scratch);
	let first = [write(1, 1, 300), write(2, 1, 0)];
	call(&mut store, &sync(0, &first));
	call(
		&mut store,
		&Request::Put {
			v: Version(1),
			blob: vec![7; 60],
		},
	);
	let before = state(&store.0);
	drop(store);
	let mut store = Store::open(&path).expect("reopens");
	assert_eq!(state(&store.0), before);
	assert_eq!(call(&mut store, &sync(0, &[])), pulled(first.to_vec(), 2));
	assert_eq!(
		call(&mut store, &Request::Get),
		Response::Get {
			v: Version(1),
			blob: vec![7; 60]
		}
	);
}

#[test]
fn a_database_from_a_newer_schema_is_refused_unchanged() {
	let scratch = Scratch::new("newer");
	let (store, path) = opened(&scratch);
	store
		.0
		.pragma_update(None, "user_version", MIGRATIONS.len() as i64 + 1)
		.expect("sets the version");
	drop(store);
	let bytes = fs::read(&path).expect("reads");
	assert_eq!(Store::open(&path).err(), Some(Cause::NewerSchema));
	assert_eq!(fs::read(&path).expect("reads"), bytes);
}

#[test]
fn a_database_that_fails_its_integrity_check_is_refused_unchanged() {
	let scratch = Scratch::new("damaged");
	let (mut store, path) = opened(&scratch);
	let writes: Vec<_> = (0..40).map(|id| write(id, 1, 200)).collect();
	call(&mut store, &sync(0, &writes));
	let (index_page, page_size): (i64, i64) = store
		.0
		.query_row(
			"SELECT rootpage, (SELECT page_size FROM pragma_page_size) FROM sqlite_schema WHERE name = 'sqlite_autoindex_note_2'",
			[],
			|row| Ok((row.get(0)?, row.get(1)?)),
		)
		.expect("finds the seq index");
	drop(store);
	assert!(!scratch.join("native-note.sqlite-wal").exists());

	let violated = Connection::open(&path).expect("opens");
	violated
		.execute_batch(
			"PRAGMA writable_schema = ON;
			UPDATE sqlite_schema SET sql = replace(sql, 'CHECK (v > 0)', 'CHECK (v > 1)') WHERE name = 'note';",
		)
		.expect("tightens a check the stored notes break");
	drop(violated);
	let bytes = fs::read(&path).expect("reads");
	assert_eq!(Store::open(&path).err(), Some(Cause::Damaged));
	assert_eq!(fs::read(&path).expect("reads"), bytes);

	let mut bytes = bytes;
	let start = usize::try_from((index_page - 1) * page_size).expect("fits");
	bytes[start..start + 16].fill(0);
	fs::write(&path, &bytes).expect("damages the index");
	assert_eq!(
		Store::open(&path).err(),
		Some(Cause::Sqlite(ErrorCode::DatabaseCorrupt))
	);
	assert_eq!(fs::read(&path).expect("reads"), bytes);

	fs::write(&path, payload(8192, 5)).expect("overwrites");
	assert_eq!(
		Store::open(&path).err(),
		Some(Cause::Sqlite(ErrorCode::NotADatabase))
	);
	assert_eq!(fs::read(&path).expect("reads"), payload(8192, 5));
}

#[test]
fn a_database_that_cannot_be_created_is_an_io_failure() {
	let scratch = Scratch::new("missing");
	let path = scratch.join("absent").join("native-note.sqlite");
	assert_eq!(
		Store::open(&path).err(),
		Some(Cause::Io(std::io::ErrorKind::NotFound))
	);
}

#[test]
fn every_outcome_of_each_action_is_answered_from_the_database() {
	let scratch = Scratch::new("actions");
	let (mut store, _) = opened(&scratch);
	assert_eq!(
		call(&mut store, &Request::Get),
		Response::Get {
			v: Version(0),
			blob: Vec::new()
		}
	);
	assert_eq!(
		call(
			&mut store,
			&Request::Put {
				v: Version(2),
				blob: vec![1; 60]
			}
		),
		Response::Put {
			status: Status::Conflict,
			v: Version(0)
		}
	);
	assert_eq!(
		call(
			&mut store,
			&Request::Put {
				v: Version(1),
				blob: vec![1; 60]
			}
		),
		Response::Put {
			status: Status::Accepted,
			v: Version(1)
		}
	);
	assert_eq!(
		call(
			&mut store,
			&Request::Put {
				v: Version(2),
				blob: vec![2; 60]
			}
		),
		Response::Put {
			status: Status::Accepted,
			v: Version(2)
		}
	);
	assert_eq!(
		call(&mut store, &Request::Get),
		Response::Get {
			v: Version(2),
			blob: vec![2; 60]
		}
	);

	let writes = [
		write(1, 1, 300),
		write(1, 2, NOTE_MAX),
		write(1, 2, 10),
		write(2, 1, NOTE_MAX + 1),
		write(3, 2, 10),
		write(3, 1, 0),
	];
	assert_eq!(
		call(&mut store, &sync(0, &writes)),
		Response::Sync {
			results: vec![
				result(Status::Accepted, 1, 1),
				result(Status::Accepted, 2, 2),
				result(Status::Conflict, 2, 0),
				result(Status::TooLarge, 0, 0),
				result(Status::Conflict, 0, 0),
				result(Status::Accepted, 1, 3),
			],
			changes: vec![writes[1].clone(), writes[5].clone()],
			next_seq: Seq(3),
			more: false,
		}
	);
	let large = [write(4, 1, NOTE_MAX), write(5, 1, NOTE_MAX)];
	let Response::Sync {
		changes,
		next_seq,
		more,
		..
	} = call(&mut store, &sync(3, &large))
	else {
		panic!("a sync response");
	};
	assert_eq!(
		(changes, next_seq, more),
		(vec![large[0].clone()], Seq(4), true)
	);
	assert_eq!(
		call(&mut store, &sync(4, &[])),
		pulled(vec![large[1].clone()], 5)
	);
	for since in [5, i64::MAX as u64, i64::MAX as u64 + 1, u64::MAX] {
		assert_eq!(
			call(&mut store, &sync(since, &[])),
			pulled(Vec::new(), 5),
			"{since}"
		);
	}
}

#[test]
fn a_seq_past_what_sqlite_holds_or_a_stored_value_out_of_range_answers_a_storage_failure() {
	let scratch = Scratch::new("ranges");
	let (mut store, _) = opened(&scratch);
	store
		.0
		.execute(
			"INSERT INTO note VALUES (?1, 1, ?2, ?3, x'')",
			rusqlite::params![[1_u8; 16], i64::MAX, [2_u8; 16]],
		)
		.expect("seeds the last seq");
	let before = state(&store.0);
	assert_eq!(
		store.answer(&sync(0, &[write(9, 1, 8)])).err(),
		Some(Failure::Storage(Cause::Conversion))
	);
	assert_eq!(state(&store.0), before);
	assert_eq!(
		call(&mut store, &sync(i64::MAX as u64, &[])),
		pulled(Vec::new(), i64::MAX as u64)
	);

	store
		.0
		.execute("UPDATE note SET v = ?1", [i64::from(u32::MAX) + 1])
		.expect("stores a v past u32");
	store
		.0
		.execute(
			"INSERT INTO content_key VALUES (1, ?1, x'00')",
			[i64::from(u32::MAX) + 1],
		)
		.expect("stores a blob v past u32");
	for request in [
		sync(i64::MAX as u64, &[write(1, 1, 8)]),
		sync(0, &[]),
		Request::Get,
	] {
		assert_eq!(
			store.answer(&request).err(),
			Some(Failure::Storage(Cause::Conversion))
		);
	}
	store
		.0
		.execute("DELETE FROM content_key", [])
		.expect("drops the blob");
	store
		.0
		.execute("UPDATE note SET v = 1, seq = 1", [])
		.expect("restores the note");
	store
		.0
		.execute("INSERT INTO content_key VALUES (1, ?1, x'00')", [-1])
		.expect_err("the schema refuses a v below 1");
	store
		.0
		.execute(
			"INSERT INTO note VALUES (x'00', 1, 2, ?1, x'')",
			[[0_u8; 16]],
		)
		.expect_err("the schema refuses a short id");
	assert_eq!(
		call(&mut store, &sync(0, &[])),
		pulled(
			vec![Record {
				id: BlindedNoteId([1; 16]),
				v: Version(1),
				write_id: [2; 16],
				payload: Vec::new(),
			}],
			1
		)
	);
}

#[test]
fn a_request_waits_for_another_connection_holding_the_write_lock() {
	let scratch = Scratch::new("busy");
	let (mut store, path) = opened(&scratch);
	let holder = thread::spawn(move || {
		let connection = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_WRITE)
			.expect("opens a second connection");
		connection
			.execute_batch("BEGIN IMMEDIATE")
			.expect("takes the write lock");
		thread::sleep(Duration::from_millis(400));
		connection.execute_batch("COMMIT").expect("releases it");
	});
	thread::sleep(Duration::from_millis(100));
	let started = Instant::now();
	assert_eq!(
		call(&mut store, &sync(0, &[write(1, 1, 8)])),
		Response::Sync {
			results: vec![result(Status::Accepted, 1, 1)],
			changes: vec![write(1, 1, 8)],
			next_seq: Seq(1),
			more: false,
		}
	);
	assert!(started.elapsed() >= Duration::from_millis(200));
	holder.join().expect("the holder finishes");
}
