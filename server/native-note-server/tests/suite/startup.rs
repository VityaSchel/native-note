use crate::support::{Client, Recorder, api_key, call, mode, runtime, serve_at};
use native_note_core::{Request, Version};
use native_note_server::{Cause, Runtime, Server, Stage, run};
use native_note_testkit::client::Response;
use native_note_testkit::scratch::Scratch;
use std::ffi::OsString;
use std::fs;
use std::io::ErrorKind;
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::ExitCode;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

const KEY_TEXT: &str = "8b1e0c57d2a94f36e7b1c58d03a96f2e4c7b10d95e28a3f6b04c9d17e2a5f83c";

fn open(data: &Path, runtime: Runtime) -> Result<(), (Stage, Cause)> {
	Server::open("127.0.0.1:0".parse().expect("an address"), data, runtime).map(drop)
}

fn opened(data: &Path) -> (Result<(), (Stage, Cause)>, Vec<String>) {
	let log = Arc::new(Recorder::default());
	(open(data, runtime(&log)), log.lines())
}

#[test]
fn anything_but_a_listen_address_and_a_data_directory_prints_usage_and_exits_2() {
	let usage =
		"level=error event=usage expected=\"native-note-server <listen address> <data directory>\"";
	for args in [
		&[][..],
		&["127.0.0.1:8080"],
		&["127.0.0.1:8080", "/tmp/data", "extra"],
		&["localhost:8080", "/tmp/data"],
		&["8080", "/tmp/data"],
		&["127.0.0.1", "/tmp/data"],
	] {
		let log = Arc::new(Recorder::default());
		let code = run(args.iter().map(OsString::from), runtime(&log));
		assert_eq!(code, ExitCode::from(2), "{args:?}");
		assert_eq!(log.lines(), [usage], "{args:?}");
	}
}

#[test]
fn a_started_server_logs_its_key_file_and_address_then_answers_there() {
	let scratch = Scratch::new("startup-serves");
	let log = Arc::new(Recorder::default());
	let args = ["127.0.0.1:0".into(), scratch.path().as_os_str().to_owned()];
	let serving = runtime(&log);
	thread::spawn(move || run(args, serving));
	let started = Instant::now();
	while log.lines().len() < 2 && started.elapsed() < Duration::from_secs(10) {
		thread::sleep(Duration::from_millis(10));
	}
	let lines = log.lines();
	assert_eq!(
		lines[0],
		format!(
			"level=info event=api_key_created path={:?}",
			scratch.join("api-key")
		)
	);
	let address = lines[1]
		.strip_prefix("level=info event=listening address=127.0.0.1:")
		.and_then(|port| port.parse::<u16>().ok())
		.map(|port| ([127, 0, 0, 1], port).into())
		.unwrap_or_else(|| panic!("{lines:?}"));
	let mut client = Client::new(address, api_key(scratch.path()), 13);
	assert_eq!(
		call(&mut client, &Request::Get),
		Response::Get {
			v: Version(0),
			blob: Vec::new()
		}
	);
	assert_eq!(log.lines().len(), 2);
}

#[test]
fn a_startup_failure_logs_its_stage_and_cause_and_exits_1() {
	let scratch = Scratch::new("startup-run");
	let file = scratch.join("file");
	fs::write(&file, b"not a directory").expect("writes");
	let log = Arc::new(Recorder::default());
	let args = ["[::1]:0".into(), file.join("data").into_os_string()];
	assert_eq!(run(args, runtime(&log)), ExitCode::FAILURE);
	let lines = log.lines();
	assert_eq!(lines.len(), 1, "{lines:?}");
	assert!(
		lines[0].starts_with("level=error event=startup_failed stage=data_directory cause=io:"),
		"{lines:?}"
	);
}

#[test]
fn the_data_directory_is_created_owner_only_and_an_existing_one_is_left_as_it_is() {
	let scratch = Scratch::new("startup-dir");
	let data = scratch.join("a").join("b");
	assert_eq!(opened(&data).0, Ok(()));
	assert_eq!((mode(&scratch.join("a")), mode(&data)), (0o700, 0o700));

	let existing = scratch.join("existing");
	fs::create_dir(&existing).expect("creates");
	fs::set_permissions(&existing, fs::Permissions::from_mode(0o750)).expect("chmods");
	assert_eq!(opened(&existing).0, Ok(()));
	assert_eq!(mode(&existing), 0o750);
}

