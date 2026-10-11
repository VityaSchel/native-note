use native_note_core::DecodeError;
use rusqlite::ErrorCode;
use std::fmt;
use std::io::{self, Write};
use std::net::SocketAddr;
use std::path::Path;

/// Every field is an address, an operator-given path or a fixed category, so no line can carry a
/// key, a request or a stored byte.
#[derive(Debug, PartialEq, Eq)]
pub enum Event<'a> {
	Usage,
	KeyCreated { path: &'a Path },
	Listening { address: SocketAddr },
	StartupFailed { stage: Stage, cause: Cause },
	RequestFailed { failure: Failure },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
	DataDirectory,
	ApiKey,
	Database,
	Listen,
	Workers,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cause {
	Io(io::ErrorKind),
	Sqlite(ErrorCode),
	Conversion,
	Damaged,
	NewerSchema,
	NoWal,
	Malformed,
	Random,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
	Decode(DecodeError),
	Storage(Cause),
	SeqExhausted,
	Unanswerable,
	Random,
	Seal,
	Respond(io::ErrorKind),
}

pub trait Log: Send + Sync {
	fn record(&self, event: Event<'_>);
}

pub struct Stderr;

impl Log for Stderr {
	fn record(&self, event: Event<'_>) {
		io::stderr()
			.lock()
			.write_all(format!("{event}\n").as_bytes())
			.unwrap_or(());
	}
}

impl From<io::Error> for Cause {
	fn from(error: io::Error) -> Cause {
		Cause::Io(error.kind())
	}
}

impl From<rusqlite::Error> for Cause {
	fn from(error: rusqlite::Error) -> Cause {
		error
			.sqlite_error_code()
			.map_or(Cause::Conversion, Cause::Sqlite)
	}
}

impl fmt::Display for Event<'_> {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Event::Usage => f.write_str(
				"level=error event=usage expected=\"native-note-server <listen address> <data directory>\"",
			),
			Event::KeyCreated { path } => {
				write!(f, "level=info event=api_key_created path={path:?}")
			}
			Event::Listening { address } => {
				write!(f, "level=info event=listening address={address}")
			}
			Event::StartupFailed { stage, cause } => {
				write!(
					f,
					"level=error event=startup_failed stage={stage} cause={cause}"
				)
			}
			Event::RequestFailed { failure } => {
				write!(f, "level=error event=request_failed failure={failure}")
			}
		}
	}
}

impl fmt::Display for Stage {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(match self {
			Stage::DataDirectory => "data_directory",
			Stage::ApiKey => "api_key",
			Stage::Database => "database",
			Stage::Listen => "listen",
			Stage::Workers => "workers",
		})
	}
}

impl fmt::Display for Cause {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Cause::Io(kind) => write!(f, "io:{kind:?}"),
			Cause::Sqlite(code) => write!(f, "sqlite:{code:?}"),
			Cause::Conversion => f.write_str("conversion"),
			Cause::Damaged => f.write_str("damaged"),
			Cause::NewerSchema => f.write_str("newer_schema"),
			Cause::NoWal => f.write_str("no_wal"),
			Cause::Malformed => f.write_str("malformed"),
			Cause::Random => f.write_str("random"),
		}
	}
}

impl fmt::Display for Failure {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Failure::Decode(error) => write!(f, "decode cause={error:?}"),
			Failure::Storage(cause) => write!(f, "storage cause={cause}"),
			Failure::SeqExhausted => f.write_str("seq_exhausted"),
			Failure::Unanswerable => f.write_str("unanswerable"),
			Failure::Random => f.write_str("random"),
			Failure::Seal => f.write_str("seal"),
			Failure::Respond(kind) => write!(f, "respond cause=io:{kind:?}"),
		}
	}
}
