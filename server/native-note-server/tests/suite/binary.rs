use crate::support::{Client, api_key, call, mode};
use native_note_core::{Record, Request, Seq, Version};
use native_note_testkit::client::{Response, Status};
use native_note_testkit::corpus::{payload, write};
use native_note_testkit::scratch::Scratch;
use std::fs;
use std::io::{BufRead, BufReader, ErrorKind};
use std::net::{SocketAddr, TcpStream};
use std::path::Path;
use std::process::{Child, ChildStderr, Command, Stdio};
use std::{panic, thread};

const BINARY: &str = env!("CARGO_BIN_EXE_native-note-server");

struct Process {
	child: Child,
	stderr: BufReader<ChildStderr>,
}

impl Process {
	fn start(data: &Path) -> Process {
		let mut child = Command::new(BINARY)
			.args(["127.0.0.1:0".as_ref(), data.as_os_str()])
			.stdin(Stdio::null())
			.stdout(Stdio::null())
			.stderr(Stdio::piped())
			.spawn()
			.expect("starts the server");
		let stderr = BufReader::new(child.stderr.take().expect("pipes stderr"));
		Process { child, stderr }
	}

	fn line(&mut self) -> String {
		let mut line = String::new();
		self.stderr.read_line(&mut line).expect("reads a log line");
		line
	}

	fn address(&mut self) -> SocketAddr {
		let line = self.line();
		line.strip_prefix("level=info event=listening address=")
			.and_then(|rest| {
				rest.trim_end()
					.strip_suffix(concat!(" version=", env!("CARGO_PKG_VERSION")))
			})
			.and_then(|address| address.parse().ok())
			.unwrap_or_else(|| panic!("not listening: {line:?}"))
	}

	fn kill(mut self) {
		self.child.kill().expect("kills the server");
		self.child.wait().expect("reaps it");
	}
}

impl Drop for Process {
	fn drop(&mut self) {
		self.child.kill().ok();
		self.child.wait().ok();
	}
}

#[test]
fn the_binary_survives_a_kill_with_every_answered_write_and_its_key() {
	let scratch = Scratch::new("binary");
	let data = scratch.join("data");
	let mut server = Process::start(&data);
	assert_eq!(
		server.line(),
		format!(
			"level=info event=api_key_created path={:?}\n",
			data.join("api-key")
		)
	);
	let mut client = Client::new(server.address(), api_key(&data), 11);
	let notes = [write(1, 1, 300), write(2, 1, 1 << 20), write(3, 1, 0)];
	let Response::Sync { results, .. } = call(
		&mut client,
		&Request::Sync {
			since: Seq(0),
			writes: notes.to_vec(),
		},
	) else {
		panic!("a sync response");
	};
	assert!(
		results
			.iter()
			.all(|result| result.status == Status::Accepted)
	);
	assert_eq!(
		call(
			&mut client,
			&Request::Put {
				v: Version(1),
				blob: vec![5; 60]
			}
		),
		Response::Put {
			status: Status::Accepted,
			v: Version(1)
		}
	);
	server.kill();
	assert_eq!((mode(&data), mode(&data.join("api-key"))), (0o700, 0o600));
	assert_eq!(mode(&data.join("native-note.sqlite")), 0o600);

	let mut server = Process::start(&data);
	let mut client = Client::new(server.address(), api_key(&data), 12);
	assert_eq!(
		call(
			&mut client,
			&Request::Sync {
				since: Seq(0),
				writes: Vec::new(),
			}
		),
		Response::Sync {
			results: Vec::new(),
			changes: notes.to_vec(),
			next_seq: Seq(3),
			more: false,
		}
	);
	assert_eq!(
		call(&mut client, &Request::Get),
		Response::Get {
			v: Version(1),
			blob: vec![5; 60]
		}
	);
	server.kill();
}

#[test]
fn a_test_that_unwinds_kills_its_server() {
	let scratch = Scratch::new("binary-unwound");
	let data = scratch.join("data");
	let unwound = thread::spawn(move || {
		let mut server = Process::start(&data);
		server.line();
		panic::resume_unwind(Box::new(server.address()));
	})
	.join()
	.expect_err("unwinds");
	let address = unwound.downcast::<SocketAddr>().expect("the address");
	assert_eq!(
		TcpStream::connect(*address).err().map(|error| error.kind()),
		Some(ErrorKind::ConnectionRefused)
	);
}

