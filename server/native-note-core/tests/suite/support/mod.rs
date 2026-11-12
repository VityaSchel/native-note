use native_note_core::{Envelope, EnvelopeKey, Opened, Rejection, Secret};

pub use native_note_testkit::{BODY_MAX, NOTE_MAX, SEALED_MAX, client, corpus, session};

pub mod harness;
pub mod memory;
pub mod vectors;

pub fn server_key(api_key: [u8; 32]) -> EnvelopeKey {
	EnvelopeKey::derive(&Secret::new(api_key)).expect("a 32-byte key derives")
}

pub fn open(key: &EnvelopeKey, body: Vec<u8>) -> Result<Opened, Rejection> {
	key.open(Envelope::parse(body)?)
}
