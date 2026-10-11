use native_note_core::{Envelope, EnvelopeKey, Opened, Rejection};

pub use native_note_testkit::{BODY_MAX, NOTE_MAX, SEALED_MAX, client, corpus, session};

pub mod harness;
pub mod memory;
pub mod vectors;

pub fn open(key: &EnvelopeKey, body: Vec<u8>) -> Result<Opened, Rejection> {
	key.open(Envelope::parse(body)?)
}
