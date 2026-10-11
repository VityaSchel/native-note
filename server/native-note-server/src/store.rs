use crate::log::{Cause, Failure};
use native_note_core::{
	BlindedNoteId, Fault, Record, Reply, Request, Seq, Storage, Version, process,
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use std::fs::OpenOptions;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::time::Duration;

const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

const MIGRATIONS: [&str; 1] = ["
	CREATE TABLE note (
		blindedId BLOB    PRIMARY KEY NOT NULL CHECK (length(blindedId) = 16),
		v         INTEGER NOT NULL CHECK (v > 0),
		seq       INTEGER NOT NULL UNIQUE CHECK (seq > 0),
		writeId   BLOB    NOT NULL CHECK (length(writeId) = 16),
		payload   BLOB    NOT NULL
	) STRICT;
	CREATE TABLE content_key (
		id   INTEGER PRIMARY KEY CHECK (id = 1),
		v    INTEGER NOT NULL CHECK (v > 0),
		blob BLOB    NOT NULL
	) STRICT;
"];

pub struct Store(Connection);

impl Store {
	/// Refuses a database that fails `integrity_check` before writing to it.
	pub fn open(path: &Path) -> Result<Store, Cause> {
		OpenOptions::new()
			.write(true)
			.create(true)
			.truncate(false)
			.mode(0o600)
			.open(path)?;
		let mut connection = Connection::open(path)?;
		connection.busy_timeout(BUSY_TIMEOUT)?;
		let report = connection
			.prepare("PRAGMA integrity_check")?
			.query_map([], |row| row.get::<_, String>(0))?
			.collect::<Result<Vec<_>, _>>()?;
		if report != ["ok"] {
			return Err(Cause::Damaged);
		}
		let mode: String =
			connection.pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get(0))?;
		if mode != "wal" {
			return Err(Cause::NoWal);
		}
		connection.pragma_update(None, "synchronous", "FULL")?;
		migrate(&mut connection)?;
		Ok(Store(connection))
	}

	pub fn answer(&mut self, request: &Request) -> Result<Reply, Failure> {
		self.transact(|rows| process(rows, request))
	}

	/// Commits only a reply; a fault, or a failed commit, rolls back as `Rows` drops.
	pub(crate) fn transact(
		&mut self,
		step: impl FnOnce(&mut Rows<'_>) -> Result<Reply, Fault<rusqlite::Error>>,
	) -> Result<Reply, Failure> {
		let mut rows = Rows(
			self.0
				.transaction_with_behavior(TransactionBehavior::Immediate)?,
		);
		let reply = step(&mut rows)?;
		rows.0.commit()?;
		Ok(reply)
	}
}

fn migrate(connection: &mut Connection) -> Result<(), Cause> {
	let applied: u32 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
	let pending = usize::try_from(applied)
		.ok()
		.and_then(|applied| MIGRATIONS.get(applied..))
		.ok_or(Cause::NewerSchema)?;
	for (migration, version) in pending.iter().zip(applied.saturating_add(1)..) {
		let transaction = connection.transaction()?;
		transaction.execute_batch(migration)?;
		transaction.pragma_update(None, "user_version", version)?;
		transaction.commit()?;
	}
	Ok(())
}

impl From<rusqlite::Error> for Failure {
	fn from(error: rusqlite::Error) -> Failure {
		Failure::Storage(error.into())
	}
}

impl From<Fault<rusqlite::Error>> for Failure {
	fn from(fault: Fault<rusqlite::Error>) -> Failure {
		match fault {
			Fault::Storage(error) => error.into(),
			Fault::SeqExhausted => Failure::SeqExhausted,
			Fault::Unanswerable => Failure::Unanswerable,
		}
	}
}

pub(crate) struct Rows<'c>(rusqlite::Transaction<'c>);

fn seq_column(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<Seq> {
	let value: i64 = row.get(index)?;
	u64::try_from(value)
		.map(Seq)
		.map_err(|_| rusqlite::Error::IntegralValueOutOfRange(index, value))
}

fn seq_param(seq: Seq) -> rusqlite::Result<i64> {
	i64::try_from(seq.0).map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))
}

fn record(row: &rusqlite::Row<'_>) -> rusqlite::Result<(Seq, Record)> {
	Ok((
		seq_column(row, 0)?,
		Record {
			id: BlindedNoteId(row.get(1)?),
			v: Version(row.get(2)?),
			write_id: row.get(3)?,
			payload: row.get(4)?,
		},
	))
}

impl Storage for Rows<'_> {
	type Error = rusqlite::Error;

	fn latest_seq(&mut self) -> rusqlite::Result<Seq> {
		self.0
			.query_row("SELECT COALESCE(MAX(seq), 0) FROM note", [], |row| {
				seq_column(row, 0)
			})
	}

	fn note_version(&mut self, id: &BlindedNoteId) -> rusqlite::Result<Option<Version>> {
		self.0
			.query_row("SELECT v FROM note WHERE blindedId = ?1", [id.0], |row| {
				row.get(0)
			})
			.optional()
			.map(|v| v.map(Version))
	}

	fn store_note(&mut self, seq: Seq, record: &Record) -> rusqlite::Result<()> {
		self.0
			.execute(
				"INSERT INTO note (blindedId, v, seq, writeId, payload) VALUES (?1, ?2, ?3, ?4, ?5)
				ON CONFLICT (blindedId) DO UPDATE
				SET v = excluded.v, seq = excluded.seq, writeId = excluded.writeId, payload = excluded.payload",
				params![
					record.id.0,
					record.v.0,
					seq_param(seq)?,
					record.write_id,
					record.payload
				],
			)
			.map(drop)
	}

	fn next_change(&mut self, after: Seq) -> rusqlite::Result<Option<(Seq, Record)>> {
		let Ok(after) = i64::try_from(after.0) else {
			return Ok(None);
		};
		self.0
			.query_row(
				"SELECT seq, blindedId, v, writeId, payload FROM note
				WHERE seq > ?1 ORDER BY seq LIMIT 1",
				[after],
				record,
			)
			.optional()
	}

	fn content_key(&mut self) -> rusqlite::Result<Option<(Version, Vec<u8>)>> {
		self.0
			.query_row("SELECT v, blob FROM content_key WHERE id = 1", [], |row| {
				Ok((Version(row.get(0)?), row.get(1)?))
			})
			.optional()
	}

	fn store_content_key(&mut self, v: Version, blob: &[u8]) -> rusqlite::Result<()> {
		self.0
			.execute(
				"INSERT INTO content_key (id, v, blob) VALUES (1, ?1, ?2)
				ON CONFLICT (id) DO UPDATE SET v = excluded.v, blob = excluded.blob",
				params![v.0, blob],
			)
			.map(drop)
	}
}

#[cfg(test)]
mod tests;
