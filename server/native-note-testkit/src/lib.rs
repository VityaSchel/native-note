pub mod client;
pub mod corpus;
pub mod model;
pub mod scenario;
pub mod scratch;
pub mod session;

pub const NOTE_MAX: usize = 1 << 20;
pub const BODY_MAX: usize = 2 << 20;
pub const SEALED_MAX: usize = BODY_MAX + 12 + 16;

pub fn nonce_of(body: &[u8]) -> [u8; 12] {
	*body.first_chunk().expect("a body holds a nonce")
}
