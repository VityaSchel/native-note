use super::SEALED_MAX;
use super::client::{self, Response};
use super::corpus::SplitMix64;
use super::memory::{Injected, MemoryStorage};
use native_note_core::{
	DecodeError, Envelope, EnvelopeKey, Fault, Rejection, Reply, Request, Secret, admit, process,
};

const NONCE_SEED: u64 = 0x6e6f_6e63_6573;

#[derive(Debug, PartialEq, Eq)]
pub enum Http {
	BadRequest,
	TooLarge,
	ServerError,
	Ok(Vec<u8>),
}

#[derive(Debug, PartialEq, Eq)]
pub enum Failure {
	Decode(DecodeError),
	Fault(Fault<Injected>),
}

pub struct Harness {
	key: EnvelopeKey,
	client_key: [u8; 32],
	nonces: SplitMix64,
	pub storage: MemoryStorage,
	pub failures: Vec<Failure>,
}

pub fn nonce_of(body: &[u8]) -> [u8; 12] {
	*body.first_chunk().expect("a body holds a nonce")
}

impl Harness {
	pub fn new(api_key: [u8; 32], storage: MemoryStorage) -> Self {
		Self {
			key: EnvelopeKey::derive(&Secret::new(api_key)).expect("a 32-byte key derives"),
			client_key: client::envelope_key(&api_key),
			nonces: SplitMix64::new(NONCE_SEED),
			storage,
			failures: Vec::new(),
		}
	}

	pub fn exchange(&mut self, body: Vec<u8>, response_nonce: [u8; 12]) -> Http {
		let opened = match admit(body.len())
			.and_then(|()| Envelope::parse(body))
			.and_then(|envelope| self.key.open(envelope))
		{
			Ok(opened) => opened,
			Err(Rejection::TooLarge) => return Http::TooLarge,
			Err(Rejection::Unopenable) => return Http::BadRequest,
		};
		let reply = match opened.request() {
			Ok(request) => self.transact(&request),
			Err(error) => {
				self.failures.push(Failure::Decode(error));
				Reply::error()
			}
		};
		self.key
			.seal(reply, &opened.nonce(), response_nonce)
			.map_or(Http::ServerError, Http::Ok)
	}

	fn transact(&mut self, request: &Request) -> Reply {
		let mut transaction = self.storage.begin();
		match process(&mut transaction, request) {
			Ok(reply) => {
				transaction.commit();
				reply
			}
			Err(fault) => {
				drop(transaction);
				self.failures.push(Failure::Fault(fault));
				Reply::error()
			}
		}
	}

	pub fn seal(&mut self, inner: &[u8]) -> Vec<u8> {
		client::seal_request(&self.client_key, self.nonces.array(), inner)
	}

	pub fn open(&self, request_nonce: &[u8; 12], reply: &[u8]) -> Option<Vec<u8>> {
		client::open_response(&self.client_key, request_nonce, reply)
	}

	pub fn post(&mut self, body: &[u8]) -> Vec<u8> {
		let response_nonce = self.nonces.array();
		let Http::Ok(reply) = self.exchange(body.to_vec(), response_nonce) else {
			panic!("a sealed request gets a sealed reply");
		};
		assert!(reply.len() <= SEALED_MAX, "{} bytes", reply.len());
		assert_eq!(nonce_of(&reply), response_nonce);
		self.open(&nonce_of(body), &reply)
			.expect("the reply opens under the request nonce")
	}

	pub fn send(&mut self, inner: &[u8]) -> Vec<u8> {
		let body = self.seal(inner);
		self.post(&body)
	}

	pub fn call(&mut self, request: &Request) -> Response {
		client::decode_response(&self.send(&client::encode_request(request)))
	}
}
