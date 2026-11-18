use crate::support::{Client, Recorder, api_key, call, mode, runtime, send_to};
use native_note_core::{Request, Version};
use native_note_server::{Cause, Listen, Server, Stage, run};
use native_note_testkit::client::Response;
use native_note_testkit::scratch::Scratch;
use std::fs;
use std::io::ErrorKind;
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

const HEALTH_CHECK: &[u8] = b"POST / HTTP/1.1\r\nHost: notes.test\r\nContent-Length: 0\r\n\r\n";

fn serve_unix(socket: &Path, data: &Path) -> Result<Listen, (Stage, Cause)> {
	let log = Arc::new(Recorder::default());
	let server = Server::open(Listen::Unix(socket.to_owned()), data, runtime(&log))?;
	let address = server.address().clone();
	thread::spawn(move || server.serve());
	Ok(address)
}

#[test]
fn a_socket_path_serves_sealed_requests_and_lets_every_local_user_connect() {
	let scratch = Scratch::new("unix");
	let (socket, data) = (scratch.join("s"), scratch.join("d"));
	let log = Arc::new(Recorder::default());
	let args = [
		socket.clone().into_os_string(),
		data.clone().into_os_string(),
	];
	let serving = runtime(&log);
	thread::spawn(move || run(args, serving));
	let started = Instant::now();
	while log.lines().len() < 2 && started.elapsed() < Duration::from_secs(10) {
		thread::sleep(Duration::from_millis(10));
	}
	let lines = log.lines();
	assert_eq!(
		lines.get(1),
		Some(&format!("level=info event=listening address={socket:?}")),
		"{lines:?}"
	);
	assert_eq!(mode(&socket), 0o666);

	let address = Listen::Unix(socket);
	let mut client = Client::new(address.clone(), api_key(&data), 21);
	assert_eq!(
		call(&mut client, &Request::Get),
		Response::Get {
			v: Version(0),
			blob: Vec::new()
		}
	);
	assert_eq!(
		send_to(&address, HEALTH_CHECK).expect("a reply").status,
		400
	);
	assert_eq!(log.lines().len(), 2);
}

#[test]
fn a_socket_left_by_a_stopped_server_is_replaced_but_a_live_one_or_any_other_file_is_not() {
	let scratch = Scratch::new("unix-stale");
	let socket = scratch.join("s");
	drop(UnixListener::bind(&socket).expect("binds"));
	assert!(socket.exists());
	let address = serve_unix(&socket, &scratch.join("a")).expect("replaces the abandoned socket");
	assert_eq!(
		send_to(&address, HEALTH_CHECK).expect("a reply").status,
		400
	);

	assert_eq!(
		serve_unix(&socket, &scratch.join("b")).map(drop),
		Err((Stage::Listen, Cause::Io(ErrorKind::AddrInUse)))
	);
	assert_eq!(
		send_to(&address, HEALTH_CHECK)
			.expect("still answers")
			.status,
		400
	);

	let file = scratch.join("f");
	fs::write(&file, b"kept").expect("writes");
	assert_eq!(
		serve_unix(&file, &scratch.join("c")).map(drop),
		Err((Stage::Listen, Cause::Io(ErrorKind::AddrInUse)))
	);
	assert_eq!(fs::read(&file).expect("reads"), b"kept");
}

#[test]
fn a_socket_path_too_long_for_the_system_stops_startup() {
	let scratch = Scratch::new("unix-long");
	assert_eq!(
		serve_unix(&scratch.join(&"s".repeat(120)), &scratch.join("d")).map(drop),
		Err((Stage::Listen, Cause::Io(ErrorKind::InvalidInput)))
	);
}
