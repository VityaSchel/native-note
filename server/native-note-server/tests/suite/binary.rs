use crate::support::{Client, api_key, call, mode};
use native_note_core::{Request, Seq, Version};
use native_note_testkit::client::{Response, Status};
use native_note_testkit::corpus::{payload, write};
use native_note_testkit::scratch::Scratch;
use std::fs;
use std::io::{BufRead, BufReader};
use std::net::SocketAddr;
use std::path::Path;
use std::process::{Child, ChildStderr, Command, Stdio};

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
			.and_then(|address| address.trim_end().parse().ok())
			.unwrap_or_else(|| panic!("not listening: {line:?}"))
	}

	fn kill(mut self) {
		self.child.kill().expect("kills the server");
		self.child.wait().expect("reaps it");
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