#[test]
fn the_first_start_writes_a_new_key_owner_only_and_logs_only_its_path() {
	let scratch = Scratch::new("startup-key");
	let (result, lines) = opened(scratch.path());
	assert_eq!(result, Ok(()));
	let path = scratch.join("api-key");
	assert_eq!(
		lines,
		[format!("level=info event=api_key_created path={path:?}")]
	);
	let text = fs::read_to_string(&path).expect("reads");
	assert_eq!(text.len(), 65);
	assert!(text.ends_with('\n'));
	assert!(
		text[..64]
			.bytes()
			.all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
	);
	assert_eq!(mode(&path), 0o600);
	assert_eq!(mode(&scratch.join("native-note.sqlite")), 0o600);
	assert!(!scratch.join("api-key.new").exists());
	assert!(!lines[0].contains(&text[..64]));

	let key = api_key(scratch.path());
	assert_eq!(opened(scratch.path()), (Ok(()), Vec::new()));
	assert_eq!(api_key(scratch.path()), key);
	let other = Scratch::new("startup-key-other");
	assert_eq!(opened(other.path()).0, Ok(()));
	assert_ne!(api_key(other.path()), key);
}

#[test]
fn a_temporary_key_left_by_a_crash_is_replaced_by_an_owner_only_one() {
	let scratch = Scratch::new("startup-stale");
	let stale = scratch.join("api-key.new");
	fs::write(&stale, KEY_TEXT).expect("leaves a temporary key");
	fs::set_permissions(&stale, fs::Permissions::from_mode(0o644)).expect("chmods");
	assert_eq!(opened(scratch.path()).0, Ok(()));
	assert_eq!(mode(&scratch.join("api-key")), 0o600);
	assert_ne!(
		fs::read_to_string(scratch.join("api-key")).expect("reads"),
		format!("{KEY_TEXT}\n")
	);
	assert!(!stale.exists());
}

#[test]
fn a_key_file_is_64_lowercase_hex_characters_with_surrounding_whitespace_trimmed() {
	let scratch = Scratch::new("startup-parse");
	let path = scratch.join("api-key");
	for text in [
		KEY_TEXT.to_owned(),
		format!("{KEY_TEXT}\n"),
		format!(" \t{KEY_TEXT}\r\n\n"),
	] {
		fs::write(&path, &text).expect("writes");
		assert_eq!(opened(scratch.path()), (Ok(()), Vec::new()), "{text:?}");
	}
	for text in [
		KEY_TEXT.to_uppercase(),
		KEY_TEXT[..63].to_owned(),
		format!("{KEY_TEXT}0"),
		format!("{}g", &KEY_TEXT[..63]),
		format!("{} {}", &KEY_TEXT[..32], &KEY_TEXT[32..]),
		format!("0x{}", &KEY_TEXT[..62]),
		String::new(),
	] {
		fs::write(&path, &text).expect("writes");
		assert_eq!(
			opened(scratch.path()).0,
			Err((Stage::ApiKey, Cause::Malformed)),
			"{text:?}"
		);
	}
	fs::remove_file(&path).expect("removes");
	fs::create_dir(&path).expect("puts a directory in its place");
	assert!(matches!(
		opened(scratch.path()).0,
		Err((Stage::ApiKey, Cause::Io(_)))
	));
}

#[test]
fn no_key_is_written_without_randomness_or_room_for_its_temporary_file() {
	let scratch = Scratch::new("startup-random");
	let log = Arc::new(Recorder::default());
	let mut broken = runtime(&log);
	broken.fill = |_| Err(ring::error::Unspecified);
	assert_eq!(
		open(scratch.path(), broken),
		Err((Stage::ApiKey, Cause::Random))
	);
	assert_eq!(fs::read_dir(scratch.path()).expect("lists").count(), 0);

	let blocked = scratch.join("blocked");
	fs::create_dir_all(blocked.join("api-key.new")).expect("puts a directory in the way");
	assert_eq!(
		opened(&blocked).0,
		Err((Stage::ApiKey, Cause::Io(ErrorKind::AlreadyExists)))
	);
	assert!(!blocked.join("api-key").exists());
	assert!(log.lines().is_empty());
}

#[test]
fn the_server_waits_10_s_per_socket_operation_and_60_s_per_connection() {
	let timing = Runtime::server().timing;
	assert_eq!(
		(timing.io, timing.deadline),
		(Duration::from_secs(10), Duration::from_secs(60))
	);
}

#[test]
fn a_damaged_database_or_a_taken_address_stops_startup() {
	let scratch = Scratch::new("startup-database");
	fs::write(scratch.join("api-key"), KEY_TEXT).expect("writes the key");
	fs::write(scratch.join("native-note.sqlite"), [0x5a; 4096]).expect("writes a non-database");
	assert_eq!(
		opened(scratch.path()).0,
		Err((
			Stage::Database,
			Cause::Sqlite(rusqlite::ErrorCode::NotADatabase)
		))
	);

	let fresh = Scratch::new("startup-listen");
	let taken = TcpListener::bind("127.0.0.1:0").expect("binds");
	let log = Arc::new(Recorder::default());
	assert_eq!(
		Server::open(
			taken.local_addr().expect("an address"),
			fresh.path(),
			runtime(&log)
		)
		.map(drop),
		Err((Stage::Listen, Cause::Io(ErrorKind::AddrInUse)))
	);
	assert_ne!(serve_at(fresh.path(), runtime(&log)).port(), 0);
}
