pub mod aead;
pub mod codec;
pub mod content;
pub mod envelope;
pub mod frame;
pub mod hex;
pub mod kdf;
pub mod mnemonic;
pub mod note;
pub mod server;
pub mod vectors;

pub fn seq_bytes(start: u8, len: usize) -> Vec<u8> {
	(0..len).map(|i| start.wrapping_add(i as u8)).collect()
}

pub fn fixed<const N: usize>(start: u8) -> [u8; N] {
	seq_bytes(start, N).try_into().unwrap()
}
