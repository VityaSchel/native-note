use native_note_core::DecodeError;
use native_note_server::{Cause, Event, Failure, Stage};
use rusqlite::ErrorCode;
use std::io::ErrorKind;
use std::path::Path;

#[test]
fn each_event_is_one_line_of_fixed_keys_and_categories() {
	let cases = [
		(
			Event::KeyCreated {
				path: Path::new("/var/lib/native-note-server/api-key"),
			},
			"level=info event=api_key_created path=\"/var/lib/native-note-server/api-key\"",
		),
		(
			Event::Listening {
				address: "[::]:8080".parse().expect("an address"),
			},
			"level=info event=listening address=[::]:8080",
		),
		(
			Event::StartupFailed {
				stage: Stage::Workers,
				cause: Cause::Io(ErrorKind::WouldBlock),
			},
			"level=error event=startup_failed stage=workers cause=io:WouldBlock",
		),
		(
			Event::StartupFailed {
				stage: Stage::DataDirectory,
				cause: Cause::Io(ErrorKind::PermissionDenied),
			},
			"level=error event=startup_failed stage=data_directory cause=io:PermissionDenied",
		),
		(
			Event::StartupFailed {
				stage: Stage::ApiKey,
				cause: Cause::Malformed,
			},
			"level=error event=startup_failed stage=api_key cause=malformed",
		),
		(
			Event::StartupFailed {
				stage: Stage::ApiKey,
				cause: Cause::Random,
			},
			"level=error event=startup_failed stage=api_key cause=random",
		),
		(
			Event::StartupFailed {
				stage: Stage::Listen,
				cause: Cause::Io(ErrorKind::AddrInUse),
			},
			"level=error event=startup_failed stage=listen cause=io:AddrInUse",
		),
		(
			Event::StartupFailed {
				stage: Stage::Database,
				cause: Cause::Damaged,
			},
			"level=error event=startup_failed stage=database cause=damaged",
		),
		(
			Event::StartupFailed {
				stage: Stage::Database,
				cause: Cause::NewerSchema,
			},
			"level=error event=startup_failed stage=database cause=newer_schema",
		),
		(
			Event::StartupFailed {
				stage: Stage::Database,
				cause: Cause::Conversion,
			},
			"level=error event=startup_failed stage=database cause=conversion",
		),
		(
			Event::RequestFailed {
				failure: Failure::Storage(Cause::Sqlite(ErrorCode::DiskFull)),
			},
			"level=error event=request_failed failure=storage cause=sqlite:DiskFull",
		),
		(
			Event::RequestFailed {
				failure: Failure::Decode(DecodeError::Truncated),
			},
			"level=error event=request_failed failure=decode cause=Truncated",
		),
		(
			Event::RequestFailed {
				failure: Failure::Random,
			},
			"level=error event=request_failed failure=random",
		),
		(
			Event::RequestFailed {
				failure: Failure::Seal,
			},
			"level=error event=request_failed failure=seal",
		),
		(
			Event::RequestFailed {
				failure: Failure::SeqExhausted,
			},
			"level=error event=request_failed failure=seq_exhausted",
		),
		(
			Event::RequestFailed {
				failure: Failure::Unanswerable,
			},
			"level=error event=request_failed failure=unanswerable",
		),
		(
			Event::RequestFailed {
				failure: Failure::Respond(ErrorKind::ConnectionReset),
			},
			"level=error event=request_failed failure=respond cause=io:ConnectionReset",
		),
	];
	for (event, line) in cases {
		assert_eq!(event.to_string(), line);
	}
}

#[test]
fn a_sqlite_error_is_logged_by_its_code_and_a_value_out_of_range_as_a_conversion() {
	let busy = rusqlite::Error::SqliteFailure(
		rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
		Some("database is locked".to_owned()),
	);
	assert_eq!(Cause::from(busy), Cause::Sqlite(ErrorCode::DatabaseBusy));
	assert_eq!(
		Cause::from(rusqlite::Error::IntegralValueOutOfRange(0, -1)),
		Cause::Conversion
	);
	assert_eq!(
		Cause::from(std::io::Error::from(ErrorKind::NotFound)),
		Cause::Io(ErrorKind::NotFound)
	);
}
