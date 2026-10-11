use native_note_core::Request;
use native_note_server::{Event, Log, Runtime, Server, Timing};
use native_note_testkit::client::{self, Response};
use native_note_testkit::corpus::SplitMix64;
use native_note_testkit::scratch::Scratch;

pub use native_note_testkit::scratch::mode;
use native_note_testkit::session::Exchange;
use native_note_testkit::{SEALED_MAX, nonce_of};
use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub const IO: Duration = Duration::from_millis(600);
pub const DEADLINE: Duration = Duration::from_secs(2);

#[derive(Default)]
pub struct Recorder(Mutex<Vec<String>>);

impl Log for Recorder {
	fn record(&self, event: Event<'_>) {
		self.0.lock().expect("records").push(event.to_string());
	}
}

impl Recorder {
	pub fn lines(&self) -> Vec<String> {
		self.0.lock().expect("reads").clone()
	}

	pub fn take(&self) -> Vec<String> {
		std::mem::take(&mut *self.0.lock().expect("reads"))
	}
}

/// The server's own timing and randomness, logging to `log`.
pub fn runtime(log: &Arc<Recorder>) -> Runtime {
	Runtime {
		log: Arc::clone(log) as Arc<dyn Log>,
		..Runtime::server()
	}
}

/// Timeouts short enough for a test to wait them out.
pub fn hasty(log: &Arc<Recorder>) -> Runtime {
	Runtime {
		timing: Timing {
			io: IO,
			deadline: DEADLINE,
		},
		..runtime(log)
	}
}

pub fn api_key(data: &Path) -> [u8; 32] {
	client::read_api_key(&data.join("api-key"))
}

pub fn call(client: &mut Client, request: &Request) -> Response {
	call_inner(client, &client::encode_request(request))
}

pub fn call_inner(client: &mut Client, inner: &[u8]) -> Response {
	let body = client.seal(inner);
	client::decode_response(&client.post(&body))
}

pub struct Running {
	pub address: SocketAddr,
	pub key: [u8; 32],
	pub log: Arc<Recorder>,
	pub data: Scratch,
}

impl Running {
	pub fn client(&self, seed: u64) -> Client {
		Client::new(self.address, self.key, seed)
	}
}

pub fn serve_at(data: &Path, runtime: Runtime) -> SocketAddr {
	let server = Server::open("127.0.0.1:0".parse().expect("an address"), data, runtime)
		.unwrap_or_else(|(stage, cause)| panic!("starts: {stage} {cause}"));
	let address = server.address();
	thread::spawn(move || server.serve());
	address
}

pub fn start(name: &str) -> Running {
	let data = Scratch::new(name);
	let log = Arc::new(Recorder::default());
	let address = serve_at(data.path(), runtime(&log));
	let created = log.take();
	assert_eq!(created.len(), 1, "{created:?}");
	assert!(created[0].starts_with("level=info event=api_key_created path="));
	Running {
		address,
		key: api_key(data.path()),
		log,
		data,
	}
}

#[derive(Debug)]
pub struct Reply {
	pub status: u16,
	pub head: String,
	pub body: Vec<u8>,
}

pub fn connect(address: SocketAddr) -> TcpStream {
	let stream = TcpStream::connect(address).expect("connects");
	stream
		.set_read_timeout(Some(Duration::from_secs(30)))
		.expect("sets a timeout");
	stream
}

/// Reads until the server closes, which it does after every response.
pub fn read_reply(mut stream: TcpStream) -> Option<Reply> {
	let mut bytes = Vec::new();
	stream.read_to_end(&mut bytes).ok()?;
	if bytes.is_empty() {
		return None;
	}
	let end = bytes
		.windows(4)
		.position(|window| window == b"\r\n\r\n")
		.expect("a complete head")
		+ 4;
	let head = String::from_utf8(bytes[..end].to_vec()).expect("an ASCII head");
	let body = bytes[end..].to_vec();
	let status = head[9..12].parse().expect("a status code");
	assert!(head.starts_with("HTTP/1.1 "), "{head}");
	assert!(
		head.contains(&format!("\r\nContent-Length: {}\r\n", body.len())),
		"{head}"
	);
	assert!(head.contains("\r\nConnection: close\r\n"), "{head}");
	Some(Reply { status, head, body })
}

pub fn send(address: SocketAddr, bytes: &[u8]) -> Option<Reply> {
	let mut stream = connect(address);
	stream.write_all(bytes).expect("sends");
	stream.shutdown(Shutdown::Write).ok();
	read_reply(stream)
}

pub fn request(body: &[u8]) -> Vec<u8> {
	[
		format!(
			"POST / HTTP/1.1\r\nHost: notes.test\r\nContent-Length: {}\r\n\r\n",
			body.len()
		)
		.as_bytes(),
		body,
	]
	.concat()
}

pub fn post(address: SocketAddr, body: &[u8]) -> Reply {
	send(address, &request(body)).expect("a reply")
}

pub struct Client {
	address: SocketAddr,
	key: [u8; 32],
	nonces: SplitMix64,
}

impl Client {
	pub fn new(address: SocketAddr, api_key: [u8; 32], seed: u64) -> Client {
		Client {
			address,
			key: client::envelope_key(&api_key),
			nonces: SplitMix64::new(seed),
		}
	}

	pub fn open(&self, body: &[u8], reply: &Reply) -> Option<Vec<u8>> {
		assert_eq!(reply.status, 200, "{}", reply.head);
		assert!(reply.body.len() <= SEALED_MAX);
		assert_ne!(nonce_of(&reply.body), nonce_of(body));
		client::open_response(&self.key, &nonce_of(body), &reply.body)
	}
}

impl Exchange for Client {
	fn seal(&mut self, inner: &[u8]) -> Vec<u8> {
		client::seal_request(&self.key, self.nonces.array(), inner)
	}

	fn post(&mut self, body: &[u8]) -> Vec<u8> {
		let reply = post(self.address, body);
		self.open(body, &reply)
			.expect("the reply opens under the request nonce")
	}
}
