use crate::key;
use crate::log::{Cause, Event, Failure, Log, Stage, Stderr};
use crate::seq_file::SeqFile;
use crate::store::Store;
use native_note_core::http::{self, HEAD_MAX, Status};
use native_note_core::{Envelope, EnvelopeKey, Reason, Rejection, Reply, Request};
use ring::error::Unspecified;
use ring::rand::{SecureRandom, SystemRandom};
use std::fs::DirBuilder;
use std::io::{self, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

const WORKERS: usize = 8;
const ACCEPT_RETRY: Duration = Duration::from_millis(100);
const DATABASE: &str = "native-note.sqlite";

pub type Fill = fn(&mut [u8]) -> Result<(), Unspecified>;

#[derive(Clone, Copy)]
pub struct Timing {
	pub socket_io_timeout: Duration,
	pub connection_deadline: Duration,
}

#[derive(Clone)]
pub struct Runtime {
	pub timing: Timing,
	pub fill: Fill,
	pub log: Arc<dyn Log>,
}

impl Runtime {
	pub fn server() -> Runtime {
		Runtime {
			timing: Timing {
				socket_io_timeout: Duration::from_secs(10),
				connection_deadline: Duration::from_secs(60),
			},
			fill: |bytes| SystemRandom::new().fill(bytes),
			log: Arc::new(Stderr),
		}
	}
}

pub struct Server {
	listener: TcpListener,
	address: SocketAddr,
	shared: Arc<Shared>,
}

struct Shared {
	key: EnvelopeKey,
	store: Mutex<Store>,
	runtime: Runtime,
}

impl Server {
	pub fn open(
		address: SocketAddr,
		data: &Path,
		runtime: Runtime,
	) -> Result<Server, (Stage, Cause)> {
		DirBuilder::new()
			.recursive(true)
			.mode(0o700)
			.create(data)
			.map_err(at(Stage::DataDirectory))?;
		let api_key =
			key::load_or_create(data, runtime.fill, &*runtime.log).map_err(at(Stage::ApiKey))?;
		let key = EnvelopeKey::derive(&api_key).ok_or((Stage::ApiKey, Cause::Malformed))?;
		let seq_file = SeqFile::load(data).map_err(at(Stage::Seq))?;
		let store = Store::open(&data.join(DATABASE), seq_file).map_err(at(Stage::Database))?;
		let listener = TcpListener::bind(address).map_err(at(Stage::Listen))?;
		let address = listener.local_addr().map_err(at(Stage::Listen))?;
		Ok(Server {
			listener,
			address,
			shared: Arc::new(Shared {
				key,
				store: Mutex::new(store),
				runtime,
			}),
		})
	}

	pub fn address(&self) -> SocketAddr {
		self.address
	}

	pub fn serve(self) -> Cause {
		let listener = Arc::new(self.listener);
		for _ in 1..WORKERS {
			let (listener, shared) = (Arc::clone(&listener), Arc::clone(&self.shared));
			if let Err(error) = thread::Builder::new().spawn(move || shared.work(&listener)) {
				return error.into();
			}
		}
		self.shared.work(&listener)
	}
}

fn at<E: Into<Cause>>(stage: Stage) -> impl FnOnce(E) -> (Stage, Cause) {
	move |error| (stage, error.into())
}

enum Refusal {
	Closed,
	Status(Status),
	Failed(Failure),
}

impl From<io::Error> for Refusal {
	fn from(_: io::Error) -> Refusal {
		Refusal::Closed
	}
}

impl From<Status> for Refusal {
	fn from(status: Status) -> Refusal {
		Refusal::Status(status)
	}
}

impl From<Rejection> for Refusal {
	fn from(rejection: Rejection) -> Refusal {
		Refusal::Status(rejection.into())
	}
}

impl Shared {
	fn work(&self, listener: &TcpListener) -> ! {
		loop {
			match listener.accept() {
				Ok((stream, _)) => self.handle(stream),
				Err(_) => thread::sleep(ACCEPT_RETRY),
			}
		}
	}

	fn handle(&self, stream: TcpStream) {
		let mut wire = Wire::new(stream, self.runtime.timing);
		match self.answer(&mut wire) {
			Ok(sealed) => {
				if let Err(error) = wire.send(&http::sealed_response_head(sealed.len()), &sealed) {
					self.fail(Failure::Respond(error.kind()));
				}
			}
			Err(Refusal::Status(status)) => {
				wire.send(status.response(), &[]).unwrap_or(());
				wire.close_without_reset();
			}
			Err(Refusal::Failed(failure)) => {
				self.fail(failure);
				wire.send(Status::ServerError.response(), &[]).unwrap_or(());
			}
			Err(Refusal::Closed) => {}
		}
	}

	fn answer(&self, wire: &mut Wire) -> Result<Vec<u8>, Refusal> {
		let opened = self.key.open(Envelope::parse(wire.read_request()?)?)?;
		let mut nonce = [0; 12];
		(self.runtime.fill)(&mut nonce).map_err(|_| Refusal::Failed(Failure::Random))?;
		let reply = match opened.request() {
			Ok(request) => self.transact(&request),
			Err(error) => {
				self.fail(Failure::Decode(error));
				Reply::error(error.reason())
			}
		};
		self.key
			.seal(reply, &opened.nonce(), nonce)
			.ok_or(Refusal::Failed(Failure::Seal))
	}

	fn transact(&self, request: &Request) -> Reply {
		let answer = self
			.store
			.lock()
			.unwrap_or_else(PoisonError::into_inner)
			.answer(request);
		answer.unwrap_or_else(|failure| {
			self.fail(failure);
			Reply::error(Reason::Fault)
		})
	}

	fn fail(&self, failure: Failure) {
		self.runtime.log.record(Event::RequestFailed { failure });
	}
}

struct Wire {
	stream: TcpStream,
	socket_io_timeout: Duration,
	deadline: Instant,
}

impl Wire {
	fn new(stream: TcpStream, timing: Timing) -> Wire {
		let now = Instant::now();
		Wire {
			stream,
			socket_io_timeout: timing.socket_io_timeout,
			deadline: now.checked_add(timing.connection_deadline).unwrap_or(now),
		}
	}

	fn budget(&self) -> io::Result<Duration> {
		let left = self.deadline.saturating_duration_since(Instant::now());
		if left.is_zero() {
			return Err(io::ErrorKind::TimedOut.into());
		}
		Ok(left.min(self.socket_io_timeout))
	}

	fn read(&mut self, buffer: &mut [u8]) -> Result<usize, Refusal> {
		self.stream.set_read_timeout(Some(self.budget()?))?;
		match self.stream.read(buffer)? {
			0 => Err(Refusal::Closed),
			count => Ok(count),
		}
	}

	fn read_request(&mut self) -> Result<Vec<u8>, Refusal> {
		let mut head = [0; HEAD_MAX];
		let mut filled = 0;
		let head_len = loop {
			let free = head.get_mut(filled..).unwrap_or_default();
			if free.is_empty() {
				return Err(Status::BadRequest.into());
			}
			filled = filled.saturating_add(self.read(free)?);
			if let Some(len) = http::head_len(head.get(..filled).unwrap_or_default()) {
				break len;
			}
		};
		let (head, early) = head
			.get(..filled)
			.and_then(|received| received.split_at_checked(head_len))
			.unwrap_or_default();
		let body_len = http::admitted_body_len(head)?;
		let mut body: Vec<u8> = early.iter().copied().take(body_len).collect();
		let mut filled = body.len();
		body.resize(body_len, 0);
		while let Some(free) = body.get_mut(filled..).filter(|free| !free.is_empty()) {
			filled = filled.saturating_add(self.read(free)?);
		}
		Ok(body)
	}

	fn close_without_reset(mut self) {
		self.stream.shutdown(Shutdown::Write).unwrap_or(());
		let mut discard = [0; HEAD_MAX];
		while self.read(&mut discard).is_ok() {}
	}

	fn send(&mut self, head: &[u8], body: &[u8]) -> io::Result<()> {
		self.stream.set_nodelay(true)?;
		for mut bytes in [head, body] {
			while !bytes.is_empty() {
				self.stream.set_write_timeout(Some(self.budget()?))?;
				let written = self.stream.write(bytes)?;
				bytes = bytes
					.get(written..)
					.filter(|_| written > 0)
					.ok_or(io::ErrorKind::WriteZero)?;
			}
		}
		Ok(())
	}
}