#[test]
fn the_binary_exits_2_on_usage_and_1_on_a_damaged_database_leaving_it_as_it_is() {
	let usage = Command::new(BINARY).output().expect("runs");
	assert_eq!(usage.status.code(), Some(2));
	assert_eq!(
		String::from_utf8_lossy(&usage.stderr),
		"level=error event=usage expected=\"native-note-server <listen address> <data directory>\"\n"
	);
	assert!(usage.stdout.is_empty());

	let scratch = Scratch::new("binary-damaged");
	let database = scratch.join("native-note.sqlite");
	fs::write(&database, payload(8192, 3)).expect("writes a non-database");
	let damaged = Command::new(BINARY)
		.args(["127.0.0.1:0".as_ref(), scratch.path().as_os_str()])
		.output()
		.expect("runs");
	assert_eq!(damaged.status.code(), Some(1));
	let stderr = String::from_utf8_lossy(&damaged.stderr);
	assert!(
		stderr.ends_with(
			"level=error event=startup_failed stage=database cause=sqlite:NotADatabase\n"
		),
		"{stderr}"
	);
	assert_eq!(fs::read(&database).expect("reads"), payload(8192, 3));
}

fn sync(since: u64, writes: &[Record]) -> Request {
	Request::Sync {
		since: Seq(since),
		writes: writes.to_vec(),
	}
}

fn new_notes(ids: std::ops::Range<u8>) -> Vec<Record> {
	ids.map(|id| write(id, 1, 32)).collect()
}

#[test]
fn a_database_restored_from_a_backup_numbers_new_writes_above_every_seq_handed_out() {
	let scratch = Scratch::new("binary-restore");
	let data = scratch.join("data");
	let backup = scratch.join("backup.sqlite");
	let database = data.join("native-note.sqlite");
	let mut server = Process::start(&data);
	server.line();
	let mut client = Client::new(server.address(), api_key(&data), 14);
	call(&mut client, &sync(0, &new_notes(0..100)));
	rusqlite::Connection::open(&database)
		.and_then(|connection| {
			connection.busy_timeout(std::time::Duration::from_secs(5))?;
			connection.execute("VACUUM INTO ?1", [backup.to_str().expect("UTF-8")])
		})
		.expect("backs up the live database at seq 100");
	let Response::Sync { next_seq, .. } = call(&mut client, &sync(100, &new_notes(100..150)))
	else {
		panic!("a sync response");
	};
	assert_eq!(next_seq, Seq(150));
	server.kill();

	for file in ["native-note.sqlite-wal", "native-note.sqlite-shm"] {
		fs::remove_file(data.join(file)).ok();
	}
	fs::copy(&backup, &database).expect("restores the backup");
	let mut server = Process::start(&data);
	let address = server.address();
	let mut writer = Client::new(address, api_key(&data), 15);
	let mut reader = Client::new(address, api_key(&data), 16);
	let pulled = |changes: Vec<Record>, next_seq| Response::Sync {
		results: Vec::new(),
		changes,
		next_seq: Seq(next_seq),
		more: false,
	};
	assert_eq!(call(&mut reader, &sync(150, &[])), pulled(Vec::new(), 150));
	let after = [write(200, 1, 32), write(201, 1, 32)];
	for (index, note) in after.iter().enumerate() {
		let Response::Sync {
			results, next_seq, ..
		} = call(&mut writer, &sync(150, std::slice::from_ref(note)))
		else {
			panic!("a sync response");
		};
		assert_eq!(results[0].status, Status::Accepted);
		assert_eq!(next_seq, Seq(151 + index as u64));
	}
	assert_eq!(
		call(&mut reader, &sync(150, &[])),
		pulled(after.to_vec(), 152)
	);
	assert_eq!(
		fs::read_to_string(data.join("seq")).expect("reads"),
		"152\n"
	);
	server.kill();
}
