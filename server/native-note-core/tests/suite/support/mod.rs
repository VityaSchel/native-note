use native_note_core::{Envelope, EnvelopeKey, Opened, Rejection};

pub mod client;
pub mod corpus;
pub mod harness;
pub mod memory;
pub mod model;
pub mod session;
pub mod vectors;

pub const NOTE_MAX: usize = 1 << 20;
pub const BODY_MAX: usize = 2 << 20;
pub const SEALED_MAX: usize = BODY_MAX + 12 + 16;

pub fn open(key: &EnvelopeKey, body: Vec<u8>) -> Result<Opened, Rejection> {
	key.open(Envelope::parse(body)?)
}
